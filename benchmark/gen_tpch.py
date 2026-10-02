#!/usr/bin/env python3
"""
Generate TPC-H benchmark inputs for the FPGA z-score operator.

The operator consumes plain SNAPPY parquet: zscore_scan.cpp reads the footer for the
column-chunk layout and then DMAs the raw compressed bytes to the card. So there is no
special format here -- the only real constraints are:

  1. TYPE. The datapath (hardware/src/hdl/z-score/z_score_squared.sv, ELEM_BITS=32) is
     32-bit signed INTEGER. TPC-H DECIMAL(15,2) lands as physical INT64 and will be
     rejected, so every column is cast to INTEGER here.

  2. OVERFLOW. Pass 1 accumulates Sum(x^2) into a 64-bit signed register. It wraps
     silently, so a column is only usable when rows * max(|x|)^2 < 2^63. That rules out
     e.g. l_extendedprice scaled to cents, which overflows even at SF1.

The four columns below are chosen to span the COMPRESSION axis at identical row counts,
because compression ratio -- not row count -- is what moves the FPGA between
"ingress free, egress bound" and "both directions loaded". Ratios measured at SF1:

    l_discount x100   ~7.9x    (11 distinct values, dictionary)
    l_quantity        ~5.3x    (50 distinct values, dictionary)
    l_shipdate        ~2.5x    (dates as days since epoch, dictionary)
    l_extendedprice   ~1.0x    (PLAIN -- dictionary is useless, no compression at all)

Usage:
    ./gen_tpch.py --sf 20 --outdir /local/$USER/bench
    ./gen_tpch.py --sf 1 10 100 --columns extprice --outdir /local/$USER/bench

Writes one parquet per (column, scale) plus a datasets.csv describing them.
"""

import argparse
import csv
import os
import subprocess
import sys

# Sum(x^2) is accumulated in a signed 64-bit register (z_score_squared.sv:30).
INT64_MAX = 2**63 - 1

# name -> (SQL expression producing an INT32, human description)
COLUMNS = {
    "discount": (
        "(l_discount * 100)::INTEGER",
        "l_discount scaled to integer percent (11 distinct values)",
    ),
    "quantity": (
        "l_quantity::INTEGER",
        "l_quantity, 1..50",
    ),
    "shipdate": (
        "(l_shipdate - DATE '1970-01-01')::INTEGER",
        "l_shipdate as days since epoch",
    ),
    "extprice": (
        "l_extendedprice::INTEGER",
        "l_extendedprice truncated to whole dollars (cents would overflow)",
    ),
}


def duckdb_sql(binary, sql, csv_out=False):
    """Run SQL through the DuckDB CLI. -init /dev/null keeps ~/.duckdbrc (which may
    autoload the FPGA extension and fail on a node without hugepages) out of the way."""
    cmd = [binary, "-init", "/dev/null"]
    if csv_out:
        cmd.append("-csv")
    cmd += ["-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"duckdb failed:\n{res.stdout}\n{res.stderr}")
    return res.stdout


def generate(binary, sf, columns, outdir):
    """dbgen once per scale factor, then write one single-column parquet per column."""
    copies = []
    for name in columns:
        expr, _ = COLUMNS[name]
        path = os.path.join(outdir, f"tpch_sf{sf}_{name}.parquet")
        copies.append(
            f"COPY (SELECT {expr} AS x FROM lineitem) TO '{path}' "
            f"(FORMAT parquet, COMPRESSION snappy);"
        )
    print(f"  dbgen(sf={sf}) + {len(copies)} column(s) ...", flush=True)
    duckdb_sql(binary, "LOAD tpch; CALL dbgen(sf=%s);\n%s" % (sf, "\n".join(copies)))
    return [os.path.join(outdir, f"tpch_sf{sf}_{n}.parquet") for n in columns]


def describe(binary, path):
    """Footer stats (cheap) plus the two data-dependent numbers the guard cares about."""
    meta = duckdb_sql(
        binary,
        f"""SELECT any_value(type), any_value(encodings), sum(num_values),
                   sum(total_compressed_size)
            FROM parquet_metadata('{path}');""",
        csv_out=True,
    ).strip().splitlines()
    typ, enc, nvals, csize = meta[1].split(",")
    nvals, csize = int(nvals), int(csize)

    # HUGEINT so the oracle itself cannot overflow while checking for overflow.
    vals = duckdb_sql(
        binary,
        f"""SELECT max(abs(x))::BIGINT, sum(x::HUGEINT * x::HUGEINT)::VARCHAR
            FROM read_parquet('{path}');""",
        csv_out=True,
    ).strip().splitlines()
    abs_max, sum_sq = vals[1].split(",")
    abs_max, sum_sq = int(abs_max), int(sum_sq)

    return {
        "file": path,
        "type": typ,
        "encoding": enc,
        "rows": nvals,
        "compressed_bytes": csize,
        "bytes_per_value": round(csize / nvals, 4),
        "ratio_vs_int32": round(nvals * 4.0 / csize, 2),
        "max_abs": abs_max,
        "sum_sq": sum_sq,
        # Worst case the hardware can hit, which is what the bind-time guard tests.
        "worst_sum_sq": nvals * abs_max * abs_max,
        "overflow": "FAIL" if nvals * abs_max * abs_max > INT64_MAX else "ok",
        # Always 0 here -- TPC-H needs no cleaning. Present so both generators emit the
        # same datasets schema and run_bench.sh can read either without special-casing.
        "dropped": 0,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sf", nargs="+", type=float, default=[20],
                    help="TPC-H scale factors (lineitem has ~6.0M rows per SF)")
    ap.add_argument("--columns", nargs="+", default=list(COLUMNS),
                    choices=list(COLUMNS), help="which columns to emit")
    ap.add_argument("--outdir", default=os.environ.get("BENCH_DIR", "/local/bench"),
                    help="output directory -- use LOCAL disk, not NFS")
    ap.add_argument("--duckdb", default=os.environ.get("DUCKDB_BIN", "duckdb"),
                    help="vanilla DuckDB CLI with the tpch extension available")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    files = []
    for sf in args.sf:
        sf = int(sf) if float(sf).is_integer() else sf
        print(f"scale factor {sf}:")
        files += generate(args.duckdb, sf, args.columns, args.outdir)

    print("\nmeasuring ...", flush=True)
    rows = [describe(args.duckdb, f) for f in files]

    datasets = os.path.join(args.outdir, "tpch.csv")
    with open(datasets, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    hdr = f"{'file':<44}{'enc':<18}{'rows':>12}{'B/val':>9}{'ratio':>8}{'max|x|':>12}{'ovf':>6}"
    print("\n" + hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{os.path.basename(r['file']):<44}{r['encoding']:<18}{r['rows']:>12,}"
              f"{r['bytes_per_value']:>9.3f}{r['ratio_vs_int32']:>8.2f}"
              f"{r['max_abs']:>12,}{r['overflow']:>6}")
    print(f"\ndataset list: {datasets}")

    if any(r["overflow"] == "FAIL" for r in rows):
        print("\nWARNING: columns marked FAIL exceed the 64-bit sum-of-squares accumulator.\n"
              "zscore() will refuse to bind them. Rescale (smaller units) or use fewer rows.")


if __name__ == "__main__":
    main()
