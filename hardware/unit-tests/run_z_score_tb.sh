#!/bin/bash
# Compile and run the two standalone z-score testbenches with plain xsim (no Coyote harness, no
# `make sim`). Both benches cover what the python suite cannot: the moment one stream's tlast is
# followed immediately by the next stream's first beat.
#
#   ./run_z_score_tb.sh boundary [rtl.sv]   # operator alone: modes, lengths, tkeep, bubbles, stress
#   ./run_z_score_tb.sh system   [rtl.sv]   # 3 lanes + the real OutputWriter + a Coyote DMA model
#   ./run_z_score_tb.sh all      [rtl.sv]   # both, full matrix (~15 min)
#
# Pass a path to an OLD z_score_squared.sv as the second argument to run it as a CONTROL: the
# unfixed RTL must FAIL, which is what proves the benches are sensitive.
#
# Requires: source /tools/Xilinx/Vivado/2022.1/settings64.sh
# Runs in a scratch dir so it never touches unit-tests/xsim.dir used by the python harness.

set -uo pipefail

WHAT="${1:-all}"
OASIS="$(cd "$(dirname "$0")/../.." && pwd)"
RTL="${2:-$OASIS/hardware/src/hdl/z-score/z_score_squared.sv}"
LIBSTF="$OASIS/parcore/libstf/hardware/src/hdl"
WORK="${WORK_DIR:-/tmp/z_score_tb_$USER}"

command -v xvlog >/dev/null || { echo "source /tools/Xilinx/Vivado/2022.1/settings64.sh first" >&2; exit 1; }
mkdir -p "$WORK"; cd "$WORK" || exit 1
echo "work dir : $WORK"
echo "RTL      : $RTL"

# N_STRM_AXI must equal the system bench's lane count. The simulation project is built with
# N_DECODERS=2, so patch a local copy of the generated package up to 3.
sed 's/localparam integer N_STRM_AXI = 2;/localparam integer N_STRM_AXI = 3;/' \
    "$OASIS/hardware/build-sim/sim/lynx_pkg.sv" > lynx_pkg3.sv

INC=(-i "$LIBSTF" -i "$LIBSTF/config" -i "$OASIS/parcore/libstf/coyote/hw/hdl/pkg"
     -i "$OASIS/parcore/hardware/src/hdl")

compile_boundary() {
    rm -rf xsim.dir
    xvhdl "$LIBSTF/util/shift_register.vhd" > xvhdl.out 2>&1 || { tail -20 xvhdl.out; return 1; }
    xvlog -sv "${INC[@]}" \
        lynx_pkg3.sv \
        "$OASIS/parcore/libstf/coyote/hw/hdl/pkg/axi_intf.sv" \
        "$LIBSTF/common.sv" "$OASIS/parcore/hardware/src/hdl/common.sv" \
        "$LIBSTF/util/util_interfaces.sv" "$LIBSTF/util/stream_profiler.sv" \
        "$LIBSTF/util/reset_resync.sv" \
        "$RTL" "$OASIS/hardware/unit-tests/z_score_boundary_tb.sv" > xvlog.out 2>&1 \
        || { grep ERROR xvlog.out | head; return 1; }
    xelab -debug typical z_score_boundary_tb -s ztb > xelab.out 2>&1 \
        || { grep ERROR xelab.out | head; return 1; }
}

compile_system() {
    rm -rf xsim.dir
    xvhdl "$LIBSTF/util/shift_register.vhd" "$LIBSTF/fifo/fifo.vhd" > xvhdl.out 2>&1 \
        || { tail -20 xvhdl.out; return 1; }
    # multi_insert_fifo.vhd is deliberately excluded: it instantiates a MehdiFIFO generic that does
    # not exist in fifo.vhd (pre-existing libstf inconsistency) and nothing here needs it.
    xvlog -sv "${INC[@]}" \
        lynx_pkg3.sv \
        "$OASIS/parcore/libstf/coyote/hw/hdl/pkg/axi_intf.sv" \
        "$OASIS/parcore/libstf/coyote/hw/hdl/pkg/lynx_intf.sv" \
        "$LIBSTF/common.sv" "$OASIS/parcore/hardware/src/hdl/common.sv" \
        $(find "$LIBSTF" -name "*.sv" | grep -v "/common.sv" | sort) \
        "$RTL" "$OASIS/hardware/unit-tests/z_score_system_tb.sv" > xvlog.out 2>&1 \
        || { grep ERROR xvlog.out | head; return 1; }
    xelab -debug typical z_score_system_tb -s ztb_sys > xelab.out 2>&1 \
        || { grep ERROR xelab.out | head; return 1; }
}

pass=0; fail=0
run() { # snapshot, label, plusargs...
    local snap=$1 label=$2; shift 2
    local out; out=$(xsim "$snap" -runall "$@" 2>&1)
    local res; res=$(echo "$out" | grep -o "RESULT: .*")
    printf "  %-34s %s\n" "$label" "${res:-NO RESULT}"
    if echo "$res" | grep -q PASS; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "$out" | grep -E "\[FAIL\]|Fatal" | head -6 | sed 's/^/      /'
    fi
}

if [[ "$WHAT" == "boundary" || "$WHAT" == "all" ]]; then
    echo "--- boundary bench (operator alone) ---"
    compile_boundary || exit 1
    for m in 0 1 2; do for s in 0 1 2 3; do
        run ztb "MODE=$m SCEN=$s" -testplusarg MODE=$m -testplusarg SCEN=$s -testplusarg SEED=1
    done; done
    for m in 0 1 2; do for sd in 1 2 3 4 5; do
        run ztb "MODE=$m SCEN=4 SEED=$sd" -testplusarg MODE=$m -testplusarg SCEN=4 -testplusarg SEED=$sd
    done; done
    for sc in 5 6; do for sd in 1 2; do
        run ztb "MODE=2 SCEN=$sc SEED=$sd" -testplusarg MODE=2 -testplusarg SCEN=$sc -testplusarg SEED=$sd
    done; done
fi

if [[ "$WHAT" == "system" || "$WHAT" == "all" ]]; then
    echo "--- system bench (3 lanes + OutputWriter + DMA model) ---"
    compile_system || exit 1
    for sd in 1 2; do for bp in 0 1; do
        run ztb_sys "SEED=$sd BP=$bp" -testplusarg SEED=$sd -testplusarg BP=$bp
    done; done
fi

echo "---- pass=$pass fail=$fail ----"
[[ $fail -eq 0 ]]
