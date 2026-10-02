`timescale 1ns / 1ps

import oasis::*;

`include "axi_macros.svh"

// Standalone test of celeris my_z_score_squared in the oasis sim environment.
// Local mode (ENABLE_RDMA=OFF): N_STRM_AXI == 1, input arrives on axis_host_recv[0].
// The host feeds the SAME column twice (2-pass): pass 1 accumulates stats, pass 2 classifies.

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Signals --------------------------------------------------------------------------------------
AXI4S zscore_in(.aclk(clk), .aresetn(rst_n));
AXI4S zscore_out[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb zscore_out[I].tie_off_m();
end

// -- Configuration --------------------------------------------------------------------------------
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3.
localparam int MEM_REGS = (N_STRM_AXI + 1 > 3) ? N_STRM_AXI + 1 : 3;

write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({MEM_REGS})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_config[N_STRM_AXI](.*);
MemConfig #(
    .NUM_STREAMS(N_STRM_AXI)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_config)
);

// -- Z-score (squared, division-free) -------------------------------------------------------------
`AXIS_ASSIGN(axis_host_recv[0], zscore_in) // AXI4SR to AXI4S

decoder_profile_i zscore_profile();
assign zscore_profile.stop = 1'b0;

my_z_score_squared inst_z_score (
    .clk(clk),
    .rst_n(rst_n),

    .in(zscore_in),
    .out(zscore_out[0]),

    .profile(zscore_profile),

    // Global-z-score control unused here: LEGACY keeps the original per-stream 2-pass behaviour.
    .mode(2'd0),
    .mode_valid(1'b1),
    .global_count(32'd0),
    .global_sum(64'sd0),
    .global_sum_square(64'sd0)
);

// -- Output writer --------------------------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_config),

    .data_in(zscore_out),
    .data_out(axis_host_send)
);
