# z-score benchmark harness

Generates TPC-H and NYC-taxi inputs for the FPGA z-score operator, runs them against CPU
baselines on the same machine, and records the profiler counters for each run.

```
gen_tpch.py   TPC-H lineitem  -> one INT32 parquet per (column, scale) + tpch.csv
get_taxi.py   NYC TLC yellow  -> one INT32 parquet per column          + taxi.csv
run_bench.sh  dataset list        -> results.csv + profiles/*.csv
```

## Quick start

```bash
export BENCH_DIR=/local/$USER/bench          # LOCAL disk -- /home is NFS
export DUCKDB_BIN=/path/to/vanilla/duckdb    # needs the tpch extension
export OASIS_DUCKDB=$HOME/duckdb-global      # the FPGA-enabled binary

./gen_tpch.py --sf 17                                        # ~102M rows per column
./get_taxi.py --year 2024 --drop-above distance=100000       # ~40M rows
./run_bench.sh $BENCH_DIR/tpch.csv results_tpch.csv
./run_bench.sh $BENCH_DIR/taxi.csv results_taxi.csv
```

`gen_tpch.py` and `get_taxi.py` are CPU-only and run anywhere. `run_bench.sh` needs the
FPGA node.

## Two hardware constraints these scripts exist to respect

**32-bit signed integer datapath.** `hardware/src/hdl/z-score/z_score_squared.sv` is
`ELEM_BITS = 32` with integer multipliers, and `ZScoreBind` rejects other physical types.
TPC-H `DECIMAL(15,2)` is physically INT64 and taxi amounts are DOUBLE, so every column is
cast to INTEGER during generation. Money is stored in whole units, not cents — see below.

**Sum(x²) is accumulated in a signed 64-bit register** (`z_score_squared.sv:30`) which
wraps silently. A column is only usable when `rows * max(|x|)^2 < 2^63`. Both generators
compute this from the data and mark the column `ok` or `FAIL`; `run_bench.sh` skips
`FAIL` rows, and `ZScoreBind` refuses to bind them with an explanatory error rather than
returning quietly wrong z-scores.

This constraint is not theoretical. `l_extendedprice` in **cents** reaches Σx² = 1.2e20 at
SF1 alone, 13× over the limit. In whole **dollars** it is 1.2e16 at SF1 and stays safe
through SF100. Taxi `trip_distance` fails outright until 23 junk records claiming
> 1000-mile trips (max: 312,722 miles) are dropped with `--drop-above distance=100000`.

## Why these columns

The two datasets vary along two independent axes, which is the point of running both.

**Compression ratio** — how much decode work per output byte. Measured at SF1 / 2024-01:

| column | encoding | bytes/value | ratio vs raw INT32 |
|---|---|---|---|
| `x` (existing synthetic 100M) | PLAIN_DICTIONARY | 0.052 | **77×** |
| taxi `passengers` | PLAIN_DICTIONARY | 0.282 | 14.2× |
| tpch `discount` | PLAIN_DICTIONARY | 0.505 | 7.9× |
| tpch `quantity` | PLAIN_DICTIONARY | 0.756 | 5.3× |
| taxi `tip` | PLAIN_DICTIONARY | 0.838 | 4.8× |
| taxi `fare` | PLAIN_DICTIONARY | 1.133 | 3.5× |
| tpch `shipdate` | PLAIN_DICTIONARY | 1.587 | 2.5× |
| taxi `distance` | PLAIN_DICTIONARY | 1.588 | 2.5× |
| tpch `extprice` | PLAIN | 4.000 | **1.0× (none)** |

The existing synthetic benchmark is a 77× outlier. At 100M rows it is a 5.4 MB file
producing 400 MB of output, so ingress is essentially free and the system is purely
egress-bound. `extprice` pushes 400 MB in *and* 400 MB out — roughly 28.6 ms per
direction at the measured ~14 GB/s — against a ~38 ms wall, so it should stop being
egress-bound. That shift is the experiment.

**Outlier rate** — how much the host emit path actually has to do, since
`outliers_only := true` emits one BIGINT per outlier:

| dataset | outliers at \|z\| > 3 |
|---|---|
| TPC-H (all columns) | **0** — dbgen is uniform, nothing lies beyond 3σ |
| taxi `fare` | 1.19% |
| taxi `tip` | 2.48% |
| taxi `passengers` | 3.82% |
| taxi `distance` | 3.90% |

TPC-H therefore never exercises sparse emission at all, while taxi emits millions of row
ids. Reporting TPC-H alone would flatter the host-side optimisation; reporting both
separates decode cost from emit cost.

## Method notes

- **Same binary, same machine** for CPU and FPGA. The CPU baseline is the same two-pass
  population z-score with |z| > 3, not a cheaper query.
- **Outlier counts are compared** between CPU and FPGA on every file. A mismatch is
  printed loudly; timings from a mismatched run mean nothing.
- **Fastest of `REPS` runs** is reported, after a warm-up repetition, so results are
  warm-cache on both sides.
- **A failed FPGA run records `ERROR`**, never a time. `.timer` prints a Run Time line
  even for a statement that errored, and it is always the fastest line in the output — so
  a result row is required before any timing is accepted.
- **Keep data on local disk.** `/home` is NFS here; re-reading a multi-GB parquet over
  NFS measures the network.
- Per-run counters land in `profiles/<name>_stream.csv` and `profiles/<name>_egress.csv`
  from `oasis_stream_profile()` and `oasis_egress_bandwidth()`. Note that `stalled_pct`
  above 100% is a per-lane-sum artifact, not a real value.
