#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <cstdint>
#include <libstf/configuration.hpp>
#include <parcore/configuration.hpp> // parcore::DecoderProfile (reused for the z-score stage)
#include <utility>
#include <vector>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

// Per-stream write registers: [0] vaddr, [1] size. MUST match NUM_READ_REQ_CONFIG_REGS in
// hardware/src/hdl/common.sv -- the hardware lays the per-stream FIFOs out at this stride, so a
// mismatch makes stream N's writes land in stream N+1's registers.
constexpr const uint64_t READ_REQ_CONFIG_REGS = 2;
constexpr const uint64_t READ_REQ_CONFIG_ID   = 0x2f966a70f04c0e93;

// Read-side register layout of the ZScoreProfileConfig: 2 info registers ([0]=ID, [1]=num_zscores)
// followed by 8 profiling counters per z-score lane (4 input + 4 output). Mirrors the HW layout in
// hardware/src/hdl/common.sv.
constexpr const uint64_t ZSCORE_PROFILE_CONFIG_ID   = 0x7a5c012e9b3d4f60;
constexpr const uint32_t ZSCORE_PROFILE_INFO_REGS    = 2;
constexpr const uint32_t ZSCORE_PROFILE_PROFILE_REGS = 8;
// Three aggregate registers appended after the per-lane block: [beats][stalled][window]. See
// common.sv.
constexpr const uint32_t ZSCORE_PROFILE_AGG_REGS     = 3;

// ZScoreStatsConfig: whole-column (global) z-score control. Write registers are
// [0]=mode, [1]=count, [2]=sum, [3]=sum_square. MUST match hardware/src/hdl/common.sv.
constexpr const uint64_t ZSCORE_STATS_CONFIG_ID = 0x5d3f8a1c60b7e924;
constexpr const uint32_t ZSCORE_STATS_MODE_REG       = 0;
constexpr const uint32_t ZSCORE_STATS_COUNT_REG      = 1;
constexpr const uint32_t ZSCORE_STATS_SUM_REG        = 2;
constexpr const uint32_t ZSCORE_STATS_SUM_SQUARE_REG = 3;

/**
 * Configues a hardware read request module to fetch data.
 */
class ReadReqConfig : public libstf::Config {
  public:
    ReadReqConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                   uint32_t num_regs);

    /**
     * For RDMA reads, sets the base vaddr of the remote region that read addresses are relative to.
     * It must be set before the first enqueue_read().
     */
    void set_base_vaddr(uintptr_t base_vaddr);

    // NOTE: there is deliberately no set_pid(). The hardware has no pid register -- ReadReqConfig
    // instantiates only the vaddr and len FIFOs per stream, and ReadReqGenerator hardcodes
    // sq_rd.data.pid = 0. Giving each stream its own ctid (for parallel RDMA queue pairs) needs a
    // third per-stream register in hardware first, and NUM_READ_REQ_CONFIG_REGS bumped to match.

    /**
     * Triggers a read request using the `RDMARead` or `LocalRead` module.
     *
     * Reads are relative to the base virtual address set via set_base_vaddr().
     */
    void enqueue_read(libstf::stream_t stream, size_t vaddr, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr size_t MAXIMUM_NUM_ENQUEUED_REQUESTS = 64;

    static constexpr uint64_t ID = READ_REQ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
    uintptr_t        base_vaddr_ = 0;
};

/**
 * Read-only access to the per-lane z-score StreamProfiler counters (one z-score lane per decoder).
 * Mirrors parcore::ColumnChunkDecoderConfig::read_profile, against the ZScoreProfileConfig slot.
 */
class ZScoreProfileConfig : public libstf::Config {
  public:
    ZScoreProfileConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                        uint32_t num_regs);

    /**
     * Reads the input and output StreamProfiler counters for the given z-score lane.
     *
     * @param zscore The z-score lane whose profiling counters to read.
     */
    parcore::DecoderProfile read_profile(libstf::stream_t zscore);

    const libstf::stream_t num_zscores() const;

    /**
     * One link-level measurement of the PCIe write path: total 64-byte beats across ALL egress
     * streams, the cycles at least one stream was back-pressured, and the elapsed cycles. The
     * per-lane counters from read_profile() each use their own window, so they cannot be combined
     * into a link rate; these share one clock and can be divided directly.
     */
    struct EgressAggregate {
        uint64_t beats;
        uint64_t stalled_cycles;
        uint64_t window_cycles;
    };
    EgressAggregate read_egress_aggregate();

    /**
     * DEBUG: raw dump of this config's register file over [lo, hi). Returns (index, value) pairs
     * exactly as the hardware presents them -- used to localise the egress-counter readout bug
     * (are stalled/window genuinely 0, or shifted/misread?). Reads ascending so the aggregate values
     * are captured before the last-register read resets them. Does not bounds-check against num_regs.
     */
    std::vector<std::pair<uint32_t, uint64_t>> read_raw_range(uint32_t lo, uint32_t hi);

    /** Base register index of the appended aggregate block (beats/stalled/window). */
    uint32_t aggregate_base() const;

    static constexpr uint64_t ID = ZSCORE_PROFILE_CONFIG_ID;

  private:
    libstf::stream_t num_zscores_;
};

/**
 * Control for the whole-column ("global") z-score.
 *
 * The hardware sees one parquet row group per stream -- tlast arrives at the end of each column
 * chunk, and that is what ends pass 1 -- so a single stream can only ever normalise a row group on
 * itself. Because count, sum and sum-of-squares are additive, the host works around this in two
 * phases: run every row group in STATS mode (pass 1 only, one beat of partial statistics comes back
 * per group), add the partials up, write the totals here, then re-run every row group in CLASSIFY
 * mode, which skips pass 1 and compares against those totals.
 *
 * LEGACY reproduces the original per-row-group behaviour and is the reset default, so an
 * unconfigured bitstream is unchanged.
 */
class ZScoreStatsConfig : public libstf::Config {
  public:
    ZScoreStatsConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                      uint32_t num_regs);

    enum class Mode : uint64_t {
        Legacy   = 0, // per-stream 2-pass: each row group normalised on itself
        Stats    = 1, // pass 1 only; one beat of (count, sum, sum_square) per stream
        Classify = 2, // skip pass 1; classify against the totals written below
    };

    /** The partial statistics one STATS-mode stream returns, and the running total of them. */
    struct Statistics {
        uint64_t count      = 0;
        int64_t  sum        = 0;
        int64_t  sum_square = 0;
    };

    /**
     * Selects the operator mode. Must not be changed while a stream is in flight -- the host is
     * expected to drain phase 1 completely before switching to Classify.
     */
    void set_mode(Mode mode);

    /**
     * Publishes the whole-column totals every lane classifies against. Write these before
     * set_mode(Classify); all lanes read the same values.
     */
    void set_global_statistics(const Statistics &stats);

    /** Reads back the currently selected mode (register 1 of the read file). */
    Mode mode();

    static constexpr uint64_t ID = ZSCORE_STATS_CONFIG_ID;
};

} // namespace oasis
