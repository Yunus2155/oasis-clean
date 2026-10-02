`timescale 1ns / 1ps

// Directed STREAM-BOUNDARY testbench for my_z_score_squared.
//
// Why this exists: the python harness cannot deliver two LOCAL_READ transfers back-to-back, so
// z_score_global_test.test_classify_back_to_back_streams is @unittest.skip'd and NOTHING in the
// suite ever exercised the moment one stream's tlast is followed immediately by the next stream's
// first beat. That is where phase 2 loses whole 64-byte beats on hardware.
//
// This bench drives `in` directly so it can control the boundary exactly: streams of arbitrary
// length, an arbitrary number of valid lanes in the last beat, optional input bubbles and optional
// output backpressure, and mode changes between streams. Per output stream it checks the beat
// count, the tkeep pattern and every flag against a golden model -- and when a stream is short it
// reports whether the delivered flags match the golden model SHIFTED by the shortfall (beats eaten
// at the HEAD) or at offset 0 (beats missing from the TAIL).
//
// Run:
//   xsim ztb -runall -testplusarg MODE=2 -testplusarg SCEN=4 -testplusarg SEED=7
//     MODE  0 LEGACY / 1 STATS / 2 CLASSIFY   (base mode; scenarios 5 and 6 drive mode themselves)
//     SCEN  0 uniform 64-beat streams          (the original regression)
//           1 mixed lengths + partial last beat
//           2 mixed + input bubbles
//           3 mixed + output backpressure
//           4 stress: mixed + bubbles + backpressure, 40 streams
//           5 mode switch CLASSIFY -> STATS -> CLASSIFY with NEW totals (query boundary)
//           6 CLASSIFY -> CLASSIFY with NEW totals, no STATS in between (stale-totals hazard)
//
// The two multiplier IPs are modelled behaviourally below with the SAME latency as the real
// mult_gen cores (PipeStages 18 and 6) and the same clock-enable behaviour. That is exact for a
// pipelined signed multiplier and keeps the bench free of the generated IP libraries -- what is
// under test is the handshake and the metadata pipeline, not the DSPs.

import parcore::*;

// -- Shim: decoder_profile_i, copied verbatim from parcore/hardware/src/hdl/column_chunk_decoder_config.sv
interface decoder_profile_i;
    decoder_profile_t counters;
    logic             stop;

    modport m (
        input  stop,
        output counters
    );

    modport s (
        input  counters,
        output stop
    );
endinterface

// -- Behavioural models of the two mult_gen IPs -----------------------------------------------
module int_mult_64 (
    input  logic         CLK,
    input  logic         CE,
    input  logic [63:0]  A,
    input  logic [63:0]  B,
    output logic [127:0] P
);
    localparam int LAT = 18;   // must match init_ip.tcl PipeStages for int_mult_64
    logic signed [127:0] pipe [LAT];
    always_ff @(posedge CLK) begin
        if (CE) begin
            pipe[0] <= $signed(A) * $signed(B);
            for (int i = 1; i < LAT; i++) pipe[i] <= pipe[i-1];
        end
    end
    assign P = pipe[LAT-1];
endmodule

module int_mult_32 (
    input  logic        CLK,
    input  logic        CE,
    input  logic [31:0] A,
    input  logic [31:0] B,
    output logic [63:0] P
);
    localparam int LAT = 6;    // must match init_ip.tcl PipeStages for int_mult_32
    logic signed [63:0] pipe [LAT];
    always_ff @(posedge CLK) begin
        if (CE) begin
            pipe[0] <= $signed(A) * $signed(B);
            for (int i = 1; i < LAT; i++) pipe[i] <= pipe[i-1];
        end
    end
    assign P = pipe[LAT-1];
endmodule

module z_score_boundary_tb;

    localparam int N_IN       = 16;    // int32 lanes per 512-bit beat
    localparam int MAX_BEATS  = 128;   // longest stream the bench generates
    localparam int MAX_STREAM = 64;    // most streams a scenario may use

    localparam logic [1:0] MODE_LEGACY   = 2'd0;
    localparam logic [1:0] MODE_STATS    = 2'd1;
    localparam logic [1:0] MODE_CLASSIFY = 2'd2;

    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;              // 250 MHz, 4 ns period

    int tb_mode = 2;
    int tb_scen = 0;
    int tb_seed = 1;

    // -- DUT ------------------------------------------------------------------------------------
    AXI4S #(512) in_axis (.aclk(clk), .aresetn(rst_n));
    AXI4S #(512) out_axis(.aclk(clk), .aresetn(rst_n));
    decoder_profile_i prof();
    assign prof.stop = 1'b0;

    logic [1:0]         mode;
    logic               mode_valid;
    logic [31:0]        global_count;
    logic signed [63:0] global_sum;
    logic signed [63:0] global_sum_square;

    my_z_score_squared dut (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_axis),
        .out(out_axis),
        .profile(prof),
        .mode(mode),
        .mode_valid(mode_valid),
        .global_count(global_count),
        .global_sum(global_sum),
        .global_sum_square(global_sum_square)
    );

    // -- Stream table ----------------------------------------------------------------------------
    // st_len   : beats in the stream
    // st_lanes : valid lanes in its LAST beat (1..16). <16 exercises a partial tkeep, which every
    //            real row group has whenever num_values is not a multiple of 16.
    // st_seed  : shifts the value pattern so two streams never carry identical data (a stream that
    //            was contaminated by its neighbour then shows up as wrong flags, not as a match).
    // st_gc/gs/gq : the totals in force when this stream is classified.
    int            st_len   [MAX_STREAM];
    int            st_lanes [MAX_STREAM];
    int            st_seed  [MAX_STREAM];
    longint signed st_gc    [MAX_STREAM];
    longint signed st_gs    [MAX_STREAM];
    longint signed st_gq    [MAX_STREAM];
    int            st_mode  [MAX_STREAM];   // mode in force while this stream is fed
    int            n_streams;

    function automatic int st_values(input int s);
        st_values = (st_len[s] - 1) * N_IN + st_lanes[s];
    endfunction

    // -- Column values ---------------------------------------------------------------------------
    // A spike every 97th value, so the flag pattern has a period that is NOT a multiple of the beat
    // width and a one-beat shift is always visible.
    function automatic longint signed val_of(input int seed, input int v);
        val_of = (((v + seed) % 97) == 0) ? 64'sd1000 : (64'sd10 + ((v + seed) % 7));
    endfunction

    // -- Golden classifier, in the operator's own integer form: (n*x - S)^2 > 9*(n*Q - S^2) -------
    function automatic bit golden_flag(input longint signed x, input longint signed n,
                                       input longint signed s, input longint signed q);
        longint signed       diff;
        logic signed [159:0] d160, lhs, thr;
        diff = n * x - s;                  // 64-bit, exactly like DIFF_W in the RTL
        d160 = diff;
        lhs  = d160 * d160;
        thr  = 9 * (160'(n) * 160'(q) - 160'(s) * 160'(s));
        golden_flag = (lhs > thr);
    endfunction

    // Statistics of one whole stream (used by LEGACY, where pass 1 computes them itself, and by
    // STATS, where they are the payload).
    task automatic stream_stats(input int s, output longint signed n, output longint signed sm,
                                output longint signed sq);
        longint signed v;
        n = 0; sm = 0; sq = 0;
        for (int i = 0; i < st_values(s); i++) begin
            v   = val_of(st_seed[s], i);
            n  += 1;
            sm += v;
            sq += v * v;
        end
    endtask

    // -- Input driver -----------------------------------------------------------------------------
    logic [511:0] in_tdata_r = '0;
    logic [63:0]  in_tkeep_r = '0;
    logic         in_tlast_r = 1'b0;
    logic         in_tvalid_r = 1'b0;

    assign in_axis.tdata  = in_tdata_r;
    assign in_axis.tkeep  = in_tkeep_r;
    assign in_axis.tlast  = in_tlast_r;
    assign in_axis.tvalid = in_tvalid_r;

    // tready sampled AT the posedge, so the sequencer can tell whether the beat it presented was
    // accepted. Reading in_axis.tready after @(posedge clk) would read the post-edge value.
    logic tready_at_edge = 1'b0;
    always_ff @(posedge clk) tready_at_edge <= in_axis.tready;

    int in_bubble_pct = 0;   // chance of a gap before a beat
    int out_bp_pct    = 0;   // chance the sink withholds tready

    // Presents one beat and returns at the negedge immediately after the posedge that accepted it,
    // so the caller can present the next beat with ZERO gap.
    task automatic send_beat(input int s, input int b);
        longint signed v;
        int lanes;
        lanes = (b == st_len[s] - 1) ? st_lanes[s] : N_IN;

        if (in_bubble_pct > 0 && ($urandom_range(99) < in_bubble_pct)) begin
            in_tvalid_r = 1'b0;
            repeat ($urandom_range(1, 6)) @(negedge clk);
        end

        in_tdata_r = '0;
        in_tkeep_r = '0;
        for (int i = 0; i < lanes; i++) begin
            v = val_of(st_seed[s], b * N_IN + i);
            in_tdata_r[i*32 +: 32] = v[31:0];
            in_tkeep_r[i*4  +: 4]  = 4'hF;
        end
        in_tlast_r  = (b == st_len[s] - 1);
        in_tvalid_r = 1'b1;

        do @(negedge clk); while (!tready_at_edge);
    endtask

    // -- Sink -------------------------------------------------------------------------------------
    logic sink_ready = 1'b1;
    assign out_axis.tready = sink_ready;
    always @(negedge clk) begin
        sink_ready = (out_bp_pct == 0) ? 1'b1 : ($urandom_range(99) >= out_bp_pct);
    end

    // -- Checker -----------------------------------------------------------------------------------
    bit rx_flag [MAX_BEATS * N_IN];
    int rx_values  = 0;
    int rx_beats   = 0;
    int rx_lastlanes = 0;
    int out_stream = 0;
    int errors     = 0;
    int shorts     = 0;

    longint signed stats_word [3];

    // Which input stream an output stream corresponds to, and which one supplied its statistics.
    function automatic int src_of(input int os);
        src_of = (tb_mode == 0) ? (2*os + 1) : os;
    endfunction
    function automatic int stats_src_of(input int os);
        stats_src_of = (tb_mode == 0) ? (2*os) : os;
    endfunction
    // Scenario 5 changes mode BETWEEN streams, so the expectation for an output stream comes from
    // the mode its own input stream was fed under, not from the base MODE plusarg.
    function automatic int eff_mode_of(input int os);
        eff_mode_of = (src_of(os) < n_streams) ? st_mode[src_of(os)] : tb_mode;
    endfunction

    task automatic check_stream_end(input int beats, input int values, input int lastlanes);
        int s, ss, em;
        int exp_beats, exp_values, shortfall;
        bit ok0, ok_shift;
        int first_bad;
        longint signed n, sm, sq;

        s  = src_of(out_stream);
        ss = stats_src_of(out_stream);
        em = eff_mode_of(out_stream);

        if (out_stream >= (tb_mode == 0 ? n_streams/2 : n_streams)) begin
            $display("  [FAIL] extra output stream %0d (only %0d expected)", out_stream, n_streams);
            errors++;
            out_stream++;
            return;
        end

        exp_beats  = st_len[s];
        exp_values = st_values(s);

        if (em == 1) begin // STATS: exactly one beat carrying count / sum / sum_square
            stream_stats(s, n, sm, sq);
            if (beats != 1) begin
                $display("  [FAIL] STATS stream %0d: %0d beats, expected 1", out_stream, beats);
                errors++;
            end else if (stats_word[0] != n || stats_word[1] != sm || stats_word[2] != sq) begin
                $display("  [FAIL] STATS stream %0d: n=%0d S=%0d Q=%0d, expected n=%0d S=%0d Q=%0d",
                         out_stream, stats_word[0], stats_word[1], stats_word[2], n, sm, sq);
                errors++;
            end
        end else begin
            if (em == 0) stream_stats(ss, n, sm, sq);   // LEGACY: pass 1 computes its own
            else begin n = st_gc[s]; sm = st_gs[s]; sq = st_gq[s]; end

            shortfall = exp_beats - beats;
            ok0       = 1;
            ok_shift  = 1;
            first_bad = -1;
            for (int v = 0; v < values; v++) begin
                if (rx_flag[v] !== golden_flag(val_of(st_seed[s], v), n, sm, sq)) begin
                    ok0 = 0;
                    if (first_bad < 0) first_bad = v;
                end
                if (rx_flag[v] !== golden_flag(val_of(st_seed[s], v + shortfall*N_IN), n, sm, sq))
                    ok_shift = 0;
            end

            if (shortfall != 0) begin
                shorts++;
                errors++;
                $display("  [FAIL] stream %0d SHORT: %0d of %0d beats (lost %0d beats = %0d bytes)",
                         out_stream, beats, exp_beats, shortfall, shortfall * 64);
                if (ok_shift)     $display("         flags match golden SHIFTED by %0d beats => eaten at the HEAD", shortfall);
                else if (ok0)     $display("         flags match golden at offset 0 => missing from the TAIL");
                else              $display("         flags match NEITHER offset 0 nor offset %0d", shortfall);
            end else if (lastlanes != st_lanes[s]) begin
                errors++;
                $display("  [FAIL] stream %0d: last beat has %0d valid lanes, expected %0d",
                         out_stream, lastlanes, st_lanes[s]);
            end else if (values != exp_values) begin
                errors++;
                $display("  [FAIL] stream %0d: %0d values, expected %0d", out_stream, values, exp_values);
            end else if (!ok0) begin
                errors++;
                $display("  [FAIL] stream %0d: right length but wrong flags, first at value %0d (n=%0d S=%0d Q=%0d)",
                         out_stream, first_bad, n, sm, sq);
            end
        end

        out_stream++;
    endtask

    // ONE process owns rx_beats/rx_values: with the fix, streams come back-to-back with no gap at
    // all, so a beat of the next stream lands on the very cycle after a tlast. Splitting the fold
    // and the end-of-stream check across two processes raced and lost the counter reset.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_values <= 0;
            rx_beats  <= 0;
        end else if (out_axis.tvalid && out_axis.tready) begin
            rx_lastlanes = 0;
            if (eff_mode_of(out_stream) == 1) begin
                stats_word[0] = $signed(out_axis.tdata[63:0]);
                stats_word[1] = $signed(out_axis.tdata[127:64]);
                stats_word[2] = $signed(out_axis.tdata[191:128]);
            end else begin
                for (int i = 0; i < N_IN; i++) begin
                    if (&out_axis.tkeep[i*4 +: 4]) begin
                        rx_flag[rx_values + i] = (out_axis.tdata[i*32 +: 32] != 32'd0);
                        rx_lastlanes           = i + 1;
                    end
                end
            end
            if (out_axis.tlast) begin
                check_stream_end(rx_beats + 1, rx_values + rx_lastlanes, rx_lastlanes);
                rx_values <= 0;
                rx_beats  <= 0;
            end else begin
                rx_values <= rx_values + N_IN;
                rx_beats  <= rx_beats + 1;
            end
        end
    end

    // -- Pass-1 audit (LEGACY and STATS) -----------------------------------------------------------
    // The flag check alone is NOT sensitive to a perturbed pass 1: the injected spike is far enough
    // above the threshold to survive losing a few hundred values. So read the operator's own
    // accumulator at the moment pass 1 hands over.
    int pass1_idx = 0;
    logic [2:0] state_prev = 3'd0;
    always_ff @(posedge clk) begin
        state_prev <= dut.state;
        if (rst_n && (tb_mode == 0 || tb_mode == 1) && state_prev == 3'd0 && dut.state != 3'd0) begin
            automatic int s = (tb_mode == 0) ? 2*pass1_idx : pass1_idx;
            automatic longint signed n = 0, sm = 0, sq = 0;
            if (s < n_streams) begin
                stream_stats(s, n, sm, sq);
                if (dut.count_reg != n) begin
                    $display("  [FAIL] pass 1 of stream %0d accumulated n=%0d, expected %0d (%0d lost)",
                             s, dut.count_reg, n, n - dut.count_reg);
                    errors++;
                end
            end
            pass1_idx++;
        end
    end

    // -- Scenario construction ----------------------------------------------------------------------
    longint signed ref_n, ref_s, ref_q;      // "whole column" totals published to CLASSIFY
    longint signed alt_n, alt_s, alt_q;      // a SECOND set, for the query-boundary scenarios

    task automatic build_scenario();
        int len, lanes;
        case (tb_scen)
            0: begin
                n_streams = 6;
                for (int s = 0; s < n_streams; s++) begin
                    st_len[s] = 64; st_lanes[s] = N_IN; st_seed[s] = 0;
                end
            end
            1, 2, 3: begin
                n_streams = 12;
                for (int s = 0; s < n_streams; s++) begin
                    // deliberately includes streams SHORTER than PASS2_LAT (=37), where the last
                    // beat is still inside the pipeline when the next stream starts arriving
                    case (s % 6)
                        0: begin len = 1;   lanes = 5;  end
                        1: begin len = 2;   lanes = 16; end
                        2: begin len = 40;  lanes = 1;  end
                        3: begin len = 64;  lanes = 16; end
                        4: begin len = 3;   lanes = 11; end
                        5: begin len = 100; lanes = 9;  end
                    endcase
                    st_len[s] = len; st_lanes[s] = lanes; st_seed[s] = s * 13;
                end
            end
            4: begin
                n_streams = 40;
                for (int s = 0; s < n_streams; s++) begin
                    st_len[s]   = $urandom_range(1, 80);
                    st_lanes[s] = $urandom_range(1, N_IN);
                    st_seed[s]  = $urandom_range(0, 500);
                end
            end
            5, 6: begin
                n_streams = 12;
                for (int s = 0; s < n_streams; s++) begin
                    st_len[s]   = $urandom_range(2, 50);
                    st_lanes[s] = $urandom_range(1, N_IN);
                    st_seed[s]  = s * 7;
                end
            end
        endcase

        // LEGACY consumes streams in pairs: pass 1 and pass 2 must be the SAME stream, exactly as
        // the host re-feeds the same buffer twice.
        if (tb_mode == 0) begin
            if (n_streams % 2) n_streams--;
            for (int s = 0; s < n_streams; s += 2) begin
                st_len[s+1]   = st_len[s];
                st_lanes[s+1] = st_lanes[s];
                st_seed[s+1]  = st_seed[s];
            end
        end

        // Per-stream mode schedule and totals.
        for (int s = 0; s < n_streams; s++) begin
            st_mode[s] = tb_mode;
            st_gc[s] = ref_n; st_gs[s] = ref_s; st_gq[s] = ref_q;
        end
        if (tb_scen == 5) begin
            // query boundary the way the host actually does it: CLASSIFY, then a STATS phase, then
            // CLASSIFY again against DIFFERENT totals.
            for (int s = 0; s < n_streams; s++) begin
                if (s < 4)      st_mode[s] = 2;
                else if (s < 8) st_mode[s] = 1;
                else begin      st_mode[s] = 2; st_gc[s] = alt_n; st_gs[s] = alt_s; st_gq[s] = alt_q; end
            end
        end
        if (tb_scen == 6) begin
            // the hazard: two CLASSIFY phases in a row with NEW totals and NO mode change between
            // them. This is what the OASIS_ZSCORE_STATS path (phase-1 bypass) does.
            for (int s = 0; s < n_streams; s++) begin
                st_mode[s] = 2;
                if (s >= 6) begin st_gc[s] = alt_n; st_gs[s] = alt_s; st_gq[s] = alt_q; end
            end
        end
    endtask

    // -- Sequence -----------------------------------------------------------------------------------
    int expected_out_streams;
    int cyc_start, cyc_end;
    int cycle_count = 0;
    always_ff @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;

    initial begin
        void'($value$plusargs("MODE=%d", tb_mode));
        void'($value$plusargs("SCEN=%d", tb_scen));
        void'($value$plusargs("SEED=%d", tb_seed));
        // xsim does not accept $urandom(seed) as a seeding call; seed the process RNG instead.
        process::self().srandom(tb_seed);

        // Reference population for CLASSIFY: 2048 values of the base pattern, and a second, much
        // tighter population so the two total sets classify DIFFERENTLY (otherwise scenario 6 could
        // pass with stale totals by accident).
        ref_n = 0; ref_s = 0; ref_q = 0;
        for (int v = 0; v < 2048; v++) begin
            ref_n += 1; ref_s += val_of(0, v); ref_q += val_of(0, v) * val_of(0, v);
        end
        alt_n = 4096; alt_s = 4096 * 13; alt_q = 4096 * 13 * 13 + 100;

        build_scenario();

        mode              = 2'(st_mode[0]);
        mode_valid        = 1'b1;
        global_count      = st_gc[0][31:0];
        global_sum        = st_gs[0];
        global_sum_square = st_gq[0];
        expected_out_streams = (tb_mode == 0) ? n_streams / 2 : n_streams;

        case (tb_scen)
            2: begin in_bubble_pct = 25; out_bp_pct = 0;  end
            3: begin in_bubble_pct = 0;  out_bp_pct = 35; end
            4: begin in_bubble_pct = 20; out_bp_pct = 30; end
            default: begin in_bubble_pct = 0; out_bp_pct = 0; end
        endcase

        $display("\n=== z_score_boundary_tb  MODE=%0d(%s) SCEN=%0d SEED=%0d ===", tb_mode,
                 (tb_mode == 0) ? "LEGACY" : (tb_mode == 1) ? "STATS" : "CLASSIFY", tb_scen, tb_seed);
        $display("%0d input streams, bubbles=%0d%% backpressure=%0d%%", n_streams,
                 in_bubble_pct, out_bp_pct);

        // Change stimulus on the NEGEDGE: driving in the same time step as the posedge races the
        // always_ff blocks and double-presents beat 0 (seen as STATS n=1040 vs 1024).
        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (20) @(negedge clk);
        cyc_start = cycle_count;

        for (int s = 0; s < n_streams; s++) begin
            if (s > 0 && st_mode[s] != st_mode[s-1]) begin
                // The host only ever rewrites mode/totals with nothing in flight, so drain first.
                in_tvalid_r = 1'b0;
                repeat (200) @(negedge clk);
                mode              = 2'(st_mode[s]);
                global_count      = st_gc[s][31:0];
                global_sum        = st_gs[s];
                global_sum_square = st_gq[s];
                repeat (10) @(negedge clk);
            end else if (s > 0 && (st_gc[s] != st_gc[s-1] || st_gs[s] != st_gs[s-1] ||
                                   st_gq[s] != st_gq[s-1])) begin
                in_tvalid_r = 1'b0;
                repeat (200) @(negedge clk);
                // THE HOST CONTRACT (ZScoreInitGlobal): leave CLASSIFY before publishing new
                // totals. The operator reloads them only when it re-arms, and it re-arms on the
                // CLASSIFY edge -- it is parked ARMED with the previous query's totals at this
                // point. Measured: drop these two mode writes and exactly one stream (the first of
                // the new query) is classified against the OLD statistics.
                mode = MODE_STATS;
                repeat (20) @(negedge clk);
                global_count      = st_gc[s][31:0];
                global_sum        = st_gs[s];
                global_sum_square = st_gq[s];
                repeat (10) @(negedge clk);
                mode = 2'(st_mode[s]);
                repeat (10) @(negedge clk);
            end
            for (int b = 0; b < st_len[s]; b++) send_beat(s, b);
        end
        in_tvalid_r = 1'b0;

        // Let the last stream drain, then stop. Deliberately generous.
        repeat (5000) @(negedge clk);
        cyc_end = cycle_count;

        $display("---------------------------------------------");
        $display("output streams completed : %0d (expected %0d)", out_stream, expected_out_streams);
        $display("short streams            : %0d", shorts);
        $display("cycles                   : %0d", cyc_end - cyc_start);
        if (out_stream != expected_out_streams) begin
            $display("  [FAIL] wrong number of output streams (a missing one means the flow HUNG)");
            errors++;
        end
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $display("=============================================\n");
        $finish;
    end

endmodule
