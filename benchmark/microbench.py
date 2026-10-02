#!/usr/bin/env python3
"""
The three microbenchmark panels of the joint workshop paper, on the z-score operator.

    microbench.py size    --csv size_sweep.csv
    microbench.py codec   --csv codec_sweep.csv
    microbench.py thread  --csv thread_sweep_balanced.csv
    microbench.py thread  --knee --csv thread_sweep_knee.csv

One runner for all three, so "operator time" means the same thing everywhere.

THE PROTOCOL, fixed across every test (deviating makes the numbers incomparable to the IQR half):
  * 7 iterations of the query in ONE DuckDB session; report the arithmetic MEAN OF THE LAST 3.
    No median, no spread. DuckDB's allocator pooling is absent early in a session, which makes the
    first iterations bimodal; four discarded iterations put every measurement in steady state.
  * A FRESH DuckDB PROCESS per point. `PRAGMA threads` is never mutated mid-session.
  * The page cache is warmed by reading the file before timing. An unwarmed read is charged to
    operator time -- and in the thread sweep it would be charged UNEVENLY across thread counts,
    manufacturing a scaling curve out of nothing.
  * Correctness is checked on ALL 7 iterations of every point, not once. Outliers sit in an empty
    value gap far outside the threshold, so the expected count is exact and quantisation-proof;
    any deviation is a real bug. This doubles as a soak test -- the historical hardware failure
    signature was counts WANDERING between runs while simulation stayed bit-exact.

WHAT DIFFERS FROM THE IQR HALF, and why:
  * No fusion. That is an IQR mechanism; the z-score path has no equivalent, so Test 1 is a single
    FPGA curve. The `pass1` and `fused` CSV columns are kept (constant) so both halves share
    plotting code without reconciliation.
  * `fpga_decode_ms` is phase 1 -- the whole-column statistics barrier (read + decode + STATS, with
    only 64 bytes of egress per row group) -- and `fpga_passes_ms` is phase 2 (read + decode +
    classify + flag egress). Both phases decode; the split is at the barrier, not at the decoder.
    Named to match the IQR CSV schema, but say this in the paper rather than implying a decode
    timer we do not have.
  * The CPU arm is DuckDB SQL, not a table function, so it cannot print a `heavy` line: its
    operator time is the query's own wall time. That is fair here in a way it would not be for a
    `CREATE TABLE` -- both arms are a scan plus a count aggregate, and the aggregate is identical
    on both sides.
"""
import argparse
import csv
import math
import os
import re
import signal
import subprocess
import sys

# ----------------- OPERATOR ADAPTATION -- the roadmap's section 1.1 table, filled in -------------
DUCKDB     = os.path.expanduser(os.environ.get("OASIS_DUCKDB", "~/duckdb-bench41"))
FPGA_FN    = "zscore"                     # (path, col) -> (row_id, is_outlier)
TIMING_ENV = "OASIS_ZSCORE_TIMING"
TAG        = "zscore"                     # the [tag] prefix on the timing line
COL        = os.environ.get("OASIS_BENCH_COL", "x")
K          = 3                            # |z| > K.  k=1 would break the empty-gap argument.
# Fixed across every point. DuckDB caps scan parallelism at min(this, PRAGMA threads), so the FPGA
# arm follows the host thread budget on its own -- there is nothing to sweep here.
ZTHREADS   = os.environ.get("OASIS_ZSCORE_THREADS", "12")
PASS1      = "global"                     # no fusion; constant, kept for schema compatibility
FUSED      = "na"
# ------------------------------------------------------------------------------------------------

RUNS, AVG_LAST = 7, 3
# Test 0 deliberately uses a DIFFERENT protocol: 15 warm runs, MEDIAN, END-TO-END seconds. Keep the
# two apart in the paper and label which is which -- mixing them silently is worse than having one.
RUNS_REAL = 15
DEFAULT_TIMEOUT = 900

REAL   = re.compile(r"Run Time \(s\): real ([\d.]+) user ([\d.]+) sys ([\d.]+)")
TIMING = re.compile(rf"\[{TAG}\] heavy ([\d.]+) ms\s+phase1 ([\d.]+) ms\s+phase2 (-?[\d.]+) ms")
COUNT  = re.compile(r"^(\d+)$", re.M)     # bare result line (.mode csv + .headers off)


def mean_last(xs, k=AVG_LAST):
    return sum(xs[-k:]) / len(xs[-k:]) if xs else float("nan")


def linfit(xs, ys):
    """Least-squares y = a + b*x, returning (a, b, rms). Written out rather than pulled from numpy,
    which is not guaranteed on the run node."""
    n = len(xs)
    if n < 2:
        return (float("nan"),) * 3
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return (float("nan"),) * 3
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    rms = (sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys)) / n) ** 0.5
    return a, b, rms


def median(xs):
    """Test 0's aggregator. Its datasets are tail-heavy and end-to-end, where a median is the
    robust choice; the microbenchmarks use mean-of-last-3 on steady-state operator time instead."""
    if not xs:
        return float("nan")
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def spread(xs):
    """Peak-to-peak as a fraction of the mean. The internal checks are stated in these terms."""
    xs = [x for x in xs if x == x]
    if not xs:
        return float("nan")
    m = sum(xs) / len(xs)
    return (max(xs) - min(xs)) / m if m else float("nan")


# ---------------------------------------------------------------------------------- CPU topology
def cpu_topology():
    """[(cpu, core, socket, node)] from lscpu -p; [] if unavailable."""
    try:
        out = subprocess.run(["lscpu", "-p=CPU,CORE,SOCKET,NODE"],
                             capture_output=True, text=True, check=True).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        try:
            rows.append(tuple(int(x) if x else 0 for x in line.split(",")[:4]))
        except ValueError:
            pass
    return rows


def fpga_numa_node():
    """NUMA node of the Xilinx card, so small core counts sit next to the DMA engine."""
    try:
        ids = subprocess.run(["lspci", "-D", "-d", "10ee:"], capture_output=True, text=True).stdout
    except Exception:
        return None
    for line in ids.splitlines():
        p = f"/sys/bus/pci/devices/{line.split()[0]}/numa_node"
        if os.path.exists(p):
            n = int(open(p).read().strip())
            if n >= 0:
                return n
    return None


def pick_cpus(n, topo, prefer_node=None):
    """One CPU per physical core, the card's NUMA node first, SMT siblings last.

    Never assume ids are 0..N-1: on a multi-socket node a naive `taskset -c 0-3` can span four NUMA
    nodes, which would make the small-N points measure interconnect latency rather than core count.
    """
    if not topo:
        return f"0-{n-1}" if n > 1 else "0"
    seen, first, sibling = set(), [], []

    def key(r):
        cpu, core, sock, node = r
        return (0 if (prefer_node is not None and node == prefer_node) else 1, node, core, cpu)

    for cpu, core, sock, node in sorted(topo, key=key):
        (first if (node, core) not in seen else sibling).append(cpu)
        seen.add((node, core))
    return ",".join(str(c) for c in (first + sibling)[:n])


# ------------------------------------------------------------------------------------- execution
def warm(path):
    """Read the file once so the page cache is hot before anything is timed."""
    with open(path, "rb") as fh:
        while fh.read(1 << 24):
            pass


def stmt(arm, path, col=COL):
    if arm == "fpga":
        # FILTER, not a bare count(*), so the flag column is genuinely read and cannot be projected
        # away by the optimiser.
        return f"SELECT count(*) FILTER (WHERE is_outlier) FROM {FPGA_FN}('{path}','{col}');"
    # The SAME ALGORITHM as the hardware: a two-pass POPULATION z-score with |z| > K. A baseline
    # that computes something cheaper is not a baseline.
    return (f"WITH s AS (SELECT avg({col}::DOUBLE) m, stddev_pop({col}::DOUBLE) sd "
            f"FROM read_parquet('{path}')) "
            f"SELECT count(*) FROM read_parquet('{path}'), s "
            f"WHERE abs(({col}::DOUBLE - m) / sd) > {K};")


def _run_duckdb(sql, env, timeout, cmd_prefix=()):
    """SIGTERM-FIRST, with a 60 s grace period.

    A SIGKILLed DuckDB leaves Coyote's pinned pages and any in-flight DMA behind, and Coyote cannot
    reset user logic between host processes -- that is the path that has historically required a
    NODE REBOOT. SIGKILL is a last resort only.
    """
    p = subprocess.Popen(list(cmd_prefix) + [DUCKDB, "-init", "/dev/null"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, env=env, start_new_session=True)
    try:
        out, _ = p.communicate(sql, timeout=timeout)
        return out
    except subprocess.TimeoutExpired:
        print(f"    !! TIMEOUT after {timeout}s -- SIGTERM (never SIGKILL first)", file=sys.stderr)
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        try:
            out, _ = p.communicate(timeout=60)
            return out
        except subprocess.TimeoutExpired:
            print("    !! SIGTERM ignored for 60 s -- escalating. THE CARD MAY BE IN A BAD STATE: "
                  "re-run the correctness gate before trusting any later number.", file=sys.stderr)
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            out, _ = p.communicate()
            return out


def run_arm(arm, path, threads, timeout=DEFAULT_TIMEOUT, cpu_list=None, runs=RUNS, col=COL):
    """`runs` iterations in ONE session; the caller aggregates."""
    body = stmt(arm, path, col)
    # `PRAGMA threads` must precede `.timer on`, or the pragma's own few ms is the fastest run.
    sql = f"PRAGMA threads={threads};\n.mode csv\n.headers off\n.timer on\n" + (body + "\n") * runs

    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = (os.path.expanduser("~/opt/lib") + ":" +
                              os.path.expanduser("~/opt/jemalloc/lib") + ":" +
                              env.get("LD_LIBRARY_PATH", ""))
    env.pop(TIMING_ENV, None)
    if arm == "fpga":
        env[TIMING_ENV] = "1"
        env["OASIS_ZSCORE_THREADS"] = ZTHREADS

    out = _run_duckdb(sql, env, timeout, ["taskset", "-c", cpu_list] if cpu_list else [])

    reals = [float(m.group(1)) for m in REAL.finditer(out)]
    counts = [int(m.group(1)) for m in COUNT.finditer(out)]
    timing = [(float(a), float(b), float(c)) for a, b, c in TIMING.findall(out)]

    # `.timer` prints a Run Time line even for a statement that ERRORED, and that line is always the
    # fastest one. Requiring a RESULT ROW as well is what stops a failed bind being recorded as a
    # spectacular 0.001 s.
    if len(reals) < runs or len(counts) < runs:
        err = next((l for l in out.splitlines() if "rror" in l), "no result returned")
        print(f"    !! {arm}: {len(reals)} timed runs, {len(counts)} results (want {runs}) -- {err}",
              file=sys.stderr)
        if not counts:
            return None

    return dict(
        real=reals,
        user=[float(m.group(2)) + float(m.group(3)) for m in REAL.finditer(out)],
        counts=counts,
        heavy=[t[0] for t in timing],
        phase1=[t[1] for t in timing],
        phase2=[t[2] for t in timing],
    )


def measure(path, rows, threads, cpu_list=None, timeout=DEFAULT_TIMEOUT, expect=None, col=COL):
    """One point: both arms, the protocol, and the correctness gate. Returns a dict or None.

    `expect` defaults to rows/1000, which every planted-outlier generator guarantees exactly. Test 5
    passes it explicitly: a right-skewed distribution's own tail crosses the fence, so there the
    expectation is measured from the file rather than assumed.
    """
    if expect is None:
        expect = rows // 1000
    warm(path)
    f = run_arm("fpga", path, threads, timeout, cpu_list, col=col)
    c = run_arm("cpu", path, threads, timeout, cpu_list, col=col)
    if f is None or c is None:
        return None

    # ALL 7 iterations, both arms. The FPGA arm is the soak test; the CPU arm proves the expected
    # count is right rather than merely reproducible.
    f_ok = all(x == expect for x in f["counts"][:RUNS])
    c_ok = all(x == expect for x in c["counts"][:RUNS])
    if not f_ok:
        print(f"    !! FPGA flag count {sorted(set(f['counts']))} != expected {expect}",
              file=sys.stderr)
    if not c_ok:
        print(f"    !! CPU flag count {sorted(set(c['counts']))} != expected {expect}",
              file=sys.stderr)

    fpga_op = mean_last(f["heavy"])
    if fpga_op != fpga_op:                      # NaN: the binary predates the timing line
        print("    !! no [zscore] heavy line -- rebuild the extension with the OASIS_ZSCORE_TIMING "
              "instrumentation, or fpga_op_ms is meaningless", file=sys.stderr)
    cpu_op = mean_last(c["real"]) * 1000.0
    return dict(
        rows=rows,
        fpga_op_ms=fpga_op,
        cpu_op_ms=cpu_op,
        speedup=cpu_op / fpga_op if fpga_op else float("nan"),
        fpga_decode_ms=mean_last(f["phase1"]),
        fpga_passes_ms=mean_last(f["phase2"]),
        fpga_cpu_seconds=mean_last(f["user"]),
        cpu_cpu_seconds=mean_last(c["user"]),
        fpga_e2e_s=mean_last(f["real"]),
        cpu_e2e_s=mean_last(c["real"]),
        pass1=PASS1,
        fused=FUSED,
        flags_ok=int(f_ok and c_ok),
        expected=expect,
        fpga_count=f["counts"][-1] if f["counts"] else "",
        cpu_count=c["counts"][-1] if c["counts"] else "",
        # "wander" = the count moving BETWEEN iterations of one point. On a bitstream with 1 ps of
        # hold margin that is the failure signature, and it is invisible to a single check.
        fpga_wander=(max(f["counts"]) - min(f["counts"])) if f["counts"] else "",
        cpu_wander=(max(c["counts"]) - min(c["counts"])) if c["counts"] else "",
    )


def emit(path, fieldnames, rows):
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"\nwrote {path}")


def show(label, r):
    print(f"    {label:<22} fpga {r['fpga_op_ms']:8.1f} ms   cpu {r['cpu_op_ms']:8.1f} ms   "
          f"{r['speedup']:5.2f}x   p1 {r['fpga_decode_ms']:7.1f}  p2 {r['fpga_passes_ms']:7.1f}   "
          f"flags {'ok' if r['flags_ok'] else 'BAD'}")


# ------------------------------------------------------------------------------------ the panels
SIZE_COLS = ["rows", "fpga_op_ms", "cpu_op_ms", "speedup", "fpga_decode_ms", "fpga_passes_ms",
             "fpga_cpu_seconds", "cpu_cpu_seconds", "fpga_e2e_s", "cpu_e2e_s", "pass1", "fused",
             "flags_ok"]


def test_size(args):
    ds = os.path.expanduser(args.data)
    out = []
    for m in [int(x) for x in args.sizes.split()]:
        path = os.path.join(ds, f"size_{m}M.parquet")
        if not os.path.exists(path):
            print(f"  missing {path} -- run gen_size_sweep.sh", file=sys.stderr)
            continue
        print(f">>> {m}M rows")
        r = measure(path, m * 1_000_000, args.threads, timeout=args.timeout)
        if r:
            show(f"{m}M", r)
            out.append(r)
    emit(args.csv, SIZE_COLS, out)


CODEC_COLS = ["level", "card", "enc_intent", "compression", "encodings", "rows", "bytes",
              "bytes_per_row", "fpga_op_ms", "cpu_op_ms", "speedup", "fpga_decode_ms",
              "fpga_passes_ms", "decoded_gbs", "wire_gbs", "fpga_cpu_seconds", "cpu_cpu_seconds",
              "pass1", "flags_ok"]


def test_codec(args):
    manifest = os.path.join(os.path.expanduser(args.data), "manifest.csv")
    if not os.path.exists(manifest):
        sys.exit(f"missing {manifest} -- run gen_codec_sweep.sh")
    out = []
    for m in csv.DictReader(open(manifest)):
        path = m["file"]
        if not os.path.exists(path):
            print(f"  missing {path}", file=sys.stderr)
            continue
        rows, nbytes = int(m["rows"]), int(m["bytes"])
        print(f">>> {m['level']}/{m['enc_intent']}/{m['compression']}")
        r = measure(path, rows, args.threads, timeout=args.timeout)
        if not r:
            continue
        secs = r["fpga_op_ms"] / 1000.0
        r.update(level=m["level"], card=m["card"], enc_intent=m["enc_intent"],
                 compression=m["compression"], encodings=m["encodings"], bytes=nbytes,
                 bytes_per_row=m["bytes_per_row"],
                 # decoded = what the operator consumed, wire = what crossed PCIe inbound
                 decoded_gbs=(rows * 4) / secs / 1e9 if secs else float("nan"),
                 wire_gbs=nbytes / secs / 1e9 if secs else float("nan"))
        show(f"{m['level']}/{m['enc_intent'][:4]}/{m['compression'][:4]}", r)
        out.append(r)

    # THE INTERNAL CHECK, and why it is not the roadmap's.
    #
    # The roadmap's control is "second-pass time must be constant within a level, because the values
    # are provably identical there, so all variation must live in the decode window". That does NOT
    # transfer: its second pass streams already-decoded data, whereas OUR phase 2 re-reads and
    # re-decodes the column (the global scheme's barrier means each phase is a full pass). So
    # representation moves BOTH phases and the spreads below are the measurement, not a defect.
    # The control that does hold is the generator's digest gate: the four files at a level provably
    # carry the same numbers.
    for lv in sorted({r["level"] for r in out}):
        p1 = [r["fpga_decode_ms"] for r in out if r["level"] == lv]
        p2 = [r["fpga_passes_ms"] for r in out if r["level"] == lv]
        print(f"  level {lv}: phase 1 spread {spread(p1)*100:.1f}%  "
              f"phase 2 spread {spread(p2)*100:.1f}%  (both phases decode, so both move)")

    # THE RESULT: operator time as a function of BYTE VOLUME alone, with no encoding or compression
    # term. A small rms is the finding -- it says representation acts on this operator THROUGH bytes
    # and through nothing else. Contrast the CPU arm, which pays for decode complexity instead and
    # therefore does not follow bytes at all.
    bpr = [float(r["bytes_per_row"]) for r in out]
    for label, ys in (("fpga_op_ms", [r["fpga_op_ms"] for r in out]),
                      ("cpu_op_ms ", [r["cpu_op_ms"] for r in out])):
        a, b, rms = linfit(bpr, ys)
        print(f"  {label} ~ {a:6.2f} + {b:5.2f} * bytes_per_row    rms {rms:.2f} ms")
    emit(args.csv, CODEC_COLS, out)


THREAD_COLS = ["threads", "rows", "dataset", "fpga_op_ms", "cpu_op_ms", "speedup",
               "fpga_decode_ms", "fpga_passes_ms", "fpga_cpu_seconds", "cpu_cpu_seconds",
               "offload_ratio", "fused", "cpu_list", "pass1", "flags_ok"]


def test_thread(args):
    path = os.path.expanduser(args.file)
    if not os.path.exists(path):
        sys.exit(f"missing {path}")
    rows = args.rows
    dataset = os.path.basename(path)

    topo = cpu_topology()
    node = fpga_numa_node()
    print(f"core plan: {len(topo)} logical cpus, card on NUMA node {node}")

    out = []
    for t in [int(x) for x in args.sweep.split()]:
        cpus = None if args.no_taskset else pick_cpus(t, topo, node)
        print(f">>> threads={t}  taskset={cpus}")
        r = measure(path, rows, t, cpu_list=cpus, timeout=args.timeout)
        if not r:
            continue
        r.update(threads=t, dataset=dataset, cpu_list=cpus or "none",
                 offload_ratio=(r["cpu_cpu_seconds"] / r["fpga_cpu_seconds"]
                                if r["fpga_cpu_seconds"] else float("nan")))
        show(f"threads={t}", r)
        out.append(r)

    # THE INTERNAL CHECK, adapted -- and the adaptation is itself a measured result.
    #
    # The roadmap checks that the SECOND PASS is flat across thread counts, on the grounds that the
    # FPGA has identical work at every point. True for its host, which only orchestrates. Ours also
    # FEEDS phase 2 from the scan threads, so phase 2 legitimately scales with them. That is
    # measured, not assumed: a `--no-taskset` run (all 32 cores available, only PRAGMA threads
    # varying) still moved phase 2 from 40.4 ms to 9.2 ms, so the cause is host feed depth, not core
    # confinement. ==> WE CANNOT CLAIM CORE-COUNT INDEPENDENCE, and the honest statement is the
    # saturation point instead: how few host threads the FPGA path needs to beat the CPU on 32.
    #
    # What IS a pure hardware-side quantity is PHASE 1: it runs inside ZScoreInitGlobal before any
    # scan thread exists, so the pragma must not move it. Reported as a SLOPE per doubling rather
    # than a spread, because with six points a peak-to-peak is dominated by whichever point was
    # noisiest -- and a slope that flips sign between runs is the signature of no trend at all.
    lg = [math.log2(r["threads"]) for r in out]
    for label, ys in (("phase 1", [r["fpga_decode_ms"] for r in out]),
                      ("phase 2", [r["fpga_passes_ms"] for r in out])):
        a, b, _ = linfit(lg, ys)
        mean = sum(ys) / len(ys)
        pct = 100.0 * b / mean if mean else float("nan")
        if label == "phase 1":
            v = "FLAT (as required)" if abs(pct) < 5.0 else ">>> NOT FLAT -- phase 1 runs before any scan thread exists"
        else:
            v = "scales with the thread budget -- the FINDING, not a failure"
        print(f"  {label}: {pct:+.1f}% per doubling of threads   {v}")

    best = min(out, key=lambda r: r["fpga_op_ms"])
    cpu32 = next((r for r in out if r["threads"] == 32), None)
    if cpu32:
        beats = [r for r in out if r["fpga_op_ms"] < cpu32["cpu_op_ms"]]
        if beats:
            r = min(beats, key=lambda r: r["threads"])
            print(f"  the FPGA path passes the 32-thread CPU baseline ({cpu32['cpu_op_ms']:.1f} ms) "
                  f"at {r['threads']} host thread(s): {r['fpga_op_ms']:.1f} ms "
                  f"({cpu32['cpu_op_ms']/r['fpga_op_ms']:.2f}x). Fastest point: "
                  f"{best['fpga_op_ms']:.1f} ms at {best['threads']} threads.")
    emit(args.csv, THREAD_COLS, out)


SKEW_COLS = ["a", "skewness", "kurtosis", "mean_over_median", "bins_per_iqr", "rows",
             "bytes_per_row", "distinct", "gate", "natural_outliers", "expected_total",
             "fpga_op_ms", "cpu_op_ms", "speedup", "fpga_decode_ms", "fpga_passes_ms",
             "fpga_cpu_seconds", "cpu_cpu_seconds", "fpga_count", "cpu_count", "fpga_err",
             "cpu_err", "fpga_wander", "cpu_wander", "pass1", "fused", "flags_ok"]


def test_skew(args):
    """TEST 5 -- distribution shape. A CONTROL, NOT A PANEL: both arms are expected to come out
    flat. RUN IT TWICE and compare the same-point repeat spread against the across-skew spread --
    on one run alone, "flat" is an eyeball claim a reviewer can push back on.

    `bins_per_iqr` stays empty: it is an IQR quantisation control and a z-score fence does not
    quantise.
    """
    manifest = os.path.join(os.path.expanduser(args.data), "manifest.csv")
    if not os.path.exists(manifest):
        sys.exit(f"missing {manifest} -- run gen_skew_sweep.sh")
    out = []
    for m in csv.DictReader(open(manifest)):
        path = m["file"]
        if not os.path.exists(path):
            print(f"  missing {path}", file=sys.stderr)
            continue
        rows, planted = int(m["rows"]), int(m["planted"])
        expect = int(m["expected_flags"])
        print(f">>> a={m['a']}  skewness {m['skewness']}  kurtosis {m['kurtosis']}")
        r = measure(path, rows, args.threads, timeout=args.timeout, expect=expect)
        if not r:
            continue
        r.update(a=m["a"], skewness=m["skewness"], kurtosis=m["kurtosis"], mean_over_median="",
                 bins_per_iqr="", bytes_per_row=m["bytes_per_row"], distinct=m["distinct"],
                 gate="measured", natural_outliers=expect - planted, expected_total=expect,
                 fpga_err=(r["fpga_count"] - expect) if r["fpga_count"] != "" else "",
                 cpu_err=(r["cpu_count"] - expect) if r["cpu_count"] != "" else "")
        show(f"a={m['a']}", r)
        out.append(r)

    s = spread([r["fpga_op_ms"] for r in out])
    print(f"  FPGA operator spread across skewness: {s*100:.1f}%")
    print("  >>> RUN THIS AGAIN into a second CSV. If the same-point repeat difference is as large "
          "as this spread, there is no trend -- and that comparison IS the result.")
    emit(args.csv, SKEW_COLS, out)


REAL_COLS = ["dataset", "rows", "column", "scale", "distinct", "fpga_e2e_s", "cpp_e2e_s",
             "sql_e2e_s", "fpga_over_cpp", "cpp_over_sql", "fpga_over_sql", "fpga_cpu_seconds",
             "cpp_cpu_seconds", "sql_cpu_seconds", "min_group_mod8", "encodings", "path_used",
             "fpga_op_ms", "fpga_decode_ms", "fpga_passes_ms", "expected", "flags_ok"]


def test_real(args):
    """TEST 0 -- the real datasets. A DIFFERENT protocol from every other test here: medians of 15
    warm runs, END-TO-END seconds.

    Two arms, not the roadmap's three. Their `cpp` arm is a hand-written CPU operator and their
    `sql` arm exists to prove that operator is not a strawman; our baseline IS the SQL, so the
    fairness question does not arise and the `cpp_*` columns stay empty. They are kept so the two
    halves of the paper share plotting code.

    Real data has no planted outliers, so the correctness target is the CPU reference count that
    gen_real.sh computed per file and wrote into the manifest.
    """
    manifest = os.path.join(os.path.expanduser(args.data), "manifest.csv")
    if not os.path.exists(manifest):
        sys.exit(f"missing {manifest} -- run gen_real.sh")
    out = []
    for m in csv.DictReader(open(manifest)):
        path, col = m["file"], m["column"]
        if not os.path.exists(path):
            print(f"  missing {path}", file=sys.stderr)
            continue
        expect = int(m["cpu_outliers"])
        print(f">>> {m['dataset']}  ({int(m['rows']):,} rows, {m['encodings']})")
        warm(path)
        f = run_arm("fpga", path, args.threads, args.timeout, runs=RUNS_REAL, col=col)
        c = run_arm("cpu", path, args.threads, args.timeout, runs=RUNS_REAL, col=col)
        if f is None or c is None:
            continue
        # ALL 15 iterations, both arms -- the soak test matters most on the ragged real files.
        f_ok = all(x == expect for x in f["counts"][:RUNS_REAL])
        c_ok = all(x == expect for x in c["counts"][:RUNS_REAL])
        if not f_ok:
            print(f"    !! FPGA count {sorted(set(f['counts']))} != CPU reference {expect}",
                  file=sys.stderr)
        fe, se = median(f["real"]), median(c["real"])
        r = dict(dataset=m["dataset"], rows=int(m["rows"]), column=col, scale=m["scale"],
                 distinct=m["distinct"], fpga_e2e_s=fe, cpp_e2e_s="", sql_e2e_s=se,
                 fpga_over_cpp="", cpp_over_sql="",
                 fpga_over_sql=se / fe if fe else float("nan"),
                 fpga_cpu_seconds=median(f["user"]), cpp_cpu_seconds="",
                 sql_cpu_seconds=median(c["user"]),
                 min_group_mod8=m["min_group_mod8"], encodings=m["encodings"],
                 # This host has no ragged guard, so every dataset takes the same path. Recorded
                 # rather than assumed, because it is exactly what the roadmap warns about.
                 path_used="stream",
                 fpga_op_ms=median(f["heavy"]), fpga_decode_ms=median(f["phase1"]),
                 fpga_passes_ms=median(f["phase2"]), expected=expect,
                 flags_ok=int(f_ok and c_ok))
        print(f"    {m['dataset']:<22} fpga {fe*1000:8.1f} ms   sql {se*1000:8.1f} ms   "
              f"{r['fpga_over_sql']:5.2f}x   flags {'ok' if r['flags_ok'] else 'BAD'}")
        out.append(r)

    ratios = [r["fpga_over_sql"] for r in out if r["fpga_over_sql"] == r["fpga_over_sql"]]
    if ratios:
        # GEOMETRIC mean: an arithmetic mean of ratios is meaningless.
        g = 1.0
        for x in ratios:
            g *= x
        print(f"  geomean speedup over {len(ratios)} datasets: {g ** (1.0/len(ratios)):.2f}x")
    emit(args.csv, REAL_COLS, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="test", required=True)

    p = sub.add_parser("real", help="Test 0 -- real datasets (medians of 15, END-TO-END seconds)")
    p.add_argument("--data", default="~/bench/microbench/real")
    p.add_argument("--threads", type=int, default=32)
    p.add_argument("--csv", default="real_datasets.csv")
    p.add_argument("--timeout", type=int, default=1800)
    p.set_defaults(func=test_real)

    p = sub.add_parser("size", help="Test 1 -- size sweep")
    p.add_argument("--data", default="~/bench/microbench/sizesweep")
    p.add_argument("--sizes", default="1 3 6 10 20 40 60 80 100")
    p.add_argument("--threads", type=int, default=32)
    p.add_argument("--csv", default="size_sweep.csv")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.set_defaults(func=test_size)

    p = sub.add_parser("codec", help="Test 4 -- compression & encoding")
    p.add_argument("--data", default="~/bench/microbench/codecsweep")
    p.add_argument("--threads", type=int, default=32)
    p.add_argument("--csv", default="codec_sweep.csv")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.set_defaults(func=test_codec)

    p = sub.add_parser("skew", help="Test 5 -- distribution shape (a CONTROL; run it TWICE)")
    p.add_argument("--data", default="~/bench/microbench/skew")
    p.add_argument("--threads", type=int, default=32)
    p.add_argument("--csv", default="skew_sweep.csv")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.set_defaults(func=test_skew)

    p = sub.add_parser("thread", help="Test 3 -- core-count sweep")
    p.add_argument("--file", default="~/bench/microbench/sizesweep/size_20M.parquet")
    p.add_argument("--rows", type=int, default=20_000_000)
    p.add_argument("--sweep", default="1 2 4 8 16 32")
    p.add_argument("--knee", action="store_true",
                   help="run the control dataset (10M rows, cardinality 100k) instead")
    p.add_argument("--no-taskset", action="store_true",
                   help="pragma only, no pinning -- isolates FPGA-arm host cost outside DuckDB's "
                        "scheduler. Worth one run; not the headline.")
    p.add_argument("--csv", default="thread_sweep_balanced.csv")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.set_defaults(func=test_thread)

    args = ap.parse_args()
    if getattr(args, "knee", False):
        args.file = "~/bench/microbench/knee/card_100000.parquet"
        args.rows = 10_000_000
    if not os.path.exists(DUCKDB):
        sys.exit(f"no DuckDB binary at {DUCKDB} (set OASIS_DUCKDB)")
    print(f"binary:  {DUCKDB}\nzthreads: {ZTHREADS}   protocol: {RUNS} runs, mean of last {AVG_LAST}\n")
    args.func(args)


if __name__ == "__main__":
    main()
