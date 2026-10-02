`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"

// Standalone sim of the DECODE-ONCE z-score path in the oasis sim environment.
// Local mode (ENABLE_RDMA=OFF): N_STRM_AXI == 1, N_CARD_AXI == 1.
//
// Pass 1: the host sends the column ONCE on axis_host_recv[0]. The values (already int32, the decoder
//         is skipped here since it is tested separately) are forked: one copy feeds the z-score, one
//         copy is stored into HBM by CardWrite (strm=STRM_CARD) at card vaddr 0.
// Pass 2: ZScoreCardReplay waits for the store to complete, self-issues a card read of the same
//         buffer, and feeds the replayed data to the z-score -- so the second pass never re-reads
//         from the host. The z-score emits one flag per value (1 = outlier).
//
// This exercises: CardWrite store, the sq_wr/cq/notify sharing with OutputWriter, the card read on
// the sq_rd arbiter, the replay FSM + input mux, and the card-memory model in the sim testbench.

localparam int DATABEAT_SIZE      = AXI_DATA_BITS / 8;
localparam int CARD_BUF_LOG2_BYTES = 30;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;
assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration (MemConfig for the OutputWriter host buffers) ----------------------------------
localparam int MEM_REGS = (N_STRM_AXI + 1 > 3) ? N_STRM_AXI + 1 : 3;

write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({MEM_REGS})
) inst_config (
    .clk(clk), .rst_n(rst_n),
    .axi_ctrl(axi_ctrl),
    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_config[N_STRM_AXI](.*);
MemConfig #(.NUM_STREAMS(N_STRM_AXI)) inst_mem_config (
    .clk(clk), .rst_n(rst_n),
    .write_config(write_configs[0]),
    .read_config(read_configs[0]),
    .out(mem_config)
);

// -- Write send-queue sharing: OutputWriter (slot 0) + CardWrite (slot 1) -------------------------
localparam int N_WR = 2;
metaIntf #(.STYPE(req_t))     wr_sq     [N_WR](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(irq_not_t)) wr_notify [N_WR](.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_host       (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card_all   (.aclk(clk), .aresetn(rst_n));
metaIntf #(.STYPE(ack_t))     wr_cq_card[1]    (.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(.N_INTERFACES(N_WR), .STYPE(req_t)) inst_sq_wr_share (
    .clk(clk), .rst_n(rst_n), .intf_in(wr_sq), .intf_out(sq_wr)
);
MetaIntfArbiter #(.N_INTERFACES(N_WR), .STYPE(irq_not_t)) inst_notify_share (
    .clk(clk), .rst_n(rst_n), .intf_in(wr_notify), .intf_out(notify)
);
always_comb begin
    wr_cq_host.valid     = cq_wr.valid && (cq_wr.data.strm == STRM_HOST);
    wr_cq_host.data      = cq_wr.data;
    wr_cq_card_all.valid = cq_wr.valid && (cq_wr.data.strm == STRM_CARD);
    wr_cq_card_all.data  = cq_wr.data;
    cq_wr.ready = (cq_wr.data.strm == STRM_CARD) ? wr_cq_card_all.ready : wr_cq_host.ready;
end
CQDemultiplexer #(.N_STREAMS(1)) inst_card_cq_demux (
    .clk(clk), .rst_n(rst_n), .data_in(wr_cq_card_all), .data_out(wr_cq_card)
);

// -- Read send-queue: only the card read here (slot 0) --------------------------------------------
metaIntf #(.STYPE(req_t)) sq_rd_strm [1](.aclk(clk), .aresetn(rst_n));
MetaIntfArbiter #(.N_INTERFACES(1), .STYPE(req_t)) inst_sq_rd_arb (
    .clk(clk), .rst_n(rst_n), .intf_in(sq_rd_strm), .intf_out(sq_rd)
);

// -- Input: host column -> ndata -> fork ----------------------------------------------------------
AXI4S axi_host_in(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_in)

ndata_i #(data8_t, DATABEAT_SIZE) decoded_nd(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata (
    .clk(clk), .rst_n(rst_n), .in(axi_host_in), .out(decoded_nd)
);

ndata_i #(data8_t, DATABEAT_SIZE) out_fork[2](.*);
NDataDuplicator #(2) inst_fork (
    .clk(clk), .rst_n(rst_n), .in(decoded_nd), .out(out_fork)
);

AXI4S axi_decoded(.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_nd2axi_z (
    .clk(clk), .rst_n(rst_n), .in(out_fork[0]), .out(axi_decoded)
);

AXI4S axi_card_store(.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_nd2axi_c (
    .clk(clk), .rst_n(rst_n), .in(out_fork[1]), .out(axi_card_store)
);

// -- CardWrite: store the column into HBM ---------------------------------------------------------
mem_config_i card_mem_conf(clk, rst_n);
assign card_mem_conf.buffer_data.vaddr = 0;
assign card_mem_conf.buffer_data.size  = 1 << CARD_BUF_LOG2_BYTES;
assign card_mem_conf.buffer_valid      = 1'b1;
assign card_mem_conf.flush_buffers     = 1'b0;

CardWrite #(.AXI_STRM_ID(0)) inst_card_write (
    .clk(clk), .rst_n(rst_n),
    .sq_wr (wr_sq [1]),
    .cq_wr (wr_cq_card[0]),
    .notify(wr_notify[1]),
    .mem_config(card_mem_conf),
    .input_data(axi_card_store),
    .output_data(axis_card_send[0])
);

// -- Replay control: pass 1 = decoded passthrough, pass 2 = HBM replay ----------------------------
AXI4S axi_card_recv_s(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_card_recv[0], axi_card_recv_s)

logic store_done;
assign store_done = wr_notify[1].valid && wr_notify[1].ready && wr_notify[1].data.value[31];

AXI4S axi_zin(.aclk(clk), .aresetn(rst_n));
ZScoreCardReplay #(
    .AXI_STRM_ID(0),
    .DATABEAT_SIZE(DATABEAT_SIZE),
    .CARD_VADDR(0)
) inst_replay (
    .clk(clk), .rst_n(rst_n),
    .decoded_in(axi_decoded),
    .card_recv(axi_card_recv_s),
    .sq_rd(sq_rd_strm[0]),
    .store_done(store_done),
    .zscore_in(axi_zin)
);

// -- Z-score --------------------------------------------------------------------------------------
AXI4S zscore_out[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));
for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb zscore_out[I].tie_off_m();
end

decoder_profile_i zscore_profile();
assign zscore_profile.stop = 1'b0;

my_z_score_squared inst_z_score (
    .clk(clk), .rst_n(rst_n),
    .in(axi_zin),
    .out(zscore_out[0]),
    .profile(zscore_profile),

    // Global-z-score control unused here: LEGACY keeps the original per-stream 2-pass behaviour.
    .mode(2'd0),
    .mode_valid(1'b1),
    .global_count(32'd0),
    .global_sum(64'sd0),
    .global_sum_square(64'sd0)
);

// -- Output writer (flags -> host) ----------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk), .rst_n(rst_n),
    .sq_wr(wr_sq[0]),
    .cq_wr(wr_cq_host),
    .notify(wr_notify[0]),
    .mem_config(mem_config),
    .data_in(zscore_out),
    .data_out(axis_host_send)
);
