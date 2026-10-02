#include "oasis_profile.hpp"

#include "oasis_context_cache_entry.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/configuration.hpp"
#include "parcore/configuration.hpp"

#include "duckdb/function/table_function.hpp"

namespace duckdb {

namespace {

// Hardware facts the throughput derivation is based on: every stream handshake transports one
// 64-byte databeat, and the accelerator runs at 250 MHz (a 4 ns clock period).
constexpr double BYTES_PER_HANDSHAKE = 64.0;
constexpr double CLOCK_PERIOD_NS = 4.0;

// One materialized output row: the raw counters for a decoder's input and output stream plus the
// derived throughput numbers. throughput is in GB/s (== bytes per nanosecond).
struct ProfileRow {
	uint64_t decoder;

	parcore::DecoderProfile profile;

	double in_throughput_gbps;            // over the whole profiled window (includes idle cycles)
	double in_throughput_excl_idle_gbps;  // excluding inter-stream idle cycles
	double out_throughput_gbps;
	double out_throughput_excl_idle_gbps;
};

// Bytes transported divided by the time spent over `cycles` clock cycles, in GB/s. Returns 0 when
// there is no time to divide by so an unused stream reads as zero rather than NaN.
double ThroughputGBps(uint64_t handshakes, uint64_t cycles) {
	if (cycles == 0) {
		return 0.0;
	}
	double bytes = static_cast<double>(handshakes) * BYTES_PER_HANDSHAKE;
	double time_ns = static_cast<double>(cycles) * CLOCK_PERIOD_NS;
	return bytes / time_ns;
}

ProfileRow MakeRow(uint64_t decoder, const parcore::DecoderProfile &p) {
	ProfileRow row;
	row.decoder = decoder;
	row.profile = p;

	// Overall: every cycle the profiler observed for this stream, including idle gaps between
	// streams. Excluding-idle: the cycles the stream was actually running.
	uint64_t in_total = p.in.handshakes_cycles + p.in.starved_cycles + p.in.stalled_cycles + p.in.idle_cycles;
	uint64_t in_busy = p.in.handshakes_cycles + p.in.starved_cycles + p.in.stalled_cycles;
	uint64_t out_total =
	    p.out.handshakes_cycles + p.out.starved_cycles + p.out.stalled_cycles + p.out.idle_cycles;
	uint64_t out_busy = p.out.handshakes_cycles + p.out.starved_cycles + p.out.stalled_cycles;

	row.in_throughput_gbps = ThroughputGBps(p.in.handshakes_cycles, in_total);
	row.in_throughput_excl_idle_gbps = ThroughputGBps(p.in.handshakes_cycles, in_busy);
	row.out_throughput_gbps = ThroughputGBps(p.out.handshakes_cycles, out_total);
	row.out_throughput_excl_idle_gbps = ThroughputGBps(p.out.handshakes_cycles, out_busy);
	return row;
}

struct OasisProfileBindData : public TableFunctionData {
	vector<string> names;
	vector<LogicalType> types;
};

// Reads every decoder's counters from the hardware once at init and holds the rows to emit.
struct OasisProfileGlobalState : public GlobalTableFunctionState {
	vector<ProfileRow> rows;
	idx_t offset = 0;

	idx_t MaxThreads() const override {
		return 1;
	}
};

// Column layout, kept in one place so bind and scan stay in sync.
void DefineColumns(vector<string> &names, vector<LogicalType> &types) {
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		types.emplace_back(std::move(type));
	};

	add("decoder", LogicalType::UBIGINT);

	add("in_handshakes_cycles", LogicalType::UBIGINT);
	add("in_starved_cycles", LogicalType::UBIGINT);
	add("in_stalled_cycles", LogicalType::UBIGINT);
	add("in_idle_cycles", LogicalType::UBIGINT);

	add("out_handshakes_cycles", LogicalType::UBIGINT);
	add("out_starved_cycles", LogicalType::UBIGINT);
	add("out_stalled_cycles", LogicalType::UBIGINT);
	add("out_idle_cycles", LogicalType::UBIGINT);

	add("in_throughput_gbps", LogicalType::DOUBLE);
	add("in_throughput_excl_idle_gbps", LogicalType::DOUBLE);
	add("out_throughput_gbps", LogicalType::DOUBLE);
	add("out_throughput_excl_idle_gbps", LogicalType::DOUBLE);
}

unique_ptr<FunctionData> OasisProfileBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<OasisProfileBindData>();
	DefineColumns(names, return_types);
	bind_data->names = names;
	bind_data->types = return_types;
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisProfileInitGlobal(ClientContext &context,
                                                            TableFunctionInitInput &input) {
	auto gstate = make_uniq<OasisProfileGlobalState>();

	auto &ctx = GetOrCreateOasisContext(context);
	auto config = ctx.config<parcore::ColumnChunkDecoderConfig>();

	auto num_decoders = config->num_decoders();
	gstate->rows.reserve(num_decoders);
	for (libstf::stream_t decoder = 0; decoder < num_decoders; decoder++) {
		gstate->rows.push_back(MakeRow(decoder, config->read_profile(decoder)));
	}

	return std::move(gstate);
}

// Same as above but reads the z-score stage's StreamProfiler counters (one lane per decoder). Reuses
// the shared bind/scan/row helpers; only the hardware config it reads from differs.
unique_ptr<GlobalTableFunctionState> OasisZScoreProfileInitGlobal(ClientContext &context,
                                                                  TableFunctionInitInput &input) {
	auto gstate = make_uniq<OasisProfileGlobalState>();

	auto &ctx = GetOrCreateOasisContext(context);
	auto config = ctx.config<oasis::ZScoreProfileConfig>();

	auto num_zscores = config->num_zscores();
	gstate->rows.reserve(num_zscores);
	for (libstf::stream_t zscore = 0; zscore < num_zscores; zscore++) {
		gstate->rows.push_back(MakeRow(zscore, config->read_profile(zscore)));
	}

	return std::move(gstate);
}

void OasisProfileFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<OasisProfileGlobalState>();

	idx_t remaining = gstate.rows.size() - gstate.offset;
	idx_t count = MinValue<idx_t>(remaining, STANDARD_VECTOR_SIZE);
	if (count == 0) {
		output.SetChildCardinality(0);
		return;
	}

	for (idx_t i = 0; i < count; i++) {
		const auto &row = gstate.rows[gstate.offset + i];
		const auto &p = row.profile;

		idx_t col = 0;
		output.data[col++].SetValue(i, Value::UBIGINT(row.decoder));

		output.data[col++].SetValue(i, Value::UBIGINT(p.in.handshakes_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.in.starved_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.in.stalled_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.in.idle_cycles));

		output.data[col++].SetValue(i, Value::UBIGINT(p.out.handshakes_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.starved_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.stalled_cycles));
		output.data[col++].SetValue(i, Value::UBIGINT(p.out.idle_cycles));

		output.data[col++].SetValue(i, Value::DOUBLE(row.in_throughput_gbps));
		output.data[col++].SetValue(i, Value::DOUBLE(row.in_throughput_excl_idle_gbps));
		output.data[col++].SetValue(i, Value::DOUBLE(row.out_throughput_gbps));
		output.data[col++].SetValue(i, Value::DOUBLE(row.out_throughput_excl_idle_gbps));
	}

	gstate.offset += count;
	output.SetChildCardinality(count);
}

// -- oasis_egress_bandwidth() ---------------------------------------------------------------------
// The one link-level number. Every other row in this file uses a per-lane window (each StreamProfiler
// starts on its own first beat), so lanes cannot be summed into a PCIe rate without assuming their
// windows align. These two counters share one clock across all egress streams, so bytes/seconds here
// is the write-path bandwidth with no alignment assumption.
struct EgressBandwidthState : public GlobalTableFunctionState {
	oasis::ZScoreProfileConfig::EgressAggregate aggregate {};
	bool emitted = false;
};

unique_ptr<FunctionData> OasisEgressBandwidthBind(ClientContext &context,
                                                  TableFunctionBindInput &input,
                                                  vector<LogicalType> &return_types,
                                                  vector<string> &names) {
	auto bind_data = make_uniq<OasisProfileBindData>();
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		return_types.push_back(std::move(type));
	};
	add("beats", LogicalType::UBIGINT);
	add("stalled_cycles", LogicalType::UBIGINT);
	add("window_cycles", LogicalType::UBIGINT);
	add("bytes", LogicalType::UBIGINT);
	add("seconds", LogicalType::DOUBLE);
	add("throughput_gbps", LogicalType::DOUBLE);
	add("stalled_pct", LogicalType::DOUBLE);

	bind_data->names = names;
	bind_data->types = return_types;
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisEgressBandwidthInitGlobal(ClientContext &context,
                                                                    TableFunctionInitInput &input) {
	auto gstate = make_uniq<EgressBandwidthState>();

	auto &ctx = GetOrCreateOasisContext(context);
	auto config = ctx.config<oasis::ZScoreProfileConfig>();

	// Plain ascending readout of the aggregate block: beats, stalled, window. All three are exact
	// at ANY lane count (the hardware counters are link-level by construction), and reading window
	// last clears the set for the next measurement.
	// ⚠ REQUIRES a bitstream with the HARDENED agg_stop (registered compare in
	// zscore_profile_config.sv). On the pre-fix build-34/35 bitstreams the synthesized clear fired
	// on the whole aligned 8-register block around window, so this order read zeros there -- use
	// the older workaround binary with those builds.
	gstate->aggregate = config->read_egress_aggregate();

	return std::move(gstate);
}

void OasisEgressBandwidthFunction(ClientContext &context, TableFunctionInput &data_p,
                                  DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<EgressBandwidthState>();
	if (gstate.emitted) {
		output.SetChildCardinality(0);
		return;
	}

	double bytes = static_cast<double>(gstate.aggregate.beats) * BYTES_PER_HANDSHAKE;
	double seconds = static_cast<double>(gstate.aggregate.window_cycles) * CLOCK_PERIOD_NS * 1e-9;

	double window = static_cast<double>(gstate.aggregate.window_cycles);

	idx_t col = 0;
	output.data[col++].SetValue(0, Value::UBIGINT(gstate.aggregate.beats));
	output.data[col++].SetValue(0, Value::UBIGINT(gstate.aggregate.stalled_cycles));
	output.data[col++].SetValue(0, Value::UBIGINT(gstate.aggregate.window_cycles));
	output.data[col++].SetValue(0, Value::UBIGINT(static_cast<uint64_t>(bytes)));
	output.data[col++].SetValue(0, Value::DOUBLE(seconds));
	output.data[col++].SetValue(
	    0, Value::DOUBLE(seconds > 0.0 ? bytes / seconds / 1e9 : 0.0));
	output.data[col++].SetValue(
	    0, Value::DOUBLE(window > 0.0
	                         ? 100.0 * static_cast<double>(gstate.aggregate.stalled_cycles) / window
	                         : 0.0));

	gstate.emitted = true;
	output.SetChildCardinality(1);
}

// -- oasis_agg_debug() ----------------------------------------------------------------------------
// DEBUG: raw dump of the z-score profile config's register file around the appended aggregate block,
// exactly as the hardware presents it. Localises the egress-counter readout bug -- whether stalled/
// window are genuinely 0, shifted, or misread. The `is_agg` column flags the 3 aggregate registers
// (base+0=beats, base+1=stalled, base+2=window). Reads ascending so the aggregate values are read
// before the last-register read resets them.
struct AggDebugState : public GlobalTableFunctionState {
	std::vector<std::pair<uint32_t, uint64_t>> regs;
	uint32_t agg_base = 0;
	idx_t offset = 0;
};

unique_ptr<FunctionData> OasisAggDebugBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<OasisProfileBindData>();
	auto add = [&](const char *name, LogicalType type) {
		names.emplace_back(name);
		return_types.push_back(std::move(type));
	};
	add("reg", LogicalType::UBIGINT);
	add("value", LogicalType::UBIGINT);
	add("is_agg", LogicalType::BOOLEAN);
	bind_data->names = names;
	bind_data->types = return_types;
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisAggDebugInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input) {
	auto gstate = make_uniq<AggDebugState>();

	auto &ctx = GetOrCreateOasisContext(context);
	auto config = ctx.config<oasis::ZScoreProfileConfig>();
	gstate->agg_base = config->aggregate_base();

	// Sweep a window around the aggregate block: the last few per-lane registers through a couple
	// past the aggregate, so an addressing shift shows up as values landing at the wrong index.
	uint32_t lo = gstate->agg_base >= 4 ? gstate->agg_base - 4 : 0;
	uint32_t hi = gstate->agg_base + 5;
	gstate->regs = config->read_raw_range(lo, hi);

	return std::move(gstate);
}

void OasisAggDebugFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<AggDebugState>();

	idx_t remaining = gstate.regs.size() - gstate.offset;
	idx_t count = MinValue<idx_t>(remaining, STANDARD_VECTOR_SIZE);
	if (count == 0) {
		output.SetChildCardinality(0);
		return;
	}

	for (idx_t i = 0; i < count; i++) {
		const auto &r = gstate.regs[gstate.offset + i];
		bool is_agg = r.first >= gstate.agg_base && r.first < gstate.agg_base + 3;
		output.data[0].SetValue(i, Value::UBIGINT(r.first));
		output.data[1].SetValue(i, Value::UBIGINT(r.second));
		output.data[2].SetValue(i, Value::BOOLEAN(is_agg));
	}

	gstate.offset += count;
	output.SetChildCardinality(count);
}

// -- oasis_agg_peek(reg) --------------------------------------------------------------------------
// DEBUG: read exactly ONE register of the z-score profile config, nothing else. Discriminates the
// read-ORDER hypothesis: after a query, `SELECT * FROM oasis_agg_peek(20)` reads window FIRST --
// if it is nonzero alone but zero in the ascending dump, something clears the counters during the
// ascending sequence; if it is zero even alone, the readout path itself is broken.
struct AggPeekBindData : public TableFunctionData {
	uint32_t reg = 0;
};

struct AggPeekState : public GlobalTableFunctionState {
	uint32_t reg = 0;
	uint64_t value = 0;
	bool emitted = false;
};

unique_ptr<FunctionData> OasisAggPeekBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<AggPeekBindData>();
	bind_data->reg = static_cast<uint32_t>(input.inputs[0].GetValue<uint64_t>());
	names.emplace_back("reg");
	return_types.push_back(LogicalType::UBIGINT);
	names.emplace_back("value");
	return_types.push_back(LogicalType::UBIGINT);
	return std::move(bind_data);
}

unique_ptr<GlobalTableFunctionState> OasisAggPeekInitGlobal(ClientContext &context,
                                                            TableFunctionInitInput &input) {
	auto &bind = input.bind_data->Cast<AggPeekBindData>();
	auto gstate = make_uniq<AggPeekState>();
	gstate->reg = bind.reg;

	auto &ctx = GetOrCreateOasisContext(context);
	auto regs = ctx.config<oasis::ZScoreProfileConfig>()->read_raw_range(bind.reg, bind.reg + 1);
	gstate->value = regs.empty() ? 0 : regs.front().second;

	return std::move(gstate);
}

void OasisAggPeekFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<AggPeekState>();
	if (gstate.emitted) {
		output.SetChildCardinality(0);
		return;
	}
	output.data[0].SetValue(0, Value::UBIGINT(gstate.reg));
	output.data[1].SetValue(0, Value::UBIGINT(gstate.value));
	gstate.emitted = true;
	output.SetChildCardinality(1);
}

} // namespace

void RegisterOasisProfileFunction(ExtensionLoader &loader) {
	TableFunction profile_function("oasis_stream_profile", {}, OasisProfileFunction, OasisProfileBind,
	                               OasisProfileInitGlobal);
	loader.RegisterFunction(profile_function);

	// Same columns/scan, but reads the z-score stage's profiler counters.
	TableFunction zscore_profile_function("oasis_zscore_profile", {}, OasisProfileFunction,
	                                       OasisProfileBind, OasisZScoreProfileInitGlobal);
	loader.RegisterFunction(zscore_profile_function);

	// The link-level PCIe write bandwidth: one row, one shared window across all egress streams.
	TableFunction egress_bandwidth_function("oasis_egress_bandwidth", {},
	                                        OasisEgressBandwidthFunction,
	                                        OasisEgressBandwidthBind,
	                                        OasisEgressBandwidthInitGlobal);
	loader.RegisterFunction(egress_bandwidth_function);

	// DEBUG: raw register dump around the aggregate block (localises the window/stalled=0 bug).
	TableFunction agg_debug_function("oasis_agg_debug", {}, OasisAggDebugFunction, OasisAggDebugBind,
	                                 OasisAggDebugInitGlobal);
	loader.RegisterFunction(agg_debug_function);

	// DEBUG: read a single z-score-profile register in isolation (read-order discriminator).
	TableFunction agg_peek_function("oasis_agg_peek", {LogicalType::UBIGINT}, OasisAggPeekFunction,
	                                OasisAggPeekBind, OasisAggPeekInitGlobal);
	loader.RegisterFunction(agg_peek_function);
}

} // namespace duckdb
