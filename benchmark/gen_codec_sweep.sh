#!/bin/bash
#
# TEST 4 -- COMPRESSION & ENCODING SENSITIVITY, plus the Test 3 "knee" control file.
#
# 8 files holding provably THE SAME 20 million numbers in 8 different on-disk representations, so
# any difference in operator time is attributable to the representation and nothing else. The
# decoder is shared with the IQR half of the paper, so this panel characterises the substrate both
# operators sit behind.
#
# ---------------------------------------------------------------------------------------------
# THE DESIGN PROBLEM, AND WHY THERE ARE TWO CARDINALITY LEVELS
# ---------------------------------------------------------------------------------------------
# A naive 2x2 (PLAIN/dictionary x raw/Snappy) CANNOT separate "dictionary decoding costs more per
# element" from "dictionary moved fewer bytes", because at ordinary cardinalities dictionary always
# means fewer bytes. The fix is to replicate at two cardinalities chosen so the dictionary's byte
# effect CHANGES SIGN:
#
#   lo (10,000 distinct)   dictionary SHRINKS the file  (~1.9x)
#   hi (400,000 distinct)  dictionary GROWS  the file  (~1.4x)
#
# Why a dictionary can make a file BIGGER: parquet dictionaries are per ROW GROUP. At 122,880 rows
# per group drawn from 400,000 distinct values, a group holds ~106,000 dictionary entries --
# essentially a second copy of the data. Counter-intuitive, legal, inside the hardware's 524,288
# entry bound (ID_BITS=19), and exactly what makes the design identifiable.
#
# Cardinality is NOT an axis under test here. It is the lever that de-collinearises the design.
#
# ---------------------------------------------------------------------------------------------
# THE VALUE SPACE
# ---------------------------------------------------------------------------------------------
# The roadmap's Test 4 constants (RANGE 1e7, outliers +5e7) need Sum(x^2) = 7.3e21 at 20M rows,
# 790x what pass 1's signed 64-bit accumulator holds. Scaled by 1/20 -- z-score is scale-invariant,
# so every ratio is preserved and only the square shrinks:
#
#     RANGE 500,000   outliers +2,500,000   threshold(k=3) = 746,200
#     base tops out 1.49x BELOW it, outliers start 3.35x ABOVE it   (identical to the roadmap)
#     Sum(x^2) = 1.82e18 = 20% of the accumulator (5.1x of headroom)
#     EXPECTED FLAGS = 20,000 in every one of the 8 files
#
# PERM = 2654435761 is a multiplicative permutation and it matters. It is odd and not divisible by
# 5, so gcd(PERM, 500000) = 1 and level*PERM mod 500000 is a BIJECTION: exactly CARD levels with
# the low bits fully spread. A "tidy" step such as RANGE/CARD leaves trailing zero bits on every
# value, which imbalances a radix/hash-partitioning baseline by an amount that VARIES WITH
# CARDINALITY -- the roadmap hit exactly that and it manufactured a smooth, entirely fake CPU trend.
#
# Usage:
#   ./gen_codec_sweep.sh           generate the 8 codec files + the knee control
#   ./gen_codec_sweep.sh verify    re-print the manifest and re-run the gates, generating nothing
set -u

DB="${DB:-$HOME/duckdb-bench41}"
DS="${DS:-$HOME/bench/microbench/codecsweep}"
KNEE_DS="${KNEE_DS:-$HOME/bench/microbench/knee}"
export LD_LIBRARY_PATH="$HOME/opt/lib:$HOME/opt/jemalloc/lib:${LD_LIBRARY_PATH:-}"

ROWS="${ROWS:-20000000}"                       # FIXED. 20M == Test 3's `balanced` point.
COL="${COL:-x}"
RANGE="${RANGE:-500000}"                       # FIXED value range -> the threshold never moves
PERM="${PERM:-2654435761}"                     # coprime with RANGE -> bijection (see above)
OUTLIER_EVERY="${OUTLIER_EVERY:-1000}"
OUTLIER_OFFSET="${OUTLIER_OFFSET:-2500000}"
RGS="${RGS:-122880}"
CARD_LO="${CARD_LO:-10000}"                    # dictionary shrinks the file
CARD_HI="${CARD_HI:-400000}"                   # dictionary GROWS the file (pathological but legal)
DICT_OFF=0
DICT_ON="${DICT_ON:-104857600}"                # 100 MiB: keeps the writer building a dictionary
                                               # instead of giving up at its ~128 KB default
KNEE_ROWS="${KNEE_ROWS:-10000000}"
KNEE_CARD="${KNEE_CARD:-100000}"

MANIFEST="$DS/manifest.csv"
SUMSQ_LIMIT=9223372036854775807

mkdir -p "$DS" "$KNEE_DS"
[[ -x "$DB" ]] || { echo "duckdb not found: $DB  (set DB=...)" >&2; exit 2; }
(( RGS % 8 == 0 )) || { echo "ROW_GROUP_SIZE $RGS is not a multiple of 8 -- refusing" >&2; exit 2; }
(( CARD_HI <= RANGE )) || { echo "CARD_HI $CARD_HI exceeds RANGE $RANGE -- not a bijection" >&2; exit 2; }

levels() { echo "lo:$CARD_LO hi:$CARD_HI"; }

# The value expression, shared by the codec files and the knee control so they cannot drift apart.
value_expr() { # $1 = cardinality
	echo "((((hash(i) % $1) * $PERM) % $RANGE) + CASE WHEN i % $OUTLIER_EVERY = 0 THEN $OUTLIER_OFFSET ELSE 0 END)::INTEGER"
}

write_manifest() {
	echo "level,card,enc_intent,compression,file,rows,bytes,bytes_per_row,encodings,groups,min_group,min_group_mod8,coltype,digest_count,digest_sum,digest_hash,distinct,sum_square" > "$MANIFEST"
	for lv in $(levels); do
		name="${lv%%:*}"; card="${lv##*:}"
		for enc in plain dict; do for comp in uncompressed snappy; do
			f="$DS/codec_${name}_${enc}_${comp}.parquet"; [[ -f "$f" ]] || continue
			bytes=$(stat -c %s "$f"); bpr=$(awk "BEGIN{printf \"%.2f\", $bytes/$ROWS}")
			# digest_* = ORDER-INDEPENDENT fingerprint of the value multiset. All four files at a
			# level must agree, or "only the representation changed" is FALSE and the sweep is void.
			row=$($DB -noheader -list -c "
				SELECT (SELECT string_agg(DISTINCT encodings,'+') FROM parquet_metadata('$f')) || ',' ||
				       (SELECT count(*)            FROM parquet_metadata('$f')) || ',' ||
				       (SELECT min(num_values)     FROM parquet_metadata('$f')) || ',' ||
				       (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
				       (SELECT string_agg(DISTINCT type,'+') FROM parquet_metadata('$f')) || ',' ||
				       (SELECT count(*)                     FROM read_parquet('$f')) || ',' ||
				       (SELECT sum($COL)::HUGEINT           FROM read_parquet('$f')) || ',' ||
				       (SELECT sum(hash($COL))::HUGEINT     FROM read_parquet('$f')) || ',' ||
				       (SELECT approx_count_distinct($COL)  FROM read_parquet('$f')) || ',' ||
				       (SELECT sum($COL::HUGEINT * $COL::HUGEINT) FROM read_parquet('$f'));") \
				|| row=",,,,,,,,,"
			echo "$name,$card,$enc,$comp,$f,$ROWS,$bytes,$bpr,$row" >> "$MANIFEST"
		done; done
	done
	column -s, -t "$MANIFEST"
}

check_gates() {
	SUMSQ_LIMIT="$SUMSQ_LIMIT" python3 - "$MANIFEST" <<-'PY'
	import csv, itertools, os, sys
	rows = list(csv.DictReader(open(sys.argv[1])))
	limit = int(os.environ["SUMSQ_LIMIT"])
	ok = True
	def bad(m):
	    global ok; ok = False; print(f"  FAIL  {m}")
	def base(r):
	    return os.path.basename(r["file"])

	if not rows:
	    bad("manifest empty -- nothing was generated")

	for r in rows:
	    encs = (r["encodings"] or "").upper()
	    # What was asked for must be what landed on disk. DuckDB silently abandons a dictionary when
	    # it outgrows the limit, and an encoding flip mid-sweep wears another variable's costume.
	    if (r["enc_intent"] == "dict") != ("DICTIONARY" in encs):
	        bad(f"{base(r)}: asked {r['enc_intent']}, got [{encs}]")
	    if r["min_group_mod8"] != "0":
	        bad(f"{base(r)}: min_group%8={r['min_group_mod8']} (streaming rejected)")
	    if r["coltype"] != "INT32":
	        bad(f"{base(r)}: physical type {r['coltype']}, the datapath is INT32 only")
	    # The decoder supports RAW and SNAPPY only -- no ZSTD/GZIP/LZ4/Brotli.
	    if r["compression"] not in ("uncompressed", "snappy"):
	        bad(f"{base(r)}: compression outside the supported RAW/SNAPPY envelope")

	# THE decisive gate: within a level, all four files must hold the same numbers.
	for lv, grp in itertools.groupby(sorted(rows, key=lambda r: r["level"]), key=lambda r: r["level"]):
	    grp = list(grp)
	    for key in ("digest_count", "digest_sum", "digest_hash"):
	        if len({r[key] for r in grp}) != 1:
	            bad(f"level {lv}: {key} differs -> the files do NOT hold the same column, so the "
	                f"second-pass control is meaningless and the sweep is INVALID")
	    if len(grp) != 4:
	        bad(f"level {lv}: expected 4 files, found {len(grp)}")

	# OUR gate: the real Sum(x^2) must fit the 64-bit accumulator. Phase 1 throws if it does not.
	for r in rows:
	    try:
	        ssq = int(r["sum_square"])
	    except ValueError:
	        bad(f"{base(r)}: no sum(x^2) measured"); continue
	    head = limit / ssq if ssq else float("inf")
	    if head < 1.0:
	        bad(f"{base(r)}: sum(x^2)={ssq} exceeds the 64-bit accumulator ({head:.2f}x)")
	    elif head < 2.0:
	        bad(f"{base(r)}: sum(x^2) headroom {head:.2f}x is under 2x -- rescale")

	# The point of the design: the dictionary's byte effect must change SIGN between the levels.
	# If it does not, the encoding and byte-volume terms stay collinear and the panel proves nothing.
	for lv in ("lo", "hi"):
	    grp = [r for r in rows if r["level"] == lv and r["compression"] == "uncompressed"]
	    b = {r["enc_intent"]: float(r["bytes_per_row"]) for r in grp}
	    if {"plain", "dict"} <= b.keys():
	        ratio = b["dict"] / b["plain"]
	        print(f"  level {lv}: dict/plain bytes-per-row = {ratio:.2f}x "
	              f"({'shrinks' if ratio < 1 else 'GROWS'} the file)")
	        if lv == "lo" and ratio >= 1.0:
	            bad("level lo: the dictionary was supposed to SHRINK the file")
	        if lv == "hi" and ratio <= 1.0:
	            bad("level hi: the dictionary was supposed to GROW the file -- raise CARD_HI")

	print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
	sys.exit(0 if ok else 1)
	PY
}

if [[ "${1:-}" == "verify" ]]; then write_manifest; check_gates; exit $?; fi

for lv in $(levels); do
	name="${lv%%:*}"; card="${lv##*:}"
	for enc in plain dict; do
		[[ "$enc" == plain ]] && dl=$DICT_OFF || dl=$DICT_ON
		for comp in uncompressed snappy; do
			[[ "$comp" == uncompressed ]] && COMP=UNCOMPRESSED || COMP=SNAPPY
			f="$DS/codec_${name}_${enc}_${comp}.parquet"
			[[ -f "$f" && -z "${FORCE:-}" ]] && { echo "  $(basename "$f") exists -- skipping"; continue; }
			echo "  writing $(basename "$f")  (card=$card, DICTIONARY_SIZE_LIMIT=$dl, $COMP) ..."
			tmp="$f.partial"; rm -f "$tmp"
			$DB -c "
				COPY (SELECT $(value_expr "$card") AS $COL FROM range($ROWS) t(i))
				TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
				           DICTIONARY_SIZE_LIMIT $dl, COMPRESSION $COMP);" \
				&& mv -f "$tmp" "$f" || { echo "  !! failed at $f" >&2; rm -f "$tmp"; exit 1; }
		done
	done
done

# ---- Test 3's control dataset ------------------------------------------------------------------
# Same value recipe, 10M rows at cardinality 100,000, PLAIN + SNAPPY. If Test 3's conclusion also
# holds here it is architectural rather than an artefact of one file.
knee="$KNEE_DS/card_${KNEE_CARD}.parquet"
if [[ -f "$knee" && -z "${FORCE:-}" ]]; then
	echo "  $(basename "$knee") exists -- skipping"
else
	echo "  writing $(basename "$knee")  ($KNEE_ROWS rows, card=$KNEE_CARD) ..."
	tmp="$knee.partial"; rm -f "$tmp"
	$DB -c "
		COPY (SELECT $(value_expr "$KNEE_CARD") AS $COL FROM range($KNEE_ROWS) t(i))
		TO '$tmp' (FORMAT PARQUET, ROW_GROUP_SIZE $RGS,
		           DICTIONARY_SIZE_LIMIT $DICT_OFF, COMPRESSION SNAPPY);" \
		&& mv -f "$tmp" "$knee" || { echo "  !! failed at $knee" >&2; rm -f "$tmp"; exit 1; }
fi

write_manifest
check_gates
