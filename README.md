# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy 
integration into query engines.

The hardware component requires the ParCore submodule and its dependencies to be loaded by either 
cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodule as a step after cloning:

```bash
git submodule update --init extension/duckdb
git submodule update --init extension/extension-ci-tools
git submodule update --init --recursive parcore
git submodule update --init celeris
```

## Global z-score operator

This repository adds an FPGA z-score operator to Oasis. For one INT32 Parquet column, the FPGA
decodes the column with ParCore, computes the mean and standard deviation over the **whole column**,
and flags every row with |z| > 3. It runs in two phases, because the hardware sees one Parquet row
group per stream:

1. **STATS:** every row group is decoded once and the FPGA returns partial sums (count, Σx, Σx²).
   The host adds them up into whole-column statistics.
2. **CLASSIFY:** the host writes the totals into `ZScoreStatsConfig`, and every row group is decoded
   again and classified against them.

**To reproduce the z-score results, follow this section from top to bottom.** It is self-contained:
it covers cloning, building, programming the FPGA with the provided bitstream, generating the
datasets, and running the benchmark. Nothing has to be configured beyond what is written here.

### SQL functions

| function | what it runs |
|---|---|
| **`zscore(path, column)`** | **the FPGA operator**: Parquet decode, whole-column statistics and flags on the FPGA. Returns one `BOOLEAN` column `is_outlier`, one row per input row. With `outliers_only := true` it returns one `BIGINT` column `row_id`, one row per outlier. |
| **CPU baseline** (plain SQL) | the same algorithm in DuckDB: a two-pass population z-score over the whole column, \|z\| > 3 |

```sql
SELECT count(*) FILTER (WHERE is_outlier) FROM zscore('data.parquet', 'v');
WITH s AS (SELECT avg(v::DOUBLE) m, stddev_pop(v::DOUBLE) sd FROM read_parquet('data.parquet'))
SELECT count(*) FROM read_parquet('data.parquet'), s WHERE abs((v::DOUBLE - m) / sd) > 3;
```

Limits of the hardware datapath. The host checks both and stops with a clear error instead of
returning a wrong answer:
- only **INT32** columns;
- Σx² is accumulated in a signed 64-bit register, so a column is only usable when
  `rows * max(|x|)^2 < 2^63`.

Profiling functions: `oasis_stream_profile()`, `oasis_zscore_profile()`, `oasis_egress_bandwidth()`.

| part | files |
|---|---|
| z-score RTL | `hardware/src/hdl/z-score/z_score_squared.sv` |
| CSR blocks (statistics, profiling) | `hardware/src/hdl/config/zscore_stats_config.sv`, `hardware/src/hdl/zscore_profile_config.sv` |
| production vFPGA top | `hardware/src/vfpga_top.svh` |
| host driver | `software/oasis/configuration.*`, `software/oasis/oasis_context.*` |
| DuckDB table function | `extension/src/zscore_scan.cpp` |
| real-dataset benchmark | `scripts/run_real.sh` |
| RTL unit tests | `hardware/unit-tests/z_score_*` |

### 1. Requirements

- A **Xilinx Alveo U55C** on an ETH HACC node (the programming script uses `sudo` and Vivado on
  `PATH`). Build the software on the build server; program the card and run on the alveo node
  (home directory shared).
- CMake **3.16 or newer**.
- The bitstream **`cyt_top.bit` (build-41)**, attached to the **build-41** release of this
  repository (md5 `a65124a5af1cb789207e704236796576`). It was built from this repository's RTL with
  `--no-rdma --decoders 3`, without HBM (`EN_MEM=0`): 3 decoders + z-score (global two-phase) +
  egress profiler + aggregate PCIe counter.

### 2. Clone

Clone **without** `--recurse-submodules` and initialise only the submodules below (the `celeris`
submodule is not used by the build):
```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
git clone https://github.com/Yunus2155/oasis-clean.git && cd oasis-clean
git submodule update --init extension/duckdb extension/extension-ci-tools
git submodule update --init --recursive parcore
```

### 3. Build the software (build server)

The DuckDB extension links the libraries installed under `~/opt`, so install them first. ParCore
builds without Arrow by default, so Arrow is not needed.
```bash
bash parcore/libstf/scripts/install_jemalloc.sh          # installs jemalloc into ~/opt
export CMAKE_PREFIX_PATH=$HOME/opt
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
cmake --build software/build -j && cmake --install software/build   # Coyote, libstf, ParCore, Oasis
(cd extension && make -j)                                # -> extension/build/release/duckdb
```
After any later change in `software/` or `parcore/`, re-run the `cmake --install` step before
rebuilding the extension. The extension uses the installed copy, not the source tree.

### 4. Program the FPGA (alveo node)

The driver must be built on the node, because it is built for the running kernel.
```bash
md5sum /path/to/cyt_top.bit                              # must print a65124a5af1cb789207e704236796576
(cd parcore/libstf/coyote/driver && make)
bash parcore/libstf/coyote/util/program_hacc_local.sh /path/to/cyt_top.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # programming clears them
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages               # must print 8
lsmod | grep coyote_driver && ls /dev/coyote*
```
The card must hold build-41. If it was programmed with another design since (for example the IQR
bitstream), program build-41 again before running the z-score.

### 5. Generate the datasets (once, ~650 MB including the taxi downloads)

These are the same 7 datasets as the IQR evaluation: the same sources, the same rows. Two
differences are forced by the z-score hardware: every column is stored as **INT32** (the operator
only reads INT32), and the TPC-H price columns (`extprice`, `sf10`) are in **whole dollars**, not
cents (in cents, Σx² overflows the 64-bit accumulator). So the files go into their own directory.

Use the stock `duckdb` Python module (`pip install --user duckdb`), not the extension-linked binary,
which aborts at startup on a machine without 1 GiB huge pages. Do not set `ROW_GROUP_SIZE`: the
default row-group layout is part of the real data.
```bash
mkdir -p ~/datasets-zscore && cd ~/datasets-zscore
for m in 01 02 03 04 05 06; do
  curl -fL -o ytd_2024_${m}.parquet \
    "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2024-${m}.parquet"
done
python3 - <<'EOF'
import duckdb
c = duckdb.connect()
files = lambda ms: "[" + ",".join(f"'ytd_2024_{m}.parquet'" for m in ms) + "]"
for name, ms in [("taxi_d1", ["01"]), ("taxi_d2", ["01", "02"]),
                 ("taxi_d3", ["01", "02", "03", "04"]),
                 ("taxi_d4", ["01", "02", "03", "04", "05", "06"])]:
    c.sql(f"COPY (SELECT round(fare_amount*100)::INTEGER AS fare_cents FROM read_parquet({files(ms)})) "
          f"TO '{name}.parquet' (FORMAT PARQUET)")
c.sql("INSTALL tpch; LOAD tpch; CALL dbgen(sf=1)")
c.sql("COPY (SELECT l_quantity::INTEGER AS v FROM lineitem) TO 'tpch_qty.parquet' (FORMAT PARQUET)")
c.sql("COPY (SELECT l_extendedprice::INTEGER AS v FROM lineitem) TO 'tpch_extprice.parquet' (FORMAT PARQUET)")
c = duckdb.connect()
c.sql("INSTALL tpch; LOAD tpch; CALL dbgen(sf=10)")
c.sql("COPY (SELECT l_extendedprice::INTEGER AS v FROM lineitem) TO 'tpch_extprice_sf10.parquet' (FORMAT PARQUET)")
EOF
```
Check that each file holds the expected data with
`SELECT count(*), sum(<column>)::HUGEINT FROM read_parquet('<file>')`, where the column is
`fare_cents` for the taxi files and `v` for the TPC-H files. The last column is the number of
outliers the CPU baseline finds; the FPGA must find exactly the same number.

| file | rows | sum | outliers (\|z\| > 3) |
|---|--:|--:|--:|
| `taxi_d1.parquet` | 2,964,624 | 5388222476 | 35970 |
| `taxi_d2.parquet` | 5,972,150 | 10815993187 | 70362 |
| `taxi_d3.parquet` | 13,069,067 | 24176275770 | 162865 |
| `taxi_d4.parquet` | 20,332,093 | 38401520485 | 3985 |
| `tpch_qty.parquet` | 6,001,215 | 153078795 | 0 |
| `tpch_extprice.parquet` | 6,001,215 | 229577404921 | 0 |
| `tpch_extprice_sf10.parquet` | 59,986,052 | 2293814088985 | 0 |

If the NYC TLC files have been re-issued, the taxi rows will differ. TPC-H data is uniform, so it has
no value beyond 3 standard deviations; the TPC-H rows measure speed, the taxi rows also measure
outlier output.

### 6. Run the benchmark (alveo node)

```bash
scripts/run_real.sh ~/datasets-zscore
```
For each dataset this runs both queries once to warm up and then 15 times in one DuckDB session
(`PRAGMA threads=32`), and reports the median end-to-end query time. The queries aggregate the flags
(`count(*) FILTER (WHERE is_outlier)`), so storing the result is not measured. The FPGA path uses 12
host threads, the setting of the published measurements; the script sets it. The run takes a few
minutes. Only one DuckDB process may use the card at a time. Do not interrupt an FPGA query with
Ctrl-C.

The output is one table:
```
dataset             rows   CPU (ms)  FPGA (ms)   speedup
taxi_d1             3.0M        ...        ...      ...x
...
sf10               60.0M        ...        ...      ...x
```
A `WARNING:` line after the table means a dataset file is missing, a query failed, or the FPGA and
CPU outlier counts differ. The z-score is exact, so the two counts must be equal.

**Reference values** (build-41, alveo-u55c-09, medians of 15). Expect the same shape, with a
deviation of about 10–20%:

| dataset | rows | CPU (ms) | FPGA (ms) | speedup |
|---|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 17 | 8 | 2.12× |
| tpch_qty | 6.0M | | | not measured yet |
| taxi_d2 | 6.0M | 20 | 10 | 2.00× |
| extprice | 6.0M | | | not measured yet |
| taxi_d3 | 13.1M | 32 | 14 | 2.29× |
| taxi_d4 | 20.3M | 44 | 18 | 2.44× |
| sf10 | 60.0M | | | not measured yet |

### Troubleshooting

| symptom | cause |
|---|---|
| an error about 1GiB huge pages at startup | re-run the `nr_hugepages` line in step 4 (programming clears them) |
| the extension fails to configure (Coyote/libstf/parcore/oasis not found) | `export CMAKE_PREFIX_PATH=$HOME/opt` and re-run step 3 |
| `zscore() currently supports INT32 columns only` | the file was not made with the recipe in step 5 (for example the IQR's BIGINT files) |
| `zscore(): the whole-column sum of squares does not fit in 64 bits` | a column in cents instead of whole dollars; use the recipe in step 5 |
| `Hardware design on device is not an Oasis system` | the card holds a non-Oasis bitstream; program build-41 (step 4) |

## Hardware
The functionality of the hardware component can be verified with unit tests that are built on top of 
the Coyote unit test framework. We also describe how to synthesize the hardware.

### Unit tests
To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./scripts/setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

### Synthesis
**Before synthesizing, apply the Coyote placer patch** (one time, after the submodules are checked
out). It pins Vivado's placer to `AltSpreadLogic_high` instead of `Auto_1`; timing closure of this
design depends on it, and without it a rebuild silently uses a different placement strategy:

```bash
cd parcore/libstf/coyote
git apply ../../../patches/coyote-place-directive.patch
cd -
```

The exact submodule commits build-41 was built from are listed in `patches/SUBMODULE-PINS.txt`;
compare them with `git submodule status --recursive`.

To rebuild the build-41 configuration:

```bash
./scripts/synthesize.sh --no-rdma --decoders 3
```

A rebuild is a new bitstream: if timing does not close the same way, check its outlier counts
against the CPU baseline (`scripts/run_real.sh`) before trusting its numbers.

General usage:

```bash
./scripts/synthesize.sh [--no-rdma] [--decoders <number-of-decoders>]
```

The script spins off the synthesis in the background in a way that the user can disconnect from 
the server without the synthesis stopping. You can check the progress in `hardware/build-**/bitgen.log`. 
It is expected that the synthesis takes multiple hours to finish sometimes not printing anything new 
to the log for a while.

## Software
The software consists of the Oasis software library and a DuckDB extension.

### Oasis library
The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries to 
be installed or includes them from the submodules. In case they are not installed already, libSTF 
also has a dependency on jemalloc that can be installed with `./parcore/libstf/scripts/install_jemalloc.sh` 
and ParCore currently has a dependency on Arrow 21.0.0 which can be installed with `./parcore/scripts/install_arrow.sh`. 
The Oasis software library can be built as follows:

```bash
mkdir software/build
cmake -S software -B software/build
cmake --build software/build -j
```

If you want to install it to e.g., `~/opt`, you need to add `-DCMAKE_INSTALL_PREFIX=$HOME/opt` to 
the first `cmake` command and execute `cmake --install software/build` after the build.

### DuckDB extension
The DuckDB Oasis extension can be built as follows and requires the Oasis software library to be 
installed first:

```bash
cd extension
make -j
```

More detail can be found in the `extension/README.md`.

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.