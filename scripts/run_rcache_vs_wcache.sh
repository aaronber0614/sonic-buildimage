#!/bin/bash
# Direct rcache-vs-wcache validation with baselines applied.
#
# Both inputs are cache-served builds of the SAME commit; the only difference is
# the cache path exercised (write-cache populate vs. read-cache restore). They
# should therefore match modulo build non-determinism. Any UNMATCHED semantic diff
# (after subtracting the fresh-vs-fresh baseline) points to a difference between the
# cache WRITE path and the cache READ path itself.
#
#   dir-a = wcache (write-cache build under test)
#   dir-b = rcache (read-cache build under test)
#   gate  = per-platform fresh-vs-fresh baseline (generated on demand if missing)
#
# Run IDs and the output directory are configurable via the environment; the
# defaults below are the same-commit (0b06902) sweep runs verified against ADO.
#   FRESH_A=<run-id> FRESH_B=<run-id> WCACHE_RUN=<run-id> RCACHE_RUN=<run-id>
#   CACHE_VALIDATION_DIR=<output dir>  PLATFORMS="vs broadcom ..."
set -u

FRESH_A="${FRESH_A:-169783074}"   # fresh #1 (baseline pair)
FRESH_B="${FRESH_B:-169783252}"   # fresh #2 (baseline pair)
WCACHE_RUN="${WCACHE_RUN:-168526250}"
RCACHE_RUN="${RCACHE_RUN:-168403254}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/verify_cache_equivalence.sh"
BASE="${CACHE_VALIDATION_DIR:-$PWD/cache-validation-out}"
CV="${WORK_DIR:-$BASE/_cv}"
BASELINES="$BASE/baselines"
REPORTS="$BASE/reports-rcache-vs-wcache"
SUMMARY="$BASE/rcache-vs-wcache-summary.tsv"

mkdir -p "$CV" "$BASELINES" "$REPORTS"
echo -e "platform\tidentical\tcosmetic\tsemantic_UNMATCHED\tbaseline_matched\tmissing\terror\ttotal\tverdict" > "$SUMMARY"

read -r -a PLATFORMS <<< "${PLATFORMS:-aspeed-arm64 broadcom vs mellanox cisco-8000 vpp pensando nvidia-bluefield marvell-prestera-arm64 marvell-prestera-armhf broadcom-dbg}"

log(){ echo "[$(date '+%H:%M:%S')] $*"; }
dl(){ az pipelines runs artifact download --run-id "$1" --artifact-name "$2" --path "$3" >/dev/null 2>&1; }

for P in "${PLATFORMS[@]}"; do
  ART="sonic-buildimage.$P"
  BL="$BASELINES/$P.baseline.json"
  log "########## PLATFORM: $P ##########"

  # 1) Ensure a baseline exists (fresh #1 vs fresh #2). Generate on demand.
  if [ ! -f "$BL" ]; then
    FA="$CV/$P-freshA"; FB="$CV/$P-freshB"
    rm -rf "$FA" "$FB"; mkdir -p "$FA" "$FB"
    log "$P: baseline missing — downloading fresh #1 ($FRESH_A) + fresh #2 ($FRESH_B)"
    if ! dl "$FRESH_A" "$ART" "$FA" || ! dl "$FRESH_B" "$ART" "$FB"; then
      log "$P: BASELINE DOWNLOAD FAILED"; echo -e "$P\t-\t-\t-\t-\t-\t-\t-\tBASELINE_DL_FAIL" >> "$SUMMARY"; rm -rf "$FA" "$FB"; continue
    fi
    OUTB="$REPORTS/baseline/$P"; mkdir -p "$OUTB"
    log "$P: generating baseline"
    "$SCRIPT" --dir-a "$FA" --dir-b "$FB" --generate-baseline --no-diffoscope --level 1,2,3 --output-dir "$OUTB" > "$OUTB.console.log" 2>&1
    [ -f "$OUTB/equivalence-report.json" ] && cp "$OUTB/equivalence-report.json" "$BL"
    rm -rf "$FA" "$FB"
    if [ ! -f "$BL" ]; then
      log "$P: BASELINE GENERATION FAILED"; echo -e "$P\t-\t-\t-\t-\t-\t-\t-\tBASELINE_GEN_FAIL" >> "$SUMMARY"; continue
    fi
  else
    log "$P: reusing existing baseline"
  fi

  # 2) Download wcache + rcache and diff them, gated by the baseline.
  WA="$CV/$P-wcache"; RB="$CV/$P-rcache"
  rm -rf "$WA" "$RB"; mkdir -p "$WA" "$RB"
  log "$P: downloading wcache ($WCACHE_RUN) + rcache ($RCACHE_RUN)"
  if ! dl "$WCACHE_RUN" "$ART" "$WA" || ! dl "$RCACHE_RUN" "$ART" "$RB"; then
    log "$P: CACHED DOWNLOAD FAILED"; echo -e "$P\t-\t-\t-\t-\t-\t-\t-\tCACHED_DL_FAIL" >> "$SUMMARY"; rm -rf "$WA" "$RB"; continue
  fi

  OUT="$REPORTS/$P"; mkdir -p "$OUT"
  log "$P: running verify wcache-vs-rcache (baseline gated)"
  if "$SCRIPT" --dir-a "$WA" --dir-b "$RB" --baseline "$BL" --json --no-diffoscope --level 1,2,3 --output-dir "$OUT" > "$OUT.console.log" 2>&1; then
    vd=PASS
  else
    vd=FAIL
  fi
  J="$OUT/equivalence-report.json"
  if [ -f "$J" ]; then
    read i c s b mi er t < <(python3 -c "import json;d=json.load(open('$J'))['summary'];print(d.get('identical',0),d.get('cosmetic',0),d.get('semantic',0),d.get('baseline_nondeterminism',0),d.get('missing',0),d.get('error',0),d.get('total',0))" 2>/dev/null)
    echo -e "$P\t$i\t$c\t$s\t$b\t$mi\t$er\t$t\t$vd" >> "$SUMMARY"
    log "$P: DONE verdict=$vd  unmatched_semantic=$s  baseline_matched=$b  (identical=$i cosmetic=$c missing=$mi)"
  else
    echo -e "$P\t-\t-\t-\t-\t-\t-\t-\tNO_JSON" >> "$SUMMARY"
    log "$P: NO JSON"
  fi
  rm -rf "$WA" "$RB"
  log "$P: cleaned; /mnt free: $(df -h /mnt|tail -1|awk '{print $4}')"
done

log "ALL DONE"
echo "==== FINAL RCACHE-VS-WCACHE SUMMARY ===="
column -t -s$'\t' "$SUMMARY"
