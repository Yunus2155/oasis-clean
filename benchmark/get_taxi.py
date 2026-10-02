#!/usr/bin/env python3
"""
Download NYC TLC yellow-taxi trip data and convert it into z-score benchmark inputs.

Why this dataset is worth running alongside TPC-H: TPC-H columns are synthetic and
uniformly distributed, so their compression ratio is a property of the generator. Taxi
data is real -- heavy-tailed, with dirty records -- so its compression ratio, and hence
how hard the decoder has to work per output byte, is not something we chose. If the
FPGA's wall-clock stays a pure function of row count here too, the "egress bound" claim
holds on data we did not design.

The raw TLC files are already parquet, so DuckDB reads them directly. Each column is
cast to INT32 (the datapath is 32-bit signed integer) and rewritten as SNAPPY parquet.

Two things to watch, both reported below:
  * Sum(x^2) must stay under 2^63 (see gen_tpch.py). Taxi has absurd outlier records --
    six-figure fares, five-figure trip distances -- so scaled columns can overflow on
    real data where TPC-H would not. That is a genuine finding, not a bug to hide.
  * NULLs. The parquet decoder path expects a fully defined column; rows with NULL in
    the target column are dropped here so the row count is exact.

Usage:
    ./get_taxi.py --months 2024-01 2024-02 --outdir /local/$USER/bench
    ./get_taxi.py --year 2024 --outdir /local/$USER/bench          # all 12 months
"""

import argparse
import csv
import os
import subprocess
import sys

BASE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"
INT64_MAX = 2**63 - 1

# name -> (SQL expression producing an INT32, description)
COLUMNS = {
    "distance": (
        "(trip_distance * 100)::INTEGER",
        "trip_distance in hundredths of a mile",
    ),
    "fare": (
        "fare_amount::INTEGER",
        "fare_amount in whole dollars (cents would overflow)",
    ),
    "tip": (
        "tip_amount::INTEGER",
        "tip_amount in whole dollars",
    ),
    "passengers": (
        "passenger_count::INTEGER",
        "passenger_count, a low-cardinality column",
    ),
}

# Source column each derived column depends on, so we can drop NULLs precisely.
SOURCE = {
    "distance": "trip_distance",
    "fare": "fare_amount",
    "tip": "tip_amount",
    "passengers": "passenger_count",
}


def duckdb_sql(binary, sql, csv_out=False):
    cmd = [binary, "-init", "/dev/null"]
    if csv_out:
        cmd.append("-csv")
    cmd += ["-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"duckdb failed:\n{res.stdout}\n{res.stderr}")
    return res.stdout


def download(months, rawdir):
    paths = []
    os.makedirs(rawdir, exist_ok=True)
    for m in months:
        name = f"yellow_tripdata_{m}.parquet"
        dest = os.path.join(rawdir, name)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            print(f"  {name} (cached)")
        else:
            print(f"  {name} ...", flush=True)
            # -f so an HTTP error is a non-zero exit rather than a saved error page.
            rc = subprocess.run(["curl", "-fsSL", "-o", dest, f"{BASE_URL}/{name}"]).returncode
            if rc != 0:
                if os.path.exists(dest):
                    os.remove(dest)
                sys.exit(f"download failed for {name} (month may not be published yet)")
        paths.append(dest)
    return paths


def convert(binary, raw_paths, columns, outdir, drop_above):
    """One output parquet per column, concatenating every downloaded month.

    drop_above optionally discards records whose derived value exceeds a threshold. TLC
    data contains obvious junk (a 312,722-mile taxi ride), and a handful of such records
    is enough to overflow the hardware accumulator. Dropping them is legitimate data
    cleaning, but it has to be STATED, so the count removed is printed and recorded in
    the datasets rather than folded silently into the results."""
    glob = ", ".join(f"'{p}'" for p in raw_paths)
    outs = {}
    for name in columns:
        expr, _ = COLUMNS[name]
        src = SOURCE[name]
        path = os.path.join(outdir, f"taxi_{name}.parquet")
        limit = drop_above.get(name)

        where = f"{src} IS NOT NULL"
        if limit is not None:
            where += f" AND abs({expr}) <= {limit}"

        dropped = 0
        if limit is not None:
            res = duckdb_sql(
                binary,
                f"""SELECT count(*) FROM read_parquet([{glob}], union_by_name=true)
                    WHERE {src} IS NOT NULL AND abs({expr}) > {limit};""",
                csv_out=True,
            ).strip().splitlines()
            dropped = int(res[1])

        note = f"  (dropped {dropped:,} above {limit:,})" if limit is not None else ""
        print(f"  {os.path.basename(path)} ...{note}", flush=True)
        duckdb_sql(
            binary,
            f"""COPY (SELECT {expr} AS x
                      FROM read_parquet([{glob}], union_by_name=true)
                      WHERE {where})
                TO '{path}' (FORMAT parquet, COMPRESSION snappy);""",
        )
        outs[path] = dropped
    return outs


def describe(binary, path, dropped=0):
    meta = duckdb_sql(
        binary,
        f"""SELECT any_value(type), any_value(encodings), sum(num_values),
                   sum(total_compressed_size)
            FROM parquet_metadata('{path}');""",
        csv_out=True,
    ).strip().splitlines()
    typ, enc, nvals, csize = meta[1].split(",")
    nvals, csize = int(nvals), int(csize)

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
        "worst_sum_sq": nvals * abs_max * abs_max,
        "overflow": "FAIL" if nvals * abs_max * abs_max > INT64_MAX else "ok",
        "dropped": dropped,
    }


def parse_drop_above(pairs):
    out = {}
    for p in pairs or []:
        if "=" not in p:
            sys.exit(f"--drop-above expects COLUMN=VALUE, got '{p}'")
        col, val = p.split("=", 1)
        if col not in COLUMNS:
            sys.exit(f"--drop-above: unknown column '{col}'")
        out[col] = int(val)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--months", nargs="+", help="months as YYYY-MM")
    g.add_argument("--year", type=int, help="shorthand for all 12 months of a year")
    ap.add_argument("--columns", nargs="+", default=list(COLUMNS), choices=list(COLUMNS))
    ap.add_argument("--drop-above", nargs="+", metavar="COLUMN=VALUE",
                    help="discard records whose derived value exceeds VALUE, e.g. "
                         "distance=100000 (1000 miles). The count removed is reported.")
    ap.add_argument("--outdir", default=os.environ.get("BENCH_DIR", "/local/bench"),
                    help="output directory -- use LOCAL disk, not NFS")
    ap.add_argument("--duckdb", default=os.environ.get("DUCKDB_BIN", "duckdb"))
    args = ap.parse_args()

    months = args.months or [f"{args.year}-{m:02d}" for m in range(1, 13)]
    os.makedirs(args.outdir, exist_ok=True)
    rawdir = os.path.join(args.outdir, "taxi_raw")

    print(f"downloading {len(months)} month(s) (~50 MB, ~3M rows each):")
    raw = download(months, rawdir)

    print("\nconverting:")
    outs = convert(args.duckdb, raw, args.columns, args.outdir,
                   parse_drop_above(args.drop_above))

    print("\nmeasuring ...", flush=True)
    rows = [describe(args.duckdb, f, dropped) for f, dropped in outs.items()]

    datasets = os.path.join(args.outdir, "taxi.csv")
    with open(datasets, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    hdr = (f"{'file':<32}{'enc':<18}{'rows':>12}{'B/val':>9}{'ratio':>8}"
           f"{'max|x|':>14}{'dropped':>9}{'ovf':>6}")
    print("\n" + hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{os.path.basename(r['file']):<32}{r['encoding']:<18}{r['rows']:>12,}"
              f"{r['bytes_per_value']:>9.3f}{r['ratio_vs_int32']:>8.2f}"
              f"{r['max_abs']:>14,}{r['dropped']:>9,}{r['overflow']:>6}")
    print(f"\ndataset list: {datasets}")

    if any(r["overflow"] == "FAIL" for r in rows):
        print("\nWARNING: columns marked FAIL exceed the 64-bit sum-of-squares accumulator.\n"
              "zscore() will refuse to bind them. This is usually caused by a handful of\n"
              "junk records -- check max|x| above before deciding whether to filter or rescale.")


if __name__ == "__main__":
    main()
