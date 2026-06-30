#!/bin/bash
# Generate per-platform no-cache-vs-no-cache baselines from two fresh builds.
#
# Build run IDs and the output directory are configurable via the environment;
# the defaults below are only example values from a past run:
#   BUILD_A=<run-id>  BUILD_B=<run-id>  (both no-cache, same commit)
#   CACHE_VALIDATION_DIR=<output dir>
set -u

BUILD_A="${BUILD_A:-169783074}"
BUILD_B="${BUILD_B:-169783252}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/verify_cache_equivalence.sh"
BASE="${CACHE_VALIDATION_DIR:-$PWD/cache-validation-out}"
CV="${WORK_DIR:-$BASE/_cv}"
REPORTS="$BASE/reports"
BASELINES="$BASE/baselines"
SUMMARY="$BASE/summary.tsv"

mkdir -p "$CV" "$REPORTS" "$BASELINES"
[ -f "$SUMMARY" ] && mv "$SUMMARY" "$SUMMARY.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null
echo -e "platform\tidentical\tcosmetic\tsemantic\ttotal\tstatus" > "$SUMMARY"

# Regenerate ALL 11 baselines with the unified script (correctness-hardened +
# baseline workflow). Pin --level 1,2,3 to match the original baseline scope and
# keep runtime tractable (installer Level 5 is excluded). --no-diffoscope avoids
# slow HTML generation on the many inherent-non-determinism diffs.
PLATFORMS=(
  aspeed-arm64
  broadcom
  vs
  mellanox
  cisco-8000
  vpp
  pensando
  nvidia-bluefield
  marvell-prestera-arm64
  marvell-prestera-armhf
  broadcom-dbg
)

log(){ echo "[$(date '+%H:%M:%S')] $*"; }

for P in "${PLATFORMS[@]}"; do
  ART="sonic-buildimage.$P"
  DA="$CV/$P-a"; DB="$CV/$P-b"
  log "===== PLATFORM: $P ====="
  rm -rf "$DA" "$DB"; mkdir -p "$DA" "$DB"

  log "$P: downloading A ($BUILD_A)"
  if ! az pipelines runs artifact download --run-id "$BUILD_A" --artifact-name "$ART" --path "$DA" >/dev/null 2>&1; then
    log "$P: DOWNLOAD A FAILED"; echo -e "$P\t-\t-\t-\t-\tDOWNLOAD_A_FAIL" >> "$SUMMARY"; rm -rf "$DA" "$DB"; continue
  fi
  log "$P: downloading B ($BUILD_B)"
  if ! az pipelines runs artifact download --run-id "$BUILD_B" --artifact-name "$ART" --path "$DB" >/dev/null 2>&1; then
    log "$P: DOWNLOAD B FAILED"; echo -e "$P\t-\t-\t-\t-\tDOWNLOAD_B_FAIL" >> "$SUMMARY"; rm -rf "$DA" "$DB"; continue
  fi
  log "$P: sizes A=$(du -sh "$DA"|cut -f1) B=$(du -sh "$DB"|cut -f1); running verify (--generate-baseline)"

  OUT="$REPORTS/$P"
  if "$SCRIPT" --dir-a "$DA" --dir-b "$DB" --generate-baseline --no-diffoscope --level 1,2,3 --output-dir "$OUT" > "$OUT.console.log" 2>&1; then
    st=PASS
  else
    st=FAIL  # expected for baseline mode when non-determinism exists
  fi

  J="$OUT/equivalence-report.json"
  if [ -f "$J" ]; then
    cp "$J" "$BASELINES/$P.baseline.json"
    read i c s t < <(python3 -c "import json;d=json.load(open('$J'))['summary'];print(d['identical'],d['cosmetic'],d['semantic'],d['total'])" 2>/dev/null)
    echo -e "$P\t${i:-?}\t${c:-?}\t${s:-?}\t${t:-?}\t$st" >> "$SUMMARY"
    log "$P: DONE  identical=$i cosmetic=$c semantic=$s total=$t  (baseline saved)"
  else
    echo -e "$P\t-\t-\t-\t-\tNO_JSON" >> "$SUMMARY"
    log "$P: NO JSON REPORT PRODUCED"
  fi

  rm -rf "$DA" "$DB"
  log "$P: cleaned up downloads; /mnt free: $(df -h /mnt|tail -1|awk '{print $4}')"
done

log "ALL DONE"
echo "==== FINAL SUMMARY ===="
cat "$SUMMARY"
