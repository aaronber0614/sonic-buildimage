#!/bin/bash
# Full cache-equivalence sweep with the unified (correctness-hardened + baseline)
# verify script:
#   1) Regenerate all 11 per-platform baselines (fresh-vs-fresh, --level 1,2,3)
#   2) Validate rcache & wcache vs fresh for all platforms, applying baselines
# Artifacts stream from Azure pipeline runs and are cleaned per-platform.
#
# Output directory is configurable via CACHE_VALIDATION_DIR (default ./cache-validation-out).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${CACHE_VALIDATION_DIR:-$PWD/cache-validation-out}"
export CACHE_VALIDATION_DIR="$BASE"
mkdir -p "$BASE"
LOG="$BASE/full-sweep.$(date +%Y%m%d-%H%M%S).log"

{
  echo "==================================================================="
  echo " FULL CACHE-EQUIVALENCE SWEEP"
  echo " started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo " script:  $SCRIPT_DIR/verify_cache_equivalence.sh"
  echo "==================================================================="

  echo ""
  echo "######## PHASE 1: REGENERATE BASELINES ########"
  bash "$SCRIPT_DIR/run_all_baselines.sh"
  echo "PHASE 1 exit: $?"

  echo ""
  echo "######## PHASE 2: CACHED-VS-FRESH VALIDATION ########"
  bash "$SCRIPT_DIR/run_cached_vs_fresh.sh"
  echo "PHASE 2 exit: $?"

  echo ""
  echo " finished: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "==================================================================="
  echo " BASELINE SUMMARY:"; column -t -s$'\t' "$BASE/summary.tsv" 2>/dev/null
  echo ""
  echo " VALIDATION SUMMARY:"; column -t -s$'\t' "$BASE/cached-summary.tsv" 2>/dev/null
} > "$LOG" 2>&1

echo "DONE — log: $LOG"
