#!/usr/bin/env bash
#
# Where does a short flow lose its beats: did the FPGA never PRODUCE them, or did it produce them
# and the host never RECEIVE them?
#
# `oasis_zscore_profile()` counts the output handshakes of the z-score stage itself, one row per
# lane. That count is what the accelerator believes it emitted. The host, separately, reports a
# SHORT flow when a group's flags arrive incomplete. Running both in the same session ties them
# together:
#
#   run WITH a short, beats == the clean reference   -> produced but not delivered (writer/DMA/notify)
#   run WITH a short, beats short by short_bytes/64  -> never produced (operator/decoder/arbiter)
#
# One duckdb session per attempt, so the counters belong to exactly one query. The failure rate is
# ~2-3% per run, so this loops until it catches ATTEMPTS shorts (or runs out of attempts).
#
# Usage:  ./beat_accounting.sh [attempts] [threads] [file]

set -uo pipefail

ATTEMPTS="${1:-100}"
THREADS="${2:-12}"
FILE="${3:-tpch_sf17_extprice}"
DB="${OASIS_DUCKDB:-$HOME/duckdb-gz}"
BENCH="${BENCH_DIR:-$HOME/bench}"
PATH_PQ="$BENCH/$FILE.parquet"

[[ -x "$DB" ]] || { echo "no DuckDB binary at $DB (set OASIS_DUCKDB)" >&2; exit 1; }
[[ -f "$PATH_PQ" ]] || { echo "missing $PATH_PQ" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The profile read comes AFTER the scan in the same session, so it reports that scan's counters.
# Reading it first as well drains anything left over from binding.
sql() {
	cat <<-SQL
		SELECT count(*) FROM (SELECT sum(out_handshakes) FROM oasis_zscore_profile());
		SELECT count(*) AS outliers FROM zscore('$PATH_PQ','x') WHERE is_outlier;
		SELECT sum(out_handshakes) AS beats FROM oasis_zscore_profile();
	SQL
}

printf '%-5s %8s %12s %12s %10s\n' run shorts short_bytes beats delta_beats
printf '%.0s-' {1..55}; echo

ref_beats=""
shorts_seen=0

for i in $(seq "$ATTEMPTS"); do
	# NB: no `< /dev/null` here -- the SQL arrives on stdin through the pipe.
	sql | env OASIS_ZSCORE_THREADS="$THREADS" OASIS_ZSCORE_TOLERATE_SHORT=1 \
	      timeout 120 "$DB" -init /dev/null -csv > "$TMP/out.csv" 2> "$TMP/err.txt"
	rc=$?

	# Bytes missing across every short flow this run reported.
	short_bytes=$(awk '/SHORT flow/ {split($4,a,""); print}' "$TMP/err.txt" |
	              sed -E 's/.*SHORT flow: ([0-9]+) of ([0-9]+) bytes.*/\2 \1/' |
	              awk '{s += $1 - $2} END {print s+0}')
	shorts=$(grep -c 'SHORT flow' "$TMP/err.txt" || true)

	# Last numeric single-field row = the beats total.
	beats=$(awk -F, '$1 ~ /^[0-9]+$/ && NF==1 {v=$1} END {print v+0}' "$TMP/out.csv")

	if [[ $rc -ne 0 || $beats -eq 0 ]]; then
		printf '%-5s %8s %12s %12s %10s  %s\n' "$i" "$shorts" "$short_bytes" "$beats" - \
		       "FAILED rc=$rc $(grep -m1 -i error "$TMP/err.txt" | cut -c1-40)"
		continue
	fi

	# The first clean run defines the reference; every later run is judged against it.
	if [[ -z $ref_beats && $shorts -eq 0 ]]; then
		ref_beats=$beats
		printf '%-5s %8s %12s %12s %10s  <- reference\n' "$i" "$shorts" "$short_bytes" "$beats" 0
		continue
	fi

	delta=$(( ${ref_beats:-$beats} - beats ))
	if [[ $shorts -gt 0 ]]; then
		shorts_seen=$((shorts_seen + 1))
		printf '%-5s %8s %12s %12s %10s  <- SHORT, expected delta %s\n' \
		       "$i" "$shorts" "$short_bytes" "$beats" "$delta" "$((short_bytes / 64))"
	elif [[ $delta -ne 0 ]]; then
		printf '%-5s %8s %12s %12s %10s  <- beats drifted with NO short\n' \
		       "$i" "$shorts" "$short_bytes" "$beats" "$delta"
	fi
done

echo
echo "reference beats = ${ref_beats:-none}, runs with a short = $shorts_seen"
echo "Read it like this:"
echo "  delta == short_bytes/64  -> the beats were NEVER PRODUCED (operator/decoder/arbiter)"
echo "  delta == 0               -> produced but NOT DELIVERED (output writer / DMA / notify)"
echo "  beats drift with shorts=0-> the counter itself is unreliable; stop and say so"
