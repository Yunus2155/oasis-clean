#!/bin/bash
#
# TEST 0 -- THE REAL DATASETS.  Seven real columns, every property varying at once: the table a
# reviewer actually believes, and the one that says "this works on data we did not design."
#
# Tests 1/3/4/5 are synthetic and each isolates one variable. This is the opposite, so it is also
# the only test here with NO planted outliers -- which means the correctness target cannot be
# "rows/1000". It is the CPU reference count, which this script computes per file and writes into
# the manifest for the harness to gate against.
#
# ---------------------------------------------------------------------------------------------
# TWO DEVIATIONS FROM THE ROADMAP, BOTH FORCED, BOTH VISIBLE IN THE MANIFEST
# ---------------------------------------------------------------------------------------------
# 1. INT32, not BIGINT (`ELEM_BITS=32`), so `sum(hash(v))` cannot match the roadmap's digests --
#    DuckDB hashes an INTEGER and a BIGINT differently. `count(*)` and `sum(v)` DO match and are
#    checked; those are what prove the value multiset is the same.
#
# 2. Sum(x^2) must fit a signed 64-bit accumulator that wraps silently. The roadmap stores money in
#    CENTS. For TPC-H `l_extendedprice` that overflows outright: its own digest table gives
#    sum(v) = 2.296e13 over 6.0M rows, i.e. a mean of 3.83e6 cents, so Sum(x^2) >= 8.8e19 -- ~10x
#    the 9.22e18 limit at SF1 and ~100x at SF10. So the TPC-H money column is stored in WHOLE
#    DOLLARS and its digests deliberately do NOT match the roadmap's.
#    For the taxi column the answer is NOT obvious (small fares, a few huge ones), so this script
#    MEASURES it instead of assuming: `plan` computes the exact Sum(x^2) for cents and for dollars
#    and picks the finest scale with >= 2x of headroom.
#
# Row-group geometry is left at DuckDB's default and the source layout is inherited -- deliberately
# ragged, which is the point of the test. Unlike the roadmap's stack we have NO ragged guard in the
# host (nothing in zscore_scan.cpp keys off `num_values % 8`), and our existing real-data runs on
# build-41 reproduced exact counts on files built exactly this way. So Test 0 and Tests 1/3/4 take
# the SAME code path here. The manifest still records `min_group % 8` so the paper can state it.
#
# Usage:
#   ./gen_real.sh plan       measure Sum(x^2) at both scales and print the verdict. Writes nothing.
#   ./gen_real.sh            generate the seven datasets + manifest + gates
#   ./gen_real.sh verify     re-print the manifest and re-run the gates
set -u

DB="${DB:-$HOME/duckdb-bench41}"
SRC="${SRC:-$HOME/bench/taxi_raw}"          # the 12 monthly TLC files, already downloaded
DS="${DS:-$HOME/bench/microbench/real}"
WORK="${WORK:-$DS/.work}"
export LD_LIBRARY_PATH="$HOME/opt/lib:$HOME/opt/jemalloc/lib:${LD_LIBRARY_PATH:-}"

K="${K:-3}"                                  # |z| > K, matching the operator
SUMSQ_LIMIT=9223372036854775807
INT32_MAX=2147483647
MANIFEST="$DS/manifest.csv"

mkdir -p "$DS" "$WORK"
[[ -x "$DB" ]] || { echo "duckdb not found: $DB  (set DB=...)" >&2; exit 2; }

# The cumulative month ranges. Size grows while distribution shape stays essentially fixed, so the
# four taxi sets form a crude size series WITHIN the real-data table.
taxi_months() { # $1 = dataset name
	case "$1" in
		taxi_d1) echo "01" ;;
		taxi_d2) echo "01 02" ;;
		taxi_d3) echo "01 02 03 04" ;;
		taxi_d4) echo "01 02 03 04 05 06" ;;
	esac
}

taxi_files() { # $1 = dataset name -> a SQL list literal
	local out=""
	for m in $(taxi_months "$1"); do
		out="$out${out:+,}'$SRC/yellow_tripdata_2024-$m.parquet'"
	done
	echo "[$out]"
}

# fare_amount is a DOUBLE in dollars. NULLs are excluded: the column is fed to an integer datapath
# and a null would change the physical encoding (definition levels) rather than the value set. The
# count of dropped rows is printed, so the deviation from the roadmap's "no filtering" is visible
# and quantified rather than hidden.
taxi_expr() { # $1 = scale (100 = cents, 1 = whole dollars)
	if [[ "$1" == 100 ]]; then echo "round(fare_amount * 100)::INTEGER"; else echo "fare_amount::INTEGER"; fi
}

# ------------------------------------------------------------------------------------------ plan
plan() {
	echo "measuring Sum(x^2) on the SOURCE data -- nothing is written"
	printf "%-14s %6s %14s %24s %10s  %s\n" dataset scale rows "sum(x^2)" headroom verdict
	for d in taxi_d1 taxi_d2 taxi_d3 taxi_d4; do
		local files; files=$(taxi_files "$d")
		for s in 100 1; do
			local e; e=$(taxi_expr "$s")
			# max|x| is checked too: the datapath is INT32, so a value outside +-2^31-1 is fatal
			# regardless of what the accumulator can hold.
			local row
			row=$($DB -noheader -list -c "
				SELECT count(*) || ',' ||
				       sum(($e)::HUGEINT * ($e)::HUGEINT) || ',' ||
				       max(abs(($e)::HUGEINT))
				FROM read_parquet($files) WHERE fare_amount IS NOT NULL;") || row=",,"
			report_scale "$d" "$s" "$row"
		done
	done
	echo
	echo "TPC-H: l_extendedprice is stored in WHOLE DOLLARS by construction -- cents overflow by ~10x"
	echo "at SF1 and ~100x at SF10 (see the header). l_quantity is 1..50 and needs no scaling."
}

report_scale() { # $1 dataset $2 scale $3 "rows,sumsq,maxabs"
	local rows sumsq maxabs
	IFS=, read -r rows sumsq maxabs <<<"$3"
	SUMSQ_LIMIT="$SUMSQ_LIMIT" INT32_MAX="$INT32_MAX" python3 - "$1" "$2" "$rows" "$sumsq" "$maxabs" <<-'PY'
	import os, sys
	name, scale, rows, ssq, mx = sys.argv[1:6]
	limit, i32 = int(os.environ["SUMSQ_LIMIT"]), int(os.environ["INT32_MAX"])
	try:
	    ssq, mx, rows = int(ssq), int(mx), int(rows)
	except ValueError:
	    print(f"{name:<14} {scale:>6} {'?':>14} {'measurement failed':>24}"); sys.exit(0)
	head = limit / ssq if ssq else float("inf")
	v = "ok" if head >= 2.0 else ("TIGHT" if head >= 1.0 else "OVERFLOW")
	if mx > i32:
	    v += f" +INT32-OVERFLOW(max={mx})"
	print(f"{name:<14} {scale:>6} {rows:>14,} {ssq:>24,} {head:>9.2f}x  {v}")
	PY
}

# -------------------------------------------------------------------------------------- manifest
write_manifest() {
	echo "dataset,file,column,scale,rows,bytes,encodings,groups,min_group,min_group_mod8,coltype,distinct,digest_count,digest_sum,digest_hash,sum_square,cpu_outliers" > "$MANIFEST"
	for spec in "$@"; do
		local name="${spec%%:*}" col="${spec#*:}"; col="${col%%:*}"
		local scale="${spec##*:}"
		local f="$DS/$name.parquet"; [[ -f "$f" ]] || continue
		# -L follows the link: the TPCH_SF17 datasets are symlinks, and stat without it reports the
		# 45-byte link rather than the 408 MB file it points at.
		local bytes; bytes=$(stat -Lc %s "$f")
		# cpu_outliers = the whole-column z-score reference. Real data has no planted outliers, so
		# THIS is the correctness target the harness gates the FPGA against.
		local row
		row=$($DB -noheader -list -c "
			SELECT (SELECT string_agg(DISTINCT encodings,'+') FROM parquet_metadata('$f')) || ',' ||
			       (SELECT count(*)            FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values)     FROM parquet_metadata('$f')) || ',' ||
			       (SELECT min(num_values) % 8 FROM parquet_metadata('$f')) || ',' ||
			       (SELECT string_agg(DISTINCT type,'+') FROM parquet_metadata('$f')) || ',' ||
			       (SELECT approx_count_distinct($col) FROM read_parquet('$f')) || ',' ||
			       (SELECT count(*)                    FROM read_parquet('$f')) || ',' ||
			       (SELECT sum($col)::HUGEINT          FROM read_parquet('$f')) || ',' ||
			       (SELECT sum(hash($col))::HUGEINT    FROM read_parquet('$f')) || ',' ||
			       (SELECT sum($col::HUGEINT * $col::HUGEINT) FROM read_parquet('$f')) || ',' ||
			       (WITH s AS (SELECT avg($col::DOUBLE) m, stddev_pop($col::DOUBLE) sd
			                   FROM read_parquet('$f'))
			        SELECT count(*) FROM read_parquet('$f'), s
			        WHERE abs(($col::DOUBLE - m) / sd) > $K);") || row=",,,,,,,,,,"
		echo "$name,$f,$col,$scale,,$bytes,$row" >> "$MANIFEST"
	done
	# rows column is filled from digest_count, which is the authoritative read of the written file
	python3 - "$MANIFEST" <<-'PY'
	import csv, sys
	rows = list(csv.DictReader(open(sys.argv[1])))
	for r in rows:
	    r["rows"] = r["digest_count"]
	with open(sys.argv[1], "w", newline="") as fh:
	    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
	PY
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

	# The roadmap's section 3.5 reference digests. Order-independent fingerprints of the value
	# multiset: if these match, we have its exact data and the numbers are directly comparable.
	#   * sum(hash(v)) is NOT checked -- DuckDB hashes INTEGER and BIGINT differently and we store
	#     INT32, so it cannot match either way.
	#   * The two extprice sets store WHOLE DOLLARS (cents overflow the accumulator), so only their
	#     ROW COUNT is comparable; the reference sum is in cents and is shown for scale.
	# This doubles as the validation of `dbgen` itself: TPC-H SF1 is deterministic, so tpch_qty
	# matching exactly is what proves the tpch extension produced correct data despite being loaded
	# across a version-metadata mismatch.
	REFERENCE = {
	    "taxi_d1":            (2964624,  5388222476,      True),
	    "taxi_d2":            (5972150,  10815993187,     True),
	    "taxi_d3":            (13069067, 24176275770,     True),
	    "taxi_d4":            (20332093, 38401520485,     True),
	    "tpch_qty":           (6001215,  153078795,       True),
	    "tpch_extprice":      (6001215,  22957731090120,  False),
	    "tpch_extprice_sf10": (59986052, 229381315677336, False),
	}
	print(f"  {len(rows)} datasets present")
	print("  -- roadmap 3.5 reference digests --")
	for r in rows:
	    ref = REFERENCE.get(r["dataset"])
	    if not ref:
	        continue
	    want_rows, want_sum, sum_comparable = ref
	    got_rows, got_sum = int(r["digest_count"]), int(r["digest_sum"])
	    if got_rows != want_rows:
	        bad(f"{r['dataset']}: {got_rows:,} rows, the roadmap has {want_rows:,} -- this is NOT "
	            f"the same dataset")
	    if sum_comparable:
	        if got_sum != want_sum:
	            bad(f"{r['dataset']}: sum(v)={got_sum} != {want_sum}. For tpch_qty this means dbgen "
	                f"produced WRONG DATA -- suspect the version-mismatched tpch extension")
	        else:
	            print(f"  {r['dataset']:<20} rows and sum(v) MATCH the roadmap exactly")
	    else:
	        print(f"  {r['dataset']:<20} rows match; sum(v)={got_sum} is in WHOLE DOLLARS by design "
	              f"(roadmap {want_sum} is cents, which overflows the accumulator)")
	print("  -- gates --")
	for r in rows:
	    if r["coltype"] != "INT32":
	        bad(f"{r['dataset']}: physical type {r['coltype']}, the datapath is INT32 only")
	    try:
	        ssq = int(r["sum_square"])
	    except ValueError:
	        bad(f"{r['dataset']}: no sum(x^2) measured"); continue
	    head = limit / ssq if ssq else float("inf")
	    if head < 1.0:
	        bad(f"{r['dataset']}: sum(x^2)={ssq} exceeds the 64-bit accumulator ({head:.2f}x)")
	    elif head < 2.0:
	        bad(f"{r['dataset']}: sum(x^2) headroom {head:.2f}x is under 2x -- drop the scale")
	    print(f"  {r['dataset']:<20} rows {int(r['rows']):>12,}  scale {r['scale']:>3}  "
	          f"min_group%8 {r['min_group_mod8']:>1}  enc {r['encodings']:<32} "
	          f"sum(x^2) headroom {head:8.1f}x   cpu_outliers {r['cpu_outliers']}")
	# Ragged geometry is EXPECTED here and is the point of the test -- reported, never failed.
	ragged = [r["dataset"] for r in rows if r["min_group_mod8"] != "0"]
	print(f"  ragged (min_group%8 != 0): {', '.join(ragged) if ragged else 'none'} "
	      f"-- reported, not a failure: this host has no ragged guard")
	print("  ALL GATES PASS" if ok else "  >>> GATES FAILED -- do not run the benchmark <<<")
	sys.exit(0 if ok else 1)
	PY
}

# --------------------------------------------------------------------------------------- targets
# TAXI_SCALE=100 stores cents, 1 stores whole dollars. `plan` is what decides it -- run that first.
TAXI_SCALE="${TAXI_SCALE:-100}"
TAXI_COL="fare_cents"
[[ "$TAXI_SCALE" == 1 ]] && TAXI_COL="fare_dollars"

# TPCH_SF17=1 takes the TPC-H columns from the SF17 files already in ~/bench instead of running
# dbgen. Needed because the tpch extension cannot be loaded here at all: this fork's duckdb
# submodule carries no tags, so `git describe` is empty and the build reports version v0.0.1, while
# the cached extension is stamped v1.5.2. `allow_extensions_metadata_mismatch` does not lift that
# particular check. The scientific cost is small -- the roadmap's TPC-H rows exist to supply a
# TINY-cardinality tier (l_quantity, 50 distinct) and a HIGH-cardinality PLAIN tier
# (l_extendedprice), and the SF17 files supply both, already validated on build-41. The one thing
# lost is row-count comparability with the roadmap's SF1/SF10 table.
# Note this would have been lost for extprice anyway: we store WHOLE DOLLARS, so its distinct count
# is ~100k rather than the roadmap's 934k regardless of where the data came from.
TPCH_SF17="${TPCH_SF17:-0}"
SF17_QTY="${SF17_QTY:-$HOME/bench/tpch_sf17_quantity.parquet}"
SF17_EXT="${SF17_EXT:-$HOME/bench/tpch_sf17_extprice.parquet}"

# dataset:column:scale  -- scale is recorded so no number is ever quoted without its units
SPECS=(taxi_d1:$TAXI_COL:$TAXI_SCALE taxi_d2:$TAXI_COL:$TAXI_SCALE
       taxi_d3:$TAXI_COL:$TAXI_SCALE taxi_d4:$TAXI_COL:$TAXI_SCALE)
if [[ "$TPCH_SF17" == 1 ]]; then
	# Named *_sf17 on purpose: they are NOT the roadmap's datasets, so they must not be compared
	# against its reference digests, and the name is what keeps that honest in every table.
	SPECS+=(tpch_qty_sf17:x:1 tpch_extprice_sf17:x:1)
else
	SPECS+=(tpch_qty:v:1 tpch_extprice:v:1 tpch_extprice_sf10:v:1)
fi

case "${1:-}" in
	plan)   plan; exit 0 ;;
	verify) write_manifest "${SPECS[@]}"; check_gates; exit $? ;;
esac

for d in taxi_d1 taxi_d2 taxi_d3 taxi_d4; do
	f="$DS/$d.parquet"
	if [[ -f "$f" && -z "${FORCE:-}" ]]; then echo "  $d.parquet exists -- skipping"; continue; fi
	files=$(taxi_files "$d"); expr=$(taxi_expr "$TAXI_SCALE")
	echo "  writing $d.parquet  (months: $(taxi_months "$d" | tr '\n' ' '), scale $TAXI_SCALE) ..."
	tmp="$f.partial"; rm -f "$tmp"
	# NO ROW_GROUP_SIZE: the source layout is inherited and the geometry stays ragged on purpose.
	$DB -c "
		COPY (SELECT $expr AS $TAXI_COL FROM read_parquet($files) WHERE fare_amount IS NOT NULL)
		TO '$tmp' (FORMAT PARQUET);" \
		&& mv -f "$tmp" "$f" || { echo "  !! failed at $d" >&2; rm -f "$tmp"; exit 1; }
done

# TPC-H. The tpch extension is already in ~/.duckdb/extensions, so LOAD works with no network --
# but it must be copied into the v0.0.1/ tree first, because this fork's duckdb submodule has no
# tags, `git describe` comes back empty and the build therefore reports version v0.0.1 rather than
# its real base (commit 15d3f23bdf, a 1.4/1.5-era tree). Hence the metadata-mismatch override.
# The override skips a VERSION CHECK, not an ABI check, so the reference-digest gate on tpch_qty is
# what actually proves dbgen produced correct data -- TPC-H SF1 is deterministic, so an exact match
# on 6,001,215 rows / sum(v)=153078795 is not something a subtly broken extension would fake.
# dbgen runs against an ON-DISK database: SF10 lineitem does not want to live in memory.
if [[ "$TPCH_SF17" == 1 ]]; then
	for pair in "tpch_qty_sf17:$SF17_QTY" "tpch_extprice_sf17:$SF17_EXT"; do
		name="${pair%%:*}"; src="${pair#*:}"
		[[ -f "$src" ]] || { echo "  !! missing $src" >&2; exit 1; }
		# Symlinked, not copied: 485 MB of identical bytes, and the provenance stays obvious.
		ln -sfn "$src" "$DS/$name.parquet"
		echo "  $name.parquet -> $src"
	done
	write_manifest "${SPECS[@]}"
	check_gates
	exit $?
fi

for sf in 1 10; do
	case $sf in
		1)  want=("$DS/tpch_qty.parquet" "$DS/tpch_extprice.parquet") ;;
		10) want=("$DS/tpch_extprice_sf10.parquet") ;;
	esac
	missing=0; for w in "${want[@]}"; do [[ -f "$w" && -z "${FORCE:-}" ]] || missing=1; done
	(( missing )) || { echo "  tpch sf$sf outputs exist -- skipping"; continue; }

	copies=""
	if [[ $sf == 1 ]]; then
		# l_quantity is an integer 1..50 already. l_extendedprice is DECIMAL(15,2): WHOLE DOLLARS,
		# because cents overflow the accumulator (see the header).
		copies="COPY (SELECT l_quantity::INTEGER AS v FROM lineitem) TO '$DS/tpch_qty.parquet' (FORMAT PARQUET);
		        COPY (SELECT l_extendedprice::INTEGER AS v FROM lineitem) TO '$DS/tpch_extprice.parquet' (FORMAT PARQUET);"
	else
		copies="COPY (SELECT l_extendedprice::INTEGER AS v FROM lineitem) TO '$DS/tpch_extprice_sf10.parquet' (FORMAT PARQUET);"
	fi
	echo "  dbgen(sf=$sf) ... (SF10 takes a few minutes and several GB)"
	rm -f "$WORK/dbgen_sf$sf.db"
	$DB "$WORK/dbgen_sf$sf.db" -c "SET allow_extensions_metadata_mismatch=true;
		LOAD tpch; CALL dbgen(sf = $sf);
		$copies" || { echo "  !! dbgen sf=$sf failed" >&2; exit 1; }
	rm -f "$WORK/dbgen_sf$sf.db"
done

write_manifest "${SPECS[@]}"
check_gates
