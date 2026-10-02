#!/bin/bash
#
# TEST 5 -- DISTRIBUTION SHAPE / SKEW.  A CONTROL, NOT A PANEL.
#
# This does not produce a figure. Its job is to DEFEND Tests 1/3/4, all of which run on uniform
# synthetic data, against the obvious objection: "real data is skewed, so your numbers don't
# transfer." Budget two sentences and a small table.
#
# ---------------------------------------------------------------------------------------------
# WHAT VARIES AND WHAT IS PINNED
# ---------------------------------------------------------------------------------------------
# The axis is the SHAPE of the value distribution. Everything else is fixed by construction:
#
#   rows            20,000,000 -- the same i-range everywhere
#   cardinality     20,000 distinct EXACTLY. r = (i*PERM) mod N is a BIJECTION and CARD divides N,
#                   so every level gets exactly N/CARD = 1000 rows. NOT hash() -- hash leaves
#                   coupon-collector holes and the distinct count would drift with the sweep.
#   frequency       perfectly flat over levels => the skew lives entirely in the value SPACING,
#                   i.e. a genuine sample from a continuous right-skewed law, not a
#                   frequency-imbalance artefact.
#   bytes/row       exactly 4.00 -- PLAIN + UNCOMPRESSED. All six files coming out byte-identical
#                   in size IS the proof.
#   row groups      122,880, all %8 == 0.
#
# Value construction, where `a` is the skew knob and the MEASURED skewness is the reported axis:
#
#   level = ((i*PERM) mod N) mod CARD          PERM = 2654435761
#   u     = (level + 1) / CARD
#   w(u)  = u                              if a = 0   (uniform)
#         = (exp(a*u) - 1)/(exp(a) - 1)    otherwise  (right-skewed)
#   V     = level + round(S * w(u))        strictly increasing => injective => cardinality survives
#   value = V + (OFFSET on the planted rows)
#
# The `+ level` term is what guarantees injectivity: without it round() collapses thousands of low
# levels onto 0 at high `a` and the cardinality control dies silently.
#
# ---------------------------------------------------------------------------------------------
# THREE ADAPTATIONS
# ---------------------------------------------------------------------------------------------
# 1. NO power-of-two bin-width normalisation. That confound is IQR-specific: it comes from a
#    histogram whose bin width is rounded up to a power of two. A z-score fence at mean +- k*sigma
#    does not quantise, so there is nothing to normalise. (The roadmap says so explicitly.)
#
# 2. SCALE. The roadmap's CARD=1.02e6 with S=9e6 needs Sum(x^2) ~ 5e20, 55x over our signed 64-bit
#    accumulator. Ours is CARD=20,000 with S=700,000: Sum(x^2) peaks at ~3.8e18 (a=0 is the worst
#    case, since right-skew moves mass DOWN), leaving 2.4x of headroom. Lowering CARD rather than S
#    is deliberate -- skew needs S >> CARD or the uniform `+level` term dilutes the shape away.
#
# 3. THE OUTLIER SELECTION RULE IS `r < CARD`, on the PERMUTED index, never on `i`. Selecting with
#    `i % 1000 == 0` makes (i*PERM) mod N a multiple of 1000 and `mod CARD` then leaves only whole
#    levels -- which vanish from the base while the distinct count still reads plausibly. `r < CARD`
#    takes exactly ONE row from each of the 20,000 levels: 20,000 planted rows = rows/1000, and
#    every level keeps its other 999.
#
# ---------------------------------------------------------------------------------------------
# WHY THE EXPECTED COUNT IS MEASURED, NOT ASSUMED
# ---------------------------------------------------------------------------------------------
# Planted outliers sit in an empty gap, as in every other test. But a right-skewed distribution
# concentrates mass low, which SHRINKS sigma and pulls the fence DOWN -- so at high skew the base
# distribution's own upper tail crosses mean + 3*sigma. That is a property of a non-robust fence,
# not a bug, and it is the substance of the joint "why offer both operators" figure.
# So this generator computes the expected count FROM THE WRITTEN FILE using the CPU rule, and
# records the planted count separately. The harness gates FPGA against the measured expectation.
#
# Usage:
#   ./gen_skew_sweep.sh plan      print the plan (a values, constants, budget). Writes nothing.
#   ./gen_skew_sweep.sh           6 files
#   ./gen_skew_sweep.sh verify    re-print the manifest and re-run the gates
set -u

DB="${DB:-$HOME/duckdb-bench41}"
DS="${DS:-$HOME/bench/microbench/skew}"
export LD_LIBRARY_PATH="$HOME/opt/lib:$HOME/opt/jemalloc/lib:${LD_LIBRARY_PATH:-}"

ROWS="${ROWS:-20000000}"
COL="${COL:-x}"
CARD="${CARD:-20000}"                 # must DIVIDE ROWS -> exactly ROWS/CARD rows per level
PERM="${PERM:-2654435761}"            # odd, not divisible by 5 -> coprime with ROWS -> bijection
SPREAD="${SPREAD:-700000}"            # S: the value spread the shape is painted onto
OUTLIER_OFFSET="${OUTLIER_OFFSET:-3600000}"   # 5x the maximum base value
RGS="${RGS:-122880}"
AVALUES="${AVALUES:-0 2 4 6 8 12}"
K="${K:-3}"
MANIFEST="$DS/manifest.csv"
SUMSQ_LIMIT=9223372036854775807

mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found: $DB  (set DB=...)" >&2; exit 2; }
(( ROWS % CARD == 0 )) || { echo "CARD $CARD must divide ROWS $ROWS -- refusing" >&2; exit 2; }
(( RGS % 8 == 0 )) || { echo "ROW_GROUP_SIZE $RGS not a multiple of 8 -- refusing" >&2; exit 2; }

# The value expression for a given `a`. Written once so the plan, the files and the manifest can
# never describe different data.
value_expr() { # $1 = a
	local a="$1"
	local w
	if [[ "$a" == 0 ]]; then
		w="((r % $CARD) + 1.0) / $CARD"
	else
		w="(exp($a * (((r % $CARD) + 1.0) / $CARD)) - 1) / (exp($a) - 1)"
	fi
	echo "((r % $CARD) + round($SPREAD * ($w)) + CASE WHEN r < $CARD THEN $OUTLIER_OFFSET ELSE 0 END)::INTEGER"
}

# r = the PERMUTED index. i*PERM peaks at 5.3e16 for 20M rows, comfortably inside BIGINT.
source_cte() { echo "WITH t AS (SELECT ((i * $PERM) % $ROWS) AS r FROM range($ROWS) t(i))"; }

plan() {
	echo "rows            $ROWS"
	echo "cardinality     $CARD  (exactly $(( ROWS / CARD )) rows per level)"
	echo "spread S        $SPREAD   -> max base value $(( CARD - 1 + SPREAD ))"
	echo "outlier offset  $OUTLIER_OFFSET  (planted rows = r < CARD = $CARD = rows/1000)"
	echo "a values        $AVALUES"
	echo "row groups      $RGS   encoding PLAIN + UNCOMPRESSED -> 4.00 bytes/row expected"
	echo
	echo "a=0 is the Sum(x^2) worst case: right-skew moves mass DOWN, so if a=0 fits, all fit."
	echo "Nothing is written by 'plan'."
}

write_manifest() {
	echo "a,file,rows,bytes,bytes_per_row,encodings,groups,min_group,min_group_mod8,coltype,distinct,skewness,kurtosis,sum_square,planted,expected_flags" > "$MANIFEST"
	for a in $AVALUES; do
		f="$DS/skew_a${a}.parquet"; [[ -f "$f" ]] || continue
		bytes=$(stat -c %s "$f"); bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$ROWS}")
		# expected_flags is MEASURED with the CPU rule, because at high skew the natural tail
		# crosses the fence and rows/1000 stops being the right answer.
		row=$($DB -noheader -list -c "
			SELECT (SELECT string_agg(DISTINCT encodings,'+') FROM parquet_metadata('$f')) || ',' ||
			       (SELECT count(*)            FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values)     FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
			       (SELECT string_agg(DISTINCT type,'+') FROM parquet_metadata('$f')) || ',' ||
			       (SELECT count(DISTINCT $COL)  FROM read_parquet('$f')) || ',' ||
			       (SELECT printf('%.4f', skewness($COL::DOUBLE)) FROM read_parquet('$f')
			        WHERE $COL < $OUTLIER_OFFSET) || ',' ||
			       (SELECT printf('%.4f', kurtosis($COL::DOUBLE)) FROM read_parquet('$f')
			        WHERE $COL < $OUTLIER_OFFSET) || ',' ||
			       (SELECT sum($COL::HUGEINT * $COL::HUGEINT) FROM read_parquet('$f')) || ',' ||
			       (SELECT count(*) FROM read_parquet('$f') WHERE $COL >= $OUTLIER_OFFSET) || ',' ||
			       (WITH s AS (SELECT avg($COL::DOUBLE) m, stddev_pop($COL::DOUBLE) sd
			                   FROM read_parquet('$f'))
			        SELECT count(*) FROM read_parquet('$f'), s
			        WHERE abs(($COL::DOUBLE - m) / s.sd) > $K);") || row=",,,,,,,,,,"
		echo "$a,$f,$ROWS,$bytes,$bpr,$row" >> "$MANIFEST"
	done
	column -s, -t "$MANIFEST"
}

check_gates() {
	SUMSQ_LIMIT="$SUMSQ_LIMIT" CARD="$CARD" PLANTED="$CARD" python3 - "$MANIFEST" <<-'PY'
	import csv, os, sys
	rows = list(csv.DictReader(open(sys.argv[1])))
	limit, card, planted = (int(os.environ[k]) for k in ("SUMSQ_LIMIT", "CARD", "PLANTED"))
	ok = True
	def bad(m):
	    global ok; ok = False; print(f"  FAIL  {m}")

	if not rows:
	    bad("manifest empty")

	# The controls. Cardinality, byte volume and geometry must be IDENTICAL across the sweep, or
	# the axis is not shape alone and the whole point of the test is gone.
	#
	# Expected distinct = CARD + planted. Every one of the CARD levels keeps its other N/CARD - 1
	# base rows, and each planted row is that level's value shifted by OFFSET -- so the planted rows
	# contribute a SECOND block of CARD distinct values rather than reusing existing ones. What the
	# control requires is that this number is the same at every `a`, which it is; the absolute value
	# is arithmetic, not a free parameter.
	expected_distinct = card + planted
	for r in rows:
	    if int(r["distinct"]) != expected_distinct:
	        bad(f"a={r['a']}: distinct {r['distinct']} != {expected_distinct} (= CARD {card} + "
	            f"planted {planted}) -- the bijection broke, so the cardinality control is dead")
	    if r["min_group_mod8"] != "0":
	        bad(f"a={r['a']}: min_group%8={r['min_group_mod8']}")
	    if r["coltype"] != "INT32":
	        bad(f"a={r['a']}: physical type {r['coltype']}, the datapath is INT32 only")
	    if int(r["planted"]) != planted:
	        bad(f"a={r['a']}: {r['planted']} planted rows, expected {planted}")
	# Skewness and kurtosis are measured on the BASE rows only. Including the planted outliers
	# would let 0.1% of the rows dominate the statistic -- it reads ~3.5 at a=0, which is the
	# contamination, not the shape. a=0 is the construction's own sanity check: a uniform
	# distribution has skewness 0 and excess kurtosis exactly -1.2.
	base = next((r for r in rows if r["a"] == "0"), None)
	if base:
	    sk, ku = float(base["skewness"]), float(base["kurtosis"])
	    if abs(sk) > 0.01 or abs(ku + 1.2) > 0.02:
	        bad(f"a=0 measures skewness {sk} / excess kurtosis {ku}; a uniform distribution must "
	            f"give 0.00 / -1.20, so the value construction is not what it claims")

	bprs = {r["bytes_per_row"] for r in rows}
	if len(bprs) != 1:
	    bad(f"bytes/row differs across the sweep: {sorted(bprs)} -- byte volume is not pinned")
	encs = {r["encodings"] for r in rows}
	if len(encs) != 1:
	    bad(f"encoding differs across the sweep: {sorted(encs)}")

	for r in rows:
	    ssq = int(r["sum_square"])
	    head = limit / ssq if ssq else float("inf")
	    nat = int(r["expected_flags"]) - planted
	    print(f"  a={r['a']:>3}  skew {float(r['skewness']):6.3f}  kurt {float(r['kurtosis']):7.3f}  "
	          f"distinct {r['distinct']}  {r['bytes_per_row']} B/row  "
	          f"sum(x^2) headroom {head:6.2f}x  expected {r['expected_flags']} "
	          f"(planted {planted} + natural {nat})")
	    if head < 1.0:
	        bad(f"a={r['a']}: sum(x^2) exceeds the 64-bit accumulator")
	    elif head < 2.0:
	        bad(f"a={r['a']}: sum(x^2) headroom {head:.2f}x is under 2x")

	# Natural tail crossings are EXPECTED at high skew and are a result, not a failure: a z-score
	# fence is not robust, so the tail inflates mean and sigma and eventually crosses itself.
	print("  note: 'natural' > 0 means the distribution's own tail crossed the fence -- expected at "
	      "high skew, and the reason expected_flags is measured rather than assumed")
	print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
	sys.exit(0 if ok else 1)
	PY
}

case "${1:-}" in
	plan)   plan; exit 0 ;;
	verify) write_manifest; check_gates; exit $? ;;
esac

for a in $AVALUES; do
	f="$DS/skew_a${a}.parquet"
	if [[ -f "$f" && -z "${FORCE:-}" ]]; then echo "  $(basename "$f") exists -- skipping"; continue; fi
	echo "  writing $(basename "$f")  (a=$a) ..."
	tmp="$f.partial"; rm -f "$tmp"
	$DB -c "
		COPY ($(source_cte) SELECT $(value_expr "$a") AS $COL FROM t)
		TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
		           DICTIONARY_SIZE_LIMIT 0, COMPRESSION UNCOMPRESSED);" \
		&& mv -f "$tmp" "$f" || { echo "  !! failed at a=$a" >&2; rm -f "$tmp"; exit 1; }
done

write_manifest
check_gates
