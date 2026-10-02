#!/bin/bash
#
# TEST 1 -- SIZE SWEEP.  Synthetic INT32 columns, 1M..100M rows, with EVERYTHING except the row
# count held constant.
#
# ---------------------------------------------------------------------------------------------
# WHY THE VALUE SPACE IS 1/4 OF THE ROADMAP'S
# ---------------------------------------------------------------------------------------------
# The joint-paper roadmap generates base values in [0, 1e6) with outliers at +5e6, as INT64. Two
# things make that unusable here:
#
#   1. z_score_squared.sv is ELEM_BITS=32 and ZScoreBind rejects anything but INT32, so the column
#      must be INTEGER, not BIGINT.
#   2. Pass 1 accumulates Sum(x^2) into a SIGNED 64-BIT register that wraps silently. The roadmap's
#      constants give E[x^2] = 3.633e11 per element, so a 100M-row file needs 3.63e19 -- 3.94x over
#      the 9.223e18 the register holds. That recipe overflows from ~26M rows upward.
#
# z-score is scale-invariant, so dividing every value by 4 preserves EVERY ratio in the roadmap's
# gap argument exactly, while Sum(x^2) -- which scales with the SQUARE -- drops 16x:
#
#     base [0, 250000)   outliers +1,250,000   threshold(k=3) = 373,000
#     base tops out at 250,000 = 1.49x BELOW the threshold   (roadmap: 1.49x)
#     outliers start at 1,250,000 = 3.35x ABOVE it           (roadmap: 3.35x)
#     lower threshold is negative, so no base row is ever flagged low
#     Sum(x^2) at 100M rows = 2.27e18 = 25% of the register  (4.06x of headroom)
#
# Any threshold anywhere in [250000, 1250000] gives the identical answer, so no quantisation or
# precision effect in the hardware's fence can flip a single verdict.
#
#     EXPECTED FLAGS = rows / 1000, EXACTLY, at every point.
#
# The SUMSQ gate below MEASURES Sum(x^2) per file rather than trusting this comment.
#
# Usage:
#   ./gen_size_sweep.sh            generate (skips files that already exist; FORCE=1 to rewrite)
#   ./gen_size_sweep.sh verify     re-print the manifest and re-run the gates, generating nothing
set -u

DB="${DB:-$HOME/duckdb-bench41}"
DS="${DS:-$HOME/bench/microbench/sizesweep}"
export LD_LIBRARY_PATH="$HOME/opt/lib:$HOME/opt/jemalloc/lib:${LD_LIBRARY_PATH:-}"

SIZES="${SIZES:-1 3 6 10 20 40 60 80 100}"     # millions of rows
COL="${COL:-x}"                                # column name, matching the rest of benchmark/
CARD="${CARD:-250000}"                         # distinct base values, FIXED across the sweep
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"         # 0.1% -> expected flags = rows/1000
OUTLIER_OFFSET="${OUTLIER_OFFSET:-1250000}"    # lands far outside the threshold, in an empty gap
RGS="${RGS:-122880}"                           # row-group size; a multiple of 8 AND of 16
MANIFEST="$DS/manifest.csv"

# Signed 64-bit: what pass 1's sum_square_reg holds before it wraps.
SUMSQ_LIMIT=9223372036854775807

mkdir -p "$DS"
[[ -x "$DB" ]] || { echo "duckdb not found: $DB  (set DB=...)" >&2; exit 2; }
(( RGS % 8 == 0 )) || { echo "ROW_GROUP_SIZE $RGS is not a multiple of 8 -- refusing" >&2; exit 2; }

write_manifest() {
	echo "file,rows,bytes,bytes_per_row,encodings,groups,min_group,min_group_mod8,coltype,distinct,sum_square,expected_flags" > "$MANIFEST"
	for m in $SIZES; do
		f="$DS/size_${m}M.parquet"; [[ -f "$f" ]] || continue
		rows=$(( m * 1000000 )); bytes=$(stat -c %s "$f")
		bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$rows}")
		# sum_square is EXACT (HUGEINT accumulation), not the footer's worst-case bound: the bound
		# assumes every row carries max|x| and is 100x pessimistic on data with rare spikes.
		row=$($DB -noheader -list -c "
			SELECT (SELECT string_agg(DISTINCT encodings,'+') FROM parquet_metadata('$f')) || ',' ||
			       (SELECT count(*)            FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values)     FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
			       (SELECT string_agg(DISTINCT type,'+')      FROM parquet_metadata('$f')) || ',' ||
			       (SELECT approx_count_distinct($COL)        FROM read_parquet('$f')) || ',' ||
			       (SELECT sum($COL::HUGEINT * $COL::HUGEINT) FROM read_parquet('$f'));") || row=",,,,,,"
		echo "$f,$rows,$bytes,$bpr,$row,$(( rows / OUTLIER_EVERY ))" >> "$MANIFEST"
	done
	column -s, -t "$MANIFEST"
}

check_gates() {
	SUMSQ_LIMIT="$SUMSQ_LIMIT" python3 - "$MANIFEST" <<-'PY'
	import csv, os, sys
	rows = list(csv.DictReader(open(sys.argv[1])))
	limit = int(os.environ["SUMSQ_LIMIT"])
	ok = True
	def bad(m):
	    global ok; ok = False; print(f"  FAIL  {m}")

	if not rows:
	    bad("manifest empty -- nothing was generated")

	# 1. Streaming's ragged guard: a non-final row group whose num_values is not a multiple of 8
	#    changes the host's code path mid-sweep.
	for r in rows:
	    if r["min_group_mod8"] != "0":
	        bad(f"{os.path.basename(r['file'])}: min_group%8={r['min_group_mod8']}")

	# 2. Encoding must be IDENTICAL across the sweep, or a size sweep is secretly an encoding sweep.
	encs = {r["encodings"] for r in rows}
	if len(encs) != 1:
	    bad(f"encoding differs across the sweep: {sorted(encs)}")

	# 3. INT32 only -- the hardware datapath has no other width.
	types = {r["coltype"] for r in rows}
	if types != {"INT32"}:
	    bad(f"column physical type must be INT32 everywhere, got {sorted(types)}")

	# 4. No compressibility drift: byte volume must be exactly linear in N.
	bprs = sorted(float(r["bytes_per_row"]) for r in rows)
	if bprs and (bprs[-1] - bprs[0]) > 0.02 * bprs[0]:
	    bad(f"bytes/row drifts across the sweep: {bprs[0]:.2f} .. {bprs[-1]:.2f}")

	# 5. OUR gate, not the roadmap's: the real Sum(x^2) must fit the 64-bit accumulator with room.
	#    Phase 1 throws if it does not, so a failure here is a refused query, not a wrong number.
	for r in rows:
	    try:
	        ssq = int(r["sum_square"])
	    except ValueError:
	        bad(f"{os.path.basename(r['file'])}: no sum(x^2) measured"); continue
	    head = limit / ssq if ssq else float("inf")
	    tag = "ok" if head >= 2.0 else ("TIGHT" if head >= 1.0 else "OVERFLOW")
	    print(f"  sum(x^2) {os.path.basename(r['file']):<20} {ssq:>22}  headroom {head:6.2f}x  {tag}")
	    if head < 1.0:
	        bad(f"{os.path.basename(r['file'])}: sum(x^2) exceeds the 64-bit accumulator")
	    elif head < 2.0:
	        bad(f"{os.path.basename(r['file'])}: sum(x^2) headroom {head:.2f}x is under 2x -- rescale")

	print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
	sys.exit(0 if ok else 1)
	PY
}

if [[ "${1:-}" == "verify" ]]; then write_manifest; check_gates; exit $?; fi

for m in $SIZES; do
	rows=$(( m * 1000000 )); f="$DS/size_${m}M.parquet"
	if [[ -f "$f" && -z "${FORCE:-}" ]]; then echo "  $(basename "$f") exists -- skipping"; continue; fi
	echo "  writing size_${m}M.parquet ($rows rows) ..."
	# Written to .partial and renamed on success: an interrupted write otherwise leaves a TRUNCATED
	# parquet that the "exists -> skip" branch silently accepts on the next run.
	tmp="$f.partial"; rm -f "$tmp"
	# hash(i), NOT i*PRIME: a multiplicative step has period exactly CARD, which lets Snappy compress
	# the large files unusually well and drifts bytes/row across the sweep (gate 4).
	$DB -c "
		COPY (SELECT ((hash(i) % $CARD)
		             + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END)::INTEGER AS $COL
		      FROM range($rows) t(i))
		TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS);" \
		&& mv -f "$tmp" "$f" || { echo "  !! failed on ${m}M" >&2; rm -f "$tmp"; exit 1; }
done

write_manifest
check_gates
