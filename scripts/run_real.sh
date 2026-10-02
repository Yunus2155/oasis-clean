#!/bin/bash
# FPGA vs CPU z-score execution time on the 7 real datasets (the paper's real-dataset figure).
#
# Per dataset and arm: 1 warm-up + N timed runs in one DuckDB session, end-to-end query time
# (.timer "real"), median. The query aggregates the flags (count of outliers) instead of storing them,
# so DuckDB's single-threaded table append is not measured. CPU arm = the same algorithm in SQL: a
# two-pass population z-score over the whole column, |z| > 3. Speedup = CPU / FPGA.
# The FPGA arm uses 12 host emission threads (OASIS_ZSCORE_THREADS=12), the value the published
# measurements used; it is set here, so no environment variables are needed.
#
# Usage:  scripts/run_real.sh [DATASET_DIR]      (default ~/datasets-zscore; N=15 by default)
# Needs:  extension/build/release/duckdb built, FPGA programmed with build-41, 1 GiB huge pages reserved.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUCK="${DUCK:-$ROOT/extension/build/release/duckdb}"
DS="${1:-$HOME/datasets-zscore}"
N="${N:-15}"
THREADS="${THREADS:-32}"

export LD_LIBRARY_PATH="$HOME/opt/lib:$HOME/opt/jemalloc/lib:${LD_LIBRARY_PATH:-}"
export OASIS_ZSCORE_THREADS=12

# file stem, column, row count, label in the figure
DATASETS=(
    "taxi_d1            fare_cents  3.0M   taxi_d1"
    "tpch_qty           v           6.0M   tpch_qty"
    "taxi_d2            fare_cents  6.0M   taxi_d2"
    "tpch_extprice      v           6.0M   extprice"
    "taxi_d3            fare_cents  13.1M  taxi_d3"
    "taxi_d4            fare_cents  20.3M  taxi_d4"
    "tpch_extprice_sf10 v           60.0M  sf10"
)

# Runs one query 1+N times; prints "<median seconds> <outlier count>".
measure() {
    local q="$1" out
    out=$( { echo "PRAGMA threads=$THREADS;"; echo ".mode list"; echo ".headers off"; echo ".timer on"
             for _ in $(seq 0 "$N"); do echo "$q"; done; } | "$DUCK" 2>&1 )
    local med cnt
    med=$(echo "$out" | grep -oP 'Run Time \(s\): real \K[0-9.]+' | tail -n +2 | sort -n |
          awk '{a[NR]=$1} END {if (NR==0) print "nan"; else print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}')
    cnt=$(echo "$out" | grep -E '^[0-9]+$' | tail -1)
    # A failed statement still prints a Run Time line, so a time without a result is not a time.
    [ -z "$cnt" ] && med="nan"
    echo "${med:-nan} ${cnt:-nan}"
}

if [ ! -x "$DUCK" ]; then
    echo "ERROR: no DuckDB binary at $DUCK -- build the extension first (see README)" >&2
    exit 1
fi

printf "%-16s %7s %10s %10s %9s\n" "dataset" "rows" "CPU (ms)" "FPGA (ms)" "speedup"
warnings=()
for d in "${DATASETS[@]}"; do
    read -r name col rows label <<< "$d"
    f="$DS/$name.parquet"
    if [ ! -f "$f" ]; then
        warnings+=("$name: missing $f (skipped)")
        continue
    fi
    cat "$f" > /dev/null    # warm the page cache

    read -r fpga_s fpga_cnt <<< "$(measure "SELECT count(*) FILTER (WHERE is_outlier) FROM zscore('$f','$col');")"
    read -r cpu_s  cpu_cnt  <<< "$(measure "WITH s AS (SELECT avg($col::DOUBLE) m, stddev_pop($col::DOUBLE) sd FROM read_parquet('$f')) SELECT count(*) FROM read_parquet('$f'), s WHERE abs(($col::DOUBLE - m) / sd) > 3;")"

    if [[ "$fpga_s" == nan || "$cpu_s" == nan ]]; then
        printf "%-16s %7s %10s %10s %9s\n" "$label" "$rows" "-" "-" "-"
    else
        awk -v l="$label" -v r="$rows" -v c="$cpu_s" -v g="$fpga_s" \
            'BEGIN { printf "%-16s %7s %10.1f %10.1f %8.2fx\n", l, r, c*1000, g*1000, (g>0 ? c/g : 0) }'
    fi

    # Correctness: the z-score is exact, so the FPGA must flag exactly the rows the CPU flags.
    if [[ "$fpga_cnt" =~ ^[0-9]+$ && "$cpu_cnt" =~ ^[0-9]+$ ]]; then
        if [ "$fpga_cnt" -ne "$cpu_cnt" ]; then
            warnings+=("$name: FPGA flagged $fpga_cnt rows, CPU $cpu_cnt -- the counts must be equal; do not use this row")
        fi
    else
        warnings+=("$name: a query failed (FPGA='$fpga_cnt' CPU='$cpu_cnt'); rerun it by hand to see the error")
    fi
done

for w in ${warnings[@]+"${warnings[@]}"}; do echo "WARNING: $w" >&2; done
