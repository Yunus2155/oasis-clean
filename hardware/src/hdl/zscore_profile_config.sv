`timescale 1ns / 1ps

import libstf::*;
import oasis::*;

`include "libstf_macros.svh"

// Read-only config that exposes the per-lane z-score StreamProfiler counters to the host. It mirrors
// the readout half of ColumnChunkDecoderConfig (same register layout, same stop-on-last-read
// behaviour) but has no write path, because the z-score stage takes no host configuration.
module ZScoreProfileConfig #(
    parameter NUM_ZSCORES
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s read_config,

    decoder_profile_i.s profile[NUM_ZSCORES],

    // Link-level egress measurement: total 64B beats across all host-send streams, the cycles at
    // least one stream was back-pressured, and the elapsed cycles. One numerator, one denominator,
    // one clock -- unlike the per-lane counters above, these can be divided directly to get the PCIe
    // write rate and the link-level stall fraction.
    input  data64_t agg_beats,
    input  data64_t agg_stalled,
    input  data64_t agg_window,
    output logic    agg_stop
);

localparam NUM_INFO_REGS    = ZSCORE_PROFILE_INFO_REGS;
localparam NUM_PROFILE_REGS = ZSCORE_PROFILE_PROFILE_REGS;
localparam NUM_READ_REGS    = ZSCORE_PROFILE_READ_REGS(NUM_ZSCORES);
// First of the two appended aggregate registers.
localparam AGG_BASE         = NUM_INFO_REGS + NUM_PROFILE_REGS * NUM_ZSCORES;

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[NUM_READ_REGS];
assign values[0] = ZSCORE_PROFILE_CONFIG_ID;
assign values[1] = NUM_ZSCORES;

for (genvar I = 0; I < NUM_ZSCORES; I++) begin
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 0] = profile[I].counters.in.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 1] = profile[I].counters.in.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 2] = profile[I].counters.in.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 3] = profile[I].counters.in.idle_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 4] = profile[I].counters.out.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 5] = profile[I].counters.out.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 6] = profile[I].counters.out.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 7] = profile[I].counters.out.idle_cycles;
end

assign values[AGG_BASE + 0] = agg_beats;
assign values[AGG_BASE + 1] = agg_stalled;
assign values[AGG_BASE + 2] = agg_window;

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_READ_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Profile stop ---------------------------------------------------------------------------------
// The host reads a lane's 8 profile counters in ascending order. We detect the last read handshake
// and pulse stop[I] so the profilers reset once the full snapshot has been read out.
logic read_handshake;
assign read_handshake = read_config.read_valid && read_config.read_ready;

for (genvar I = 0; I < NUM_ZSCORES; I++) begin
    localparam int LAST_PROFILE_REG = NUM_INFO_REGS + NUM_PROFILE_REGS * (I + 1) - 1;
    assign profile[I].stop = read_handshake && (read_config.read_addr == LAST_PROFILE_REG);
end

// Same rule for the aggregate set: reset once its last register has been read out.
// HARDENED after the build-34/35 silicon bug: the combinational form of this compare was
// synthesized with the low 3 address bits dropped (the clear fired on the whole aligned
// 8-register block around the window register -- deterministic on two independent builds,
// source provably correct). So: compare against an int constant (the per-lane compares above
// use int and decode correctly), REGISTER the result, and pin the flop with dont_touch so no
// optimization pass can restructure the comparator. The one-cycle-late clear is harmless: the
// read value is latched on the handshake cycle, and the next read is thousands of cycles away.
localparam int AGG_LAST_REG = AGG_BASE + ZSCORE_PROFILE_AGG_REGS - 1;

(* dont_touch = "true" *) logic agg_stop_reg;
always_ff @(posedge clk) begin
    if (!reset_synced) begin
        agg_stop_reg <= 1'b0;
    end else begin
        agg_stop_reg <= read_handshake && (read_config.read_addr == AGG_LAST_REG);
    end
end
assign agg_stop = agg_stop_reg;

endmodule
