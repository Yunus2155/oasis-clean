# Microbenchmarks — the z-score half of the joint paper

Five tests, matching the IQR half so the two halves plot together. **Panels: 1, 3, 4.** Test 0 is a
table, Test 5 is two sentences.

| # | test | axis | what it supports | protocol |
|---|---|---|---|---|
| 0 | real datasets | 7 real columns, everything varying | the table a reviewer believes: "this works on data we did not design" | **medians of 15, END-TO-END s** |
| 1 | size sweep | 1M → 100M rows | the FPGA wins at every size, and the advantage is durable at scale | mean-of-last-3, operator ms |
| 3 | core sweep | 1 → 32 host threads | the offload claim: the FPGA path is flat in host core count | mean-of-last-3, operator ms |
| 4 | codec sweep | 8 representations of the same 20M numbers | the statistics stage is representation-invariant; the shared decoder is where the time goes | mean-of-last-3, operator ms |
| 5 | skew sweep | skewness 0 → ~3.4 | ⚠️ **a control, not a panel** — defends 1/3/4 (all uniform data) against "real data is skewed" | mean-of-last-3, **run TWICE** |

⚠️ **Test 0 uses a different protocol from the other four.** Report its numbers as end-to-end
seconds and the rest as operator milliseconds, and say which is which. Mixing them silently is
worse than having only one.

There is **no cardinality sweep**. It is IQR-specific: their CPU baseline pays for a `GROUP BY`,
ours is count/sum/sum-of-squares, i.e. O(rows) and cardinality-independent. Both of our arms would
be flat and the panel would say nothing.

## Configuration this was built for

| | |
|---|---|
| branch | `global-zscore` |
| bitstream | `hardware/build-41` (3 lanes, `--no-rdma --decoders 3`, EN_MEM=0) |
| binary | `~/duckdb-bench41` — the restore point's build **plus** the timing instrumentation |
| node | `alveo-u55c-09` |
| data | `~/bench/microbench/` |

⛔ `~/duckdb-global-fix` is the known-good restore-point binary and must not be overwritten.

## What differs from the roadmap, and why

**1. The value space is scaled down.** Pass 1 accumulates Σx² into a signed 64-bit register that
wraps silently (`z_score_squared.sv`), and the exact check in `ComputeGlobalStatistics()` throws
when it would. The roadmap's constants need Σx² = 3.63e19 at 100M rows — **3.94× over the 9.22e18
limit**, so its Test-1 recipe is unusable above ~26M rows, and its Test-4 recipe is 790× over.

z-score is scale-invariant, so dividing every value by a constant preserves **every ratio in the
gap argument exactly** while Σx², which scales with the square, shrinks quadratically:

| | roadmap | here | ratio preserved? |
|---|--:|--:|---|
| Test 1 base range | `[0, 1e6)` | `[0, 250000)` | — |
| Test 1 outlier offset | `+5e6` | `+1,250,000` | — |
| base top vs threshold | 1.49× below | **1.49× below** | ✅ |
| outlier floor vs threshold | 3.35× above | **3.35× above** | ✅ |
| Σx² at 100M rows | 3.63e19 ❌ | **2.27e18** (4.06× headroom) | — |
| Test 4 range / offset | 1e7 / +5e7 | 500,000 / +2,500,000 | ✅ same ratios |
| Σx² at 20M rows | 7.3e21 ❌ | **1.82e18** (5.1× headroom) | — |

Cost: Test 1's cardinality is 250,000 rather than 1,000,000. Row groups hold 122,880 rows, so
distinct-per-group (~97k) and therefore the writer's encoding decision are unchanged — the sweep
still runs PLAIN throughout, which is the property that mattered. Test 4's `hi` level is 400,000
rather than 1,000,000, still ~106k dictionary entries per row group: under the hardware's 524,288
bound (`ID_BITS=19`) and still large enough that the dictionary **grows** the file, which is the
sign change the design needs.

**Expected flags = rows / 1000, exactly, at every point of every test.** The generators gate on it
and the harness checks it on all 7 iterations of every point.

**2. INT32 only.** The datapath is `ELEM_BITS=32` and `ZScoreBind` rejects anything else, so every
generated column is `INTEGER`, not `BIGINT`. This also means PLAIN is 4 B/row rather than 8, which
weakens (but does not reverse) the dictionary's size effect at the `lo` level.

**3. No fusion.** That is an IQR mechanism. Test 1 is a single FPGA curve. The `pass1` and `fused`
CSV columns are kept as constants (`global` / `na`) so both halves share plotting code.

**4. `fpga_decode_ms` is phase 1, `fpga_passes_ms` is phase 2.** Our split is at the statistics
barrier, not at the decoder: phase 1 = read + decode + STATS with only 64 bytes of egress per row
group, phase 2 = read + decode + classify + flag egress. **Both phases decode.** The column names
match the IQR schema for plotting; the meaning must be stated in the paper rather than implying a
decode timer we do not have.

**5. The CPU arm is DuckDB SQL, not a table function**, so it cannot print a `heavy` line and its
operator time is the query's own wall time. That is fair here in a way it would not be for a
`CREATE TABLE`: both arms are a scan plus a count aggregate, and the aggregate is identical on both
sides. The baseline computes the **same algorithm** as the hardware — a two-pass population z-score
with |z| > 3 — not whatever DuckDB could do fastest.

**A harmless warning to expect.** `ZScoreBind` bounds Σx² by `rows × max|x|²`, which assumes every
row carries the outlier value; on this data that bound is ~100× pessimistic, so every query prints
`[zscore] warning: ... above the 64-bit limit`. It is a warning by design — the exact test runs in
phase 1 on the real sums. The harness ignores it.

## Running it

**Everything runs on the Alveo node.** The extension creates the OasisContext at `Load()`
(`oasis_extension.cpp:69`), so the binary cannot even open without 1 GiB huge pages — dataset
generation included. There is no vanilla DuckDB CLI on this host and no network from the compute
nodes, so generating elsewhere is not an option. The `tpch` extension is already cached in
`~/.duckdb/extensions`, so `LOAD tpch` works offline.

```bash
# 0. build with the instrumentation, then:  cp extension/build/release/duckdb ~/duckdb-bench41
# 1. on the Alveo node
~/flash.sh 41
timeout 300 ~/duckdb-bench41 -c \
  "SELECT count(*) FROM zscore('$HOME/bench/taxi_fare.parquet','x') WHERE is_outlier;"   # => 10312

# 2. datasets. Every generator has a `plan`/`verify` mode; GATES MUST PASS BEFORE ANY MEASUREMENT.
cd ~/oasis/benchmark
./gen_real.sh plan            # measures Sum(x^2) at both money scales, writes nothing
./gen_real.sh                 # Test 0   (~15 min; SF10 dbgen is the long pole)
./gen_size_sweep.sh           # Test 1   (~25 min; the 100M-row file)
./gen_codec_sweep.sh          # Test 4 + the Test 3 knee control (~15 min)
./gen_skew_sweep.sh           # Test 5   (~10 min)

# 3. the tests
python3 microbench.py real   --csv real_datasets.csv            | tee real.log
python3 microbench.py size   --csv size_sweep.csv               | tee size_sweep.log
python3 microbench.py codec  --csv codec_sweep.csv              | tee codec_sweep.log
python3 microbench.py thread --csv thread_sweep_balanced.csv    | tee thread_balanced.log
python3 microbench.py thread --knee --csv thread_sweep_knee.csv | tee thread_knee.log
python3 microbench.py skew   --csv skew_sweep.csv               | tee skew1.log
python3 microbench.py skew   --csv skew_sweep_rep2.csv          | tee skew2.log   # THE REPEAT
```

### Test 0 and Test 5 specifics

**Test 0 has no planted outliers**, so the correctness target is the CPU reference count that
`gen_real.sh` computes per file and writes into the manifest. It also has only **two arms**: the
roadmap's third (`sql`) exists to prove their hand-written `cpp` operator is not a strawman, but
our baseline *is* the SQL, so the question does not arise and the `cpp_*` columns stay empty.

Money scale: `l_extendedprice` is stored in **whole dollars**, not cents — cents give Σx² ≈ 8.8e19
at SF1, ~10× the accumulator (their own digest table is what shows this: mean 3.83e6 cents over
6.0M rows). So the two `extprice` digests deliberately do **not** match the roadmap's. For the taxi
column the answer is not obvious, so `gen_real.sh plan` **measures** it and picks the finest scale
with ≥2× headroom. `count(*)` and `sum(v)` are still checked against the roadmap; `sum(hash(v))`
cannot match either way, because DuckDB hashes INTEGER and BIGINT differently.

**Ragged row groups are not a hazard here.** Nothing in `zscore_scan.cpp` keys off `num_values % 8`
— we have no ragged guard — and our existing build-41 real-data runs used files built exactly this
way with exact counts. So Test 0 and Tests 1/3/4 take the **same** code path, which makes the
real-vs-synthetic comparison cleaner than the roadmap's. `min_group % 8` is still recorded per file.

**Test 5 is scaled down more than the others**: CARD 20,000 with spread 700,000, because the
roadmap's CARD=1.02e6 / S=9e6 needs Σx² ≈ 5e20 (55× over). Lowering the cardinality rather than the
spread is deliberate — skew needs S ≫ CARD or the uniform `+level` term dilutes the shape away. Its
IQR-specific power-of-two bin-width normalisation is dropped: a z-score fence does not quantise.

Test 5's expected count is **measured from each file**, not assumed: right-skew shrinks σ and pulls
the fence down, so at high skew the distribution's own tail crosses it. That is a real property of
a non-robust fence — and it is the substance of the joint "why offer both operators" figure the
roadmap asks for in its §7.6.

⛔ **Never Ctrl-C or Ctrl-Z an in-flight FPGA query.** Pinned pages and in-flight DMA survive the
process and Coyote cannot reset user logic between host processes; recovery has needed a reboot.
The harness uses SIGTERM first with a 60 s grace period, and SIGKILL only as a last resort.

## Results — measured 2026-08-15, alveo-u55c-09, build-41, `~/duckdb-bench41`

Every point of every test reported the exact expected flag count on **all** iterations.

### Test 0 — real data, geometric mean **2.23×** (medians of 15, end-to-end)

| dataset | rows | encoding | FPGA | SQL | speedup |
|---|--:|---|--:|--:|--:|
| taxi_d1 | 3.0M | PLAIN+PLAIN_DICT | 8.0 ms | 17.0 | 2.12× |
| taxi_d2 | 6.0M | PLAIN_DICTIONARY | 10.0 | 20.0 | 2.00× |
| taxi_d3 | 13.1M | PLAIN_DICTIONARY | 14.0 | 32.0 | 2.29× |
| taxi_d4 | 20.3M | PLAIN_DICTIONARY | 18.0 | 44.0 | 2.44× |
| tpch_qty_sf17 | 102M | PLAIN_DICTIONARY | 58.0 | 178.0 | **3.07×** |
| tpch_extprice_sf17 | 102M | PLAIN | 99.0 | 167.0 | **1.69×** |

**The roadmap's prediction for this table is inverted for us.** It expects `tpch_qty` (50 distinct)
to be the weakest row, because its CPU baseline pays for distinct values. Ours is the *strongest*.
Our ordering is set by **compression ratio**, not cardinality: qty is 5.3× compressed so ingress is
nearly free, while extprice is PLAIN at 1.0× and must move 408 MB inbound. Same operator, different
baseline, opposite ranking — worth one sentence in the paper.

### Test 1 — size sweep, the advantage is in the SLOPE

Fitted over the linear region (N ≥ 20M):

```
FPGA    4.75 ms + 0.873 ms/Mrow
CPU    12.55 ms + 1.558 ms/Mrow      => asymptotic speedup 1.78x
```

Measured speedup falls 3.12× (1M) → 1.83× (100M) and then stops falling, exactly as the slope ratio
predicts. At 100M the phase split is phase 1 = 54.5 ms, phase 2 = 37.6 ms: **the statistics barrier
is 59% of operator time**, which is where an HBM decode-once would pay.

### Test 4 — operator time is a function of BYTE VOLUME and nothing else

Two independent runs of the same eight points:

```
run 1   fpga_op ~ 10.95 + 2.71 * B/row   rms 0.31 ms      cpu_op ~ 44.06 + 0.71 * B/row   rms 2.79
run 2   fpga_op ~ 10.34 + 2.77 * B/row   rms 0.48 ms      cpu_op ~ 37.17 + 2.11 * B/row   rms 2.71
```

The FPGA slope reproduces to 2.2% with an rms of 1.4–2.2%; the CPU slope does **not** reproduce
(0.71 vs 2.11) and its rms is 6–9× larger. So the FPGA arm follows bytes and the CPU arm follows
decode complexity — visible directly in the rows, where the 2.22 B/row dictionary points cost the
CPU *more* (46.0, 43.7 ms) than the 4.00 B/row PLAIN points (42.0, 44.7 ms).

⭐ **Our byte slope, 2.71–2.77 ms per B/row, is the IQR half's 2.71 exactly** (its §5.7 fit). Same
decoder, same per-byte price, measured independently on two operators. But its fit needs `[snappy]`
and `[dict]` terms on top; ours needs neither — bytes/row alone explains the FPGA arm. That is the
"shared decoder" claim landing about as hard as it can. (One coefficient agreeing could be chance;
label it as a cross-check, not a derivation.)

Speedup spans **1.86× – 2.93×** on the same 20 million numbers, so the methodology point holds:
a speedup quoted without its encoding is meaningless.

⚠️ **The Snappy arm is null here** — 80.02 MB → 79.92 MB, 0.1%. The roadmap gets 8.00 → 4.71 B/row
because its columns are INT64 holding small values, i.e. four zero bytes per value that Snappy
crushes. Ours are INT32 whose values span most of the word. State this: it is why our compression
axis collapsed to an encoding axis, and it is a property of the *column type*, not of the codec.

### Test 3 — ⚠️ the roadmap's core-independence claim does NOT reproduce

| threads | FPGA | CPU | phase 1 | phase 2 | FPGA cpu-s | CPU cpu-s | offload |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 63.3 | 1157.3 | 17.0 | 46.3 | 0.062 | 1.153 | **18.5×** |
| 2 | 38.9 | 530.0 | 12.3 | 26.7 | 0.067 | 0.769 | 11.5× |
| 4 | 30.2 | 249.3 | 13.6 | 16.7 | 0.080 | 0.797 | 9.9× |
| 8 | 26.2 | 118.3 | 13.4 | 12.8 | 0.089 | 0.717 | 8.0× |
| 16 | 24.3 | 71.7 | 13.7 | 10.6 | 0.104 | 0.852 | 8.2× |
| 32 | 22.5 | 42.3 | 13.3 | 9.1 | 0.119 | 0.921 | **7.8×** |

**Phase 1 is flat, phase 2 is not.** Across three independent sweeps the phase-1 slope per doubling
of threads was −2.9%, +0.3% and +1.3% — mixed signs, so no trend, which is what must happen since
phase 1 runs inside `ZScoreInitGlobal` before any scan thread exists. Phase 2 moved −33.4%, −29.4%
and −33.4% per doubling: reproducible, therefore real.

The cause is **host feed depth, not core confinement** — measured, not inferred. A `--no-taskset`
sweep with all 32 cores available and only `PRAGMA threads` varying still moved phase 2 from 40.7 to
9.0 ms. One scan thread cannot keep three decode lanes fed. Pinning is a real but secondary effect:
at threads=1 it costs 63.3 vs 53.0 ms (16%).

**So do not claim "flat in host core count".** The defensible statements are:

> The FPGA path passes the 32-core CPU baseline at **2 host threads** (38.9 vs 42.3 ms), and reaches
> 1.61× of it at 8. At 32 threads it uses **7.8× fewer CPU-seconds**, rising to 18.5× at one thread.

The crossing sits at 2 threads in all three sweeps (balanced 1.09×, knee 1.25×, unpinned 1.11×), so
it is a property of the design and not of one dataset.

⚠️ **The roadmap's actionable recommendation is reversed for us.** It found the FPGA arm's
CPU-seconds doubling from 1→32 threads for a 1.8% wall gain, and concluded the operator should cap
the thread count it requests. Ours doubles too (0.062 → 0.119) but buys a **2.8× wall speedup**
(63.3 → 22.5 ms). Our operator genuinely needs those threads, and the reason is the phase-2 feed
finding above. Deeper per-worker windowing is the lever that would change this.

### Test 5 — the control holds: no shape effect

| skewness | 0.00 | 0.66 | 1.24 | 1.72 | 2.13 | 2.79 |
|---|--:|--:|--:|--:|--:|--:|
| FPGA op (ms), run 1 | 22.2 | 22.0 | 22.3 | 22.1 | 21.7 | 22.9 |
| FPGA op (ms), run 2 | 21.3 | 21.6 | 21.7 | 21.7 | 21.3 | 22.0 |

Across-skew spread was 5.3% and 3.1%; the largest **same-point repeat difference was 0.9 ms
(4.1%)** — as large as the spread itself, and the ordering reshuffles between sessions. There is no
trend. Speedup stays in 1.90–2.17×.

> Over Fisher skewness 0.00–2.79 and excess kurtosis −1.20–7.53, with rows, cardinality, encoding,
> byte volume and row-group geometry held fixed, FPGA operator time varies by 4.3% pooled over two
> sessions, and the speedup stays in 1.90–2.17×.

Construction check: a=0 measures skewness **−0.0000** and excess kurtosis **−1.2000**, the exact
theoretical values for a uniform distribution.

Unplanned bonus control: at a=8 and a=12 the flag count is 8× and 16× larger (165,854 and 332,687
vs 20,000) while operator time does not move — measured proof that flag density does not affect the
`FILTER` path.

## Why two internal checks differ from the roadmap's

Both were changed **after** confirming the roadmap's premise is false for this architecture, not
because they failed. The evidence in each case is independent of the numbers they gate:

1. **Test 4 — "phase 2 must be constant within a level" is dropped.** Its second pass streams
   already-decoded data; ours re-reads and re-decodes the column, because the global scheme's
   barrier makes each phase a full pass. So representation moves both phases, and it does — phase 1
   and phase 2 track each other at a roughly constant ratio across all eight points. The control
   that still holds is the generator's digest gate: the four files at a level provably carry the
   same numbers. Replaced by the bytes/row fit above, whose rms **is** the check.
2. **Test 3 — the flatness check moved from phase 2 to phase 1.** Phase 2 is host-fed here, so it
   legitimately scales; phase 1 runs before any scan thread exists and therefore must not move. The
   `--no-taskset` sweep is what established this rather than assuming it.

## Sanity checklist before sending results

- [ ] Every point reported the exact expected flag count on **all 7** iterations (`flags_ok=1`).
- [ ] Test 1: `min_group % 8 == 0` and identical encoding on all 9 files; Σx² headroom ≥ 2× each.
- [ ] Test 4: the digest gate said `ALL GATES PASS` — the four files at each level provably hold
      the same numbers — and the dictionary's byte effect changed sign between the levels.
- [ ] Test 4: phase 2 is flat within each level (< 10% spread). If not, **stop** and re-check the
      generator's digest gate first.
- [ ] Test 3: phase 2 is flat across thread counts; the core plan is printed in the log.
- [ ] Test 3 at `threads=32` reproduces Test 1's 20M row within ~15%.
- [ ] No number quoted without its encoding and compression.
- [ ] The offload claim says "N× fewer CPU-seconds", never "zero host CPU".

## Deliverables

`size_sweep.csv`, `codec_sweep.csv`, `thread_sweep_{balanced,knee}.csv` (the roadmap's exact column
names), plus each generator's `manifest.csv`, the run logs including the printed gates, and the
node name and bitstream each test ran on.
