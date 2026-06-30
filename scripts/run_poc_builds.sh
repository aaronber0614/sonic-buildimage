#!/bin/bash
#
# run_poc_builds.sh — DPKG Cache Equivalence PoC Build Orchestrator
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script orchestrates three controlled builds to empirically prove (or
# disprove) that cached artifacts are functionally identical to fresh-built ones:
#
#   Build A (Baseline): SONIC_DPKG_CACHE_METHOD=none — full build, no caching
#   Build B (Cache-Write): SONIC_DPKG_CACHE_METHOD=wcache — full build, writes cache
#   Build C (Cache-Read): SONIC_DPKG_CACHE_METHOD=rcache — reads from Build B's cache
#
# The primary comparison is Build B vs Build C: if the cache is correct, they
# should produce identical artifacts. Build A serves as a control to show what
# "normal" fresh-build variation looks like (timestamps, gzip headers, etc.).
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT IT DOES
# ═══════════════════════════════════════════════════════════════════════════════
#
# 1. Pre-flight checks:
#    - Validates git working tree is clean (no uncommitted changes)
#    - Verifies 'make configure' has been run (.platform exists)
#    - Records full environment snapshot to poc-env-snapshot.json
#
# 2. Build A (cache=none):
#    - Runs full build with caching completely disabled
#    - Copies all artifacts to <output-dir>/build-A/
#    - Records sha256 manifest
#
# 3. Build B (cache=wcache):
#    - Runs full build, writing all results to cache directory
#    - Copies all artifacts to <output-dir>/build-B/
#    - Records sha256 manifest
#
# 4. Cleanup between B and C:
#    - Removes built artifacts (target/debs/, target/python-wheels/, etc.)
#    - Removes tracking files (.flags, .dep.sha, .smod.smsha)
#    - Optionally prunes Docker images (--docker-prune)
#    - Verifies environment snapshot unchanged
#
# 5. Build C (cache=rcache):
#    - Reads from Build B's cache directory
#    - Copies all artifacts to <output-dir>/build-C/
#    - Records sha256 manifest
#
# 6. Generates comparison-ready output:
#    - poc-results/manifest-{A,B,C}.sha256  (per-file hashes)
#    - poc-results/build-{A,B,C}.log        (build logs)
#    - poc-results/timing.json              (build duration comparison)
#    - poc-results/env-snapshot.json        (environment lock record)
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   ./scripts/run_poc_builds.sh [OPTIONS]
#
# Required:
#   --platform PLATFORM    Target platform (e.g., vs, broadcom, mellanox)
#
# Optional:
#   --cache-dir DIR        Cache storage directory (default: /tmp/sonic-dpkg-cache)
#   --output-dir DIR       Results output directory (default: ./poc-results)
#   --target TARGET        Build target (default: target/debs/<bldenv>/ packages only)
#   --jobs N               Parallel build jobs (default: auto-detect nproc)
#   --docker-prune         Run 'docker system prune -a' between builds B and C
#   --version-control MODE Version control mode: none|all (default: all)
#   --builds BUILDS        Which builds to run: A,B,C or subset (default: A,B,C)
#   --skip-build-a         Skip Build A (useful if you only care about B vs C)
#   --dry-run              Show what would be done without executing builds
#   --continue-from BUILD  Resume from a specific build (A, B, or C)
#
# Examples:
#   # Full 3-build PoC on VS platform
#   ./scripts/run_poc_builds.sh --platform vs --docker-prune
#
#   # Quick B vs C comparison only (skip baseline)
#   ./scripts/run_poc_builds.sh --platform vs --skip-build-a --docker-prune
#
#   # Custom cache and output directories
#   ./scripts/run_poc_builds.sh --platform vs \
#       --cache-dir /mnt/fast-ssd/cache \
#       --output-dir /mnt/results/poc-run-1
#
#   # Dry run to verify configuration
#   ./scripts/run_poc_builds.sh --platform vs --dry-run
#
# ═══════════════════════════════════════════════════════════════════════════════
# INTERPRETING RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
#
# After completion, use verify_cache_equivalence.sh (Phase 3) to compare:
#   ./scripts/verify_cache_equivalence.sh \
#       --build-b ./poc-results/build-B \
#       --build-c ./poc-results/build-C
#
# Quick manual check:
#   diff <(cat poc-results/manifest-B.sha256) <(cat poc-results/manifest-C.sha256)
#
# If B and C manifests are identical: cache is producing equivalent artifacts.
# If they differ: use diffoscope on differing files to classify as cosmetic
# (timestamps/ordering) vs semantic (actual content difference = cache bug).
#
# ═══════════════════════════════════════════════════════════════════════════════
# PREREQUISITES
# ═══════════════════════════════════════════════════════════════════════════════
#
# - sonic-buildimage repository with submodules initialized
# - 'make configure PLATFORM=<platform>' already run
# - Docker installed and running
# - Sufficient disk space (300+ GiB for full builds, 100+ GiB for VS)
# - Sufficient RAM (8+ GiB)
# - ~6-18 hours wall time for 3 full builds (depending on hardware/platform)
#
# ═══════════════════════════════════════════════════════════════════════════════
# EXIT CODES
# ═══════════════════════════════════════════════════════════════════════════════
#
# 0 = All builds completed successfully
# 1 = Build failure (check build logs)
# 2 = Pre-flight check failure (dirty tree, missing .platform, etc.)
# 3 = Environment drift detected between builds (comparison invalid)
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script is part of the DPKG Cache Validation toolkit (Phase 2):
#   - Phase 1: audit_dep_completeness.sh, check_common_files.sh (static analysis)
#   - Phase 2: run_poc_builds.sh (this script), run_negative_controls.sh
#   - Phase 3: verify_cache_equivalence.sh, classify_diff.sh
#

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
PLATFORM=""
CACHE_DIR="/tmp/sonic-dpkg-cache"
OUTPUT_DIR="$REPO_ROOT/poc-results"
BUILD_TARGET=""
BUILD_JOBS=""
EXTRA_MAKE_OPTS=""
DOCKER_PRUNE=false
VERSION_CONTROL="all"
BUILDS="A,B,C"
DRY_RUN=false
CONTINUE_FROM=""
BLDENV=""

# --- Argument Parsing ---
usage() {
    echo "Usage: $0 --platform PLATFORM [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --platform PLATFORM    Target platform (required: vs, broadcom, mellanox, etc.)"
    echo "  --cache-dir DIR        Cache directory (default: /tmp/sonic-dpkg-cache)"
    echo "  --output-dir DIR       Output directory (default: ./poc-results)"
    echo "  --target TARGET        Build target (default: all debs + dockers)"
    echo "  --jobs N               Parallel build jobs (default: nproc)"
    echo "  --docker-prune         Prune Docker between builds B and C"
    echo "  --version-control MODE none|all (default: all — pins external deps)"
    echo "  --builds BUILDS        Comma-separated: A,B,C (default: A,B,C)"
    echo "  --skip-build-a         Shortcut for --builds B,C"
    echo "  --make-opts 'K=V ...'  Extra make variables (e.g., 'INCLUDE_FIPS=n')"
    echo "  --dry-run              Show plan without executing"
    echo "  --continue-from BUILD  Resume from build A, B, or C"
    echo "  --help                 Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) PLATFORM="$2"; shift 2 ;;
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --target) BUILD_TARGET="$2"; shift 2 ;;
        --jobs) BUILD_JOBS="$2"; shift 2 ;;
        --docker-prune) DOCKER_PRUNE=true; shift ;;
        --version-control) VERSION_CONTROL="$2"; shift 2 ;;
        --builds) BUILDS="$2"; shift 2 ;;
        --skip-build-a) BUILDS="B,C"; shift ;;
        --make-opts) EXTRA_MAKE_OPTS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --continue-from) CONTINUE_FROM="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

if [[ -z "$PLATFORM" ]]; then
    echo -e "${RED}ERROR: --platform is required${NC}"
    usage
fi

# --- Helper Functions ---

log_info() {
    echo -e "${CYAN}[INFO $(date '+%H:%M:%S')]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK $(date '+%H:%M:%S')]${NC} $*"
}

# Record current environment state as JSON
capture_env_snapshot() {
    local output_file="$1"
    local snapshot_time
    snapshot_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Detect BLDENV from .platform or default
    BLDENV=$(grep "^BLDENV" "$REPO_ROOT/rules/config" 2>/dev/null | awk -F'?=' '{print $2}' | tr -d ' ' || echo "")
    if [[ -z "$BLDENV" ]]; then
        BLDENV="bookworm"  # current default
    fi

    cat > "$output_file" <<EOF
{
    "timestamp": "$snapshot_time",
    "git_head": "$(git -C "$REPO_ROOT" rev-parse HEAD)",
    "git_branch": "$(git -C "$REPO_ROOT" branch --show-current)",
    "git_dirty": $(git -C "$REPO_ROOT" diff --quiet --ignore-submodules=dirty 2>/dev/null && echo "false" || echo "true"),
    "platform": "$PLATFORM",
    "bldenv": "$BLDENV",
    "configured_arch": "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')",
    "host_arch": "$(uname -m)",
    "cache_dir": "$CACHE_DIR",
    "cache_method_sequence": ["none", "wcache", "rcache"],
    "version_control": "$VERSION_CONTROL",
    "docker_prune_between_bc": $DOCKER_PRUNE,
    "build_jobs": "${BUILD_JOBS:-auto}",
    "sonic_dpkg_cache_source": "$CACHE_DIR",
    "kernel_version": "$(uname -r)",
    "docker_version": "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')",
    "make_version": "$(make --version 2>/dev/null | head -1)"
}
EOF
    log_info "Environment snapshot saved to $output_file"
}

# Verify environment hasn't drifted between builds
verify_env_unchanged() {
    local reference_file="$1"
    local current_head
    current_head=$(git -C "$REPO_ROOT" rev-parse HEAD)
    local snapshot_head
    snapshot_head=$(grep '"git_head"' "$reference_file" | grep -oP '[a-f0-9]{40}')

    if [[ "$current_head" != "$snapshot_head" ]]; then
        log_error "Git HEAD has changed! Was: $snapshot_head Now: $current_head"
        log_error "Environment drift detected — comparison would be invalid."
        return 1
    fi

    if ! git -C "$REPO_ROOT" diff --quiet --ignore-submodules 2>/dev/null; then
        log_error "Working tree has uncommitted changes since snapshot!"
        return 1
    fi

    log_success "Environment unchanged since snapshot"
    return 0
}

# Clean build artifacts for a fresh cache-read test
clean_build_artifacts() {
    log_info "Cleaning build artifacts for cache-read test..."

    local debs_dir="$REPO_ROOT/target/debs"
    local wheels_dir="$REPO_ROOT/target/python-wheels"
    local target_dir="$REPO_ROOT/target"

    # Remove built packages
    if [[ -d "$debs_dir" ]]; then
        log_info "  Removing $debs_dir/"
        $DRY_RUN || rm -rf "$debs_dir"
    fi

    if [[ -d "$wheels_dir" ]]; then
        log_info "  Removing $wheels_dir/"
        $DRY_RUN || rm -rf "$wheels_dir"
    fi

    # Remove Docker image artifacts
    log_info "  Removing target/*.gz Docker images"
    $DRY_RUN || rm -f "$target_dir"/*.gz 2>/dev/null

    # Remove python debs
    if [[ -d "$REPO_ROOT/target/python-debs" ]]; then
        log_info "  Removing target/python-debs/"
        $DRY_RUN || rm -rf "$REPO_ROOT/target/python-debs"
    fi

    # Recreate directory structure (make requires these to exist)
    $DRY_RUN || mkdir -p "$debs_dir/${BLDENV}" "$wheels_dir/${BLDENV}" "$REPO_ROOT/target/python-debs/${BLDENV}"

    # Remove tracking/hash files that trigger cache lookup
    log_info "  Removing .flags/.dep.sha/.smod.smsha tracking files"
    $DRY_RUN || find "$target_dir" -name "*.flags" -o -name "*.dep.sha" \
        -o -name "*.smod.smsha" -o -name "*.mod.sha" 2>/dev/null | xargs rm -f

    # Docker prune if requested
    if $DOCKER_PRUNE; then
        log_info "  Pruning Docker system (removes all unused images/containers)"
        $DRY_RUN || docker system prune -a --force 2>/dev/null
    fi

    log_success "Artifact cleanup complete"
}

# Generate sha256 manifest for all artifacts in a directory
generate_manifest() {
    local build_dir="$1"
    local manifest_file="$2"

    log_info "Generating sha256 manifest for $build_dir..."
    find "$build_dir" -type f \( -name "*.deb" -o -name "*.whl" -o -name "*.gz" \) \
        | sort \
        | while read -r f; do
            sha256sum "$f" | awk -v base="$build_dir" '{gsub(base"/", "", $2); print $1, $2}'
        done > "$manifest_file"

    local count
    count=$(wc -l < "$manifest_file")
    log_info "  Manifest: $count artifacts recorded"
}

# Copy build artifacts to output directory
collect_artifacts() {
    local build_label="$1"  # A, B, or C
    local dest_dir="$OUTPUT_DIR/build-$build_label"

    log_info "Collecting artifacts for Build $build_label → $dest_dir"
    mkdir -p "$dest_dir"

    # Copy debs
    if [[ -d "$REPO_ROOT/target/debs" ]]; then
        cp -a "$REPO_ROOT/target/debs" "$dest_dir/" 2>/dev/null || true
    fi

    # Copy python wheels
    if [[ -d "$REPO_ROOT/target/python-wheels" ]]; then
        cp -a "$REPO_ROOT/target/python-wheels" "$dest_dir/" 2>/dev/null || true
    fi

    # Copy python debs
    if [[ -d "$REPO_ROOT/target/python-debs" ]]; then
        cp -a "$REPO_ROOT/target/python-debs" "$dest_dir/" 2>/dev/null || true
    fi

    # Copy Docker images
    mkdir -p "$dest_dir/docker-images"
    cp "$REPO_ROOT/target/"*.gz "$dest_dir/docker-images/" 2>/dev/null || true

    # Generate manifest
    generate_manifest "$dest_dir" "$OUTPUT_DIR/manifest-$build_label.sha256"

    log_success "Build $build_label artifacts collected"
}

# Run a single build with specified cache method
run_build() {
    local build_label="$1"     # A, B, or C
    local cache_method="$2"    # none, wcache, rcache
    local log_file="$OUTPUT_DIR/build-${build_label}.log"
    local start_time end_time duration

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  BUILD $build_label — SONIC_DPKG_CACHE_METHOD=$cache_method${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Construct make arguments
    local make_args=(
        "SONIC_DPKG_CACHE_METHOD=$cache_method"
        "SONIC_DPKG_CACHE_SOURCE=$CACHE_DIR"
    )

    if [[ "$VERSION_CONTROL" == "all" ]]; then
        make_args+=("SONIC_VERSION_CONTROL_COMPONENTS=all")
        make_args+=("SONIC_VERSION_CACHE_METHOD=cache")
        make_args+=("SONIC_VERSION_CACHE_SOURCE=$CACHE_DIR/vcache")
    fi

    if [[ -n "$BUILD_JOBS" ]]; then
        make_args+=("SONIC_BUILD_JOBS=$BUILD_JOBS")
    fi

    # Add extra make options (e.g., INCLUDE_FIPS=n)
    if [[ -n "$EXTRA_MAKE_OPTS" ]]; then
        for opt in $EXTRA_MAKE_OPTS; do
            make_args+=("$opt")
        done
    fi

    # Determine build target
    local target="${BUILD_TARGET:-}"
    if [[ -z "$target" ]]; then
        # Build only bookworm (the primary BLDENV). Using NOTRIXIE=1 avoids
        # building trixie as well. The target 'all' goes through the top-level
        # Makefile dispatcher into Makefile.work -> slave.mk.
        target="all"
        # Disable all BLDENVs except the target one
        make_args+=("NOJESSIE=1" "NOSTRETCH=1" "NOBUSTER=1" "NOBULLSEYE=1")
        if [[ "$BLDENV" == "bookworm" ]]; then
            make_args+=("NOBOOKWORM=0" "NOTRIXIE=1")
        elif [[ "$BLDENV" == "trixie" ]]; then
            make_args+=("NOBOOKWORM=1" "NOTRIXIE=0")
        fi
        log_info "Building all targets for ${BLDENV} only"
    else
        log_info "Building target: $target"
    fi

    log_info "Make args: ${make_args[*]}"
    log_info "Log file: $log_file"

    if $DRY_RUN; then
        log_warn "[DRY RUN] Would execute:"
        echo "  cd $REPO_ROOT && make ${make_args[*]} $target"
        return 0
    fi

    # Verify environment hasn't changed
    if [[ -f "$OUTPUT_DIR/env-snapshot.json" ]]; then
        verify_env_unchanged "$OUTPUT_DIR/env-snapshot.json" || exit 3
    fi

    start_time=$(date +%s)

    # Run the build
    log_info "Starting build at $(date '+%Y-%m-%d %H:%M:%S')..."
    if ! (cd "$REPO_ROOT" && make "${make_args[@]}" $target 2>&1 | tee "$log_file"); then
        log_error "Build $build_label FAILED! Check log: $log_file"
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        record_timing "$build_label" "$duration" "FAILED"
        return 1
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    log_success "Build $build_label completed in ${duration}s ($(( duration / 60 ))m $(( duration % 60 ))s)"
    record_timing "$build_label" "$duration" "SUCCESS"

    # Collect artifacts
    collect_artifacts "$build_label"
}

# Record build timing to JSON
record_timing() {
    local build_label="$1"
    local duration="$2"
    local status="$3"
    local timing_file="$OUTPUT_DIR/timing.json"

    # Append to timing records (create if needed)
    if [[ ! -f "$timing_file" ]]; then
        echo '{"builds": {}}' > "$timing_file"
    fi

    # Use python for JSON manipulation (available in sonic build env)
    python3 -c "
import json, sys
with open('$timing_file', 'r') as f:
    data = json.load(f)
data['builds']['$build_label'] = {
    'duration_seconds': $duration,
    'duration_human': '${duration}s ($(( $duration / 60 ))m $(( $duration % 60 ))s)',
    'status': '$status',
    'cache_method': '$([ "$build_label" = "A" ] && echo "none" || ([ "$build_label" = "B" ] && echo "wcache" || echo "rcache"))'
}
with open('$timing_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
}

# --- Pre-flight Checks ---
preflight_checks() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SONiC DPKG Cache — PoC Build Orchestrator                    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Platform:          $PLATFORM"
    echo "  Cache directory:   $CACHE_DIR"
    echo "  Output directory:  $OUTPUT_DIR"
    echo "  Builds to run:     $BUILDS"
    echo "  Version control:   $VERSION_CONTROL"
    echo "  Docker prune:      $DOCKER_PRUNE"
    echo "  Build jobs:        ${BUILD_JOBS:-auto (nproc)}"
    echo "  Dry run:           $DRY_RUN"
    echo ""

    # Check 1: Clean git tree
    log_info "Checking git working tree..."
    if ! git -C "$REPO_ROOT" diff --quiet --ignore-submodules 2>/dev/null; then
        log_error "Working tree has uncommitted changes!"
        log_error "Commit or stash changes before running PoC builds."
        echo ""
        git -C "$REPO_ROOT" status --short --ignore-submodules | head -10
        exit 2
    fi
    log_success "Git working tree is clean"

    # Check 2: .platform exists (make configure was run)
    if [[ ! -f "$REPO_ROOT/.platform" ]]; then
        log_error ".platform not found — run 'make configure PLATFORM=$PLATFORM' first"
        exit 2
    fi
    local configured_platform
    configured_platform=$(cat "$REPO_ROOT/.platform")
    if [[ "$configured_platform" != "$PLATFORM" ]]; then
        log_error "Configured platform ($configured_platform) != requested ($PLATFORM)"
        log_error "Run 'make configure PLATFORM=$PLATFORM' to reconfigure"
        exit 2
    fi
    log_success "Platform configured: $configured_platform"

    # Check 3: Docker available
    if ! docker info &>/dev/null; then
        log_error "Docker is not running or not accessible"
        exit 2
    fi
    log_success "Docker is available"

    # Check 4: Disk space (warn if < 100GB free)
    local free_gb
    free_gb=$(df -BG "$REPO_ROOT" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ $free_gb -lt 100 ]]; then
        log_warn "Low disk space: ${free_gb}GB free (recommend 100+ GB for full builds)"
    else
        log_success "Disk space: ${free_gb}GB free"
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    mkdir -p "$CACHE_DIR"

    # Capture environment snapshot
    capture_env_snapshot "$OUTPUT_DIR/env-snapshot.json"

    echo ""
    log_success "Pre-flight checks passed"
    echo ""
}

# --- Main Execution ---
main() {
    preflight_checks

    # Determine which builds to run
    local run_a=false run_b=false run_c=false
    [[ "$BUILDS" == *"A"* ]] && run_a=true
    [[ "$BUILDS" == *"B"* ]] && run_b=true
    [[ "$BUILDS" == *"C"* ]] && run_c=true

    # Handle --continue-from
    if [[ -n "$CONTINUE_FROM" ]]; then
        case "$CONTINUE_FROM" in
            A) ;;  # run all remaining
            B) run_a=false ;;
            C) run_a=false; run_b=false ;;
            *) log_error "Invalid --continue-from value: $CONTINUE_FROM (must be A, B, or C)"; exit 1 ;;
        esac
    fi

    local overall_start
    overall_start=$(date +%s)

    # Build A: Baseline (no cache)
    if $run_a; then
        run_build "A" "none" || exit 1
    fi

    # Cleanup between A and B — Build B must rebuild from source to populate cache
    if $run_b; then
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}  CLEANUP — Preparing for Cache-Write Build${NC}"
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        if ! $DRY_RUN; then
            clean_build_artifacts
        else
            log_warn "[DRY RUN] Would clean build artifacts"
        fi
        run_build "B" "wcache" || exit 1

        # Verify cache was actually populated
        local cache_count
        cache_count=$(find "$CACHE_DIR" -name "*.tgz" 2>/dev/null | wc -l)
        log_info "Cache directory contains $cache_count .tgz files after Build B"
        if [[ "$cache_count" -eq 0 ]]; then
            log_error "No cache files written during Build B! Cache validation cannot proceed."
            exit 1
        fi
    fi

    # Cleanup between B and C
    if $run_c; then
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}  CLEANUP — Preparing for Cache-Read Build${NC}"
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        if ! $DRY_RUN; then
            clean_build_artifacts
        else
            log_warn "[DRY RUN] Would clean build artifacts"
        fi

        # Build C: Cache read
        run_build "C" "rcache" || exit 1
    fi

    # Summary
    local overall_end overall_duration
    overall_end=$(date +%s)
    overall_duration=$((overall_end - overall_start))

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  PoC COMPLETE${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Total time: ${overall_duration}s ($(( overall_duration / 3600 ))h $(( (overall_duration % 3600) / 60 ))m)"
    echo ""
    echo "  Results directory: $OUTPUT_DIR"
    echo "  ├── env-snapshot.json     (environment lock record)"
    echo "  ├── timing.json           (build durations)"
    echo "  ├── manifest-{A,B,C}.sha256  (artifact hashes)"
    echo "  ├── build-{A,B,C}.log     (full build logs)"
    echo "  └── build-{A,B,C}/        (collected artifacts)"
    echo ""
    echo "  Next steps:"
    echo "    1. Quick diff:  diff poc-results/manifest-B.sha256 poc-results/manifest-C.sha256"
    echo "    2. Deep compare: ./scripts/verify_cache_equivalence.sh --build-b $OUTPUT_DIR/build-B --build-c $OUTPUT_DIR/build-C"
    echo ""

    # Quick comparison if both B and C were run
    if $run_b && $run_c && [[ -f "$OUTPUT_DIR/manifest-B.sha256" ]] && [[ -f "$OUTPUT_DIR/manifest-C.sha256" ]]; then
        local diff_count
        diff_count=$(diff "$OUTPUT_DIR/manifest-B.sha256" "$OUTPUT_DIR/manifest-C.sha256" | grep "^[<>]" | wc -l)
        if [[ $diff_count -eq 0 ]]; then
            log_success "BUILD B vs BUILD C: All artifact hashes IDENTICAL — cache produces equivalent output!"
        else
            log_warn "BUILD B vs BUILD C: $((diff_count / 2)) artifacts differ — run verify_cache_equivalence.sh to classify"
        fi
    fi
}

main "$@"
