package oasis;

import libstf::vaddress_t;
import libstf::size_t;

parameter longint unsigned OASIS_SYSTEM_ID = 64'h0A515;

parameter int NUM_READ_REQ_CONFIG_REGS = 2;
parameter longint unsigned READ_REQ_CONFIG_ID = 64'h2f966a70f04c0e93;

typedef struct packed {
    vaddress_t vaddr;
    size_t     len;
} read_req_t;

// -- ZScoreProfileConfig: read-only readout of the per-lane z-score StreamProfiler counters --------
// Layout mirrors the decoder profile readout: [0] = CONFIG_ID, [1] = NUM_ZSCORES, then 8 counters
// per z-score lane (4 input-stream + 4 output-stream).
// The 3 aggregate registers are APPENDED after the per-lane block so every existing index keeps its
// meaning: [.. per-lane ..][beats][stalled][window]. They carry one link-level measurement -- total
// 64B beats across ALL egress streams, the cycles at least one stream was back-pressured, and the
// elapsed cycles -- because the per-lane profilers each start on their own first beat and so have no
// common timebase to divide by. `window` is read LAST: that read is what resets the set.
parameter longint unsigned ZSCORE_PROFILE_CONFIG_ID    = 64'h7a5c012e9b3d4f60;
parameter longint unsigned ZSCORE_PROFILE_INFO_REGS    = 2;
parameter longint unsigned ZSCORE_PROFILE_PROFILE_REGS = 8;
parameter longint unsigned ZSCORE_PROFILE_AGG_REGS     = 3;
function automatic longint unsigned ZSCORE_PROFILE_READ_REGS(input int num_zscores);
    return ZSCORE_PROFILE_INFO_REGS + ZSCORE_PROFILE_PROFILE_REGS * num_zscores
         + ZSCORE_PROFILE_AGG_REGS;
endfunction

// -- ZScoreStatsConfig: whole-column (global) z-score statistics -----------------------------------
// A z-score should compare a value against the mean/variance of the WHOLE column, but the hardware
// only ever sees one parquet row group per stream: `tlast` arrives at the end of each column chunk,
// which is what the operator uses to end pass 1. So a single stream can only produce that group's
// statistics, and classifying inside it normalises each row group on itself. That is invisible on
// i.i.d. data and wrong on real, ordered data (measured on NYC taxi 2026-08-04).
//
// Sum, sum-of-squares and count are ADDITIVE, so the host runs two phases instead:
//   phase 1  every row group streams through in STATS mode -- pass 1 only, ending in a single beat
//            carrying that group's (count, sum, sum_square); the host adds the partials up
//   phase 2  the totals are written here and every row group is re-streamed in CLASSIFY mode, which
//            skips pass 1 entirely and compares against the supplied totals
// The data crosses PCIe exactly twice either way, so this costs no extra bandwidth over the old
// per-stream 2-pass, and row groups stay independent flows (windowing/lanes are unaffected).
//
// Write layout: [0] = mode, [1] = count, [2] = sum, [3] = sum_square. AXI-Lite registers are 64 bit,
// so sum and sum_square each fit in one. Read: [0] = CONFIG_ID, [1] = mode readback.
parameter longint unsigned ZSCORE_STATS_CONFIG_ID  = 64'h5d3f8a1c60b7e924;
parameter int              ZSCORE_STATS_WRITE_REGS = 4;
parameter int              ZSCORE_STATS_READ_REGS  = 2;

// Values written to write register 0.
parameter int ZSCORE_MODE_LEGACY   = 0; // per-stream 2-pass: each row group normalised on itself
parameter int ZSCORE_MODE_STATS    = 1; // pass 1 only; emit one beat of (count, sum, sum_square)
parameter int ZSCORE_MODE_CLASSIFY = 2; // skip pass 1; classify against the host-supplied totals

endpackage
