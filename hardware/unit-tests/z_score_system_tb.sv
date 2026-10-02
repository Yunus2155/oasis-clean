`timescale 1ns / 1ps

// SYSTEM-level testbench for the global z-score: N_STRM_AXI z-score lanes sharing ONE
// ZScoreStatsConfig broadcast, feeding the REAL libstf OutputWriter, with a behavioural model of
// Coyote's DMA (sq_wr / cq_wr / notify) behind it.
//
// This covers the two things z_score_boundary_tb cannot:
//   (2) the mode / global_count / global_sum / global_sum_square signals are broadcast to every
//       lane, and the lanes are at DIFFERENT points in their streams when the host changes them.
//   (3) the OutputWriter is in the loop, so
//         - its two $fatal assertions police the operator's tkeep (all ones unless last;
//           contiguous from the LSB on last), and
//         - the check is made on the NOTIFIED byte count per flow, which is exactly the number the
//           host reads in LoadNextGroup and exactly what "SHORT flow: X of Y bytes" reports.
//       Buffers are deliberately undersized on some flows so a flow spans several buffers and
//       several notifies, the way a row group does on hardware.
//
// Run (N_STRM_AXI must equal N_LANE, so compile against a lynx_pkg with N_STRM_AXI = 3):
//   xsim ztb_sys -runall -testplusarg SEED=1 -testplusarg BP=1
//
// The multiplier IPs are the same behavioural models as in z_score_boundary_tb: exact for a
// pipelined signed multiplier, and they keep the bench free of the generated IP libraries.

import lynxTypes::*;
import libstf::*;
import parcore::*;

interface decoder_profile_i;
    decoder_profile_t counters;
    logic             stop;
    modport m (input stop, output counters);
    modport s (input counters, output stop);
endinterface

module int_mult_64 (
    input  logic CLK, input logic CE,
    input  logic [63:0] A, input logic [63:0] B, output logic [127:0] P
);
    localparam int LAT = 18;
    logic signed [127:0] pipe [LAT];
    always_ff @(posedge CLK) if (CE) begin
        pipe[0] <= $signed(A) * $signed(B);
        for (int i = 1; i < LAT; i++) pipe[i] <= pipe[i-1];
    end
    assign P = pipe[LAT-1];
endmodule

module int_mult_32 (
    input  logic CLK, input logic CE,
    input  logic [31:0] A, input logic [31:0] B, output logic [63:0] P
);
    localparam int LAT = 6;
    logic signed [63:0] pipe [LAT];
    always_ff @(posedge CLK) if (CE) begin
        pipe[0] <= $signed(A) * $signed(B);
        for (int i = 1; i < LAT; i++) pipe[i] <= pipe[i-1];
    end
    assign P = pipe[LAT-1];
endmodule

module z_score_system_tb;

    localparam int N_LANE     = N_STRM_AXI;
    localparam int N_IN       = 16;
    localparam int MAX_STREAM = 12;          // streams per lane
    localparam logic [1:0] MODE_STATS    = 2'd1;
    localparam logic [1:0] MODE_CLASSIFY = 2'd2;

    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;

    int tb_seed = 1;
    int tb_bp   = 0;

    // -- Shared config broadcast (one ZScoreStatsConfig drives every lane) -------------------------
    logic [1:0]         mode;
    logic               mode_valid;
    logic [31:0]        global_count;
    logic signed [63:0] global_sum;
    logic signed [63:0] global_sum_square;

    // -- Per-lane stream table --------------------------------------------------------------------
    int st_len   [N_LANE][MAX_STREAM];
    int st_lanes [N_LANE][MAX_STREAM];
    int st_seed  [N_LANE][MAX_STREAM];
    int n_streams;

    function automatic int st_values(input int l, input int s);
        st_values = (st_len[l][s] - 1) * N_IN + st_lanes[l][s];
    endfunction

    function automatic longint signed val_of(input int seed, input int v);
        val_of = (((v + seed) % 97) == 0) ? 64'sd1000 : (64'sd10 + ((v + seed) % 7));
    endfunction

    // Totals in force for each half of the run (the second query publishes different ones).
    longint signed ref_n, ref_s, ref_q;
    longint signed alt_n, alt_s, alt_q;
    int split_stream;                        // first stream of the second query

    function automatic bit golden_flag(input longint signed x, input longint signed n,
                                       input longint signed s, input longint signed q);
        longint signed       diff;
        logic signed [159:0] d160, lhs, thr;
        diff = n * x - s;
        d160 = diff;
        lhs  = d160 * d160;
        thr  = 9 * (160'(n) * 160'(q) - 160'(s) * 160'(s));
        golden_flag = (lhs > thr);
    endfunction

    function automatic longint signed tot_n(input int s); tot_n = (s < split_stream) ? ref_n : alt_n; endfunction
    function automatic longint signed tot_s(input int s); tot_s = (s < split_stream) ? ref_s : alt_s; endfunction
    function automatic longint signed tot_q(input int s); tot_q = (s < split_stream) ? ref_q : alt_q; endfunction

    int errors = 0;

    // -- Lanes ------------------------------------------------------------------------------------
    AXI4S  axi_zin  [N_LANE](.aclk(clk), .aresetn(rst_n));
    AXI4S  axi_out  [N_LANE](.aclk(clk), .aresetn(rst_n));
    AXI4SR axis_send[N_LANE](.aclk(clk), .aresetn(rst_n));
    decoder_profile_i prof[N_LANE]();

    logic       lane_start = 1'b0;           // release the drivers
    // Streams strictly below allow_upto may be fed. A level like this is race-free; a "gate" the
    // sequencer lowers after seeing lane_at is NOT -- a lane can read the gate as still open in the
    // same delta and charge into the next query with the previous query's totals still published.
    int         allow_upto;
    logic [7:0] lane_at    [N_LANE];         // stream index the driver is about to feed
    logic [7:0] lane_done  = '0;

    for (genvar L = 0; L < N_LANE; L++) begin : gen_lane
        assign prof[L].stop = 1'b0;

        logic [511:0] tdata_r  = '0;
        logic [63:0]  tkeep_r  = '0;
        logic         tlast_r  = 1'b0;
        logic         tvalid_r = 1'b0;
        assign axi_zin[L].tdata  = tdata_r;
        assign axi_zin[L].tkeep  = tkeep_r;
        assign axi_zin[L].tlast  = tlast_r;
        assign axi_zin[L].tvalid = tvalid_r;

        logic tready_at_edge = 1'b0;
        always_ff @(posedge clk) tready_at_edge <= axi_zin[L].tready;

        my_z_score_squared inst_z_score (
            .clk(clk), .rst_n(rst_n),
            .in(axi_zin[L]), .out(axi_out[L]),
            .profile(prof[L]),
            .mode(mode), .mode_valid(mode_valid),
            .global_count(global_count), .global_sum(global_sum),
            .global_sum_square(global_sum_square)
        );

        // Driver: feeds this lane's streams back-to-back, pausing only at the query boundary.
        // The beat loop must NOT wait at the top: the do-while below returns at the negedge right
        // after the accepting posedge, so writing the next beat's data there gives a zero-gap
        // back-to-back stream. An extra @(negedge clk) leaves tvalid high over one posedge with
        // stale data -- which both duplicates a beat and trips AXI4S's own $stable assertion.
        initial begin
            longint signed v;
            int lanes;
            wait (lane_start);
            @(negedge clk);
            for (int s = 0; s < n_streams; s++) begin
                lane_at[L] = 8'(s);
                if (s >= allow_upto) begin
                    tvalid_r = 1'b0;         // drain before the host changes the totals
                    wait (s < allow_upto);
                    @(negedge clk);
                end
                for (int b = 0; b < st_len[L][s]; b++) begin
                    lanes = (b == st_len[L][s] - 1) ? st_lanes[L][s] : N_IN;
                    tdata_r = '0;
                    tkeep_r = '0;
                    for (int i = 0; i < lanes; i++) begin
                        v = val_of(st_seed[L][s], b * N_IN + i);
                        tdata_r[i*32 +: 32] = v[31:0];
                        tkeep_r[i*4  +: 4]  = 4'hF;
                    end
                    tlast_r  = (b == st_len[L][s] - 1);
                    tvalid_r = 1'b1;
                    do @(negedge clk); while (!tready_at_edge);
                end
            end
            tvalid_r = 1'b0;
            lane_done[L] = 1'b1;
        end
    end

    // -- The real OutputWriter --------------------------------------------------------------------
    metaIntf #(.STYPE(req_t))     sq_wr (.aclk(clk), .aresetn(rst_n));
    metaIntf #(.STYPE(ack_t))     cq_wr (.aclk(clk), .aresetn(rst_n));
    metaIntf #(.STYPE(irq_not_t)) notify(.aclk(clk), .aresetn(rst_n));
    mem_config_i mem_conf[N_LANE](clk, rst_n);

    OutputWriter inst_output_writer (
        .clk(clk), .rst_n(rst_n),
        .sq_wr(sq_wr), .cq_wr(cq_wr), .notify(notify),
        .mem_config(mem_conf),
        .data_in(axi_out), .data_out(axis_send)
    );

    // -- DMA model: accept every request, acknowledge it after a delay -----------------------------
    assign sq_wr.ready  = 1'b1;
    assign notify.ready = 1'b1;

    int  pend_dest [$];
    int  requests_seen = 0;
    always_ff @(posedge clk) begin
        if (rst_n && sq_wr.valid && sq_wr.ready) begin
            pend_dest.push_back(int'(sq_wr.data.dest));
            requests_seen <= requests_seen + 1;
        end
    end

    initial begin
        cq_wr.valid = 1'b0;
        cq_wr.data  = '0;
        forever begin
            @(negedge clk);
            cq_wr.valid = 1'b0;
            if (pend_dest.size() > 0) begin
                repeat ($urandom_range(1, 8)) @(negedge clk);
                cq_wr.data       = '0;
                cq_wr.data.strm  = STRM_HOST;
                cq_wr.data.dest  = pend_dest.pop_front();
                cq_wr.valid      = 1'b1;
                @(negedge clk);
                cq_wr.valid      = 1'b0;
            end
        end
    end

    // -- Buffer supply: one allocation at a time per lane, sometimes too small ----------------------
    // `size` is in units of TRANSFER_LENGTH_BYTES (StreamWriter: capacity = size << 12), so a size of
    // 1 forces a big flow to span several buffers and several notifies -- exactly the multi-batch
    // case LoadNextGroup handles on hardware.
    int buf_serial [N_LANE];
    for (genvar L = 0; L < N_LANE; L++) begin : gen_buf
        initial begin
            mem_conf[L].buffer_valid  = 1'b0;
            mem_conf[L].flush_buffers = 1'b0;
            mem_conf[L].buffer_data   = '0;
            buf_serial[L]             = 0;
            wait (rst_n);
            forever begin
                @(negedge clk);
                if (mem_conf[L].buffer_ready) begin
                    mem_conf[L].buffer_data.vaddr = 64'h1000_0000 + (L << 24) + (buf_serial[L] << 20);
                    // every 3rd allocation is deliberately tiny -> multi-buffer flow
                    mem_conf[L].buffer_data.size  = (buf_serial[L] % 3 == 2) ? 1 : 8;
                    mem_conf[L].buffer_valid      = 1'b1;
                    buf_serial[L]                 = buf_serial[L] + 1;
                    @(negedge clk);
                    mem_conf[L].buffer_valid      = 1'b0;
                end
            end
        end
    end

    // -- Sink + checkers ----------------------------------------------------------------------------
    // Content: the words the OutputWriter actually sends to the host, in order.
    int cur_stream [N_LANE];
    int cur_val    [N_LANE];
    int content_bad[N_LANE];
    // Length: bytes NOTIFIED per flow, summed until last_transfer -- the host's own accounting.
    int flow_idx   [N_LANE];
    int flow_bytes [N_LANE];

    initial begin
        for (int l = 0; l < N_LANE; l++) begin
            cur_stream[l] = 0; cur_val[l] = 0; content_bad[l] = 0;
            flow_idx[l]   = 0; flow_bytes[l] = 0;
        end
    end

    logic sink_ready = 1'b1;
    always @(negedge clk) sink_ready = (tb_bp == 0) ? 1'b1 : ($urandom_range(99) >= 30);

    for (genvar L = 0; L < N_LANE; L++) begin : gen_sink
        assign axis_send[L].tready = sink_ready;

        always_ff @(posedge clk) begin
            if (rst_n && axis_send[L].tvalid && axis_send[L].tready) begin
                for (int i = 0; i < N_IN; i++) begin
                    if (&axis_send[L].tkeep[i*4 +: 4]) begin
                        automatic int s = cur_stream[L];
                        automatic bit got = (axis_send[L].tdata[i*32 +: 32] != 32'd0);
                        if (s < n_streams) begin
                            if (got !== golden_flag(val_of(st_seed[L][s], cur_val[L]),
                                                    tot_n(s), tot_s(s), tot_q(s))) begin
                                if (content_bad[L] == 0)
                                    $display("  [FAIL] lane %0d stream %0d: wrong flag at value %0d",
                                             L, s, cur_val[L]);
                                content_bad[L] = content_bad[L] + 1;
                            end
                            cur_val[L] = cur_val[L] + 1;
                            if (cur_val[L] == st_values(L, s)) begin
                                cur_stream[L] = s + 1;
                                cur_val[L]    = 0;
                            end
                        end
                    end
                end
            end
        end
    end

    // notify: value[2:0]=stream id, value[30:3]=bytes written to this allocation, value[31]=last
    always_ff @(posedge clk) begin
        if (rst_n && notify.valid && notify.ready) begin
            automatic int l = int'(notify.data.value[2:0]);
            automatic int b = int'(notify.data.value[30:3]);
            if (l < N_LANE) begin
                flow_bytes[l] = flow_bytes[l] + b;
                if (notify.data.value[31]) begin
                    automatic int s   = flow_idx[l];
                    automatic int exp = (s < n_streams) ? st_values(l, s) * 4 : -1;
                    if (s < n_streams && flow_bytes[l] != exp) begin
                        $display("  [FAIL] lane %0d flow %0d: SHORT %0d of %0d bytes (%0d beats lost)",
                                 l, s, flow_bytes[l], exp, (exp - flow_bytes[l]) / 64);
                        errors++;
                    end
                    flow_idx[l]   = s + 1;
                    flow_bytes[l] = 0;
                end
            end
        end
    end

    // -- Sequence -------------------------------------------------------------------------------------
    initial begin
        void'($value$plusargs("SEED=%d", tb_seed));
        void'($value$plusargs("BP=%d", tb_bp));
        process::self().srandom(tb_seed);

        n_streams    = MAX_STREAM;
        split_stream = MAX_STREAM / 2;

        ref_n = 0; ref_s = 0; ref_q = 0;
        for (int v = 0; v < 2048; v++) begin
            ref_n += 1; ref_s += val_of(0, v); ref_q += val_of(0, v) * val_of(0, v);
        end
        alt_n = 4096; alt_s = 4096 * 13; alt_q = 4096 * 13 * 13 + 100;

        for (int l = 0; l < N_LANE; l++) begin
            for (int s = 0; s < MAX_STREAM; s++) begin
                // TRANSFER_SIZE_BYTES is 65536, so a flow only splits into several DMA transfers
                // above 1024 beats. Every 4th stream is made big enough to split -- combined with
                // the size-1 (64 KiB) allocations above that gives several transfers AND several
                // buffers, i.e. several notifies per flow: the multi-batch case LoadNextGroup
                // handles on hardware.
                st_len  [l][s] = (s % 4 == 3) ? $urandom_range(1100, 2600) : $urandom_range(1, 200);
                st_lanes[l][s] = $urandom_range(1, N_IN);
                st_seed [l][s] = $urandom_range(0, 500);
            end
        end

        mode              = MODE_CLASSIFY;
        mode_valid        = 1'b1;
        global_count      = ref_n[31:0];
        global_sum        = ref_s;
        global_sum_square = ref_q;

        $display("\n=== z_score_system_tb  lanes=%0d SEED=%0d BP=%0d ===", N_LANE, tb_seed, tb_bp);
        $display("%0d streams per lane, 1..200 beats, every 4th 1100..2600 (spans transfers/buffers)",
                 n_streams);
        $display("query boundary after stream %0d: new totals published to ALL lanes", split_stream);

        allow_upto = split_stream;      // lanes stop by themselves at the query boundary

        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (20) @(negedge clk);

        lane_start = 1'b1;

        // Query boundary: wait until every lane has finished its first query, then republish totals
        // exactly the way ZScoreInitGlobal does -- leave CLASSIFY first so the operators re-arm.
        wait ((lane_at[0] >= split_stream) && (lane_at[1] >= split_stream) &&
              (lane_at[2] >= split_stream));
        repeat (2000) @(negedge clk);   // let every lane drain fully
        mode = MODE_STATS;
        repeat (40) @(negedge clk);
        global_count      = alt_n[31:0];
        global_sum        = alt_s;
        global_sum_square = alt_q;
        repeat (20) @(negedge clk);
        mode = MODE_CLASSIFY;
        repeat (20) @(negedge clk);
        allow_upto = n_streams;

        wait (lane_done[0] && lane_done[1] && lane_done[2]);
        repeat (40000) @(negedge clk);

        $display("---------------------------------------------");
        $display("sq_wr requests issued : %0d", requests_seen);
        for (int l = 0; l < N_LANE; l++) begin
            $display("lane %0d: flows completed %0d of %0d, streams consumed %0d, content errors %0d",
                     l, flow_idx[l], n_streams, cur_stream[l], content_bad[l]);
            if (flow_idx[l] != n_streams) begin
                $display("  [FAIL] lane %0d completed %0d of %0d flows (a missing one means a HANG)",
                         l, flow_idx[l], n_streams);
                errors++;
            end
            if (content_bad[l] != 0) errors += content_bad[l];
        end
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $display("=============================================\n");
        $finish;
    end

endmodule
