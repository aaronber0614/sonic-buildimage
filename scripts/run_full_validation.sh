#!/bin/bash
# End-to-end DPKG cache validation: Phase 1 → Phase 4
# Run this in tmux to survive disconnects.
#
# Usage: bash scripts/run_full_validation.sh [--skip-builds]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

RESULTS_DIR="$REPO_DIR/poc-results/full-run-$(date +%Y%m%d-%H%M%S)"
CACHE_DIR="/tmp/sonic-dpkg-cache"
SKIP_BUILDS=false

for arg in "$@"; do
    case "$arg" in
        --skip-builds) SKIP_BUILDS=true ;;
    esac
done

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/run.log"; }

log "╔════════════════════════════════════════════════════════════════╗"
log "║  DPKG Cache Full Validation Run                               ║"
log "╚════════════════════════════════════════════════════════════════╝"
log "Results directory: $RESULTS_DIR"
log "Skip builds: $SKIP_BUILDS"
log ""

###############################################################################
# PHASE 1: Static Analysis
###############################################################################
log "━━━ PHASE 1: Static Analysis ━━━"

log "Running audit_dep_completeness.sh..."
bash "$SCRIPT_DIR/audit_dep_completeness.sh" --verbose 2>&1 | tee "$RESULTS_DIR/phase1-audit.log"
PHASE1_AUDIT=$?

log "Running check_common_files.sh..."
bash "$SCRIPT_DIR/check_common_files.sh" --verbose 2>&1 | tee "$RESULTS_DIR/phase1-common.log"
PHASE1_COMMON=$?

log "Phase 1 complete (audit=$PHASE1_AUDIT, common=$PHASE1_COMMON)"
log ""

###############################################################################
# PHASE 2: Proof-of-Concept Builds (A, B, C)
###############################################################################
if [[ "$SKIP_BUILDS" == "true" ]]; then
    log "━━━ PHASE 2: SKIPPED (--skip-builds) ━━━"
    log "Using existing build artifacts in poc-results/build-{A,B,C}/"
    BUILD_A_DIR="$REPO_DIR/poc-results/build-A"
    BUILD_B_DIR="$REPO_DIR/poc-results/build-B"
    BUILD_C_DIR="$REPO_DIR/poc-results/build-C"
else
    log "━━━ PHASE 2: Proof-of-Concept Builds ━━━"

    BUILD_A_DIR="$RESULTS_DIR/build-A"
    BUILD_B_DIR="$RESULTS_DIR/build-B"
    BUILD_C_DIR="$RESULTS_DIR/build-C"
    mkdir -p "$BUILD_A_DIR" "$BUILD_B_DIR" "$BUILD_C_DIR"

    # Ensure clean state
    log "Cleaning build artifacts..."
    sudo rm -rf target/*
    rm -rf "$CACHE_DIR" 2>/dev/null || true
    mkdir -p "$CACHE_DIR"
    # Remove all sonic Docker images to force fresh rebuilds
    log "Removing cached Docker images..."
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -v "sonic-slave" | grep -v "^<none>" | \
        xargs -r docker rmi -f 2>/dev/null || true
    log "Re-configuring build directories..."
    make configure PLATFORM=vs 2>&1 | tail -5

    # Build A: Baseline (no cache)
    log "Starting Build A (baseline, no cache)..."
    BUILD_A_START=$(date +%s)
    set +o pipefail
    make SONIC_DPKG_CACHE_METHOD=none \
         PLATFORM=vs \
         SONIC_BUILD_JOBS=$(nproc) \
         INCLUDE_FIPS=n \
         SONIC_VERSION_CONTROL=none \
         BUILD_SKIP_TEST=y \
         target/sonic-vs.img.gz 2>&1 | tee "$RESULTS_DIR/build-A.log"
    BUILD_A_RC=${PIPESTATUS[0]}
    set -o pipefail
    BUILD_A_END=$(date +%s)
    log "Build A finished in $(( (BUILD_A_END - BUILD_A_START) / 60 )) minutes (exit=$BUILD_A_RC)"
    if [[ $BUILD_A_RC -ne 0 ]]; then
        log "ERROR: Build A failed! Check $RESULTS_DIR/build-A.log"
        exit 1
    fi

    # Copy Build A artifacts
    log "Copying Build A artifacts..."
    cp -a target/debs "$BUILD_A_DIR/" 2>/dev/null || true
    cp -a target/python-wheels "$BUILD_A_DIR/" 2>/dev/null || true
    cp -a target/python-debs "$BUILD_A_DIR/" 2>/dev/null || true
    mkdir -p "$BUILD_A_DIR/docker-images"
    cp target/docker-*.gz "$BUILD_A_DIR/docker-images/" 2>/dev/null || true

    # Clean for Build B
    log "Cleaning for Build B..."
    sudo rm -rf target/*
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -v "sonic-slave" | grep -v "^<none>" | \
        xargs -r docker rmi -f 2>/dev/null || true
    make configure PLATFORM=vs 2>&1 | tail -3
    rm -rf "$CACHE_DIR"/*

    # Build B: Write cache
    log "Starting Build B (write cache)..."
    BUILD_B_START=$(date +%s)
    set +o pipefail
    make SONIC_DPKG_CACHE_METHOD=wcache \
         SONIC_DPKG_CACHE_SOURCE="$CACHE_DIR" \
         PLATFORM=vs \
         SONIC_BUILD_JOBS=$(nproc) \
         INCLUDE_FIPS=n \
         SONIC_VERSION_CONTROL=none \
         BUILD_SKIP_TEST=y \
         target/sonic-vs.img.gz 2>&1 | tee "$RESULTS_DIR/build-B.log"
    BUILD_B_RC=${PIPESTATUS[0]}
    set -o pipefail
    BUILD_B_END=$(date +%s)
    log "Build B finished in $(( (BUILD_B_END - BUILD_B_START) / 60 )) minutes (exit=$BUILD_B_RC)"
    if [[ $BUILD_B_RC -ne 0 ]]; then
        log "ERROR: Build B failed! Check $RESULTS_DIR/build-B.log"
        exit 1
    fi

    # Copy Build B artifacts
    log "Copying Build B artifacts..."
    cp -a target/debs "$BUILD_B_DIR/" 2>/dev/null || true
    cp -a target/python-wheels "$BUILD_B_DIR/" 2>/dev/null || true
    cp -a target/python-debs "$BUILD_B_DIR/" 2>/dev/null || true
    mkdir -p "$BUILD_B_DIR/docker-images"
    cp target/docker-*.gz "$BUILD_B_DIR/docker-images/" 2>/dev/null || true

    # Clean for Build C
    log "Cleaning for Build C..."
    sudo rm -rf target/*
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -v "sonic-slave" | grep -v "^<none>" | \
        xargs -r docker rmi -f 2>/dev/null || true
    make configure PLATFORM=vs 2>&1 | tail -3

    # Build C: Read cache
    log "Starting Build C (read cache)..."
    BUILD_C_START=$(date +%s)
    set +o pipefail
    make SONIC_DPKG_CACHE_METHOD=rcache \
         SONIC_DPKG_CACHE_SOURCE="$CACHE_DIR" \
         PLATFORM=vs \
         SONIC_BUILD_JOBS=$(nproc) \
         INCLUDE_FIPS=n \
         SONIC_VERSION_CONTROL=none \
         BUILD_SKIP_TEST=y \
         target/sonic-vs.img.gz 2>&1 | tee "$RESULTS_DIR/build-C.log"
    BUILD_C_RC=${PIPESTATUS[0]}
    set -o pipefail
    BUILD_C_END=$(date +%s)
    log "Build C finished in $(( (BUILD_C_END - BUILD_C_START) / 60 )) minutes (exit=$BUILD_C_RC)"
    if [[ $BUILD_C_RC -ne 0 ]]; then
        log "ERROR: Build C failed! Check $RESULTS_DIR/build-C.log"
        exit 1
    fi

    # Copy Build C artifacts
    log "Copying Build C artifacts..."
    cp -a target/debs "$BUILD_C_DIR/" 2>/dev/null || true
    cp -a target/python-wheels "$BUILD_C_DIR/" 2>/dev/null || true
    cp -a target/python-debs "$BUILD_C_DIR/" 2>/dev/null || true
    mkdir -p "$BUILD_C_DIR/docker-images"
    cp target/docker-*.gz "$BUILD_C_DIR/docker-images/" 2>/dev/null || true
fi

log "Phase 2 complete"
log ""

###############################################################################
# PHASE 3: Equivalence Comparison (Build B vs Build C)
###############################################################################
log "━━━ PHASE 3: Equivalence Comparison (B vs C) ━━━"

log "Running verify_cache_equivalence.sh..."
bash "$SCRIPT_DIR/verify_cache_equivalence.sh" \
    --dir-a "$BUILD_B_DIR" \
    --dir-b "$BUILD_C_DIR" \
    --output-dir "$RESULTS_DIR/comparison" \
    --verbose 2>&1 | tee "$RESULTS_DIR/phase3-equivalence.log"
PHASE3_EXIT=$?

log "Phase 3 complete (exit=$PHASE3_EXIT)"
log ""

###############################################################################
# PHASE 4: Negative Control Tests
###############################################################################
log "━━━ PHASE 4: Negative Control Tests (full-build) ━━━"

bash "$SCRIPT_DIR/run_negative_controls.sh" \
    --cache-dir "$CACHE_DIR" \
    --full-build \
    --output-dir "$RESULTS_DIR/negative-controls" 2>&1 | tee "$RESULTS_DIR/phase4-nc.log"
PHASE4_EXIT=$?

log "Phase 4 complete (exit=$PHASE4_EXIT)"
log ""

###############################################################################
# SUMMARY
###############################################################################
log "╔════════════════════════════════════════════════════════════════╗"
log "║  FULL VALIDATION COMPLETE                                     ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""
log "Phase 1 — Static Analysis:      audit=$PHASE1_AUDIT, common=$PHASE1_COMMON"
log "Phase 2 — Builds:               $(if $SKIP_BUILDS; then echo SKIPPED; else echo COMPLETE; fi)"
log "Phase 3 — Equivalence (B vs C): exit=$PHASE3_EXIT"
log "Phase 4 — Negative Controls:    exit=$PHASE4_EXIT"
log ""
log "All results in: $RESULTS_DIR"
log "Done at $(date)"
