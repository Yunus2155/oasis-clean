#!/usr/bin/env bash
#
# One comprehensive study of the short-flow bug. Answers three questions in a single run:
#
#   Q1  How often do flows come back short, as a function of the file (egress rate) and the
#       host thread count?
#   Q2  When a flow IS short, are the flags nevertheless correct in memory? Each configuration is
#       run twice: once clamping to the reported length (clamp) and once reading the group in full
#       (ignore). If `ignore` is correct on runs that had short flows, the data was written and only
#       the reported length is wrong -- an accounting bug, not data loss.
#   Q3  Does the correctness of `clamp` degrade the way the short count predicts?
#
# Correctness is set-level against a CPU reference that uses the hardware's own integer predicate
# in HUGEINT, so no result can be blamed on floating point. The reference is computed once per file.
#
# Output is one summary table:
#   file  threads  mode  runs  shorts  runs_short  fp  miss  bad_runs
# `shorts` counts short flows, `runs_short` how many runs saw at least one, `bad_runs` how many runs
# differed from the reference. The row that settles Q2 is: mode=ignore, runs_short>0, bad_runs=0.
#
# Usage:  ./short_flow_study.sh [runs_per_config]

set -uo pipefail

RUNS="${1:-5}"
DB="${OASIS_DUCKDB:-$HOME/duckdb-gz}"
BENCH="${BENCH_DIR:-$HOME/bench}"
GROUP_SIZE=122880

# extprice = no compression, highest egress rate, fails earliest.
# distance  = 1.55M true outliers, so a lost tail cannot hide.
# fare      = few outliers, the case where a lost tail is easiest to miss.
FILES="${FILES:-tpch_sf17_extprice taxi_distance taxi_fare}"
THREADS="${THREADS_SWEEP:-2 4 8 12}"

[[ -x "$DB" ]] || { echo "no DuckDB binary at $DB (set OASIS_DUCKDB)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '%-24s %8s %8s %6s %8s %11s %8s %8s %9s\n' \
       file threads mode runs shorts runs_short fp miss bad_runs
printf '%.0s-' {1..100}; echo

for f in $FILES; do
	path="$BENCH/$f.parquet"
	[[ -f "$path" ]] || { echo "missing $path, skipping" >&2; continue; }

	for t in $THREADS; do
		for mode in ${MODES:-clamp ignore}; do
			if [[ $mode == clamp ]]; then
				env_var="OASIS_ZSCORE_TOLERATE_SHORT=1"
			else
				env_var="OASIS_ZSCORE_IGNORE_SHORT=1"
			fi

			{
				# Reference once per session, using the hardware's exact predicate.
				# REFERENCE=group reproduces the ORIGINAL per-row-group semantics instead of the
				# whole-column one, so it can be compared against a LEGACY (pre-global) bitstream.
				# Row groups are not uniform in size, so the boundaries come from the footer.
				if [[ "${REFERENCE:-global}" == group ]]; then
					cat <<-SQL
						CREATE TABLE truth AS
						WITH meta AS (
						  SELECT row_group_id AS rg,
						         coalesce(sum(num_values) OVER (ORDER BY row_group_id
						           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS start_row
						  FROM parquet_metadata('$path')),
						d AS (SELECT x, file_row_number AS frn
						      FROM read_parquet('$path', file_row_number = true)),
						j AS (SELECT d.x, d.frn, meta.rg FROM d ASOF JOIN meta ON d.frn >= meta.start_row),
						st AS (SELECT rg, count(*)::HUGEINT n, sum(x::HUGEINT) s,
						              sum(x::HUGEINT*x::HUGEINT) q
						       FROM j GROUP BY rg)
						SELECT j.frn AS row_id
						FROM j JOIN st USING (rg)
						WHERE (st.n*j.x::HUGEINT - st.s)*(st.n*j.x::HUGEINT - st.s)
						      > 9*(st.n*st.q - st.s*st.s);
					SQL
				else
					cat <<-SQL
						CREATE TABLE truth AS
						WITH st AS (
						  SELECT count(*)::HUGEINT n, sum(x::HUGEINT) s, sum(x::HUGEINT*x::HUGEINT) q
						  FROM read_parquet('$path')
						)
						SELECT d.file_row_number AS row_id
						FROM read_parquet('$path', file_row_number = true) d, st
						WHERE (st.n*d.x::HUGEINT - st.s)*(st.n*d.x::HUGEINT - st.s) > 9*(st.n*st.q - st.s*st.s);
					SQL
				fi
				for i in $(seq "$RUNS"); do
					cat <<-SQL
						CREATE TABLE r$i AS SELECT * FROM zscore('$path','x', outliers_only := true);
						SELECT $i AS run,
						       (SELECT count(*) FROM (SELECT * FROM r$i EXCEPT SELECT * FROM truth)) AS fp,
						       (SELECT count(*) FROM (SELECT * FROM truth EXCEPT SELECT * FROM r$i)) AS miss;
						DROP TABLE r$i;
					SQL
				done
			} | env $env_var OASIS_ZSCORE_THREADS="$t" "$DB" -init /dev/null -csv \
			      > "$TMP/out.csv" 2> "$TMP/err.txt"

			# grep -c prints 0 and exits 1 when there is no match, so guard the exit code only.
			shorts=$(grep -c 'SHORT flow' "$TMP/err.txt" || true)
			runs_short=$shorts

			# -csv prints a header per result set, so keep only rows whose first field is a number.
			fp=$(awk -F, '$1 ~ /^[0-9]+$/ && NF==3 {s+=$2} END {print s+0}' "$TMP/out.csv")
			miss=$(awk -F, '$1 ~ /^[0-9]+$/ && NF==3 {s+=$3} END {print s+0}' "$TMP/out.csv")
			bad=$(awk -F, '$1 ~ /^[0-9]+$/ && NF==3 && ($2+0>0 || $3+0>0) {c++} END {print c+0}' "$TMP/out.csv")
			done_runs=$(awk -F, '$1 ~ /^[0-9]+$/ && NF==3 {c++} END {print c+0}' "$TMP/out.csv")

			if [[ $done_runs -eq 0 ]]; then
				note=$(grep -m1 -i 'error' "$TMP/err.txt" | cut -c1-40)
				printf '%-24s %8s %8s %6s %8s %11s %8s %8s %9s  %s\n' \
				       "$f" "$t" "$mode" 0 "$shorts" "$runs_short" - - - "ABORTED: $note"
			else
				printf '%-24s %8s %8s %6s %8s %11s %8s %8s %9s\n' \
				       "$f" "$t" "$mode" "$done_runs" "$shorts" "$runs_short" "$fp" "$miss" "$bad"
			fi
		done
	done
done

echo
echo "Read it like this:"
echo "  shorts=0 everywhere for a file/thread  -> that configuration does not trigger the bug"
echo "  mode=ignore, shorts>0, fp=miss=0       -> flags were written; only the reported length is wrong"
echo "  mode=ignore, shorts>0, miss>0          -> beats really are missing from memory (RTL problem)"
echo "  mode=clamp vs ignore at the same point -> what the clamp costs in correctness"
