`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

`ifdef EN_RDMA
always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

// The z-score stats slot is appended LAST so every existing slot keeps its address range -- the
// egress aggregate counter's readout order workaround depends on where those registers sit.
localparam NUM_CONFIGS   = 5;   // [0]=mem, [1]=decoder, [2]=read-req, [3]=z-score profile, [4]=z-score stats

// ZScoreStatsConfig needs 4 write registers (mode, count, sum, sum_square) and 2 read.
localparam ZSCORE_STATS_NUM_REGS =
    (ZSCORE_STATS_WRITE_REGS > ZSCORE_STATS_READ_REGS) ? ZSCORE_STATS_WRITE_REGS : ZSCORE_STATS_READ_REGS;
`ifdef EN_RDMA
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_DECODERS  = NUM_STREAMS;
`endif


// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
ready_valid_i #(read_req_t)          read_conf[NUM_STREAMS](.*);
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);
decoder_profile_i                    decoder_profiles[NUM_DECODERS]();
// Slots 0..NUM_DECODERS-1 are the per-lane z-scores. The NUM_STREAMS slots after them are the egress
// taps on axis_host_send -- see inst_egress_profile below.
localparam NUM_ZSCORE_PROFILES = NUM_DECODERS + NUM_STREAMS;
decoder_profile_i                    zscore_profiles [NUM_ZSCORE_PROFILES]();
// Link-level egress counters -- driven at the bottom of this file, read out via ZScoreProfileConfig.
logic [31:0]                         egress_agg_beats, egress_agg_stalled, egress_agg_window;
logic                                egress_agg_stop;
// Global-z-score control, driven by ZScoreStatsConfig and broadcast to every z-score lane.
logic [1:0]                          zscore_mode;
logic [31:0]                         zscore_global_count;
logic signed [63:0]                  zscore_global_sum;
logic signed [63:0]                  zscore_global_sum_square;
logic                                zscore_mode_valid;

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS,
        ZSCORE_PROFILE_READ_REGS(NUM_ZSCORE_PROFILES)
        , ZSCORE_STATS_NUM_REGS
    })
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

MemConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf),

    .profile(decoder_profiles)
);

ReadReqConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_read_req_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(read_conf)
);

// Read-only: exposes the per-lane z-score StreamProfiler counters, followed by the per-stream egress
// taps. write_configs[3] is unused (the z-score takes no host configuration); GlobalConfig still
// drives it but nothing consumes it.
ZScoreProfileConfig #(
    .NUM_ZSCORES(NUM_ZSCORE_PROFILES)
) inst_zscore_profile_config (
    .clk(clk),
    .rst_n(rst_n),

    .read_config(read_configs[3]),

    .profile(zscore_profiles),

    .agg_beats  ({32'b0, egress_agg_beats}),
    .agg_stalled({32'b0, egress_agg_stalled}),
    .agg_window ({32'b0, egress_agg_window}),
    .agg_stop   (egress_agg_stop)
);

// Global (whole-column) z-score control. Sits in the LAST config slot so it does not shift any
// existing slot's address range. See the ZScoreStatsConfig comment in common.sv for the two-phase
// scheme; on a bitstream nobody configures, mode resets to LEGACY and the operator behaves exactly
// as before.
ZScoreStatsConfig inst_zscore_stats_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[NUM_CONFIGS - 1]),
    .read_config (read_configs [NUM_CONFIGS - 1]),

    .mode             (zscore_mode),
    .mode_valid       (zscore_mode_valid),
    .global_count     (zscore_global_count),
    .global_sum       (zscore_global_sum),
    .global_sum_square(zscore_global_sum_square)
);


// -- Arbiter the read send queue ------------------------------------------------------------------
// Slots 0..NUM_STREAMS-1 = the host/RDMA reads.
localparam int N_RD = NUM_STREAMS;
metaIntf #(.STYPE(req_t)) sq_rd_strm [N_RD](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(N_RD),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

// -- Data path ------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < NUM_DECODERS; I++) begin
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in(.*);
    typed_ndata_i #(DATABEAT_SIZE)          typed_out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) out(.*);

`ifdef EN_RDMA
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    LocalRead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_local_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`endif

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_column_chunk_decoder (
        .clk(clk),
        .rst_n(rst_n),

        .conf(column_chunk_conf[I]),

        .in(decoder_in),
        .out(typed_out),

        .profile(decoder_profiles[I])
    );

    // Discard typed
    `DATA_ASSIGN(typed_out, out);

    // -- 2-pass z-score ------------------------------------------------------------------------------
    // The column is decoded TWICE from the host: pass 1 accumulates Sum/Sum^2/count, pass 2
    // classifies. The z-score reads straight from the decoder each
    // pass. REQUIRED HOST BEHAVIOUR: the host must submit each row-group TWICE (once per pass).
    AXI4S axi_decoded(.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(out),
        .out(axi_decoded)
    );

    AXI4S axi_zout(.aclk(clk), .aresetn(rst_n));
    my_z_score_squared inst_z_score (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_decoded),
        .out(axi_zout),

        .profile(zscore_profiles[I]),

        // Global-z-score control, broadcast identically to every lane (see ZScoreStatsConfig).
        .mode(zscore_mode),
        .mode_valid(zscore_mode_valid),
        .global_count(zscore_global_count),
        .global_sum(zscore_global_sum),
        .global_sum_square(zscore_global_sum_square)
    );

    // z-score -> OutputWriter backpressure crossing.
    AXISkidBuffer inst_zout_skid (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_zout),
        .out(axi_out[I])
    );
end

// -- RDMA bypass stream (last stream slot, no decoder) --------------------------------------------
`ifdef EN_RDMA
localparam BYPASS_ID = NUM_STREAMS - 1;

AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

// AXI4SR to AXI4S
`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[BYPASS_ID]),
    .sq_rd(sq_rd_strm[BYPASS_ID]),    

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`endif

// -- Output writer --------------------------------------------------------------------------------
// The OutputWriter owns the shell write queue directly.
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);

// -- Egress (PCIe) profiling ----------------------------------------------------------------------
// axis_host_send is the LAST signal user logic can see: past it sits local_credits_host_wr, which
// only accepts a beat when the DMA engine has credit to drain it over PCIe. So `stalled` here means
// the PCIe write path itself has no room -- the one direct measurement of link saturation.
//
// This is why the existing taps cannot answer the question: the decoder's out_stalled and the
// z-score's out_stalled both just say "somebody downstream is full", lumping the z-score, the
// OutputWriter, the shared sq_wr arbiter and PCIe together. Comparing them against these counters
// localises the backpressure to a specific hop.
//
// Read out through the existing ZScoreProfileConfig as rows NUM_DECODERS..NUM_DECODERS+NUM_STREAMS-1
// (no host change needed -- it publishes its own count). Only the `out` half is meaningful: there is
// a single interface to watch, so `in` is tied off.
// Egress bytes = out_handshakes x DATABEAT_SIZE; GB/s = bytes / (total_cycles x 4ns) @250MHz.
stream_profile_i egress_profiles[NUM_STREAMS]();

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    localparam int P = NUM_DECODERS + I;

    assign zscore_profiles[P].counters.in  = '0;
    assign zscore_profiles[P].counters.out = egress_profiles[I].counters;
    assign egress_profiles[I].stop         = zscore_profiles[P].stop;

    StreamProfiler inst_egress_profile (
        .clk(clk),
        .rst_n(rst_n),

        .last (axis_host_send[I].tlast),
        .valid(axis_host_send[I].tvalid),
        .ready(axis_host_send[I].tready),

        .profile(egress_profiles[I])
    );
end

// -- Link-level egress window ---------------------------------------------------------------------
// The per-lane profilers above each start on THEIR OWN first beat and stop at their own last stream,
// so their windows are independent: summing three lanes' bytes and dividing by one lane's window
// silently assumes the windows align, which nothing guarantees. This pair fixes that by measuring
// once across all streams -- egress_agg_beats counts every 64B beat that crossed ANY host-send
// stream, egress_agg_window counts elapsed cycles from the first such beat until the host reads the
// counters out. Dividing them needs no alignment assumption:
//     PCIe write GB/s = (beats x DATABEAT_SIZE) / (window x 4ns)   @250MHz
// Gap cycles (no stream valid anywhere) are staged in egress_agg_gap and only committed to the
// window when the next beat arrives -- same trick as StreamProfiler's idle_acc_reg -- so the window
// effectively ends at the LAST beat and the value does not depend on when the host reads it.
// Flatten the interface array into plain vectors first: an interface array can only be indexed by a
// genvar, not by a procedural loop variable inside always_comb.
logic [NUM_STREAMS - 1:0] egress_valid, egress_beat, egress_blocked;
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    assign egress_valid  [I] = axis_host_send[I].tvalid;
    assign egress_beat   [I] = axis_host_send[I].tvalid &&  axis_host_send[I].tready;
    assign egress_blocked[I] = axis_host_send[I].tvalid && !axis_host_send[I].tready;
end

logic egress_any_valid, egress_any_blocked;
logic [$clog2(NUM_STREAMS + 1) - 1:0] egress_beats_this_cycle;

always_comb begin
    egress_any_valid        = |egress_valid;
    // A cycle counts as stalled if ANY stream had a beat ready that the DMA would not take. This is
    // the link-level backpressure fraction: no per-lane window, no alignment assumption.
    egress_any_blocked      = |egress_blocked;
    egress_beats_this_cycle = '0;
    for (int i = 0; i < NUM_STREAMS; i++) begin
        egress_beats_this_cycle += egress_beat[i];
    end
end

logic        egress_agg_started;
logic [31:0] egress_agg_gap;
always_ff @(posedge clk) begin
    if (!rst_n || egress_agg_stop) begin
        egress_agg_started <= 1'b0;
        egress_agg_beats   <= '0;
        egress_agg_stalled <= '0;
        egress_agg_window  <= '0;
        egress_agg_gap     <= '0;
    end else if (egress_agg_started || egress_any_valid) begin
        egress_agg_started <= 1'b1;
        if (egress_any_valid) begin
            // Commit this cycle plus any staged gap since the previous valid cycle. stalled and
            // beats can only move on valid cycles, so they need no staging.
            egress_agg_beats   <= egress_agg_beats   + egress_beats_this_cycle;
            egress_agg_stalled <= egress_agg_stalled + egress_any_blocked;
            egress_agg_window  <= egress_agg_window  + egress_agg_gap + 1;
            egress_agg_gap     <= '0;
        end else begin
            // No stream valid anywhere: stage the cycle. If no beat ever follows (query is over),
            // this is discarded uncommitted -- the window ends at the last beat.
            egress_agg_gap <= egress_agg_gap + 1;
        end
    end
end
