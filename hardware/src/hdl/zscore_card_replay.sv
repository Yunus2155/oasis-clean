`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::vaddress_t;
import oasis::read_req_t;

/*
 * Decode-once replay control for one z-score lane.
 *
 * Pass 1: passes the decoded stream straight through to the z-score (the column is simultaneously
 *         stored to HBM by a sibling CardWrite at card_vaddr).
 * Between passes: once the HBM store has completed (store_done), it issues a single card read
 *         (LOCAL_READ + STRM_CARD via LocalRead USE_CARD=1) of store_bytes bytes from card_vaddr.
 *         The returned data arrives on card_recv (axis_card_recv[AXI_STRM_ID]).
 * Pass 2: feeds the HBM-replayed data to the z-score instead of re-decoding. The z-score naturally
 *         backpressures (in.tready) until the replay data arrives, so no explicit "wait" is needed.
 *
 * The replay length is NOT recomputed here -- it comes from the CardWrite's own notify
 * (bytes_written_to_allocation), which is by definition how many bytes are actually in the buffer.
 * An earlier version counted $countones(tkeep) over the raw pass-1 beats in parallel, which is both a
 * second source of truth and wrong: StreamWriter counts the same thing only AFTER an
 * AXINullBeatSuppressor, so the raw stream it never sees can poison the tally.
 *
 * EXPERIMENTAL. Key assumptions to verify: (1) store_done is a single pulse that means "all pass-1
 * bytes are durably in HBM"; (2) card reads return on axis_card_recv[AXI_STRM_ID] with the same dest.
 */
module ZScoreCardReplay #(
    parameter AXI_STRM_ID   = 0,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s decoded_in,   // pass-1 decoded stream (from the decoder fork)
    AXI4S.s card_recv,    // axis_card_recv[AXI_STRM_ID] as AXI4S: HBM read return data
    metaIntf.m sq_rd,     // card read request (issued once, between passes)

    // Host-allocated card buffer this lane replays from, straight off CardBufferConfig -- the SAME
    // vaddr the sibling CardWrite stored to. It must be a real, TLB-mapped host allocation: Coyote
    // has no card address space, so a vaddr invented here page-faults the vFPGA into the driver.
    input vaddress_t card_vaddr,

    input logic store_done, // pulse: the sibling CardWrite finished storing pass 1 to HBM
    // How many bytes that store actually wrote, straight from the CardWrite notify's
    // bytes_written_to_allocation field. Valid with store_done; this is the replay read's length.
    input logic [27:0] store_bytes,

    AXI4S.m zscore_in     // muxed stream into the z-score
);

`RESET_RESYNC // Reset pipelining

// -- Card reader (reads the stored column back from HBM) ------------------------------------------
ready_valid_i #(read_req_t) card_conf (clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) card_ndata(clk, reset_synced);

LocalRead #(
    .AXI_STRM_ID(AXI_STRM_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE),
    .USE_CARD(1)
) inst_card_read (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(card_conf),
    .sq_rd(sq_rd),

    .in(card_recv),
    .out(card_ndata)
);

AXI4S axi_card_replay(.aclk(clk), .aresetn(reset_synced));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_card_ndata_to_axi (
    .clk(clk),
    .rst_n(reset_synced),

    .in(card_ndata),
    .out(axi_card_replay)
);

// -- Control FSM ----------------------------------------------------------------------------------
typedef enum logic [1:0] { PASS1, WAIT_STORE, ISSUE_READ, PASS2 } state_t;
state_t state;

logic sel_card;            // 0 => decoded_in (pass 1), 1 => axi_card_replay (pass 2)
assign sel_card = (state == PASS2);

// pass-1 / pass-2 last beats (on the z-score-facing side)
wire p1_last = (state == PASS1) && decoded_in.tvalid && decoded_in.tready && decoded_in.tlast;
wire p2_last = (state == PASS2) && zscore_in.tvalid && zscore_in.tready && zscore_in.tlast;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        state <= PASS1;
        card_conf.valid <= 1'b0;
    end else begin
        case (state)
            PASS1: begin
                if (p1_last) state <= WAIT_STORE;
            end
            WAIT_STORE: begin
                if (store_done) begin
                    card_conf.data.vaddr <= card_vaddr;
                    card_conf.data.len   <= store_bytes;
                    card_conf.valid      <= 1'b1;
                    state                <= ISSUE_READ;
                end
            end
            ISSUE_READ: begin
                if (card_conf.ready) begin
                    card_conf.valid <= 1'b0;
                    state           <= PASS2;
                end
            end
            PASS2: begin
                if (p2_last) state <= PASS1;
            end
        endcase
    end
end

// -- Input mux into the z-score -------------------------------------------------------------------
always_comb begin
    if (sel_card) begin
        zscore_in.tvalid     = axi_card_replay.tvalid;
        zscore_in.tdata      = axi_card_replay.tdata;
        zscore_in.tkeep      = axi_card_replay.tkeep;
        zscore_in.tlast      = axi_card_replay.tlast;
        axi_card_replay.tready = zscore_in.tready;
        decoded_in.tready    = 1'b0;
    end else begin
        zscore_in.tvalid     = decoded_in.tvalid;
        zscore_in.tdata      = decoded_in.tdata;
        zscore_in.tkeep      = decoded_in.tkeep;
        zscore_in.tlast      = decoded_in.tlast;
        decoded_in.tready    = zscore_in.tready;
        axi_card_replay.tready = 1'b0;
    end
end

endmodule
