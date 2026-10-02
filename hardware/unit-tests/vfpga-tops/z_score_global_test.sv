`timescale 1ns / 1ps

import oasis::*;

`include "axi_macros.svh"

// Test top for the GLOBAL (whole-column) z-score modes. Same wiring as z_score_test.sv, but the
// z-score's mode/statistics inputs come from a real ZScoreStatsConfig instead of being tied to
// LEGACY, so the Python test can drive them over AXI-Lite.
//
// Config slots: [0] = MemConfig (the OutputWriter's buffers, discovered by the test framework),
// [1] = ZScoreStatsConfig. GlobalConfig itself occupies registers 0..2, so slot 0 starts at 3 and
// the stats registers start at 3 + MEM_REGS -- the Python test computes the same offset.

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
localparam int STATS_REGS =
    (ZSCORE_STATS_WRITE_REGS > ZSCORE_STATS_READ_REGS) ? ZSCORE_STATS_WRITE_REGS : ZSCORE_STATS_READ_REGS;

write_config_i write_configs[2](.*);
read_config_i  read_configs [2](.*);

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({MEM_REGS, STATS_REGS})
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

logic [1:0]         zscore_mode;
logic [31:0]        zscore_global_count;
logic signed [63:0] zscore_global_sum;
logic signed [63:0] zscore_global_sum_square;
logic               zscore_mode_valid;

ZScoreStatsConfig inst_zscore_stats_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config (read_configs [1]),

    .mode             (zscore_mode),
    .mode_valid       (zscore_mode_valid),
    .global_count     (zscore_global_count),
    .global_sum       (zscore_global_sum),
    .global_sum_square(zscore_global_sum_square)
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

    .mode             (zscore_mode),
    .mode_valid       (zscore_mode_valid),
    .global_count     (zscore_global_count),
    .global_sum       (zscore_global_sum),
    .global_sum_square(zscore_global_sum_square)
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
