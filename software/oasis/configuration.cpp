#include <cstring>
#include <string>

#include <oasis/configuration.hpp>

namespace oasis {

constexpr const uint32_t READ_REQ_VADDR_ADDR = 0;
constexpr const uint32_t READ_REQ_SIZE_ADDR  = 1;

ReadReqConfig::ReadReqConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

void ReadReqConfig::set_base_vaddr(uintptr_t base_vaddr) { base_vaddr_ = base_vaddr; }

void ReadReqConfig::enqueue_read(libstf::stream_t stream, size_t vaddr, size_t size) {
    auto reg_offset = stream * READ_REQ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_VADDR_ADDR, base_vaddr_ + vaddr));
    write_register(libstf::ConfigRegister(reg_offset + READ_REQ_SIZE_ADDR, size));
}

const libstf::stream_t ReadReqConfig::num_streams() const { return num_streams_; }

ZScoreProfileConfig::ZScoreProfileConfig(std::shared_ptr<coyote::cThread> cthread,
                                         uint32_t addr_offset, uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_zscores_(read_register(1).value()) {}

parcore::DecoderProfile ZScoreProfileConfig::read_profile(libstf::stream_t zscore) {
    if (zscore >= num_zscores_) {
        throw std::runtime_error("Attempted to read profile of z-score lane " +
                                 std::to_string(zscore) + ", out of " +
                                 std::to_string(num_zscores_) + " lanes");
    }

    auto base = ZSCORE_PROFILE_INFO_REGS + zscore * ZSCORE_PROFILE_PROFILE_REGS;

    parcore::DecoderProfile profile;
    profile.in.handshakes_cycles  = read_register(base + 0).value();
    profile.in.starved_cycles     = read_register(base + 1).value();
    profile.in.stalled_cycles     = read_register(base + 2).value();
    profile.in.idle_cycles        = read_register(base + 3).value();
    profile.out.handshakes_cycles = read_register(base + 4).value();
    profile.out.starved_cycles    = read_register(base + 5).value();
    profile.out.stalled_cycles    = read_register(base + 6).value();
    profile.out.idle_cycles       = read_register(base + 7).value();
    return profile;
}

ZScoreProfileConfig::EgressAggregate ZScoreProfileConfig::read_egress_aggregate() {
    // Appended after the per-lane block, so the base moves with the lane count.
    auto base = ZSCORE_PROFILE_INFO_REGS + num_zscores_ * ZSCORE_PROFILE_PROFILE_REGS;

    EgressAggregate aggregate;
    aggregate.beats = read_register(base + 0).value();
    aggregate.stalled_cycles = read_register(base + 1).value();
    // Read last: reading this register is what pulses agg_stop and resets the set.
    aggregate.window_cycles = read_register(base + 2).value();
    return aggregate;
}

uint32_t ZScoreProfileConfig::aggregate_base() const {
    return ZSCORE_PROFILE_INFO_REGS + num_zscores_ * ZSCORE_PROFILE_PROFILE_REGS;
}

std::vector<std::pair<uint32_t, uint64_t>> ZScoreProfileConfig::read_raw_range(uint32_t lo,
                                                                               uint32_t hi) {
    std::vector<std::pair<uint32_t, uint64_t>> out;
    for (uint32_t reg = lo; reg < hi; reg++) {
        out.emplace_back(reg, read_register(reg).value());
    }
    return out;
}

const libstf::stream_t ZScoreProfileConfig::num_zscores() const { return num_zscores_; }

ZScoreStatsConfig::ZScoreStatsConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                     uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

void ZScoreStatsConfig::set_mode(Mode mode) {
    write_register(libstf::ConfigRegister(ZSCORE_STATS_MODE_REG, static_cast<uint64_t>(mode)));
}

void ZScoreStatsConfig::set_global_statistics(const Statistics &stats) {
    // Written before the mode switch, so a lane can never latch a half-updated set: nothing is in
    // flight while these land, and CLASSIFY only samples them when a stream starts.
    write_register(libstf::ConfigRegister(ZSCORE_STATS_COUNT_REG, stats.count));
    write_register(
        libstf::ConfigRegister(ZSCORE_STATS_SUM_REG, static_cast<uint64_t>(stats.sum)));
    write_register(
        libstf::ConfigRegister(ZSCORE_STATS_SUM_SQUARE_REG, static_cast<uint64_t>(stats.sum_square)));
}

ZScoreStatsConfig::Mode ZScoreStatsConfig::mode() {
    return static_cast<Mode>(read_register(1).value());
}

} // namespace oasis
