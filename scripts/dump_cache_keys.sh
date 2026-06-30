#!/bin/bash
#
# dump_cache_keys.sh — Display Computed Cache Key Components for Any Target
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# When debugging cache hits/misses, you need to know WHAT went into the cache
# key computation. This script shows:
#   - The target's cache filename pattern (<target>-<hash1>-<hash2>.tgz)
#   - hash1 (DEP_MOD_SHA): derived from dependency hashes (transitive)
#   - hash2 (MOD_HASH): derived from .flags/.dep.sha/.smod.smsha content
#   - All input files that contribute to each hash
#   - Current cache status (HIT/MISS/NOT_CACHED)
#
# Use this when you need to understand WHY a target got a cache hit or miss,
# or to verify that a specific file change would correctly invalidate the cache.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   ./scripts/dump_cache_keys.sh [OPTIONS] [TARGET...]
#
# Arguments:
#   TARGET    One or more target names (e.g., swss, docker-orchagent, sonic-utilities)
#             If omitted, dumps keys for ALL cached targets.
#
# Options:
#   --cache-dir DIR    Cache directory to check for HIT/MISS (default: from rules/config)
#   --show-files       Show all input files contributing to each hash
#   --show-flags       Show the DEP_FLAGS values for each target
#   --show-deps        Show the dependency chain (what targets feed into DEP_MOD_SHA)
#   --all              Equivalent to --show-files --show-flags --show-deps
#   --json             Output in JSON format
#   --verbose          Extra detail (git hash-object outputs, etc.)
#   --help             Show this help
#
# Examples:
#   # Show cache key for swss
#   ./scripts/dump_cache_keys.sh swss
#
#   # Show all components for docker-orchagent
#   ./scripts/dump_cache_keys.sh --all docker-orchagent
#
#   # Check cache status against a specific cache directory
#   ./scripts/dump_cache_keys.sh --cache-dir /tmp/sonic-cache swss sonic-utilities
#
#   # Dump all targets in JSON for scripting
#   ./scripts/dump_cache_keys.sh --json > cache-keys.json
#
# ═══════════════════════════════════════════════════════════════════════════════
# HOW CACHE KEYS WORK (from Makefile.cache)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Cache filename format: <target>-<DEP_MOD_SHA>-<MOD_HASH>.tgz
#
# MOD_HASH (23 chars):
#   - GIT_CONTENT_SHA mode (default): sha1sum of (.flags + .dep.sha + .smod.smsha)
#   - GIT_COMMIT_SHA mode: last git commit hash in the source directory
#
# DEP_MOD_SHA (23 chars):
#   For each dependency in _DEPENDS:
#     - Include that dep's .flags, .dep.sha, .smod.smsha
#     - Include that dep's OWN DEP_MOD_SHA and MOD_HASH (transitive!)
#   Then sha1sum all of those values together.
#
# Input files for .dep.sha:
#   - SONIC_COMMON_FILES_LIST (.platform, rules/functions, Makefile.cache)
#   - SONIC_COMMON_BASE_FILES_LIST (sonic-slave-*/Dockerfile*)
#   - Package-specific DEP_FILES (rules/<pkg>.mk, rules/<pkg>.dep, etc.)
#   - SMDEP_FILES (git ls-files on source directory)
#
# Input flags for .flags:
#   - SONIC_COMMON_FLAGS_LIST (global flags)
#   - Package-specific DEP_FLAGS
#
# ═══════════════════════════════════════════════════════════════════════════════
# EXIT CODES
# ═══════════════════════════════════════════════════════════════════════════════
#
# 0 = Success (information displayed)
# 1 = Target not found or not cacheable
# 2 = Script error (not in repo root, etc.)
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# Part of the DPKG Cache Validation toolkit (Phase 3):
#   - verify_cache_equivalence.sh: compares build outputs
#   - classify_diff.sh: classifies differences
#   - dump_cache_keys.sh: (this script) shows cache key internals
#

set -uo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RULES_DIR="$REPO_ROOT/rules"
MAKEFILE_CACHE="$REPO_ROOT/Makefile.cache"
TARGET_DIR="$REPO_ROOT/target"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
CACHE_DIR=""
SHOW_FILES=false
SHOW_FLAGS=false
SHOW_DEPS=false
JSON_OUTPUT=false
VERBOSE=false
TARGETS=()

# --- Argument Parsing ---
usage() {
    echo "Usage: $0 [OPTIONS] [TARGET...]"
    echo ""
    echo "Options:"
    echo "  --cache-dir DIR    Cache directory to check HIT/MISS status"
    echo "  --show-files       Show input files for hash computation"
    echo "  --show-flags       Show DEP_FLAGS values"
    echo "  --show-deps        Show dependency chain"
    echo "  --all              Show everything (files + flags + deps)"
    echo "  --json             JSON output"
    echo "  --verbose          Extra detail"
    echo "  --help             Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --show-files) SHOW_FILES=true; shift ;;
        --show-flags) SHOW_FLAGS=true; shift ;;
        --show-deps) SHOW_DEPS=true; shift ;;
        --all) SHOW_FILES=true; SHOW_FLAGS=true; SHOW_DEPS=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) usage ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done

# Validate environment
if [[ ! -f "$MAKEFILE_CACHE" ]]; then
    echo -e "${RED}ERROR: Makefile.cache not found. Run from sonic-buildimage root.${NC}"
    exit 2
fi

# Default cache dir from rules/config
if [[ -z "$CACHE_DIR" ]]; then
    CACHE_DIR=$(grep "^SONIC_DPKG_CACHE_SOURCE" "$REPO_ROOT/rules/config" 2>/dev/null | \
        awk -F'?=' '{print $2}' | tr -d ' ' || echo "/var/cache/sonic/artifacts")
fi

# --- Helper Functions ---

# Find dep file for a target name
find_dep_file() {
    local target="$1"
    local dep_file="$RULES_DIR/${target}.dep"

    if [[ -f "$dep_file" ]]; then
        echo "$dep_file"
        return 0
    fi

    # Try with docker- prefix
    dep_file="$RULES_DIR/docker-${target}.dep"
    if [[ -f "$dep_file" ]]; then
        echo "$dep_file"
        return 0
    fi

    # Search by partial name
    local found
    found=$(find "$RULES_DIR" -name "*${target}*.dep" | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi

    return 1
}

# Extract DEP_FILES list from a .dep file
get_dep_files() {
    local dep_file="$1"
    # Parse DEP_FILES lines (may span multiple lines with +=)
    grep "DEP_FILES\|SMDEP_FILES" "$dep_file" | \
        sed 's/.*:=//;s/.*+=//' | \
        tr '\\' ' ' | tr '\n' ' ' | \
        grep -oP '[\w./$()]+' | \
        grep -v "DEP_FILES\|SMDEP_FILES\|eval\|shell"
}

# Extract DEP_FLAGS from a .dep file
get_dep_flags() {
    local dep_file="$1"
    grep "DEP_FLAGS" "$dep_file" | \
        grep -oP '\$\(\w+\)' | \
        tr -d '$()'
}

# Extract CACHE_MODE from a .dep file
get_cache_mode() {
    local dep_file="$1"
    local mode
    mode=$(grep "CACHE_MODE" "$dep_file" | grep -oP 'GIT_\w+' | head -1)
    echo "${mode:-GIT_CONTENT_SHA}"
}

# Extract _DEPENDS from corresponding .mk file
get_depends() {
    local target="$1"
    local mk_file="$RULES_DIR/${target}.mk"
    [[ ! -f "$mk_file" ]] && mk_file=$(find "$RULES_DIR" -name "*${target}*.mk" | head -1)
    [[ -z "$mk_file" || ! -f "$mk_file" ]] && return

    grep "_DEPENDS\|_RDEPENDS" "$mk_file" | \
        grep -oP '\$\(\w+\)' | \
        tr -d '$()'  | \
        sort -u
}

# Check if a cache file exists for this target
check_cache_status() {
    local target="$1"
    if [[ ! -d "$CACHE_DIR" ]]; then
        echo "UNKNOWN (cache dir not found)"
        return
    fi

    local matches
    matches=$(find "$CACHE_DIR" -name "${target}-*-*.tgz" 2>/dev/null | wc -l)
    if [[ $matches -gt 0 ]]; then
        echo "CACHED ($matches versions)"
    else
        echo "NOT IN CACHE"
    fi
}

# List cache files for a target
list_cache_files() {
    local target="$1"
    find "$CACHE_DIR" -name "${target}-*-*.tgz" 2>/dev/null | sort
}

# --- Main Display ---

dump_target() {
    local target="$1"

    local dep_file
    dep_file=$(find_dep_file "$target") || {
        echo -e "${YELLOW}  $target: No .dep file found (not cacheable)${NC}"
        return 1
    }

    local base_name
    base_name=$(basename "$dep_file" .dep)

    echo ""
    echo -e "${BOLD}┌─ $base_name ─────────────────────────────────────────${NC}"

    # Cache mode
    local cache_mode
    cache_mode=$(get_cache_mode "$dep_file")
    echo -e "│ Cache mode:    ${CYAN}$cache_mode${NC}"

    # Cache status
    local status
    status=$(check_cache_status "$base_name")
    local status_color="$YELLOW"
    [[ "$status" == CACHED* ]] && status_color="$GREEN"
    [[ "$status" == "NOT IN CACHE" ]] && status_color="$RED"
    echo -e "│ Cache status:  ${status_color}$status${NC}"

    # Show cached file names if they exist
    if [[ -d "$CACHE_DIR" ]] && $VERBOSE; then
        local cache_files
        cache_files=$(list_cache_files "$base_name")
        if [[ -n "$cache_files" ]]; then
            echo "│ Cache files:"
            echo "$cache_files" | while read -r cf; do
                local fname
                fname=$(basename "$cf")
                # Parse hash1 and hash2 from filename
                local hashes
                hashes=$(echo "$fname" | grep -oP '[a-f0-9]{23}')
                echo "│   $fname"
            done
        fi
    fi

    # DEP_FLAGS
    if $SHOW_FLAGS; then
        echo "│"
        echo "│ DEP_FLAGS (variables in cache key):"
        local flags
        flags=$(get_dep_flags "$dep_file")
        if [[ -n "$flags" ]]; then
            echo "$flags" | while read -r flag; do
                echo "│   \$($flag)"
            done
        else
            echo "│   (uses SONIC_COMMON_FLAGS_LIST only)"
        fi
    fi

    # DEP_FILES
    if $SHOW_FILES; then
        echo "│"
        echo "│ DEP_FILES (files hashed for cache key):"
        local files
        files=$(get_dep_files "$dep_file")
        if [[ -n "$files" ]]; then
            echo "$files" | while read -r f; do
                # Check if it's a variable reference or actual file
                if [[ "$f" == *'$('* ]]; then
                    echo "│   $f  (variable — expands at build time)"
                elif [[ -f "$REPO_ROOT/$f" ]]; then
                    echo -e "│   ${GREEN}$f${NC}"
                else
                    echo -e "│   ${YELLOW}$f${NC}  (not found — may be build-time path)"
                fi
            done
        fi

        # Show SMDEP pattern
        local smdep
        smdep=$(grep "SMDEP" "$dep_file" | head -1)
        if [[ -n "$smdep" ]]; then
            echo "│"
            echo "│ SMDEP_FILES pattern:"
            echo "│   $smdep"
        fi
    fi

    # Dependencies
    if $SHOW_DEPS; then
        echo "│"
        echo "│ Dependencies (contribute to DEP_MOD_SHA transitively):"
        local deps
        deps=$(get_depends "$base_name")
        if [[ -n "$deps" ]]; then
            echo "$deps" | while read -r dep; do
                echo "│   → $dep"
            done
        else
            echo "│   (none declared)"
        fi
    fi

    echo -e "${BOLD}└──────────────────────────────────────────────────────${NC}"
}

# --- Main ---
main() {
    if ! $JSON_OUTPUT; then
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  SONiC DPKG Cache — Cache Key Inspector                       ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  Cache directory: $CACHE_DIR"
        echo "  Show files: $SHOW_FILES | Show flags: $SHOW_FLAGS | Show deps: $SHOW_DEPS"
    fi

    # If no targets specified, find all cacheable targets
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        while IFS= read -r dep_file; do
            TARGETS+=("$(basename "$dep_file" .dep)")
        done < <(find "$RULES_DIR" -name "*.dep" -type f | sort)
    fi

    if $JSON_OUTPUT; then
        echo "["
        local first=true
        for target in "${TARGETS[@]}"; do
            local dep_file
            dep_file=$(find_dep_file "$target") || continue
            local base_name
            base_name=$(basename "$dep_file" .dep)

            if ! $first; then echo ","; fi
            first=false

            local cache_mode status flags deps
            cache_mode=$(get_cache_mode "$dep_file")
            status=$(check_cache_status "$base_name")
            flags=$(get_dep_flags "$dep_file" | tr '\n' ',' | sed 's/,$//')
            deps=$(get_depends "$base_name" | tr '\n' ',' | sed 's/,$//')

            printf '  {"target": "%s", "cache_mode": "%s", "status": "%s", "dep_flags": "%s", "depends": "%s"}' \
                "$base_name" "$cache_mode" "$status" "$flags" "$deps"
        done
        echo ""
        echo "]"
    else
        for target in "${TARGETS[@]}"; do
            dump_target "$target"
        done

        echo ""
        echo "  Total targets examined: ${#TARGETS[@]}"
    fi
}

main "$@"
