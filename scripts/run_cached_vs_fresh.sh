#!/bin/bash
# Cached-vs-fresh validation with baselines applied.
#   FRESH (dir-a)  = a no-cache build (commit X)
#   CACHED (dir-b) = read-cache (rcache) AND write-cache (wcache) of the same commit
# Unmatched SEMANTIC (after baseline downgrade) = genuine cache bug.
#
# Pipeline run IDs and the output directory are configurable via the environment;
# the defaults below are only example values from a past sweep:
#   FRESH=<run-id>  RCACHE_RUN=<run-id>  WCACHE_RUN=<run-id>
#   CACHE_VALIDATION_DIR=<output dir>
set -u

FRESH="${FRESH:-169783074}"
declare -A METHODS=( [rcache]="${RCACHE_RUN:-168403254}" [wcache]="${WCACHE_RUN:-168526250}" )
ORDER=(rcache wcache)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/verify_cache_equivalence.sh"
BASE="${CACHE_VALIDATION_DIR:-$PWD/cache-validation-out}"
CV="${WORK_DIR:-$BASE/_cv}"
BASELINES="$BASE/baselines"
REPORTS="$BASE/reports-cached"
SUMMARY="$BASE/cached-summary.tsv"

mkdir -p "$CV" "$REPORTS"
echo -e "method\tplatform\tidentical\tcosmetic\tsemantic_UNMATCHED\tbaseline_matched\tmissing\terror\ttotal\tverdict" > "$SUMMARY"

PLATFORMS=(
  aspeed-arm64 broadcom vs mellanox cisco-8000 vpp pensando
  nvidia-bluefield marvell-prestera-arm64 marvell-prestera-armhf broadcom-dbg
)

log(){ echo "[$(date '+%H:%M:%S')] $*"; }
dl(){ az pipelines runs artifact download --run-id "$1" --artifact-name "$2" --path "$3" >/dev/null 2>&1; }

for P in "${PLATFORMS[@]}"; do
  ART="sonic-buildimage.$P"
  BL="$BASELINES/$P.baseline.json"
  FA="$CV/$P-fresh"
  log "########## PLATFORM: $P ##########"
  rm -rf "$FA"; mkdir -p "$FA"
  log "$P: downloading FRESH ($FRESH)"
  if ! dl "$FRESH" "$ART" "$FA"; then
    log "$P: FRESH DOWNLOAD FAILED"; for m in "${ORDER[@]}"; do echo -e "$m\t$P\t-\t-\t-\t-\t-\t-\t-\tFRESH_DL_FAIL" >> "$SUMMARY"; done; rm -rf "$FA"; continue
  fi
  for m in "${ORDER[@]}"; do
    CID=${METHODS[$m]}
    CD="$CV/$P-$m"
    log "$P/$m: downloading CACHED ($CID)"
    rm -rf "$CD"; mkdir -p "$CD"
    if ! dl "$CID" "$ART" "$CD"; then
      log "$P/$m: CACHED DOWNLOAD FAILED"; echo -e "$m\t$P\t-\t-\t-\t-\t-\t-\t-\tCACHED_DL_FAIL" >> "$SUMMARY"; rm -rf "$CD"; continue
    fi
    OUT="$REPORTS/$m/$P"
    mkdir -p "$OUT"
    BLARG=(); [ -f "$BL" ] && BLARG=(--baseline "$BL")
    log "$P/$m: running verify (baseline=$( [ -f "$BL" ] && echo yes || echo MISSING ))"
    if "$SCRIPT" --dir-a "$FA" --dir-b "$CD" "${BLARG[@]}" --json --no-diffoscope --level 1,2,3 --output-dir "$OUT" > "$OUT.console.log" 2>&1; then
      vd=PASS
    else
      vd=FAIL
    fi
    J="$OUT/equivalence-report.json"
    if [ -f "$J" ]; then
      read i c s b mi er t < <(python3 -c "import json;d=json.load(open('$J'))['summary'];print(d.get('identical',0),d.get('cosmetic',0),d.get('semantic',0),d.get('baseline_nondeterminism',0),d.get('missing',0),d.get('error',0),d.get('total',0))" 2>/dev/null)
      echo -e "$m\t$P\t$i\t$c\t$s\t$b\t$mi\t$er\t$t\t$vd" >> "$SUMMARY"
      log "$P/$m: DONE verdict=$vd  unmatched_semantic=$s  baseline_matched=$b  (identical=$i cosmetic=$c missing=$mi)"
    else
      echo -e "$m\t$P\t-\t-\t-\t-\t-\t-\t-\tNO_JSON" >> "$SUMMARY"
      log "$P/$m: NO JSON"
    fi
    rm -rf "$CD"
  done
  rm -rf "$FA"
  log "$P: cleaned; /mnt free: $(df -h /mnt|tail -1|awk '{print $4}')"
done

log "ALL DONE"
echo "==== FINAL CACHED-VS-FRESH SUMMARY ===="
column -t -s$'\t' "$SUMMARY"
