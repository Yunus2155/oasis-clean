`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::TRANSFER_SIZE_BYTES;

`include "axi_macros.svh"
`include "libstf_macros.svh"

/**
 * Writes a single AXI4S stream into on-card HBM via an FPGA-initiated transfer. It is a thin wrapper
 * around StreamWriter with STRM = STRM_CARD: the ONLY difference from OutputWriter's host path is the
 * descriptor's strm field, which routes the DMA to card (HBM) memory instead of host DRAM. Same
 * opcode (LOCAL_WRITE), same engine, same completion handshake on cq_wr.
 *
 * Used in pass 1 of the z-score to cache the decoded column in HBM, so pass 2 can replay it from HBM
 * (see CardRead / ReadReqGenerator USE_CARD) instead of paying the decode cost a second time.
 *
 * NOTE: input_data must be a normalized stream (tkeep all 1s except on the last beat), exactly like
 * OutputWriter requires, since StreamWriter packs beats into fixed-length transfers.
 */
// NOTE: TRANSFER_LENGTH_BYTES must stay TRANSFER_SIZE_BYTES, matching OutputWriter. buffer_t's size
// field is only BUFFER_SIZE_BITS wide (28 - $clog2(TRANSFER_SIZE_BYTES)) and StreamWriter reads it in
// units of TRANSFER_LENGTH_BYTES, so any other value makes the writer interpret a host-packed buffer
// size in the wrong units. The host packs it as capacity / BYTES_PER_FPGA_TRANSFER (= 65536).
module CardWrite #(
    parameter AXI_STRM_ID = 0,
    parameter TRANSFER_LENGTH_BYTES = TRANSFER_SIZE_BYTES
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,
    metaIntf.m notify,

    mem_config_i.s mem_config, // card buffer (vaddr, size) the decoded column is stored at

    AXI4S.s  input_data,       // decoded values, tee'd from the decoder output in pass 1
    AXI4SR.m output_data       // -> axis_card_send[AXI_STRM_ID]
);

`RESET_RESYNC // Reset pipelining

StreamWriter #(
    .STRM(STRM_CARD),
    .AXI_STRM_ID(AXI_STRM_ID),
    .IS_LOCAL(1),
    .TRANSFER_LENGTH_BYTES(TRANSFER_LENGTH_BYTES)
) inst_stream_writer (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_config),

    .input_data(input_data),
    .output_data(output_data)
);

endmodule
