#!/bin/bash

# N_DECODERS=2 is a SIMULATION-ONLY requirement, not a design constraint: the libstf test framework
# asserts N_STRM_AXI % 2 == 0 (libstf_utils/common.py), and in local mode N_STRM_AXI == N_DECODERS,
# so the default of 1 makes every oasis test fail at import with "The number of streams needs to be
# divisible by two". Synthesis has no such rule -- synthesize.sh --no-rdma with 1 decoder is fine.
# The test benches tie off the lanes they do not use. Extra args are passed through to cmake, so
# e.g. `./scripts/setup_simulation.sh -DN_DECODERS=4` overrides the default.
pushd hardware
rm -rf build-sim
mkdir build-sim
pushd build-sim
echo Creating Vivado simulation project in hardware/build-sim...
/usr/bin/cmake -DENABLE_RDMA=OFF -DFDEV_NAME=u55c -DN_DECODERS=2 "$@" ..
make sim
