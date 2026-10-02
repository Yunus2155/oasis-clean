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

This branch adds an FPGA z-score operator: for one INT32 Parquet column, the hardware decodes the
column with ParCore, computes the population mean and standard deviation over the **whole column**,
and flags every row with |z| > 3.

It works in two phases, because the hardware sees one Parquet row group per stream:

1. **STATS** -- every row group is decoded once and the hardware returns partial sums
   (count, Σx, Σx²). The host adds them up into whole-column statistics.
2. **CLASSIFY** -- the host writes the totals into `ZScoreStatsConfig`, and every row group is
   decoded again and classified against them.

Use it from DuckDB:

```sql
LOAD oasis;
-- one BOOLEAN column is_outlier, one row per input value
SELECT * FROM zscore('/path/to/file.parquet', 'column_name');
-- one BIGINT column row_id, one row per outlier (this is what the benchmarks measure)
SELECT count(*) FROM zscore('/path/to/file.parquet', 'column_name', outliers_only := true);
```

Limits of the hardware datapath, checked by the host with a clear error instead of a wrong answer:

- Only **INT32** columns. Cast decimals/doubles to integers when generating data.
- Σx² is accumulated in a signed 64-bit register: a column is only usable when
  `rows * max(|x|)^2 < 2^63`.

Profiling functions, used by the benchmark scripts: `oasis_stream_profile()`,
`oasis_zscore_profile()` and `oasis_egress_bandwidth()`.

### The validated bitstream: build-41

All results in `benchmark/` were measured on **build-41**, on an Alveo U55C:

| | |
|---|---|
| contents | 3 × ColumnChunkDecoder + z-score (global two-phase) + egress profiler + aggregate PCIe counter |
| build flags | `./scripts/synthesize.sh --no-rdma --decoders 3` (with `EN_MEM=0`, the default in `hardware/CMakeLists.txt`) |
| file | `cyt_top.bit`, attached to the **build-41** release of this repository (not committed to git) |
| md5 | `a65124a5af1cb789207e704236796576` |

Check the md5 after downloading (`md5sum cyt_top.bit`). The Coyote kernel driver is built locally
on the FPGA host from `parcore/libstf/coyote/driver`, as usual for Coyote.

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

A rebuild is a new bitstream: if timing does not close the same way, it must be validated again
before its numbers are compared with `benchmark/`.

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

## Benchmarks
`benchmark/` holds the z-score evaluation: the scripts that generate the datasets and run them, the
results (`results_*.csv`, `*_sweep.csv`, `profiles/`), and the raw logs the results came from.

- `benchmark/README.md` -- TPC-H and NYC-taxi end-to-end runs (`gen_tpch.py`, `get_taxi.py`,
  `run_bench.sh`), CPU baseline vs FPGA in the same DuckDB binary, with outlier counts compared.
- `benchmark/MICROBENCH.md` -- the size, core, codec and skew sweeps, with their measured results.

The datasets themselves are not in git (several GB); the generator scripts recreate them.

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.