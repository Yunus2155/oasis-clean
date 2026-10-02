`timescale 1ns / 1ps

import libstf::*;
import oasis::*;

`include "libstf_macros.svh"

/*
 * Host-supplied HBM scratch buffer for the z-score decode-once replay: one persistent buffer per
 * lane, holding the decoded column between pass 1 (CardWrite stores it) and pass 2 (ZScoreCardReplay
 * reads it back).
 *
 * WHY THE HOST HAS TO SUPPLY THIS (the bug that crashed alveo-u55c-09 on 2026-07-16): the vaddr
 * cannot be a constant chosen in RTL. Coyote has no card address space to choose from --
 * CoyoteAllocType is {REG, THP, HPF, PRM, GPU}, with no CARD option. There is ONE address space
 * (host virtual), and the driver tracks per-page whether those pages currently live in host DRAM or
 * in card HBM; LOCAL_OFFLOAD/LOCAL_SYNC migrate them. A descriptor's `strm` field selects WHICH COPY
 * of a vaddr the DMA hits, not a different address space. So a STRM_CARD write to a vaddr the host
 * never allocated makes the vFPGA page-fault into the driver, which then tries to pin an unmapped
 * user page (for the old hardcoded vaddr of 0, literally pin NULL).
 *
 * Unlike MemConfig this is a REGISTER, not a FIFO: the same buffer is reused for every row group, so
 * buffer_valid stays high and StreamWriter simply re-latches it (vaddr + counters reset) each time it
 * returns to WAIT_FOR_BUFFER. buffer_valid only rises once the host has actually written the
 * register, so CardWrite cannot start against an unmapped address after reset.
 *
 * Write layout (one register per lane, packed exactly like MemConfig's buffer_t):
 *     reg[I] = vaddr << BUFFER_SIZE_BITS | capacity_in_transfers
 * Read layout: [0] = CARD_BUFFER_CONFIG_ID, [1] = NUM_LANES.
 */
module CardBufferConfig #(
    parameter NUM_LANES
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    mem_config_i.m out[NUM_LANES]
);

localparam NUM_INFO_REGS  = CARD_BUFFER_INFO_REGS;
localparam NUM_WRITE_REGS = NUM_CARD_BUFFER_CONFIG_REGS;

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[NUM_INFO_REGS];
assign values[0] = CARD_BUFFER_CONFIG_ID;
assign values[1] = NUM_LANES;

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_INFO_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Write ----------------------------------------------------------------------------------------
for (genvar I = 0; I < NUM_LANES; I++) begin
    localparam int BUFFER_ADDR = I * NUM_WRITE_REGS + 0;

    buffer_t card_buffer;
    ConfigWriteRegister #(BUFFER_ADDR, buffer_t) inst_card_buffer (
        .clk(clk),

        .write_config(write_config),
        .data(card_buffer)
    );

    // Sticky: the buffer stays valid once written, so the same HBM region is reused for every row
    // group. Low until the host writes it, which keeps CardWrite parked in WAIT_FOR_BUFFER rather
    // than issuing a descriptor against an unmapped vaddr.
    logic card_buffer_written;
    always_ff @(posedge clk) begin
        if (!reset_synced) begin
            card_buffer_written <= 1'b0;
        end else if (write_config.valid && write_config.addr == BUFFER_ADDR) begin
            card_buffer_written <= 1'b1;
        end
    end

    assign out[I].buffer_data   = card_buffer;
    assign out[I].buffer_valid  = card_buffer_written;
    assign out[I].flush_buffers = 1'b0;
end

endmodule
