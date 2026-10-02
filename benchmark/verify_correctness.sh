#!/usr/bin/env bash
#
# Set-level correctness check for zscore(). Counts and checksums can agree by accident; this
# compares the actual set of outlier row ids the FPGA returns against the exact set computed on the
# CPU, and repeats it, because the failure we are chasing is intermittent.
#
# The CPU reference uses the SAME division-free integer predicate the hardware evaluates,
#   (n*x - S)^2 > k^2 * (n*Q - S^2),
# in HUGEINT, so a difference cannot be blamed on floating-point rounding. It uses file_row_number
# so the row ids are the same absolute ids the scan reports.
#
# Per run it reports:
#   fp    false positives -- ids the FPGA returned that are not outliers
#   miss  misses          -- outliers the FPGA did not return
#   grp   how many distinct row groups the wrong ids fall in
# A correct run is fp=0 miss=0.
#
# Usage:
#   ./verify_correctness.sh <file.parquet> [runs] [threads]

set -euo pipefail

FILE="${1:?usage: verify_correctness.sh <file.parquet> [runs] [threads]}"
RUNS="${2:-10}"
export OASIS_ZSCORE_THREADS="${3:-12}"
DB="${OASIS_DUCKDB:-$HOME/duckdb-gz}"
# DuckDB's writer emits fixed-size row groups; only used to attribute wrong ids to a group.
GROUP_SIZE="${GROUP_SIZE:-122880}"

[[ -x "$DB" ]] || { echo "no DuckDB binary at $DB (set OASIS_DUCKDB)" >&2; exit 1; }

echo "file    : $FILE"
echo "runs    : $RUNS at OASIS_ZSCORE_THREADS=$OASIS_ZSCORE_THREADS"
echo

{
	# Ground truth once, from the file itself.
	cat <<-SQL
		CREATE TABLE truth AS
		WITH st AS (
		  SELECT count(*)::HUGEINT n, sum(x::HUGEINT) s, sum(x::HUGEINT * x::HUGEINT) q
		  FROM read_parquet('$FILE')
		)
		SELECT d.file_row_number AS row_id
		FROM read_parquet('$FILE', file_row_number = true) d, st
		WHERE (st.n * d.x::HUGEINT - st.s) * (st.n * d.x::HUGEINT - st.s) > 9 * (st.n * st.q - st.s * st.s);
		SELECT 'truth' AS run, count(*) AS n, 0 AS fp, 0 AS miss, 0 AS grp FROM truth;
	SQL

	for i in $(seq "$RUNS"); do
		cat <<-SQL
			CREATE TABLE r$i AS
			  SELECT * FROM zscore('$FILE', 'x', outliers_only := true);
			CREATE TABLE d$i AS
			  SELECT row_id, 'fp' AS kind FROM (SELECT * FROM r$i EXCEPT SELECT * FROM truth)
			  UNION ALL
			  SELECT row_id, 'miss'      FROM (SELECT * FROM truth EXCEPT SELECT * FROM r$i);
			SELECT '$i' AS run,
			       (SELECT count(*) FROM r$i) AS n,
			       (SELECT count(*) FROM r$i) - (SELECT count(DISTINCT row_id) FROM r$i) AS dup,
			       (SELECT count(*) FROM d$i WHERE kind = 'fp')   AS fp,
			       (SELECT count(*) FROM d$i WHERE kind = 'miss') AS miss,
			       (SELECT count(DISTINCT row_id // $GROUP_SIZE) FROM d$i) AS grp;
			-- Where the wrong ids sit: which row groups, and how far into each. A cluster at one
			-- group means that group's buffer was paired with the wrong flow; a spread means
			-- something more general.
			SELECT '$i' AS run, kind, row_id // $GROUP_SIZE AS row_group,
			       min(row_id % $GROUP_SIZE) AS first_off, max(row_id % $GROUP_SIZE) AS last_off,
			       count(*) AS ids
			FROM d$i GROUP BY 1, 2, 3 ORDER BY 3, 2;
			DROP TABLE r$i; DROP TABLE d$i;
		SQL
	done
} | "$DB" -init /dev/null -box
