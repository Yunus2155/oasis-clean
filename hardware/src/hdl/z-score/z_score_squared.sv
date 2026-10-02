`timescale 1ns / 1ps

`include "libstf_macros.svh"

module my_z_score_squared
#(parameter int ELEM_BITS = 32)
 (input  logic clk,
  input  logic rst_n,
    AXI4S.s in,
    AXI4S.m out,
    decoder_profile_i.m profile,   // in = pass1+pass2 input stream, out = pass2 flag output stream

  // Global-z-score control from ZScoreStatsConfig (see common.sv). LEGACY leaves the operator exactly
  // as it was: one stream = pass 1 + pass 2, normalised on itself. The two new modes split that in
  // half so the host can normalise against the WHOLE column instead of one row group.
  input  logic [1:0]         mode,
  // High once the host has actually written the mode register. Until then the operator refuses input:
  // the AXI-Lite config write and the data stream are independent paths and the data can arrive
  // first, in which case an unconfigured operator would consume it as a LEGACY pass 1. Tie this high
  // in tops that wire `mode` to a constant.
  input  logic               mode_valid,
  input  logic [31:0]        global_count,
  input  logic signed [63:0] global_sum,
  input  logic signed [63:0] global_sum_square);

`RESET_RESYNC // Reset pipelining (provides reset_synced)

    localparam int IN_BITS   = in.AXI4S_DATA_BITS;   // 512
    localparam int N_IN      = IN_BITS / ELEM_BITS;  // 16 input lanes
    localparam int KEEP_PER  = ELEM_BITS / 8;        // 4 keep bits per lane
    localparam int K         = 3;                    // threshold multiplier (k^2 = 9)
    localparam int WIDE      = 160;                  // wide enough for diff^2 and threshold
    localparam int DIFF_W    = 64;                   // diff = n*x - S; 64b (mult IP max). Assumes |n*x - S| < 2^63.
    localparam int MULT_LAT  = 18;                   // !! MUST match int_mult_64 PipeStages in init_ip.tcl (optimum for 64x64)
    // Pass-2 datapath latency, input beat -> squared output: n*x IP (MULT_LAT) + subtract reg (1)
    // + squaring IP (MULT_LAT). The metadata pipeline is this deep so valid/keep/last stay aligned.
    localparam int PASS2_LAT = 2*MULT_LAT + 1;

    // Mode encoding -- MUST match ZSCORE_MODE_* in hardware/src/hdl/common.sv. Kept as local
    // constants rather than an `import oasis::*` so this module still elaborates standalone in the
    // unit-test tops, which do not pull in the oasis package.
    localparam logic [1:0] MODE_LEGACY   = 2'd0;
    localparam logic [1:0] MODE_STATS    = 2'd1;
    localparam logic [1:0] MODE_CLASSIFY = 2'd2;

    // ---- accumulator + state ----
    // output_stats is the STATS-mode tail: instead of running pass 2, emit one beat carrying this
    // stream's (count, sum, sum_square) so the host can add the row groups up itself.
    typedef enum logic [2:0] {accumulate, compute_wait, compute_sub, compute_scale, output_z_score,
                              output_stats} state_t;
    state_t state;
    logic signed [63:0]     sum_reg;
    logic signed [63:0]     sum_square_reg;
    logic        [31:0]     count_reg;
    logic        [4:0]      wait_cnt;               // counts the compute-multiplier latency (up to MULT_LAT)

    logic signed [WIDE-1:0] nq_minus_s2_reg;        // n*Q - S^2
    logic signed [WIDE-1:0] threshold_reg;          // k^2 * (n*Q - S^2), computed once

    // ---- pass-1 accumulate pipeline ------------------------------------------------------------
    // The per-beat reduction is split so it isn't one deep multiply+tree+accumulate cone:
    //   stage a : per-lane number^2 / number / popcount  (DSP mults, registered)
    //   stage b : reduce 16 -> 4   (sum of 4 each)
    //   stage c : reduce 4  -> 1   (per-beat totals)
    //   stage d : accumulate into sum / sum_square / count  (one add)
    // Throughput stays 1 beat/cycle; a 3-cycle drain after tlast flushes the last beats.
    logic signed [63:0]  a_psq [N_IN];
    logic signed [63:0]  a_psm [N_IN];
    logic        [4:0]   a_cnt;
    logic                a_valid, a_last;

    // stage a is a pipelined 32x32 DSP square (int_mult_32) instead of a combinational number*number
    // (which was the timing bottleneck). The IP has SQ_LAT cycles of latency, so value/keep/valid/last
    // are delayed by matching pipelines and realigned with the product at the tail.
    `ASSERT_ELAB(ELEM_BITS == 32)   // int_mult_32 is a fixed 32x32 IP
    localparam int SQ_LAT  = 6;     // !! MUST match int_mult_32 PipeStages in init_ip.tcl
    localparam int SQ_TAIL = SQ_LAT - 1;
    logic signed [ELEM_BITS-1:0] lane_val  [N_IN];          // combinational per-lane value (square input)
    logic                        lane_keep [N_IN];          // combinational per-lane keep (all bits set)
    logic signed [63:0]          ip_psq    [N_IN];          // number^2, valid SQ_LAT cycles after input
    logic signed [ELEM_BITS-1:0] val_reg   [SQ_LAT][N_IN];  // value delay line (aligns with ip_psq)
    logic                        keep_reg  [SQ_LAT][N_IN];  // keep  delay line
    logic                        sqvalid_reg [SQ_LAT];      // valid delay line
    logic                        sqlast_reg  [SQ_LAT];      // last  delay line
    logic signed [63:0]  b_g4sq [4];
    logic signed [63:0]  b_g4sm [4];
    logic        [4:0]   b_cnt;
    logic                b_valid, b_last;
    logic signed [63:0]  c_bsq;
    logic signed [63:0]  c_bsm;
    logic        [4:0]   c_cnt;
    logic                c_valid, c_last;
    logic                draining;                  // pass done; flushing the pipe, input closed
    // High while this visit to output_z_score was entered by the CLASSIFY load rather than by a
    // LEGACY pass 1. Used only to gate the "host switched away from CLASSIFY" exit below, which
    // must not fire during a LEGACY pass 2 (there `mode` is also != MODE_CLASSIFY).
    logic                classify_run;

    // ---- pass-2 stage 0: input buffer (registers in.tdata so the decoder->z-score crossing is
    //      register-to-register with no logic in it) ----
    logic signed [ELEM_BITS-1:0] x_reg [N_IN];
    // ---- pass-2 stage 1: diff = n*x - S, per lane (drives the squaring IPs) ----
    logic signed [DIFF_W-1:0] s1_diff [N_IN];

    // ---- metadata pipeline: valid/keep/last delayed PASS2_LAT cycles to align with IP output ----
    logic                 meta_valid [PASS2_LAT+1];
    logic [IN_BITS/8-1:0] meta_keep  [PASS2_LAT+1];
    logic                 meta_last  [PASS2_LAT+1];

    // The pipeline advances when the output slot is free or draining.
    logic pipe_adv;
    assign pipe_adv = out.tready || !out.tvalid;

    // ---- multiplier IPs --------------------------------------------------------------------------
    // Compute multiplies (run once per stream; inputs are stable so CE is tied high).
    logic [127:0] ip_ss_p;                          // sum * sum          (S^2)
    logic [127:0] ip_nq_p;                          // count * sum_square (n*Q)
    wire  [63:0]  ss_a = sum_reg;                    // sum     (signed 64b)
    wire  [63:0]  nq_a = {32'b0, count_reg};         // count   (>= 0)
    wire  [63:0]  nq_b = sum_square_reg;             // sum_sq  (>= 0)
    int_mult_64 mult_ss (.CLK(clk), .CE(1'b1), .A(ss_a), .B(ss_a), .P(ip_ss_p));
    int_mult_64 mult_nq (.CLK(clk), .CE(1'b1), .A(nq_a), .B(nq_b), .P(ip_nq_p));

    // Pass-2 stage 1 input: n*x per lane via DSP IP, fed from the x_reg input buffer (in phase with
    // meta[0]). The n*x multiply is pipelined instead of combinational. n = count_reg, constant
    // throughout pass 2. CE = pipe_adv so it freezes with the rest of the pipe.
    logic [127:0] ip_nx_p [N_IN];
    wire  [63:0]  nx_a = {32'b0, count_reg};         // n (>= 0) as signed 64b
    generate
        for (genvar gi = 0; gi < N_IN; gi++) begin : gen_nx
            wire [63:0] nx_b = {{(64-ELEM_BITS){x_reg[gi][ELEM_BITS-1]}}, x_reg[gi]};   // x sign-extended to 64b
            int_mult_64 mult_nx (
                .CLK(clk), .CE(pipe_adv),
                .A(nx_a), .B(nx_b),
                .P(ip_nx_p[gi])
            );
        end
    endgenerate

    // Pass-2 squares: dsq = diff*diff per lane. CE = pipe_adv so the whole pipe freezes together.
    logic [127:0] ip_dsq_p [N_IN];
    generate
        for (genvar gi = 0; gi < N_IN; gi++) begin : gen_dsq
            int_mult_64 mult_dsq (
                .CLK(clk), .CE(pipe_adv),
                .A(s1_diff[gi]), .B(s1_diff[gi]),
                .P(ip_dsq_p[gi])
            );
        end
    endgenerate

    // Pass-1 squares: number^2 per lane via a pipelined 32x32 DSP IP (int_mult_32, SQ_LAT cycles).
    // Free-running (CE=1); the value/keep/valid/last delay lines realign the metadata with ip_psq.
    generate
        for (genvar gi = 0; gi < N_IN; gi++) begin : gen_sq
            assign lane_val [gi] = signed'(in.tdata[gi*ELEM_BITS +: ELEM_BITS]);
            assign lane_keep[gi] = &in.tkeep[gi*KEEP_PER +: KEEP_PER];
            int_mult_32 mult_sq (
                .CLK(clk), .CE(1'b1),
                .A(lane_val[gi]), .B(lane_val[gi]),
                .P(ip_psq[gi])
            );
        end
    endgenerate

    // tready: pass 1 ready until the pipe is draining; pass 2 ready when it can advance.
    // In CLASSIFY mode there is no pass 1, so `accumulate` must not swallow beats -- it is only a
    // one-cycle staging state that loads the host-supplied totals and jumps to the threshold compute.
    // `draining` closes the input in BOTH passes. Pass 2 needs it for the same reason pass 1 does:
    // the last beat of a stream is only at the head of a PASS2_LAT-deep pipeline, and for the
    // PASS2_LAT+1 cycles it takes to reach the output the input would otherwise still be accepting
    // -- so the next stream's first beats get consumed and are then wiped by the end-of-stream
    // reset below. On hardware that is the "SHORT flow" beat loss: whole 64-byte beats missing from
    // the HEAD of the next row group, up to the pipeline depth.
    assign in.tready = (state == accumulate)     ? (!draining && mode_valid && mode != MODE_CLASSIFY) :
                       (state == output_z_score) ? (pipe_adv && !draining) :
                                                   1'b0;

    // The STATS-mode result beat: count, sum and sum_square as three 64-bit little-endian words in
    // the low 24 bytes of the beat, the rest zero. Kept 64-bit-aligned so the host can read it as
    // three int64s. Sampled a cycle after pass 1 finishes, so the accumulators are final.
    logic [IN_BITS-1:0] stats_beat;
    assign stats_beat = {{(IN_BITS-192){1'b0}}, sum_square_reg, sum_reg, 32'b0, count_reg};

    integer k;
    always_ff @(posedge clk) begin
        if (!reset_synced) begin
            state           <= accumulate;
            sum_reg         <= '0;
            sum_square_reg  <= '0;
            count_reg       <= '0;
            wait_cnt        <= '0;
            nq_minus_s2_reg <= '0;
            threshold_reg   <= '0;
            a_valid <= 1'b0; b_valid <= 1'b0; c_valid <= 1'b0;
            a_last  <= 1'b0; b_last  <= 1'b0; c_last  <= 1'b0;
            draining        <= 1'b0;
            classify_run    <= 1'b0;
            for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
            for (k = 0; k < SQ_LAT; k++) begin sqvalid_reg[k] <= 1'b0; sqlast_reg[k] <= 1'b0; end
            out.tvalid      <= 1'b0;
            out.tdata       <= '0;
            out.tkeep       <= '0;
            out.tlast       <= 1'b0;
        end else begin
            case (state)
                // ---- pass 1: accumulate Sum, Sum^2, count (pipelined) ----
                accumulate: begin
                    // stage a: per-lane squares via the pipelined IP. The value/keep/valid/last of the
                    // beat presented now enter the delay lines at stage 0; the beat presented SQ_LAT
                    // cycles ago is at the tail, in phase with its ip_psq product.
                    sqvalid_reg[0] <= in.tvalid && in.tready;
                    sqlast_reg [0] <= in.tvalid && in.tready && in.tlast;
                    for (int i = 0; i < N_IN; i++) begin
                        val_reg [0][i] <= lane_val [i];
                        keep_reg[0][i] <= lane_keep[i];
                    end
                    for (k = 1; k < SQ_LAT; k++) begin
                        sqvalid_reg[k] <= sqvalid_reg[k-1];
                        sqlast_reg [k] <= sqlast_reg [k-1];
                        for (int i = 0; i < N_IN; i++) begin
                            val_reg [k][i] <= val_reg [k-1][i];
                            keep_reg[k][i] <= keep_reg[k-1][i];
                        end
                    end

                    // stage a tail: latch the product (or 0 for dropped lanes) and the aligned value.
                    begin
                        automatic logic [4:0] cnt = '0;
                        for (int i = 0; i < N_IN; i++) begin
                            if (keep_reg[SQ_TAIL][i]) begin
                                a_psq[i] <= ip_psq[i];
                                a_psm[i] <= 64'(val_reg[SQ_TAIL][i]);
                                cnt = cnt + 1'b1;
                            end else begin
                                a_psq[i] <= '0;
                                a_psm[i] <= '0;
                            end
                        end
                        a_cnt <= cnt;
                    end
                    a_valid <= sqvalid_reg[SQ_TAIL];
                    a_last  <= sqlast_reg [SQ_TAIL];

                    // stage b: 16 -> 4
                    for (int j = 0; j < 4; j++) begin
                        b_g4sq[j] <= a_psq[4*j] + a_psq[4*j+1] + a_psq[4*j+2] + a_psq[4*j+3];
                        b_g4sm[j] <= a_psm[4*j] + a_psm[4*j+1] + a_psm[4*j+2] + a_psm[4*j+3];
                    end
                    b_cnt   <= a_cnt;
                    b_valid <= a_valid;
                    b_last  <= a_last;

                    // stage c: 4 -> 1 (per-beat totals)
                    c_bsq   <= b_g4sq[0] + b_g4sq[1] + b_g4sq[2] + b_g4sq[3];
                    c_bsm   <= b_g4sm[0] + b_g4sm[1] + b_g4sm[2] + b_g4sm[3];
                    c_cnt   <= b_cnt;
                    c_valid <= b_valid;
                    c_last  <= b_last;

                    // stage d: accumulate the per-beat totals into the running registers
                    if (c_valid) begin
                        sum_reg        <= sum_reg        + c_bsm;
                        sum_square_reg <= sum_square_reg + c_bsq;
                        count_reg      <= count_reg      + 32'(c_cnt);
                    end

                    // CLASSIFY: there is no pass 1 in this mode. Load the host-supplied totals into
                    // the very registers pass 1 would have filled and jump straight to the threshold
                    // compute. Everything downstream (mult_ss/mult_nq for the threshold, nx_a and
                    // s1_diff for pass 2) reads only these three registers, so the compute and
                    // classify datapaths need no changes at all.
                    // Arm as soon as the mode says CLASSIFY -- deliberately NOT gated on in.tvalid.
                    // Gating on it deadlocks: `accumulate` holds tready low in this mode, and a
                    // source that waits for tready before asserting tvalid then never starts the
                    // next stream. Caught in sim: after the first stream the operator sat in
                    // `accumulate` forever and streams 2..N were never presented.
                    // Leaving the armed state when the host switches modes is handled in
                    // output_z_score below, which is what keeps the next query's phase 1 safe.
                    if (mode == MODE_CLASSIFY) begin
                        count_reg      <= global_count;
                        sum_reg        <= global_sum;
                        sum_square_reg <= global_sum_square;
                        state          <= compute_wait;
                        wait_cnt       <= '0;
                        draining       <= 1'b0;
                        classify_run   <= 1'b1;
                    end

                    // pass 1 ends at tlast: stop accepting, then drain the pipe
                    if (in.tvalid && in.tready && in.tlast) draining <= 1'b1;

                    // last beat fully accumulated -> STATS hands the partials back to the host,
                    // LEGACY carries straight on into the threshold + pass 2 for this same stream.
                    if (c_valid && c_last) begin
                        state    <= (mode == MODE_STATS) ? output_stats : compute_wait;
                        wait_cnt <= '0;
                        draining <= 1'b0;
                        a_valid  <= 1'b0;
                        b_valid  <= 1'b0;
                        c_valid  <= 1'b0;
                        for (k = 0; k < SQ_LAT; k++) begin sqvalid_reg[k] <= 1'b0; sqlast_reg[k] <= 1'b0; end
                    end
                end

                // ---- wait for the (free-running) compute multipliers to settle ----
                compute_wait: begin
                    if (wait_cnt == 5'(MULT_LAT)) state <= compute_sub;
                    else                          wait_cnt <= wait_cnt + 1'b1;
                end
                compute_sub: begin
                    nq_minus_s2_reg <= $signed(ip_nq_p) - $signed(ip_ss_p);   // n*Q - S^2
                    state           <= compute_scale;
                end
                compute_scale: begin
                    threshold_reg <= K*K*nq_minus_s2_reg;                     // * 9
                    for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;   // clear pass-2 pipe
                    state         <= output_z_score;
                end

                // ---- pass 2: classify. diff -> [squaring IP, MULT_LAT cycles] -> compare ----
                output_z_score: begin
                    if (pipe_adv) begin
                        // output stage: compare the squared diffs (IP output) to the threshold
                        automatic logic [IN_BITS-1:0] flags = '0;
                        for (int i = 0; i < N_IN; i++) begin
                            if ((&meta_keep[PASS2_LAT][i*KEEP_PER +: KEEP_PER]) &&
                                ($signed(ip_dsq_p[i]) > threshold_reg))
                                flags[i*ELEM_BITS +: ELEM_BITS] = 32'd1;
                        end
                        out.tvalid <= meta_valid[PASS2_LAT];
                        out.tdata  <= flags;
                        out.tkeep  <= meta_keep [PASS2_LAT];
                        out.tlast  <= meta_last [PASS2_LAT];

                        // shift the metadata pipeline (aligns with the total pass-2 latency)
                        for (k = PASS2_LAT; k >= 1; k--) begin
                            meta_valid[k] <= meta_valid[k-1];
                            meta_keep [k] <= meta_keep [k-1];
                            meta_last [k] <= meta_last [k-1];
                        end

                        // stage 0: buffer the input and latch metadata, all in phase
                        meta_valid[0] <= in.tvalid;     // in.tready == pipe_adv here
                        meta_keep [0] <= in.tkeep;
                        meta_last [0] <= in.tlast;
                        for (int i = 0; i < N_IN; i++) begin
                            x_reg[i] <= signed'(in.tdata[i*ELEM_BITS +: ELEM_BITS]);
                        end

                        // stage 1 (subtract): the n*x IPs (gen_nx) have produced n*x for the beat now
                        // at this stage; subtract S. |n*x - S| < 2^63 is assumed (see DIFF_W), so the
                        // low DIFF_W bits of the signed product carry the value.
                        for (int i = 0; i < N_IN; i++) begin
                            s1_diff[i] <= $signed(ip_nx_p[i][DIFF_W-1:0]) - sum_reg;
                        end
                    end

                    // pass 2 ends at tlast: stop accepting, then let the pipe drain. Without this the
                    // next stream's head is consumed during the drain and destroyed by the reset
                    // below -- which is the "SHORT flow" beat loss seen on hardware.
                    if (in.tvalid && in.tready && in.tlast) draining <= 1'b1;

                    // The host switched away from CLASSIFY between queries (phase 2 of one query
                    // ends, phase 1 of the next begins). Leave the armed state while the pipe is
                    // idle, so the next query's statistics pass is ACCUMULATED rather than
                    // classified against the previous query's totals. Gated on classify_run: in
                    // LEGACY `mode` is also != MODE_CLASSIFY, and this state is then a pass 2 in
                    // progress -- leaving it on an input bubble would abandon the stream and the
                    // flow would never see its tlast.
                    if (classify_run && mode != MODE_CLASSIFY && !out.tvalid && !in.tvalid) begin
                        classify_run   <= 1'b0;
                        sum_reg        <= '0;
                        sum_square_reg <= '0;
                        count_reg      <= '0;
                        threshold_reg  <= '0;
                        draining       <= 1'b0;
                        for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
                        for (k = 0; k < SQ_LAT; k++) begin sqvalid_reg[k] <= 1'b0; sqlast_reg[k] <= 1'b0; end
                        state          <= accumulate;
                    end

                    // end of stream: last output beat delivered -> reset & restart. This runs in
                    // CLASSIFY too, on purpose: re-arming per stream is what makes the operator
                    // reload count/sum/sum_square from the config registers for every row group. If
                    // it stayed armed instead, a second query that publishes NEW totals and writes
                    // CLASSIFY again WITHOUT an intervening STATS write would be classified against
                    // the previous query's statistics -- silently wrong. (That is the phase-1-bypass
                    // path, OASIS_ZSCORE_STATS.) The re-arm costs ~22 idle cycles plus the
                    // PASS2_LAT drain per row group, under 1% of a 7680-beat group.
                    if (out.tvalid && out.tready && out.tlast) begin
                        classify_run   <= 1'b0;
                        out.tvalid     <= 1'b0;
                        sum_reg        <= '0;
                        sum_square_reg <= '0;
                        count_reg      <= '0;
                        threshold_reg  <= '0;
                        a_valid <= 1'b0; b_valid <= 1'b0; c_valid <= 1'b0;
                        draining       <= 1'b0;
                        for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
                        for (k = 0; k < SQ_LAT; k++) begin sqvalid_reg[k] <= 1'b0; sqlast_reg[k] <= 1'b0; end
                        state          <= accumulate;
                    end
                end

                // ---- STATS mode tail: hand this stream's partial statistics to the host ----------
                // Entered one cycle after the final accumulate, so sum/sum_square/count are settled
                // and stats_beat carries the totals for the whole row group.
                output_stats: begin
                    if (!out.tvalid) begin
                        out.tvalid <= 1'b1;
                        out.tdata  <= stats_beat;
                        out.tkeep  <= '1;
                        out.tlast  <= 1'b1;
                    end else if (out.tready) begin
                        // Beat accepted -> reset exactly like the end of a legacy stream, so the
                        // next row group starts from zero.
                        out.tvalid     <= 1'b0;
                        out.tlast      <= 1'b0;
                        sum_reg        <= '0;
                        sum_square_reg <= '0;
                        count_reg      <= '0;
                        threshold_reg  <= '0;
                        a_valid <= 1'b0; b_valid <= 1'b0; c_valid <= 1'b0;
                        draining       <= 1'b0;
                        for (k = 0; k <= PASS2_LAT; k++) meta_valid[k] <= 1'b0;
                        for (k = 0; k < SQ_LAT; k++) begin sqvalid_reg[k] <= 1'b0; sqlast_reg[k] <= 1'b0; end
                        state          <= accumulate;
                    end
                end
            endcase
        end
    end

    // ------ Stream profiling ------------------------
    // Same pattern as ColumnChunkDecoder: tap the input (decoded values, both passes) and the output
    // (pass-2 flags). out_starved high => z-score is the producer limiter; out_stalled high =>
    // OutputWriter backpressures us; in_starved high => decoder isn't feeding us fast enough.
    stream_profile_i profile_in ();
    stream_profile_i profile_out();

    assign profile.counters.in  = profile_in.counters;
    assign profile.counters.out = profile_out.counters;
    assign profile_in.stop      = profile.stop;
    assign profile_out.stop     = profile.stop;

    StreamProfiler inst_profile_in (
        .clk(clk),
        .rst_n(reset_synced),

        .last (in.tlast),
        .valid(in.tvalid),
        .ready(in.tready),

        .profile(profile_in)
    );

    StreamProfiler inst_profile_out (
        .clk(clk),
        .rst_n(reset_synced),

        .last (out.tlast),
        .valid(out.tvalid),
        .ready(out.tready),

        .profile(profile_out)
    );

endmodule
