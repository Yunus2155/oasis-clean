#!/bin/bash
# Comprehensive phase-1 elimination matrix for the global z-score.
#
# Phase 1 (the STATS pass) takes ~11.4 ms on taxi_fare while the decoder moves only ~5.3 ms of beats
# and NEVER stalls. Four single-shot probes failed to explain the gap (parallel submit, scheduler
# queue depth, per-flow batching, per-worker collect timing), so this sweeps every candidate at once
# instead and prints one table.
#
#   Run:  ./phase1_matrix.sh [outfile.csv]
#   Needs: a flashed board, ~/duckdb-global-fix built from this branch.
#
# WHAT EACH COLUMN ELIMINATES
#   preread=1 pulls every column chunk into memory BEFORE the submit loop, so the loop does no file
#   I/O at all. workers=N runs the submit/collect loop on N threads.
#
#   wall drops sharply at preread=1        -> the host read serialises phase 1. The loop alternates
#                                             "read one group" and "block on the previous one" on the
#                                             same thread, so the two never overlap.
#   wall unchanged at preread=1            -> the read is already hidden; the floor is hardware.
#   read total grows with workers          -> file reads do NOT parallelise (NFS / page cache), which
#                                             is why the earlier 12-worker attempt netted zero.
#   wall flat across workers AND preread   -> neither host nor read; the floor is the FPGA, and the
#                                             next step is a hardware-side measurement, not host code.
#   extprice vs taxi_fare                  -> extprice is 1.0x compressed (408 MB read) vs taxi 3.5x
#                                             (46 MB) for a similar decoded volume. If phase 1 tracks
#                                             READ bytes it is I/O; if it tracks DECODED bytes it is
#                                             the decoder.
#
# Every run uses OASIS_ZSCORE_PHASE1_ONLY=1, so nothing from phase 2 or from DuckDB's scan setup is
# charged to phase 1 -- no subtraction, no contamination.

set -uo pipefail

OUT="${1:-phase1_matrix.csv}"
DB="${OASIS_DUCKDB:-$HOME/duckdb-global-fix}"
BENCH="${BENCH_DIR:-$HOME/bench}"
FILES="${FILES:-taxi_fare tpch_sf17_extprice}"
WORKERS="${WORKERS:-1 2 4 12}"
PREREAD="${PREREAD:-0 1}"
REPS="${REPS:-3}"

[[ -x "$DB" ]] || { echo "no DuckDB binary at $DB (set OASIS_DUCKDB)" >&2; exit 1; }

echo "file,workers,preread,rep,wall_ms,preread_ms,allocate_ms,read_ms,alloc_out_ms,submit_ms,collect_ms" > "$OUT"

printf '%-22s %8s %8s %10s %10s %10s %10s %10s\n' \
       file workers preread wall_ms preread_ms read_ms submit_ms collect_ms
printf '%.0s-' {1..96}; echo

for f in $FILES; do
    path="$BENCH/$f.parquet"
    [[ -f "$path" ]] || { echo "missing $path, skipping" >&2; continue; }

    for pr in $PREREAD; do
        for w in $WORKERS; do
            # One duckdb process per cell. The first rep warms the page cache and the board; only
            # the later reps are reported, and every rep is written to the CSV so the spread is visible.
            log=$(mktemp)
            # Build the environment as an array: a `$(... && echo VAR=1)` prefix is expanded AFTER
            # the command is parsed, so bash treats it as a command name, not an assignment.
            envs=(OASIS_ZSCORE_PHASE1_ONLY=1 OASIS_ZSCORE_DEBUG_PHASE1=1
                  OASIS_ZSCORE_PHASE1_WORKERS="$w")
            [[ "$pr" == "1" ]] && envs+=(OASIS_ZSCORE_PHASE1_PREREAD=1)
            {
                echo ".timer off"
                for ((i = 0; i < REPS; i++)); do
                    echo "SELECT count(*) FROM zscore('$path','x', outliers_only := true);"
                done
            } | env "${envs[@]}" timeout 300 "$DB" > /dev/null 2> "$log"

            rep=0
            last=""
            while IFS=, read -r wall prd alloc rd aout sub col grp wrk prf; do
                echo "$f,$w,$pr,$rep,$wall,$prd,$alloc,$rd,$aout,$sub,$col" >> "$OUT"
                last="$wall $prd $rd $sub $col"   # report the LAST (warm) rep
                rep=$((rep + 1))
            done < <(grep -oP '(?<=phase1csv,).*' "$log")

            if [[ -n "$last" ]]; then
                read -r c_wall c_prd c_rd c_sub c_col <<< "$last"
                printf '%-22s %8s %8s %10s %10s %10s %10s %10s\n' \
                       "$f" "$w" "$pr" "$c_wall" "$c_prd" "$c_rd" "$c_sub" "$c_col"
            else
                printf '%-22s %8s %8s %10s\n' "$f" "$w" "$pr" "NO DATA"
                tail -5 "$log" | sed 's/^/    /'
            fi
            unset last
            rm -f "$log"
        done
    done
done

echo
echo "full CSV: $OUT"
