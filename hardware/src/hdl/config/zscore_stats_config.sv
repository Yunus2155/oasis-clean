`timescale 1ns / 1ps

import libstf::*;
import oasis::*;

`include "config_macros.svh"
`include "libstf_macros.svh"

// Host-written control for the global (whole-column) z-score, see the ZScoreStatsConfig comment in
// common.sv for why the two-phase scheme exists.
//
// There is deliberately NO per-lane readout here: phase 1's partial statistics come back through the
// normal output stream (one beat per row group) rather than through registers, so the host does not
// have to know which decoder lane processed which row group -- it just adds up what it collects.
//
// The outputs are broadcast unchanged to every z-score lane. All lanes classify against the same
// totals, and the host only rewrites them between phases, never while a stream is in flight.
module ZScoreStatsConfig (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    output logic [1:0]         mode,
    output logic [31:0]        global_count,
    output logic signed [63:0] global_sum,
    output logic signed [63:0] global_sum_square,

    // Goes high on the FIRST write to the mode register and stays there. The operator holds its
    // input off until this is set: AXI-Lite writes and the data stream are independent paths, and
    // the data can win. Measured in sim -- data reached the operator at 216 ns while the mode write
    // landed at 344 ns, so the operator ran a LEGACY pass 1 over it and then waited forever for a
    // second pass. Same class of bug as the min_set/scale_set gate in celeris' iqr.sv.
    output logic               mode_valid
);

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[ZSCORE_STATS_READ_REGS];

assign read_registers[0] = ZSCORE_STATS_CONFIG_ID;
assign read_registers[1] = {{(AXIL_DATA_BITS - 2){1'b0}}, mode};

ConfigReadRegisterFile #(
    .NUM_REGS(ZSCORE_STATS_READ_REGS)
) inst_read_register_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(read_registers)
);

// -- Write ----------------------------------------------------------------------------------------
ready_valid_i #(logic [AXIL_DATA_BITS-1:0]) w_mode      (clk, reset_synced);
ready_valid_i #(logic [AXIL_DATA_BITS-1:0]) w_count     (clk, reset_synced);
ready_valid_i #(logic [AXIL_DATA_BITS-1:0]) w_sum       (clk, reset_synced);
ready_valid_i #(logic [AXIL_DATA_BITS-1:0]) w_sum_square(clk, reset_synced);

ConfigWriteReadyRegister #(0, logic [AXIL_DATA_BITS-1:0]) inst_mode
    (clk, reset_synced, write_config, w_mode);
ConfigWriteReadyRegister #(1, logic [AXIL_DATA_BITS-1:0]) inst_count
    (clk, reset_synced, write_config, w_count);
ConfigWriteReadyRegister #(2, logic [AXIL_DATA_BITS-1:0]) inst_sum
    (clk, reset_synced, write_config, w_sum);
ConfigWriteReadyRegister #(3, logic [AXIL_DATA_BITS-1:0]) inst_sum_square
    (clk, reset_synced, write_config, w_sum_square);

// Accept immediately: these are plain latched values, nothing downstream can back-pressure them.
assign w_mode.ready       = 1'b1;
assign w_count.ready      = 1'b1;
assign w_sum.ready        = 1'b1;
assign w_sum_square.ready = 1'b1;

// Latch each word on its write pulse and hold it. Reset defaults to LEGACY so a bitstream that is
// never configured behaves exactly like the old per-stream 2-pass operator.
always_ff @(posedge clk) begin
    if (!reset_synced) begin
        mode              <= 2'(ZSCORE_MODE_LEGACY);
        mode_valid        <= 1'b0;
        global_count      <= '0;
        global_sum        <= '0;
        global_sum_square <= '0;
    end else begin
        if (w_mode.valid)       mode_valid        <= 1'b1;
        if (w_mode.valid)       mode              <= w_mode.data[1:0];
        if (w_count.valid)      global_count      <= w_count.data[31:0];
        if (w_sum.valid)        global_sum        <= signed'(w_sum.data[63:0]);
        if (w_sum_square.valid) global_sum_square <= signed'(w_sum_square.data[63:0]);
    end
end

endmodule
