#include "zscore_scan.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/string_util.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <libstf/profiling.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace duckdb {

namespace {

using libstf::Profiler;

bool PerGroupMode();   // T2 diagnostic, defined below
bool DoubleDecodeMode(); // short-flow discriminator, defined below

// Caliper region names (mirrors parcore's "ns::Class::" convention). Built ONCE at file scope:
// open_regions/close_regions take a const&, so passing these costs nothing per call. Building them
// inline (`{prefix + "emit"}`) concatenates a string, heap-allocates and frees a vector on EVERY
// call -- at ~49k calls per 100M-row scan that overhead dwarfed the regions themselves.
const std::vector<std::string> kFunction   = {"duckdb::zscore_scan::function"};
const std::vector<std::string> kLoadGroup  = {"duckdb::zscore_scan::load_group"};
const std::vector<std::string> kFillWindow = {"duckdb::zscore_scan::fill_window"};
const std::vector<std::string> kAllocate   = {"duckdb::zscore_scan::allocate"};
const std::vector<std::string> kRead       = {"duckdb::zscore_scan::read"};
const std::vector<std::string> kBuildFlow  = {"duckdb::zscore_scan::build_flow"};
const std::vector<std::string> kCollect    = {"duckdb::zscore_scan::collect"};
const std::vector<std::string> kEmit       = {"duckdb::zscore_scan::emit"};

// Bind-time state: which file, the ParCore metadata (row groups + chunk layout), and the resolved
// column index the z-score runs on.
struct ZScoreBindData : public TableFunctionData {
	string filename;
	parcore::metadata::Metadata metadata;
	size_t column_id = 0;
	// outliers_only: emit one BIGINT row id per outlier instead of one BOOLEAN per value. The scan then
	// hands DuckDB ~20k rows instead of 100M, so neither the emit loop nor a downstream filter has to
	// materialise and re-scan a bool per value.
	bool outliers_only = false;
	// First global row index of each row group, so outliers_only can report absolute row ids.
	std::vector<int64_t> group_first_row;
};

// OASIS_ZSCORE_TIMING=1 prints one line per query with the operator's own wall time, split at the
// statistics barrier. Read once: a getenv per chunk would cost more than the thing being timed.
bool TimingEnabled() {
	static const bool on = std::getenv("OASIS_ZSCORE_TIMING") != nullptr;
	return on;
}

// Shared across workers. The only mutable shared state is the row-group cursor (claimed atomically),
// mirroring read_oasis. Capped to one worker for now -- this is the first hardware bring-up of the
// z-score path, so we keep it single-threaded and deterministic.
struct ZScoreGlobalState : public GlobalTableFunctionState {
	oasis::OasisContext *ctx = nullptr;
	size_t total_groups = 0;
	std::atomic<size_t> next_group {0};

	// Workers already claim row groups atomically off next_group and each owns its own file handle and
	// in-flight window, so the scan parallelises without further locking. Kept env-tunable because each
	// worker holds up to WINDOW row-group buffers in flight -- threads x WINDOW hugepage buffers must
	// still fit the pool, so sweep this rather than jumping straight to core count.
	// OASIS_ZSCORE_THREADS=1 restores the old serial behaviour exactly.
	idx_t MaxThreads() const override {
		const char *env = std::getenv("OASIS_ZSCORE_THREADS");
		if (env) {
			const int n = std::atoi(env);
			if (n > 0) {
				return (idx_t)n;
			}
		}
		return 4;
	}

	// --- OASIS_ZSCORE_TIMING ----------------------------------------------------------------
	// heavy = phase 1 (the statistics barrier in ZScoreInitGlobal) + phase 2 (this scan). It is
	// stamped when a worker's scan terminates, NOT at teardown, so unmapping the hugepage buffers
	// is not charged to the operator. Every worker terminates exactly once, so this costs a handful
	// of clock reads per query rather than one per chunk. Workers race on last_ns, but they finish
	// within microseconds of each other and the line reports ms, so a plain store is enough.
	std::chrono::steady_clock::time_point start {};
	double phase1_ms = 0.0;
	std::atomic<int64_t> last_ns {0};
	size_t rows = 0;
	size_t threads = 0;

	~ZScoreGlobalState() {
		if (!TimingEnabled()) {
			return;
		}
		const int64_t last = last_ns.load();
		// PHASE1_ONLY emits nothing, so no worker ever stamps: the operator's time IS phase 1.
		const double heavy_ms = last > 0 ? last / 1e6 : phase1_ms;
		fprintf(stderr,
		        "[zscore] heavy %.2f ms  phase1 %.2f ms  phase2 %.2f ms  groups %llu  threads %llu  "
		        "rows %llu\n",
		        heavy_ms, phase1_ms, heavy_ms - phase1_ms, (unsigned long long)total_groups,
		        (unsigned long long)threads, (unsigned long long)rows);
	}
};

// Stamp the moment this worker's scan ended. The last stamp wins, so the destructor reports the
// operator's time to the final chunk instead of to state teardown.
void StampProgress(ZScoreGlobalState &gstate) {
	if (!TimingEnabled()) {
		return;
	}
	gstate.last_ns.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
	                         std::chrono::steady_clock::now() - gstate.start)
	                         .count(),
	                     std::memory_order_relaxed);
}

// One row group submitted to the FPGA and awaiting its flags. This is phase 2 (CLASSIFY), so the flow
// is a single pass over the group; the scheduler keeps the input buffer mapped until it completes and
// we hold the handle to collect the flag buffer, with num_values telling us how many flags it carries.
struct InFlightZGroup {
	oasis::SplinterResultHandle handle;
	size_t num_values = 0;
	// Flag values this flow is expected to produce. Equal to num_values, except under the
	// OASIS_ZSCORE_DOUBLE_DECODE diagnostic (see SubmitGroup), where the flow feeds the column twice
	// and therefore emits twice as many flags -- only the first num_values of which are read.
	size_t expected_values = 0;
	int64_t first_row = 0; // global row index of this group's first value
};

// Per-worker state: this worker's file handle plus the flag buffer of the row group it is currently
// slicing into STANDARD_VECTOR_SIZE-sized vectors.
struct ZScoreLocalState : public LocalTableFunctionState {
	unique_ptr<FileHandle> file_handle;

	// Sliding window of row groups submitted ahead of consumption, so the decoder stays fed while the
	// host is still emitting the current group's flags. Collected FIFO -> flags come back in row-group
	// order, exactly like the old one-at-a-time path.
	std::deque<InFlightZGroup> in_flight;

	// A row group's flags do NOT always arrive in one buffer: the output writer raises one interrupt
	// per completed buffer, so under load a group can be split across several. Observed on hardware
	// at 12 host threads -- a 122,880-value group came back as 122,784 values plus a remainder.
	// Reading the group as a single buffer meant reading past what the FPGA had written, which
	// produced garbage flags and row ids that changed between runs.
	std::deque<std::shared_ptr<libstf::Buffer>> pending_batches; // rest of this group, in order
	std::shared_ptr<libstf::Buffer> current_flags;
	size_t current_flags_values = 0; // values still unread in current_flags
	size_t current_flags_pos = 0;    // read position within current_flags
	size_t current_offset = 0;    // values already emitted from THIS ROW GROUP (drives the row id)
	size_t current_remaining = 0; // values still to emit from this row group
	int64_t current_first_row = 0; // global row index of this group's first value
	size_t short_by = 0;           // values the flow never delivered (diagnostic mode only)
};

unique_ptr<FunctionData> ZScoreBind(ClientContext &context, TableFunctionBindInput &input,
                                    vector<LogicalType> &return_types, vector<string> &names) {
	auto parquet_file = StringValue::Get(input.inputs[0]);
	auto column_name = StringValue::Get(input.inputs[1]);

	ParquetOptions parquet_opts(context);
	ParquetReader parquet_reader(context, OpenFileInfo {parquet_file}, parquet_opts);

	auto meta = BuildParcoreMetadata(parquet_reader);
	if (meta.groups.empty()) {
		throw InvalidInputException("Parquet file '%s' contains no row groups", parquet_file);
	}

	// Resolve the column by name.
	size_t col_id = meta.column_names.size();
	for (size_t i = 0; i < meta.column_names.size(); i++) {
		if (meta.column_names[i] == column_name) {
			col_id = i;
			break;
		}
	}
	if (col_id == meta.column_names.size()) {
		throw BinderException("Column '%s' not found in '%s'", column_name, parquet_file);
	}

	// The hardware z-score operates on INT32 values; reject anything else with a clear message.
	if (meta.groups[0].chunks[col_id].type != parcore::metadata::Type::INT32_T) {
		throw BinderException("zscore() currently supports INT32 columns only; column '%s' is a different type",
		                      column_name);
	}

	// Pass 1 accumulates Sum(x^2) into the 64-bit signed sum_square_reg of z_score_squared.sv, which
	// wraps silently on overflow. All the footer statistics can bound is the WORST case,
	// N * max(|x|)^2; columns without statistics are let through (nothing to test). See below for
	// why that bound only warns.
	int64_t abs_max = 0;
	if (ParquetInt32ColumnAbsMax(parquet_reader, col_id, abs_max)) {
		uint64_t num_rows = 0;
		for (auto &group : meta.groups) {
			num_rows += group.chunks[col_id].num_values;
		}
		const unsigned __int128 worst_sum_sq =
		    (unsigned __int128)num_rows * (unsigned __int128)abs_max * (unsigned __int128)abs_max;
		if (worst_sum_sq > (unsigned __int128)std::numeric_limits<int64_t>::max()) {
			const double worst_approx = (double)num_rows * (double)abs_max * (double)abs_max;
			// WARNING, not a rejection. This bound assumes EVERY row carries max(|x|), which is
			// wildly pessimistic on spiky data: test100m (a 1e6 spike every 5000th row, otherwise
			// 0..99) bounds at 1e20 but its true Sum(x^2) is ~2e16 -- 460x of headroom -- and this
			// check rejected it outright. The exact test is in ComputeGlobalStatistics(), on the
			// real per-row-group sums phase 1 measures.
			if (std::getenv("OASIS_ZSCORE_STRICT_OVERFLOW")) {
				throw BinderException(
				    "zscore() would overflow the hardware sum-of-squares accumulator on column '%s': "
				    "%s rows with max |value| %s can reach ~%s, above the 64-bit signed limit "
				    "9223372036854775807. Rescale the column so that rows * max(|value|)^2 stays "
				    "below that limit (for example store currency in whole units rather than cents).",
				    column_name, std::to_string(num_rows), std::to_string(abs_max),
				    StringUtil::Format("%.3g", worst_approx));
			}
			fprintf(stderr,
			        "[zscore] warning: column '%s' could reach Sum(x^2) ~%s in the worst case (%s "
			        "rows, max |value| %s), above the 64-bit limit. That is an upper bound, not a "
			        "measurement -- phase 1 checks the real sums and fails the query if they do "
			        "overflow. OASIS_ZSCORE_STRICT_OVERFLOW=1 rejects here instead.\n",
			        column_name.c_str(), StringUtil::Format("%.3g", worst_approx).c_str(),
			        std::to_string(num_rows).c_str(), std::to_string(abs_max).c_str());
		}
	}

	auto bind_data = make_uniq<ZScoreBindData>();
	bind_data->filename = parquet_file;
	bind_data->metadata = std::move(meta);
	bind_data->column_id = col_id;

	auto opt = input.named_parameters.find("outliers_only");
	if (opt != input.named_parameters.end()) {
		bind_data->outliers_only = BooleanValue::Get(opt->second);
	}

	// Prefix sum of per-group value counts: group g's first value is global row group_first_row[g].
	bind_data->group_first_row.resize(bind_data->metadata.groups.size());
	int64_t running = 0;
	for (size_t g = 0; g < bind_data->metadata.groups.size(); g++) {
		bind_data->group_first_row[g] = running;
		running += (int64_t)bind_data->metadata.groups[g].chunks[col_id].num_values;
	}

	if (bind_data->outliers_only) {
		names.emplace_back("row_id");
		return_types.emplace_back(LogicalType::BIGINT);
	} else {
		names.emplace_back("is_outlier");
		return_types.emplace_back(LogicalType::BOOLEAN);
	}
	return std::move(bind_data);
}

// Whole-column statistics supplied by the caller, for the phase-1 bypass diagnostic. Given as
// OASIS_ZSCORE_STATS="count,sum,sum_square" (the values gen_tpch.py / get_taxi.py already record in
// the manifest). Deliberately NOT computed with context.Query() here: InitGlobal runs inside the
// query that is being planned, and re-entering the same ClientContext deadlocks -- that is what hung
// the first attempt, not the accelerator.
oasis::ZScoreStatsConfig::Statistics ParseSuppliedStatistics(const char *spec) {
	oasis::ZScoreStatsConfig::Statistics stats;
	if (sscanf(spec, "%llu,%lld,%lld", (unsigned long long *)&stats.count, (long long *)&stats.sum,
	           (long long *)&stats.sum_square) != 3) {
		throw InvalidInputException(
		    "OASIS_ZSCORE_STATS must be \"count,sum,sum_square\", got '%s'", spec);
	}
	return stats;
}

// PHASE 1 of the global z-score: streams every row group through the operator in STATS mode and adds
// up the per-group partials it returns.
//
// This exists because the hardware can never see the whole column as one stream -- `tlast` arrives at
// the end of every parquet column chunk, and that is exactly what ends pass 1. Sum, sum of squares
// and count are additive though, so the totals assembled here are exactly the whole-column
// statistics, and phase 2 classifies against them. It runs once, in InitGlobal, before any scan
// thread starts -- that is the barrier between the phases.
//
// EXPERIMENT KNOBS (all default to the shipping behaviour, all measured with OASIS_ZSCORE_DEBUG_PHASE1=1):
//   OASIS_ZSCORE_PHASE1_WORKERS=N  submit/collect on N threads sharing an atomic group cursor
//                                  (default 1). Separate from OASIS_ZSCORE_THREADS, which is
//                                  DuckDB's phase-2 scan parallelism and does not touch phase 1.
//   OASIS_ZSCORE_PHASE1_PREREAD=1  read EVERY column chunk into memory BEFORE the submit loop, so
//                                  the loop itself does zero file I/O. Isolates "the host read
//                                  serialises phase 1" from "the hardware is the floor". Costs the
//                                  compressed column size in pool memory (46 MB taxi, 408 MB extprice).
//   OASIS_ZSCORE_PHASE1_ONLY=1     (in ZScoreInitGlobal) run phase 1 and emit no rows, so
//                                  oasis_stream_profile() shows phase 1 alone with nothing to subtract.
//
// ⚠ ALREADY MEASURED AND REJECTED -- do not re-try without new evidence:
//   * raising `oasis_scheduler_queue_depth` -- wall time identical;
//   * packing K row groups into one flow, each with its own sink, to amortise the per-flow round
//     trip -- `submit` fell 5x, wall identical, so the round trip is NOT the cost.
oasis::ZScoreStatsConfig::Statistics ComputeGlobalStatistics(ClientContext &context,
                                                            oasis::OasisContext &ctx,
                                                            const ZScoreBindData &bind) {
	constexpr size_t WINDOW = 8;
	// One 64-byte beat per row group: [0] count, [1] sum, [2] sum_square, as three int64s.
	constexpr size_t STATS_BEAT_BYTES = 64;

	auto &fs = FileSystem::GetFileSystem(context);
	const auto &groups = bind.metadata.groups;

	size_t num_workers = 1;
	if (const char *env = std::getenv("OASIS_ZSCORE_PHASE1_WORKERS")) {
		const int n = std::atoi(env);
		if (n > 0) {
			num_workers = (size_t)n;
		}
	}
	num_workers = std::max<size_t>(1, std::min(num_workers, std::max<size_t>(1, groups.size())));
	const bool preread = std::getenv("OASIS_ZSCORE_PHASE1_PREREAD") != nullptr;

	using phase1_clock = std::chrono::steady_clock;
	auto ns_since = [](phase1_clock::time_point t) {
		return (int64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(phase1_clock::now() - t)
		    .count();
	};
	std::vector<int64_t> t_alloc(num_workers, 0), t_read(num_workers, 0), t_out(num_workers, 0),
	    t_submit(num_workers, 0), t_collect(num_workers, 0);
	std::vector<size_t> n_groups(num_workers, 0);
	int64_t t_preread = 0;
	const auto phase1_start = phase1_clock::now();

	// Optional pre-read: pull every chunk into pool memory up front, so the submit loop never touches
	// the file system. Single-threaded on purpose -- this measures the read as a lump.
	std::vector<std::shared_ptr<libstf::Buffer>> chunk_cache;
	if (preread) {
		const auto t0 = phase1_clock::now();
		auto file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);
		chunk_cache.resize(groups.size());
		for (size_t g = 0; g < groups.size(); g++) {
			const auto &cc = groups[g].chunks[bind.column_id];
			if (cc.num_values == 0) {
				continue;
			}
			void *ptr;
			auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
			if (!status.ok()) {
				throw IOException("Could not pre-read z-score statistics input buffer: " +
				                  status.message());
			}
			file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
			chunk_cache[g] = libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size,
			                                     cc.total_compressed_size);
		}
		t_preread = ns_since(t0);
	}

	std::atomic<size_t> next_group {0};
	std::vector<__int128> w_sum(num_workers, 0), w_sum_square(num_workers, 0);
	std::vector<unsigned __int128> w_count(num_workers, 0);
	std::mutex error_mutex;
	std::exception_ptr first_error;

	auto worker = [&](size_t w) {
		try {
			std::unique_ptr<FileHandle> file_handle;
			if (!preread) {
				file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);
			}
			std::deque<oasis::SplinterResultHandle> in_flight;

			auto collect_one = [&]() {
				auto handle = std::move(in_flight.front());
				in_flight.pop_front();
				const auto t_wait = phase1_clock::now();
				auto batch = handle.get_next_batch();
				if (!batch) {
					throw InternalException("z-score statistics flow closed with no output");
				}
				// Drain the flow before dropping the handle: a half-consumed flow leaves completion
				// state in the scheduler and a stale buffer then surfaces on a LATER handle.
				while (handle.get_next_batch()) {
				}
				t_collect[w] += ns_since(t_wait);
				if (batch->buffer->size < STATS_BEAT_BYTES) {
					throw InternalException(
					    "z-score statistics beat is %llu bytes, expected at least %llu",
					    (unsigned long long)batch->buffer->size, (unsigned long long)STATS_BEAT_BYTES);
				}
				const auto *words = reinterpret_cast<const int64_t *>(batch->buffer->ptr);
				// EXACT overflow test on what the hardware accumulated: every term of Sum(x^2) is a
				// square, so a negative partial can only mean the 64-bit sum_square_reg wrapped.
				if (words[2] < 0) {
					throw InvalidInputException(
					    "zscore(): the hardware sum-of-squares accumulator overflowed on a row group "
					    "(partial Sum(x^2) came back as %lld). Rescale the column so that, within one row "
					    "group, the sum of squares stays below 9223372036854775807.",
					    (long long)words[2]);
				}
				w_count[w] += (unsigned __int128)(uint64_t)words[0];
				w_sum[w] += (__int128)words[1];
				w_sum_square[w] += (__int128)words[2];
			};

			bool exhausted = false;
			while (!exhausted || !in_flight.empty()) {
				while (in_flight.size() < WINDOW && !exhausted) {
					const size_t group = next_group.fetch_add(1);
					if (group >= groups.size()) {
						exhausted = true;
						break;
					}
					const auto &cc = groups[group].chunks[bind.column_id];
					if (cc.num_values == 0) {
						continue;
					}

					std::shared_ptr<libstf::Buffer> input_buf;
					if (preread) {
						input_buf = chunk_cache[group];
					} else {
						void *ptr;
						auto t_stage = phase1_clock::now();
						auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
						t_alloc[w] += ns_since(t_stage);
						if (!status.ok()) {
							throw IOException("Could not allocate z-score statistics input buffer: " +
							                  status.message());
						}
						t_stage = phase1_clock::now();
						file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
						t_read[w] += ns_since(t_stage);
						input_buf = libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size,
						                                cc.total_compressed_size);
					}
					n_groups[w]++;

					oasis::OperatorFlow flow;
					flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
					flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(
					    cc.compression, cc.num_values, parcore::metadata::to_libstf_type(cc.type)));
					auto t_stage2 = phase1_clock::now();
					auto stats_buf = ctx.allocate_output_buffer(STATS_BEAT_BYTES);
					t_out[w] += ns_since(t_stage2);
					flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(stats_buf), 0));

					oasis::QuerySplinter splinter;
					splinter.streams.push_back(std::move(flow));
					t_stage2 = phase1_clock::now();
					in_flight.push_back(ctx.scheduler().submit(std::move(splinter)));
					t_submit[w] += ns_since(t_stage2);
				}
				if (!in_flight.empty()) {
					collect_one();
				}
			}
		} catch (...) {
			std::lock_guard<std::mutex> lock(error_mutex);
			if (!first_error) {
				first_error = std::current_exception();
			}
		}
	};

	if (num_workers == 1) {
		worker(0);
	} else {
		std::vector<std::thread> threads;
		threads.reserve(num_workers);
		for (size_t w = 0; w < num_workers; w++) {
			threads.emplace_back(worker, w);
		}
		for (auto &t : threads) {
			t.join();
		}
	}
	if (first_error) {
		std::rethrow_exception(first_error);
	}

	__int128 exact_sum = 0, exact_sum_square = 0;
	unsigned __int128 exact_count = 0;
	int64_t a = 0, r = 0, o = 0, sub = 0, col = 0;
	size_t total_groups_done = 0;
	for (size_t w = 0; w < num_workers; w++) {
		exact_sum += w_sum[w];
		exact_sum_square += w_sum_square[w];
		exact_count += w_count[w];
		a += t_alloc[w]; r += t_read[w]; o += t_out[w]; sub += t_submit[w]; col += t_collect[w];
		total_groups_done += n_groups[w];
	}

	if (std::getenv("OASIS_ZSCORE_DEBUG_PHASE1")) {
		const double wall_ms = ns_since(phase1_start) / 1e6;
		fprintf(stderr,
		        "[zscore] phase1 wall %.2f ms | groups %llu | workers %llu | preread %d\n"
		        "[zscore]   preread %.2f  allocate %.2f  read %.2f  alloc_out %.2f  submit %.2f  "
		        "collect %.2f  (ms, summed over workers)\n",
		        wall_ms, (unsigned long long)total_groups_done, (unsigned long long)num_workers,
		        preread ? 1 : 0, t_preread / 1e6, a / 1e6, r / 1e6, o / 1e6, sub / 1e6, col / 1e6);
		// Machine-readable twin of the line above. Parsing the padded human line was fragile, so
		// scripts should read THIS one: phase1csv,wall,preread,allocate,read,alloc_out,submit,collect,groups,workers,preread_flag
		fprintf(stderr, "[zscore] phase1csv,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%llu,%llu,%d\n",
		        wall_ms, t_preread / 1e6, a / 1e6, r / 1e6, o / 1e6, sub / 1e6, col / 1e6,
		        (unsigned long long)total_groups_done, (unsigned long long)num_workers,
		        preread ? 1 : 0);
	}

	// The whole column must also fit: CLASSIFY publishes these as 64-bit registers and the operator
	// computes n*Q from them.
	if (exact_sum_square > (__int128)std::numeric_limits<int64_t>::max()) {
		throw InvalidInputException(
		    "zscore(): the whole-column sum of squares does not fit in 64 bits (measured ~%.3g, limit "
		    "9223372036854775807). Rescale the column.",
		    (double)exact_sum_square);
	}
	if (exact_sum > (__int128)std::numeric_limits<int64_t>::max() ||
	    exact_sum < (__int128)std::numeric_limits<int64_t>::min()) {
		throw InvalidInputException(
		    "zscore(): the whole-column sum does not fit in 64 bits (measured ~%.3g). Rescale the "
		    "column.",
		    (double)exact_sum);
	}

	oasis::ZScoreStatsConfig::Statistics totals;
	totals.count = (uint64_t)exact_count;
	totals.sum = (int64_t)exact_sum;
	totals.sum_square = (int64_t)exact_sum_square;
	return totals;
}

unique_ptr<GlobalTableFunctionState> ZScoreInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto &bind = input.bind_data->Cast<ZScoreBindData>();
	auto gstate = make_uniq<ZScoreGlobalState>();
	gstate->start = std::chrono::steady_clock::now();
	gstate->ctx = &GetOrCreateOasisContext(context);
	gstate->total_groups = bind.metadata.groups.size();
	gstate->threads = (size_t)gstate->MaxThreads();
	for (const auto &group : bind.metadata.groups) {
		gstate->rows += group.chunks[bind.column_id].num_values;
	}

	// Phase 1 -> totals -> phase 2. The mode switch is only safe because nothing is in flight: the
	// stats pass is fully drained before the totals are published, and no scan thread has started.
	if (PerGroupMode()) {
		// Run no statistics pass, but DO write the mode register once, with LEGACY. On a bitstream
		// that has ZScoreStatsConfig the operator holds its input off until `mode_valid` is set, so
		// skipping the write entirely leaves it refusing data forever -- seen as a hang on build-39.
		// A pre-global bitstream has no such config and nothing to write, which is not an error.
		try {
			gstate->ctx->config<oasis::ZScoreStatsConfig>()->set_mode(
			    oasis::ZScoreStatsConfig::Mode::Legacy);
		} catch (const std::exception &) {
			// Pre-global bitstream (e.g. build-38): LEGACY-only by construction, nothing to set.
		}
		return std::move(gstate);
	}

	auto stats_config = gstate->ctx->config<oasis::ZScoreStatsConfig>();
	oasis::ZScoreStatsConfig::Statistics totals;

	// Leave CLASSIFY *before* publishing new totals. The operator reloads count/sum/sum_square from
	// these registers only when it re-arms, and it re-arms on the CLASSIFY edge -- so if the mode is
	// already CLASSIFY when the totals change, the first row group of this query is classified
	// against the PREVIOUS query's statistics. The phase-1 path below writes Stats anyway; this
	// makes the transition unconditional so the supplied-statistics path gets it too. Measured in
	// hardware/unit-tests/z_score_boundary_tb.sv (SCEN=6): without it, exactly one stream is wrong.
	stats_config->set_mode(oasis::ZScoreStatsConfig::Mode::Stats);

	if (const char *supplied = std::getenv("OASIS_ZSCORE_STATS")) {
		// Diagnostic: skip phase 1 and compute the whole-column statistics on the CPU, so phase 2
		// runs on its own. Splits the global path in two -- if the short-flow loss survives this it
		// belongs to phase 2 / CLASSIFY; if it disappears it belongs to phase 1 or to the hand-over
		// between the phases. The results are identical either way, so correctness still applies.
		totals = ParseSuppliedStatistics(supplied);
	} else {
		totals = ComputeGlobalStatistics(context, *gstate->ctx, bind);
	}

	// Everything above is phase 1: it runs before any scan thread exists, so the barrier ends here.
	gstate->phase1_ms = std::chrono::duration_cast<std::chrono::nanoseconds>(
	                        std::chrono::steady_clock::now() - gstate->start)
	                        .count() /
	                    1e6;

	// OASIS_ZSCORE_DEBUG_STATS=1 prints the totals phase 1 assembled, so they can be diffed against
	// the exact values computed on the CPU. A mismatch localises a wrong result to phase 1
	// (partials lost or double-counted) rather than to the classification pass.
	if (std::getenv("OASIS_ZSCORE_DEBUG_STATS")) {
		fprintf(stderr, "[zscore] phase-1 totals: n=%llu sum=%lld sum_square=%lld\n",
		        (unsigned long long)totals.count, (long long)totals.sum, (long long)totals.sum_square);
	}

	stats_config->set_global_statistics(totals);
	stats_config->set_mode(oasis::ZScoreStatsConfig::Mode::Classify);

	// OASIS_ZSCORE_PHASE1_ONLY=1: run phase 1 and then emit nothing, so oasis_stream_profile() shows
	// phase 1 ALONE. Every phase-1 number so far came from subtracting a phase-2-only run from a
	// full run, which also charges phase 1 for the gap between the phases (mode writes plus DuckDB
	// bringing the scan pipeline up) -- several ms that belong to neither.
	if (std::getenv("OASIS_ZSCORE_PHASE1_ONLY")) {
		gstate->total_groups = 0;
	}

	return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> ZScoreInitLocal(ExecutionContext &context, TableFunctionInitInput &input,
                                                    GlobalTableFunctionState *) {
	auto &bind = input.bind_data->Cast<ZScoreBindData>();
	auto lstate = make_uniq<ZScoreLocalState>();
	// Each worker owns its file handle: DuckDB FileHandles are not safe to share across threads.
	auto &fs = FileSystem::GetFileSystem(context.client);
	lstate->file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);
	return std::move(lstate);
}

// Submits one row group's CLASSIFY pass to the scheduler WITHOUT blocking, returning the handle to
// collect its flags later. The whole-column statistics were already published by phase 1 in
// ZScoreInitGlobal, so this is a single pass over the group. Claims the next group atomically, skips empty ones, and returns nullopt
// once the row groups are exhausted (nothing submitted).
std::optional<InFlightZGroup> SubmitGroup(oasis::OasisContext &ctx, ZScoreGlobalState &gstate,
                                          ZScoreLocalState &lstate, const ZScoreBindData &bind) {
	while (true) {
		size_t group = gstate.next_group.fetch_add(1);
		if (group >= gstate.total_groups) {
			return std::nullopt;
		}
		const auto &cc = bind.metadata.groups[group].chunks[bind.column_id];
		if (cc.num_values == 0) {
			continue; // Skip empty row groups.
		}

		// The flag output (one int32 per value) must fit in a single FPGA output buffer. The
		// double-decode diagnostic feeds the column twice and CLASSIFY re-arms after the first
		// tlast, so that flow emits a full set of flags per pass.
		const size_t passes = DoubleDecodeMode() && !PerGroupMode() ? 2 : 1;
		const size_t flag_size = cc.num_values * passes * sizeof(int32_t);
		if (flag_size > libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE) {
			throw NotImplementedException(
			    "Row group %llu produces %llu flag bytes, exceeding the %llu byte maximum output buffer size",
			    (unsigned long long)group, (unsigned long long)flag_size,
			    (unsigned long long)libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
		}

		// Read the compressed column-chunk bytes into one FPGA-mappable input buffer. Both z-score
		// passes read from this same buffer (the host re-feeds the column; no second allocation).
		void *ptr;
		Profiler::open_regions(kAllocate);
		auto status = ctx.memory_pool()->allocate(cc.total_compressed_size, &ptr);
		Profiler::close_regions(kAllocate);
		if (!status.ok()) {
			throw IOException("Could not allocate z-score input buffer: " + status.message());
		}
		Profiler::open_regions(kRead);
		lstate.file_handle->Read(ptr, cc.total_compressed_size, cc.offset);
		Profiler::close_regions(kRead);
		auto input_buf =
		    libstf::make_buffer(ctx.memory_pool(), ptr, cc.total_compressed_size, cc.total_compressed_size);

		const auto type = parcore::metadata::to_libstf_type(cc.type);

		// ONE source+decode: in CLASSIFY mode the operator does no pass 1, it compares straight
		// against the whole-column statistics phase 1 published (see ZScoreStatsConfig). The column
		// still crosses PCIe twice per query -- once in phase 1, once here -- exactly as it did when
		// each row group carried its own 2-pass, so this costs no extra bandwidth.
		Profiler::open_regions(kBuildFlow);
		oasis::OperatorFlow flow;
		flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
		flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		if (PerGroupMode() || DoubleDecodeMode()) {
			// LEGACY needs the column twice: pass 1 accumulates this group's stats, pass 2 classifies.
			// In CLASSIFY the second pair is redundant work (see DoubleDecodeMode).
			flow.push_back(std::make_unique<oasis::LocalSourceOperator>(input_buf));
			flow.push_back(
			    std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
		}
		auto flag_buf = ctx.allocate_output_buffer(flag_size);
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(std::move(flag_buf), 0));

		oasis::QuerySplinter splinter;
		splinter.streams.push_back(std::move(flow));
		Profiler::close_regions(kBuildFlow);

		// MEASURED 2026-08-05: with a second source+decode the flow still returns exactly ONE set of
		// flags (491520 of a doubled 983040 bytes) -- the sink closes on the first tlast and the
		// second pass's output goes nowhere. The extra decode still costs its time, which is the
		// point of the experiment, so the guard expects one set.
		return InFlightZGroup{ctx.scheduler().submit(std::move(splinter)), cc.num_values, cc.num_values,
		                      bind.group_first_row[group]};
	}
}

// Tops the in-flight window back up to WINDOW submitted groups (or until the groups run out). Keeping
// several 2-pass flows queued is what stops the decoder idling between groups.
void FillWindow(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                const ZScoreBindData &bind) {
	constexpr size_t WINDOW = 8;
	Profiler::open_regions(kFillWindow);
	while (lstate.in_flight.size() < WINDOW) {
		auto g = SubmitGroup(ctx, gstate, lstate, bind);
		if (!g) {
			break; // row groups exhausted
		}
		lstate.in_flight.push_back(std::move(*g));
	}
	Profiler::close_regions(kFillWindow);
}

// T2 diagnostic: OASIS_ZSCORE_PER_GROUP=1 reproduces the ORIGINAL per-row-group path on top of the
// current software -- no phase 1, the mode register is never written (so the operator stays in
// LEGACY), and every row group is submitted as its own 2-pass flow. Used to tell whether the
// short-flow beat loss arrived with the two-phase global work or predates it. Results are per-row-
// group z-scores by construction, so only the SHORT-flow count is meaningful in this mode.
bool PerGroupMode() {
	static const bool on = std::getenv("OASIS_ZSCORE_PER_GROUP") != nullptr;
	return on;
}

// Short-flow discriminator: OASIS_ZSCORE_DOUBLE_DECODE=1 gives every CLASSIFY flow a SECOND,
// redundant source+decode pair. Only two things separate a phase-2 flow from a (clean) per-group
// flow: it carries half the decode work, so flows complete twice as fast, and it arms CLASSIFY.
// Doubling the decode work halves the flow-completion rate while leaving the arming rate alone --
// the operator resets on each tlast and re-arms from the config registers, so it still arms once
// per stream, i.e. twice per flow.
//   loss disappears -> the trigger is the flow-completion / interrupt rate
//   loss persists    -> the trigger is CLASSIFY arming itself
// The extra pass classifies the same values against the same totals, so the flow emits 2x the
// flags; the buffer is sized for both and only the first num_values are read.
bool DoubleDecodeMode() {
	static const bool on = std::getenv("OASIS_ZSCORE_DOUBLE_DECODE") != nullptr;
	return on;
}

// Moves on to the next buffer of the current row group once the current one is fully read. A group's
// flags can span several buffers (one interrupt per completed buffer), and every read must stay
// inside the buffer it belongs to.
void AdvanceFlagBuffer(ZScoreLocalState &lstate) {
	while (lstate.current_flags_values == 0 && !lstate.pending_batches.empty()) {
		lstate.current_flags = std::move(lstate.pending_batches.front());
		lstate.pending_batches.pop_front();
		lstate.current_flags_values = lstate.current_flags->size / sizeof(int32_t);
		lstate.current_flags_pos = 0;
	}
}

// Makes the next row group's flags current: tops up the pipeline, then collects the oldest in-flight
// group (FIFO -> row-group order preserved). Returns false once all groups are consumed.
bool LoadNextGroup(oasis::OasisContext &ctx, ZScoreGlobalState &gstate, ZScoreLocalState &lstate,
                   const ZScoreBindData &bind) {
	Profiler::open_regions(kLoadGroup);
	FillWindow(ctx, gstate, lstate, bind); // prime on the first call, top up thereafter
	if (lstate.in_flight.empty()) {
		Profiler::close_regions(kLoadGroup);
		return false; // all row groups done
	}

	auto group = std::move(lstate.in_flight.front());
	lstate.in_flight.pop_front();

	Profiler::open_regions(kCollect);
	auto batch = group.handle.get_next_batch(); // usually already complete: it was submitted groups ago
	Profiler::close_regions(kCollect);
	if (!batch) {
		Profiler::close_regions(kLoadGroup);
		throw InternalException("z-score flow closed with no output");
	}

	// Collect every buffer this flow produced until the group's flags are complete. One interrupt is
	// raised per completed buffer, so a group can arrive in several pieces; taking only the first
	// one silently reads unwritten memory past its end.
	const size_t expected = group.expected_values * sizeof(int32_t);
	size_t collected = batch->buffer->size;
	lstate.pending_batches.clear();
	lstate.pending_batches.push_back(std::move(batch->buffer));
	while (collected < expected) {
		auto more = group.handle.get_next_batch();
		if (!more) {
			// OASIS_ZSCORE_TOLERATE_SHORT=1 keeps going instead of throwing, so one query can report
			// EVERY short flow at once. That tells us whether the missing beats reappear in another
			// flow (totals conserved, a buffer/flow misalignment) or are simply gone (data loss).
			if (std::getenv("OASIS_ZSCORE_TOLERATE_SHORT") || std::getenv("OASIS_ZSCORE_IGNORE_SHORT")) {
				fprintf(stderr, "[zscore] SHORT flow: %llu of %llu bytes, first_row=%lld values=%llu\n",
				        (unsigned long long)collected, (unsigned long long)expected,
				        (long long)group.first_row, (unsigned long long)group.num_values);
				break;
			}
			throw InternalException(
			    "z-score flow ended after %llu of %llu flag bytes for a %llu value row group",
			    (unsigned long long)collected, (unsigned long long)expected,
			    (unsigned long long)group.num_values);
		}
		collected += more->buffer->size;
		lstate.pending_batches.push_back(std::move(more->buffer));
	}
	if (collected > expected) {
		throw InternalException("z-score flow produced %llu flag bytes, expected %llu",
		                        (unsigned long long)collected, (unsigned long long)expected);
	}
	// A short flow leaves the tail of the group unread; clamp so we never read past what arrived.
	// Under DoubleDecodeMode the shortfall is measured against both passes, so it can exceed the
	// group -- the emitted part is capped at num_values below either way.
	lstate.short_by = std::min((expected - collected) / sizeof(int32_t), group.num_values);

	// OASIS_ZSCORE_IGNORE_SHORT=1 reads the group in FULL even when the completion reported fewer
	// bytes. This separates two very different failures: if the results are still exactly right, the
	// flags WERE written and only the reported length is wrong (a notify/size-accounting bug); if
	// they are wrong, beats really are missing from memory. The buffer is allocated for the whole
	// group either way, so reading it is in-bounds.
	const bool ignore_short =
	    lstate.short_by != 0 && std::getenv("OASIS_ZSCORE_IGNORE_SHORT") && lstate.pending_batches.size() == 1;
	if (ignore_short) {
		lstate.short_by = 0;
	}

	lstate.current_flags = std::move(lstate.pending_batches.front());
	lstate.pending_batches.pop_front();
	lstate.current_flags_values = lstate.current_flags->size / sizeof(int32_t);
	if (ignore_short) {
		// Read the whole group out of the buffer that was allocated for it, past the length the
		// completion reported.
		lstate.current_flags_values = group.num_values;
	}
	lstate.current_flags_pos = 0;
	lstate.current_offset = 0;
	lstate.current_remaining = group.num_values - lstate.short_by;
	lstate.current_first_row = group.first_row;
	Profiler::close_regions(kLoadGroup);
	return true;
}

void ZScoreFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
	auto &gstate = data_p.global_state->Cast<ZScoreGlobalState>();
	auto &lstate = data_p.local_state->Cast<ZScoreLocalState>();
	auto &bind = data_p.bind_data->Cast<ZScoreBindData>();
	auto &ctx = *gstate.ctx;

	// Outermost region: every call into the table function. load_group/emit nest under it, so the
	// report reads as a tree and `function` (I) accounts for the whole scan's host time.
	Profiler::open_regions(kFunction);

	if (bind.outliers_only) {
		// Scan flags and emit only the outliers' row ids. A chunk may span several row groups (outliers
		// are rare), so keep loading groups until the output vector fills or the groups run out --
		// returning cardinality 0 is how DuckDB is told the scan is finished, so we must not do it early.
		auto &vec = output.data[0];
		vec.SetVectorType(VectorType::FLAT_VECTOR);
		auto *out = FlatVector::GetDataMutable<int64_t>(vec);
		idx_t n = 0;

		while (n < STANDARD_VECTOR_SIZE) {
			if (lstate.current_remaining == 0) {
				if (!LoadNextGroup(ctx, gstate, lstate, bind)) {
					break; // all row groups consumed
				}
			}
			AdvanceFlagBuffer(lstate);
			const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
			Profiler::open_regions(kEmit);
			// Bounded by what is left in THIS buffer as well as by the group and the output vector.
			while (lstate.current_flags_values > 0 && lstate.current_remaining > 0 &&
			       n < STANDARD_VECTOR_SIZE) {
				if (flags[lstate.current_flags_pos] != 0) {
					out[n++] = lstate.current_first_row + (int64_t)lstate.current_offset;
				}
				lstate.current_flags_pos++;
				lstate.current_flags_values--;
				lstate.current_offset++;
				lstate.current_remaining--;
			}
			Profiler::close_regions(kEmit);
			if (lstate.current_remaining == 0) {
				lstate.current_flags = nullptr; // release; next iteration loads the next group
				lstate.current_flags_values = 0; // drop any unread tail (double-decode's 2nd pass)
			}
		}

		output.SetCardinality(n);
		if (n == 0) {
			StampProgress(gstate); // no row ids left anywhere: this worker's scan is over
		}
		Profiler::close_regions(kFunction);
		return;
	}

	if (lstate.current_remaining == 0) {
		if (!LoadNextGroup(ctx, gstate, lstate, bind)) {
			output.SetCardinality(0);
			StampProgress(gstate); // all row groups consumed: this worker's scan is over
			Profiler::close_regions(kFunction);
			return;
		}
	}

	AdvanceFlagBuffer(lstate);
	// Never read past the current buffer: a row group can span several of them.
	const size_t emit =
	    std::min<size_t>({lstate.current_flags_values, lstate.current_remaining, STANDARD_VECTOR_SIZE});

	auto &vec = output.data[0];
	vec.SetVectorType(VectorType::FLAT_VECTOR);
	// This DuckDB fork makes FlatVector::GetData const; GetDataMutable is the writable accessor.
	auto *out = FlatVector::GetDataMutable<bool>(vec);
	const auto *flags = reinterpret_cast<const int32_t *>(lstate.current_flags->ptr);
	Profiler::open_regions(kEmit);
	for (size_t i = 0; i < emit; i++) {
		out[i] = flags[lstate.current_flags_pos + i] != 0;
	}
	Profiler::close_regions(kEmit);
	output.SetCardinality(emit);

	lstate.current_flags_pos += emit;
	lstate.current_flags_values -= emit;
	lstate.current_offset += emit;
	lstate.current_remaining -= emit;
	if (lstate.current_remaining == 0) {
		lstate.current_flags = nullptr; // Release the flag buffer; next call loads the next group.
		lstate.current_flags_values = 0; // drop any unread tail (double-decode's 2nd pass)
	}
	Profiler::close_regions(kFunction);
}

} // namespace

void RegisterZScoreFunction(ExtensionLoader &loader) {
	TableFunction zscore("zscore",                                          // Function name
	                     {LogicalType::VARCHAR, LogicalType::VARCHAR},       // Args: parquet path, column name
	                     ZScoreFunction,                                     // Table function
	                     ZScoreBind,                                         // Bind
	                     ZScoreInitGlobal,                                   // Init global
	                     ZScoreInitLocal);                                   // Init local
	zscore.named_parameters["outliers_only"] = LogicalType::BOOLEAN;
	loader.RegisterFunction(zscore);
}

} // namespace duckdb
