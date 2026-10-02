#!/usr/bin/env bash
#
# Run the z-score benchmark over every parquet listed in a dataset list produced by
# gen_tpch.py / get_taxi.py, and emit one tidy CSV.
#
# For each input it runs, IN THE SAME DuckDB BINARY ON THE SAME MACHINE:
#   * a CPU baseline at each thread count in THREADS
#   * the FPGA path via zscore(..., outliers_only := true)
# and it compares the outlier counts, so a wrong result cannot quietly become a fast one.
#
# The CPU query is deliberately the SAME ALGORITHM as the hardware -- a two-pass
# population z-score with |z| > 3 -- rather than whatever DuckDB could do fastest. A
# baseline that computes something cheaper is not a baseline.
#
# Usage:
#   ./run_bench.sh /local/$USER/bench/tpch.csv results.csv
#
# Environment:
#   OASIS_DUCKDB          DuckDB binary with the oasis extension  (default ~/duckdb-global)
#   THREADS               CPU thread counts to sweep              (default "1 4 8 16 32")
#   REPS                  timed repetitions per configuration     (default 3)
#   OASIS_ZSCORE_THREADS  host emission threads for the FPGA path (default 12 = 4 per lane)
#
# NOTE: keep the parquet files on LOCAL disk. /home is NFS here, and re-reading a
# multi-GB file over NFS measures the network, not the accelerator.

set -euo pipefail

DATASETS="${1:?usage: run_bench.sh <tpch.csv> [results.csv]}"
RESULTS="${2:-results.csv}"

DB="${OASIS_DUCKDB:-$HOME/duckdb-global}"
THREADS="${THREADS:-1 4 8 16 32}"
REPS="${REPS:-3}"
# 4, not more: at 6+ host threads the FPGA drops whole 64-byte beats from a row group's flag
# stream (measured 2026-08-05: 0 short flows in 5 runs at 1/2/4 threads, 8 in 5 runs at 6, and
# more at 8/12). The loss is below the host -- no flow receives the missing bytes -- so it cannot
# be worked around here. 4 threads is the fastest setting that is lossless; zscore_scan.cpp throws
# if a flow ever comes up short, so a regression cannot pass silently.
export OASIS_ZSCORE_THREADS="${OASIS_ZSCORE_THREADS:-4}"

# REFERENCE=group benchmarks the ORIGINAL per-row-group semantics on BOTH sides: the CPU baseline
# normalises each parquet row group on its own statistics, and the FPGA is put in the same mode via
# OASIS_ZSCORE_PER_GROUP (which also keeps the operator in LEGACY, so a pre-global bitstream such as
# build-38 can be measured). Setting both here means the two sides cannot drift apart.
REFERENCE="${REFERENCE:-global}"
if [[ "$REFERENCE" == group ]]; then
	export OASIS_ZSCORE_PER_GROUP=1
fi
echo "reference: $REFERENCE   fpga per-group: ${OASIS_ZSCORE_PER_GROUP:-0}"

PROFILE_DIR="$(dirname "$RESULTS")/profiles"
mkdir -p "$PROFILE_DIR"

[[ -x "$DB" ]] || { echo "no DuckDB binary at $DB (set OASIS_DUCKDB)" >&2; exit 1; }

# Pull "Run Time (s): real 0.170 ..." out of the CLI's timer output and keep the fastest,
# so one unlucky page-cache miss or scheduler hiccup does not become the reported number.
# .timer is switched on AFTER any SET statement, otherwise the SET's own ~4ms would win.
best_time() { awk '/Run Time \(s\)/ {print $5}' | sort -g | head -1; }
# Runs in -csv mode, so a result row is a bare integer on its own line.
last_count() { awk '/^[0-9]+$/ {c=$0} END {print c}'; }

echo "dataset,file,rows,ratio_vs_int32,engine,threads,seconds,rows_per_sec,outliers" > "$RESULTS"

# Field order is fixed by the generators: file,type,encoding,rows,compressed_bytes,...
tail -n +2 "$DATASETS" | while IFS=, read -r file _type _enc rows _cbytes _bpv ratio _maxabs _sumsq _worst overflow _rest; do
	[[ -f "$file" ]] || { echo "missing $file, skipping" >&2; continue; }
	name="$(basename "$file" .parquet)"

	if [[ "$overflow" == "FAIL" ]]; then
		echo ">>> $name: SKIPPED, exceeds the 64-bit sum-of-squares accumulator" >&2
		continue
	fi

	echo ">>> $name  ($rows rows, ${ratio}x compression)"

	# ---- CPU baselines -------------------------------------------------------------
	for t in $THREADS; do
		out=$($DB -init /dev/null -csv <<-SQL
			SET threads=$t;
			.timer on
			$(for _ in $(seq $((REPS + 1))); do
				if [[ "$REFERENCE" == group ]]; then
					# Row groups are not uniform in size, so boundaries come from the footer and each
					# row is attached to its group with an ASOF join.
					echo "WITH meta AS (SELECT row_group_id AS rg, coalesce(sum(num_values) OVER (ORDER BY row_group_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS start_row FROM parquet_metadata('$file')),"
					echo "     d AS (SELECT x, file_row_number AS frn FROM read_parquet('$file', file_row_number = true)),"
					echo "     j AS (SELECT d.x, meta.rg FROM d ASOF JOIN meta ON d.frn >= meta.start_row),"
					echo "     s AS (SELECT rg, avg(x::DOUBLE) m, stddev_pop(x::DOUBLE) sd FROM j GROUP BY rg)"
					echo "SELECT count(*) FROM j JOIN s USING (rg) WHERE s.sd > 0 AND abs((j.x::DOUBLE - s.m) / s.sd) > 3;"
				else
					echo "WITH s AS (SELECT avg(x::DOUBLE) m, stddev_pop(x::DOUBLE) sd FROM read_parquet('$file'))"
					echo "SELECT count(*) FROM read_parquet('$file'), s WHERE abs((x::DOUBLE - m) / sd) > 3;"
				fi
			done)
		SQL
		)
		# The first repetition warms the page cache; best_time discards it implicitly.
		secs=$(echo "$out" | best_time)
		cnt=$(echo "$out" | last_count)
		rps=$(awk -v r="$rows" -v s="$secs" 'BEGIN{printf "%.0f", (s+0>0)? r/(s+0) : 0}')
		echo "    cpu x$t: ${secs}s  ($cnt outliers)"
		echo "$(basename "$DATASETS" .csv),$name,$rows,$ratio,cpu,$t,$secs,$rps,$cnt" >> "$RESULTS"
		cpu_count="$cnt"
	done

	# ---- FPGA ----------------------------------------------------------------------
	# A refused bind (overflow guard) or a wedged board must not abort a long sweep, so the
	# failure is recorded against this file and the run moves on.
	out=$($DB -init /dev/null -csv 2>&1 <<-SQL || true
		.timer on
		$(for _ in $(seq $((REPS + 1))); do
			echo "SELECT count(*) FROM zscore('$file', 'x', outliers_only := true);"
		done)
	SQL
	)
	secs=$(echo "$out" | best_time)
	cnt=$(echo "$out" | last_count)

	# .timer still prints a Run Time line for a statement that ERRORED, and that line is
	# always the fastest one in the output. Requiring a result row as well is what stops a
	# failed bind from being recorded as a spectacular 0.001s.
	if [[ -z "$secs" || -z "$cnt" ]]; then
		echo "    fpga  : FAILED -- $(echo "$out" | grep -m1 -i error || echo "no result returned")" >&2
		echo "$(basename "$DATASETS" .csv),$name,$rows,$ratio,fpga,$OASIS_ZSCORE_THREADS,,,ERROR" >> "$RESULTS"
		continue
	fi
	rps=$(awk -v r="$rows" -v s="$secs" 'BEGIN{printf "%.0f", (s+0>0)? r/(s+0) : 0}')
	echo "    fpga  : ${secs}s  ($cnt outliers)"
	echo "$(basename "$DATASETS" .csv),$name,$rows,$ratio,fpga,$OASIS_ZSCORE_THREADS,$secs,$rps,$cnt" >> "$RESULTS"

	if [[ -n "${cpu_count:-}" && "$cpu_count" != "$cnt" ]]; then
		echo "    !! MISMATCH: cpu=$cpu_count fpga=$cnt -- timing above is meaningless" >&2
	fi

	# ---- profiler counters ---------------------------------------------------------
	# Taken from a fresh single run so the counters describe one scan, not REPS of them.
	$DB -init /dev/null -csv <<-SQL > "$PROFILE_DIR/${name}_stream.csv" 2>/dev/null || true
		SELECT count(*) FROM zscore('$file', 'x', outliers_only := true);
		SELECT * FROM oasis_stream_profile();
	SQL
	$DB -init /dev/null -csv <<-SQL > "$PROFILE_DIR/${name}_egress.csv" 2>/dev/null || true
		SELECT count(*) FROM zscore('$file', 'x', outliers_only := true);
		SELECT * FROM oasis_egress_bandwidth();
	SQL
done

echo
echo "results:  $RESULTS"
echo "profiles: $PROFILE_DIR"
