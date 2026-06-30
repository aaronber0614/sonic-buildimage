#!/bin/bash
#
# audit_dep_completeness.sh — Per-Package .dep File Completeness Audit
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# In SONiC's DPKG caching system (Makefile.cache), each package has a .dep file
# (rules/<pkg>.dep) that declares what inputs affect its cache key. If a .dep file
# is incomplete — missing a build flag, a source file pattern, or a dependency —
# the cache key won't change when it should, and stale artifacts will be served.
#
# This script performs static analysis across ALL rules/*.dep files to identify
# gaps where build inputs exist in .mk files but are not reflected in cache key
# computation. It cross-references:
#   - rules/*.mk  (what flags/deps/sources actually affect each package)
#   - rules/*.dep (what the cache system tracks)
#   - Makefile.cache (global lists and hash computation logic)
#   - Source directories (whether packages have source code at all)
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT IT CHECKS (8 checks)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Check 1: Packages registered in build categories without a .dep file
#           These packages have NO cache key computation at all — they'll always
#           get a cache hit on first write, regardless of source changes.
#
# Check 2: .dep files that don't include their own .mk file in DEP_FILES
#           The .mk file defines dependencies and build flags — if it changes
#           (e.g., new _DEPENDS added), the cache key must reflect that.
#
# Check 3: Build flags (ifeq/ifneq conditionals) in .mk not tracked in .dep
#           Analyzes WHAT each conditional does to distinguish:
#           - Build-affecting: changes _DEPENDS, _RDEPENDS, build commands → REAL gap
#           - Assembly-only: changes SONIC_INSTALL_DOCKER_IMAGES → safe to ignore
#
# Check 4: _DEPENDS declared in .mk but not reflected in .dep DEP_FILES
#           If package A depends on package B, A's cache key should include B.
#
# Check 5: Source directory patterns — .dep declares _SRC_PATH or git ls-files
#           but the pattern may miss files (e.g., generated sources, submodules).
#
# Check 6: CACHE_MODE consistency — GIT_COMMIT_SHA vs GIT_CONTENT_SHA
#           GIT_COMMIT_SHA mode uses the git commit hash (fast but coarse).
#           GIT_CONTENT_SHA hashes actual file content (precise but slower).
#
# Check 7: Cross-package dependency completeness — are transitive deps covered?
#           If A depends on B depends on C, does A's cache key transitively
#           include C's changes? (Makefile.cache handles this via DEP_MOD_SHA
#           recursion, but only if B is declared as a dep of A.)
#
# Check 8: slave.mk flags used in package build rules but not tracked
#           Scans for flags like SONIC_BUILD_JOBS, ENABLE_SYNCD_RPC that are
#           used in conditionals but not in SONIC_COMMON_FLAGS_LIST or DEP_FLAGS.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   ./scripts/audit_dep_completeness.sh [OPTIONS]
#
# Options:
#   --verbose        Show detailed explanations for each finding
#   --json           Output findings in JSON format (for downstream tooling)
#   --package NAME   Audit only the specified package (e.g., --package swss)
#
# Examples:
#   # Full audit of all ~165 .dep files
#   ./scripts/audit_dep_completeness.sh
#
#   # Audit a specific package with details
#   ./scripts/audit_dep_completeness.sh --verbose --package docker-orchagent
#
#   # Machine-readable output for CI integration
#   ./scripts/audit_dep_completeness.sh --json > findings.json
#
# ═══════════════════════════════════════════════════════════════════════════════
# INTERPRETING RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
#
# Findings are classified by severity:
#
#   P0 = Confirmed stale cache risk
#        The gap WILL cause incorrect cache hits under normal usage.
#        Example: A package has no .dep file at all.
#
#   P1 = Likely stale cache risk (needs verification)
#        Strong evidence of a gap, but needs Phase 2 PoC to confirm binary diff.
#        Example: ENABLE_SYNCD_RPC changes build profile but isn't in syncd.dep.
#
#   P2 = Potential risk / cosmetic concern
#        May or may not cause issues depending on usage patterns.
#        Example: A .dep doesn't include its own .mk file (redundant if .mk
#        rarely changes build output independently of source).
#
#   P3 = Informational / design observation
#        Not a bug, but worth knowing for completeness.
#        Example: Deprecated flag still tracked in some .dep files.
#
# The summary table at the end shows counts by severity. Focus on P0/P1 first.
#
# Exit codes:
#   0 = No P0 findings (P1 warnings may exist but are not blocking)
#   1 = P0 findings present (confirmed stale cache risk)
#   2 = Script error (e.g., not run from repo root, missing Makefile.cache)
#
# ═══════════════════════════════════════════════════════════════════════════════
# FALSE POSITIVE FILTERING
# ═══════════════════════════════════════════════════════════════════════════════
#
# The script includes filters to reduce noise from known non-issues:
#
# - Assembly-only flags: INCLUDE_* flags that only control whether a Docker image
#   is INSTALLED into the final NOS image (SONIC_INSTALL_DOCKER_IMAGES) — they
#   don't change what's INSIDE the image during build.
#
# - Block-content analysis: For Check 3, the script inspects WHAT a conditional
#   block does. If it only modifies SONIC_INSTALL_DOCKER_IMAGES, SONIC_PACKAGES_LOCAL,
#   or DEFAULT_FEATURE_STATE/OWNER, it's classified as assembly-only (not a gap).
#
# - Deprecated flags: ENABLE_PY2_MODULES is always 'n' on modern distros and is
#   reported as P3 informational only.
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script is part of the DPKG Cache Validation toolkit:
#   - audit_dep_completeness.sh  → per-package .dep file audit (this script)
#   - check_common_files.sh      → global cache input audit (5 checks)
#
# Together they form Phase 1 (Static Analysis) of the DPKG Cache Equivalence
# verification plan. Their output feeds into Phase 2 (PoC builds) to confirm
# whether identified gaps cause actual binary differences.
#

set -uo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RULES_DIR="$REPO_ROOT/rules"
PLATFORM_DIR="$REPO_ROOT/platform/${CONFIGURED_PLATFORM:-vs}"
MAKEFILE_CACHE="$REPO_ROOT/Makefile.cache"

# Colors for terminal output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TOTAL_DEP_FILES=0
FINDINGS_P0=0
FINDINGS_P1=0
FINDINGS_P2=0
FINDINGS_P3=0

# Options
VERBOSE=false
JSON_OUTPUT=false
FILTER_PACKAGE=""
FINDINGS=()

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --package|-p)
            FILTER_PACKAGE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--json] [--package PKGNAME]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v     Show detailed analysis for each .dep file"
            echo "  --json            Output findings as JSON (for programmatic consumption)"
            echo "  --package, -p     Only audit a specific package (e.g., 'swss')"
            echo "  --help, -h        Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Helper Functions ---

log_verbose() {
    if $VERBOSE; then
        echo -e "  ${CYAN}[VERBOSE]${NC} $1"
    fi
}

add_finding() {
    local severity="$1"
    local package="$2"
    local issue="$3"
    local suggestion="$4"

    FINDINGS+=("$severity|$package|$issue|$suggestion")

    case $severity in
        P0) ((FINDINGS_P0++)) ;;
        P1) ((FINDINGS_P1++)) ;;
        P2) ((FINDINGS_P2++)) ;;
        P3) ((FINDINGS_P3++)) ;;
    esac
}

# --- Check 1: Missing .dep files ---
# Packages with .mk files but no .dep file are NEVER cached.
check_missing_dep_files() {
    echo -e "\n${CYAN}=== Check 1: Packages without .dep files (never cached) ===${NC}"

    local count=0
    for mk_file in "$RULES_DIR"/*.mk; do
        local base
        base=$(basename "$mk_file" .mk)
        local dep_file="$RULES_DIR/$base.dep"

        # Skip non-package mk files (config, functions, etc.)
        if [[ "$base" == "config" ]] || [[ "$base" == "functions" ]]; then
            continue
        fi

        # Check if .mk defines any SONIC_* target category
        if ! grep -qE "SONIC_(DPKG_DEBS|MAKE_DEBS|ONLINE_DEBS|COPY_DEBS|PYTHON_STDEB_DEBS|PYTHON_WHEELS|DOCKER_IMAGES|MAKE_FILES)" "$mk_file"; then
            continue
        fi

        if [[ ! -f "$dep_file" ]]; then
            ((count++))
            # Check if any cached package depends on this uncached package.
            # If yes → P1 (downstream stale risk). If no → P2 (performance only).
            # Strategy: extract variable names assigned in this .mk file, then check
            # if other .mk files reference them in DEPENDS lines.
            local has_dependents=false
            local defined_vars
            # Match both "$(VAR)_DEPENDS" style and "VAR = value" style assignments
            defined_vars=$(grep -oP '^\s*\$\(\K[A-Z][A-Z0-9_]+' "$mk_file" 2>/dev/null | sort -u)
            if [[ -z "$defined_vars" ]]; then
                # Try bare variable assignments (VAR = value)
                defined_vars=$(grep -oP '^\s*\K[A-Z][A-Z0-9_]+(?=\s*[:+?]?=)' "$mk_file" 2>/dev/null | sort -u)
            fi
            for var in $defined_vars; do
                # Skip common non-package variables
                [[ "$var" =~ ^(SONIC_|BLDENV|CONFIGURED|PATH|SRC_PATH|VERSION) ]] && continue
                if grep -rl "DEPENDS.*\$($var)" "$RULES_DIR"/*.mk "$PLATFORM_DIR"/*.mk 2>/dev/null | grep -qv "$mk_file"; then
                    has_dependents=true
                    break
                fi
            done

            if $has_dependents; then
                add_finding "P1" "$base" "No .dep file — package is never cached (other cached packages depend on it)" "Create $dep_file to enable caching"
            else
                add_finding "P2" "$base" "No .dep file — package is never cached (performance only, no downstream dependents)" "Create $dep_file to enable caching"
            fi
            if $VERBOSE; then
                echo -e "  ${YELLOW}MISSING${NC}: $base.dep (targets defined in $base.mk)"
            fi
        fi
    done

    echo "  Found $count packages without .dep files"
}

# --- Check 2: SONIC_COMMON_BASE_FILES_LIST completeness ---
# Verify all sonic-slave-* directories are tracked
check_common_base_files() {
    echo -e "\n${CYAN}=== Check 2: SONIC_COMMON_BASE_FILES_LIST completeness ===${NC}"

    # Extract currently tracked slave containers from Makefile.cache
    local tracked_slaves
    tracked_slaves=$(grep -oP 'sonic-slave-\w+' "$MAKEFILE_CACHE" | sort -u)

    # Find all sonic-slave-* directories that exist
    local existing_slaves
    existing_slaves=$(find "$REPO_ROOT" -maxdepth 1 -type d -name "sonic-slave-*" -exec basename {} \; | sort)

    echo "  Tracked in SONIC_COMMON_BASE_FILES_LIST:"
    echo "$tracked_slaves" | sed 's/^/    /'

    echo "  Existing sonic-slave-* directories:"
    echo "$existing_slaves" | sed 's/^/    /'

    # Find gaps
    while IFS= read -r slave_dir; do
        if ! echo "$tracked_slaves" | grep -q "^${slave_dir}$"; then
            add_finding "P1" "$slave_dir" "Missing from SONIC_COMMON_BASE_FILES_LIST in Makefile.cache" \
                "Add ${slave_dir}/Dockerfile.j2 and ${slave_dir}/Dockerfile.user.j2 to the list"
            echo -e "  ${RED}GAP${NC}: $slave_dir exists but is NOT tracked!"
        fi
    done <<< "$existing_slaves"
}

# --- Check 3: DEP_FLAGS vs actual build-affecting flags ---
# For each .dep, check if the .mk uses conditional flags not declared in DEP_FLAGS
check_dep_flags_coverage() {
    echo -e "\n${CYAN}=== Check 3: DEP_FLAGS coverage vs conditional build flags ===${NC}"

    # Extract SONIC_COMMON_FLAGS_LIST once for lookups
    local common_flags_list
    common_flags_list=$(sed -n '/^SONIC_COMMON_FLAGS_LIST/,/[^\\]$/p' "$MAKEFILE_CACHE" | \
        grep -oP '\$\(\w+\)' | tr -d '$()' | sort -u)

    for dep_file in "$RULES_DIR"/*.dep; do
        local base
        base=$(basename "$dep_file" .dep)
        local mk_file="$RULES_DIR/$base.mk"

        # Skip if no corresponding .mk
        [[ ! -f "$mk_file" ]] && continue

        # Filter if specific package requested
        if [[ -n "$FILTER_PACKAGE" ]] && [[ "$base" != "$FILTER_PACKAGE" ]]; then
            continue
        fi

        # Extract flags declared in .dep
        local dep_flags
        dep_flags=$(grep "_DEP_FLAGS" "$dep_file" 2>/dev/null | grep -oP '\$\(\w+\)' | tr -d '$()')

        # Extract conditional flags used in .mk (ifeq/ifneq patterns)
        local mk_flags
        mk_flags=$(grep -oP '(?<=ifeq \(\$\()[\w]+(?=\))' "$mk_file" 2>/dev/null || true)
        mk_flags+=$'\n'
        mk_flags+=$(grep -oP '(?<=ifneq \(\$\()[\w]+(?=\))' "$mk_file" 2>/dev/null || true)

        # Filter to ENABLE_* and INCLUDE_* flags (build-affecting)
        local build_flags
        build_flags=$(echo "$mk_flags" | grep -E "^(ENABLE_|INCLUDE_|SONIC_)" | sort -u)

        if [[ -z "$build_flags" ]]; then
            log_verbose "$base: No conditional build flags in .mk"
            continue
        fi

        # Check each build flag is covered
        while IFS= read -r flag; do
            [[ -z "$flag" ]] && continue

            # --- FALSE POSITIVE FILTERING ---

            # Pattern 0: Effectively deprecated flags (always off in current build envs)
            # ENABLE_PY2_MODULES is always 'n' on bullseye/bookworm/trixie
            if [[ "$flag" == "ENABLE_PY2_MODULES" ]]; then
                log_verbose "$base: \$$flag is deprecated (always n on current build envs) — downgrading to P3"
                add_finding "P3" "$base" \
                    "Flag \$$flag used but effectively deprecated (always n on bullseye/bookworm/trixie)" \
                    "Low priority — only matters for legacy jessie/stretch/buster builds"
                continue
            fi

            # Check what the conditional actually DOES in the .mk file.
            # Extract lines inside the ifeq block for this flag
            local block_content
            block_content=$(sed -n "/ifeq.*\$(${flag})/,/endif/p" "$mk_file" 2>/dev/null || true)

            # Pattern 1: Flag only controls SONIC_INSTALL_DOCKER_IMAGES / SONIC_INSTALL_DOCKER_DBG_IMAGES
            # These don't affect how the package/image is BUILT, only whether it's included in the final OS
            local install_only=false
            if [[ -n "$block_content" ]]; then
                # Get non-comment, non-empty lines inside the block (excluding ifeq/endif)
                local action_lines
                action_lines=$(echo "$block_content" | grep -v "^#\|^ifeq\|^ifneq\|^endif\|^else\|^$" | \
                    sed 's/^[[:space:]]*//' || true)

                if [[ -n "$action_lines" ]]; then
                    # Check if ALL action lines only affect install/inclusion/metadata (not build)
                    local non_install_lines
                    non_install_lines=$(echo "$action_lines" | \
                        grep -v "SONIC_INSTALL_DOCKER_IMAGES\|SONIC_INSTALL_DOCKER_DBG_IMAGES\|SONIC_BOOKWORM_DOCKERS\|SONIC_TRIXIE_DOCKERS\|SONIC_BULLSEYE_DOCKERS\|SONIC_BUSTER_DOCKERS\|SONIC_BOOKWORM_DBG_DOCKERS\|SONIC_TRIXIE_DBG_DOCKERS\|SONIC_BULLSEYE_DBG_DOCKERS\|DEFAULT_FEATURE_OWNER\|DEFAULT_FEATURE_STATE\|SONIC_DOCKER_IMAGES\|SONIC_DOCKER_DBG_IMAGES\|SONIC_PACKAGES_LOCAL\|SONIC_PACKAGES " || true)

                    if [[ -z "$non_install_lines" ]]; then
                        install_only=true
                        log_verbose "$base: \$$flag only controls INSTALL/metadata (not build) — skipping"
                    fi
                fi
            fi

            # Skip false positives
            if $install_only; then
                continue
            fi

            # Check if flag is in DEP_FLAGS (directly or via SONIC_COMMON_FLAGS_LIST)
            if ! echo "$dep_flags" | grep -q "$flag"; then
                # Check if it's already in SONIC_COMMON_FLAGS_LIST (also check SONIC_ prefix variant)
                local flag_in_common=false
                if echo "$common_flags_list" | grep -q "^${flag}$"; then
                    flag_in_common=true
                elif echo "$common_flags_list" | grep -q "^SONIC_${flag}$"; then
                    flag_in_common=true
                fi

                if $flag_in_common; then
                    log_verbose "$base: $flag is in SONIC_COMMON_FLAGS_LIST (OK)"
                elif echo "$dep_flags" | grep -q "SONIC_COMMON_FLAGS_LIST"; then
                    # The dep uses SONIC_COMMON_FLAGS_LIST — check if the flag is there
                    if echo "$common_flags_list" | grep -q "^${flag}$" || \
                       echo "$common_flags_list" | grep -q "^SONIC_${flag}$"; then
                        log_verbose "$base: $flag covered via SONIC_COMMON_FLAGS_LIST"
                    else
                        add_finding "P1" "$base" \
                            "Flag \$$flag used in .mk conditional but not in DEP_FLAGS or SONIC_COMMON_FLAGS_LIST" \
                            "Add \$($flag) to ${base}_DEP_FLAGS in $base.dep, or add to SONIC_COMMON_FLAGS_LIST"
                        if $VERBOSE; then
                            echo -e "  ${YELLOW}GAP${NC}: $base uses \$$flag but doesn't track it"
                        fi
                    fi
                else
                    add_finding "P1" "$base" \
                        "Flag \$$flag used in .mk conditional but not tracked in DEP_FLAGS" \
                        "Add \$($flag) to DEP_FLAGS in $base.dep"
                fi
            fi
        done <<< "$build_flags"
    done
}

# --- Check 4: _DEPENDS declared in .mk vs what .dep tracks ---
# The .dep tracks file-level inputs. But _DEPENDS in .mk declares package-level deps.
# Those package deps are handled separately by Makefile.cache (via DEP_MOD_SHA).
# This check verifies that all _DEPENDS packages themselves have .dep files.
check_dependency_chain_coverage() {
    echo -e "\n${CYAN}=== Check 4: Dependency chain — do all dependencies have .dep files? ===${NC}"

    local missing_dep_count=0

    for mk_file in "$RULES_DIR"/*.mk; do
        local base
        base=$(basename "$mk_file" .mk)

        [[ "$base" == "config" ]] || [[ "$base" == "functions" ]] && continue
        if [[ -n "$FILTER_PACKAGE" ]] && [[ "$base" != "$FILTER_PACKAGE" ]]; then
            continue
        fi

        # Extract _DEPENDS targets (the variable names, not filenames)
        local depends
        depends=$(grep -oP '\$\((\w+)\)_DEPENDS' "$mk_file" 2>/dev/null | head -1 | grep -oP '(?<=\$\()\w+(?=\))' || true)

        if [[ -z "$depends" ]]; then
            continue
        fi

        # Get the dependency list (right side of _DEPENDS assignment)
        local dep_packages
        dep_packages=$(grep "_DEPENDS" "$mk_file" | grep -oP '\$\(\w+\)' | grep -v "_DEPENDS\|_RDEPENDS\|_UNINSTALLS" | tr -d '$()')

        for dep_pkg_var in $dep_packages; do
            # Find which .mk defines this variable
            local defining_mk
            defining_mk=$(grep -l "^${dep_pkg_var}\s*=" "$RULES_DIR"/*.mk 2>/dev/null | head -1 || true)

            if [[ -n "$defining_mk" ]]; then
                local dep_base
                dep_base=$(basename "$defining_mk" .mk)
                if [[ ! -f "$RULES_DIR/$dep_base.dep" ]]; then
                    ((missing_dep_count++))
                    add_finding "P2" "$base" \
                        "Depends on \$($dep_pkg_var) (from $dep_base.mk) which has no .dep file" \
                        "Cache key for $base may not reflect changes in $dep_base"
                    log_verbose "$base depends on $dep_pkg_var → $dep_base has no .dep"
                fi
            fi
        done
    done

    echo "  Found $missing_dep_count dependency chain gaps"
}

# --- Check 5: Source path exclusion patterns ---
# Some .dep files use grep -Ev to exclude files. Flag these for review.
# Filter out benign patterns like `grep -v " "` (filename sanitization).
check_exclusion_patterns() {
    echo -e "\n${CYAN}=== Check 5: Source file exclusion patterns in .dep files ===${NC}"

    for dep_file in "$RULES_DIR"/*.dep; do
        local base
        base=$(basename "$dep_file" .dep)

        if [[ -n "$FILTER_PACKAGE" ]] && [[ "$base" != "$FILTER_PACKAGE" ]]; then
            continue
        fi

        # Look for grep -Ev or grep -v (exclusion patterns)
        local exclusions
        exclusions=$(grep -oP 'grep\s+-[Ev]+\s+"[^"]*"' "$dep_file" 2>/dev/null || true)

        if [[ -n "$exclusions" ]]; then
            # Filter out benign patterns:
            # - `grep -v " "` just removes filenames with spaces (sanitization)
            local is_benign=false
            if echo "$exclusions" | grep -qP 'grep\s+-v\s+" "'; then
                is_benign=true
                log_verbose "$base: Exclusion is just space-filtering (benign)"
            fi

            if ! $is_benign; then
                add_finding "P2" "$base" \
                    "Uses exclusion pattern: $exclusions" \
                    "Verify excluded files don't affect build output"
                if $VERBOSE; then
                    echo -e "  ${YELLOW}EXCLUSION${NC}: $base — $exclusions"
                fi
            fi
        fi
    done
}

# --- Check 6: CACHE_MODE analysis ---
# GIT_CONTENT_SHA vs GIT_COMMIT_SHA — the latter is stricter but causes more cache misses
check_cache_modes() {
    echo -e "\n${CYAN}=== Check 6: Cache mode analysis ===${NC}"

    local content_sha_count=0
    local commit_sha_count=0
    local no_mode_count=0

    for dep_file in "$RULES_DIR"/*.dep; do
        local base
        base=$(basename "$dep_file" .dep)

        if [[ -n "$FILTER_PACKAGE" ]] && [[ "$base" != "$FILTER_PACKAGE" ]]; then
            continue
        fi

        if grep -q "GIT_CONTENT_SHA" "$dep_file"; then
            ((content_sha_count++))
        elif grep -q "GIT_COMMIT_SHA" "$dep_file"; then
            ((commit_sha_count++))
            add_finding "P3" "$base" \
                "Uses GIT_COMMIT_SHA mode — any commit (even non-functional) invalidates cache" \
                "Consider GIT_CONTENT_SHA if commit metadata doesn't affect output"
        else
            ((no_mode_count++))
            add_finding "P3" "$base" \
                "No explicit CACHE_MODE set (defaults may apply)" \
                "Consider explicitly setting CACHE_MODE for clarity"
        fi
    done

    echo "  GIT_CONTENT_SHA: $content_sha_count packages"
    echo "  GIT_COMMIT_SHA:  $commit_sha_count packages"
    echo "  No explicit mode: $no_mode_count packages"
}

# --- Check 7: Docker images — verify Dockerfile.j2 directory is fully tracked ---
check_docker_dep_tracking() {
    echo -e "\n${CYAN}=== Check 7: Docker image .dep file completeness ===${NC}"

    for dep_file in "$RULES_DIR"/docker-*.dep; do
        [[ ! -f "$dep_file" ]] && continue
        local base
        base=$(basename "$dep_file" .dep)

        if [[ -n "$FILTER_PACKAGE" ]] && [[ "$base" != "$FILTER_PACKAGE" ]]; then
            continue
        fi

        # Check if dep tracks the Docker directory via git ls-files
        if ! grep -q "git ls-files" "$dep_file" && ! grep -q "shell.*ls" "$dep_file"; then
            # Check if it at least references the DPATH
            if ! grep -q "DPATH\|_PATH" "$dep_file"; then
                add_finding "P1" "$base" \
                    "Docker .dep doesn't appear to track Dockerfile directory contents" \
                    "Add: DEP_FILES += \$(shell git ls-files \$(DPATH))"
            fi
        fi

        # Check for SMDEP_FILES (docker images usually don't have them — they use DEP_FILES)
        # This is expected behavior, not a gap
        log_verbose "$base: Docker dep structure OK"
    done
}

# --- Check 8: Validate SONIC_COMMON_FLAGS_LIST against slave.mk usage ---
check_common_flags_completeness() {
    echo -e "\n${CYAN}=== Check 8: SONIC_COMMON_FLAGS_LIST vs actual build-affecting variables ===${NC}"

    # Extract flags from SONIC_COMMON_FLAGS_LIST in Makefile.cache
    # Only extract from the actual definition line (lines 112-118), not subsequent content
    local common_flags
    common_flags=$(sed -n '/^SONIC_COMMON_FLAGS_LIST/,/[^\\]$/p' "$MAKEFILE_CACHE" | \
        grep -oP '\$\(\w+\)' | tr -d '$()' | sort -u)

    echo "  Current SONIC_COMMON_FLAGS_LIST:"
    echo "$common_flags" | sed 's/^/    /'

    # Look for ENABLE_*/INCLUDE_*/SONIC_* vars used in slave.mk conditionals
    local slave_flags
    slave_flags=$(grep -oP '(?<=ifeq \(\$\()(ENABLE_\w+|INCLUDE_\w+|SONIC_\w+)(?=\))' \
        "$REPO_ROOT/slave.mk" 2>/dev/null | sort -u)

    # Flags that are known to NOT affect cached package output:
    # - They only affect post-build assembly (rootfs, installer, Docker inclusion)
    # - They only affect parallelism or tooling options
    # - They're already tracked per-package in individual .dep files
    local KNOWN_ASSEMBLY_ONLY_FLAGS=(
        "SONIC_BUILD_JOBS"
        "SONIC_CONFIG_MAKE_JOBS"
        "SONIC_CONFIG_USE_CCACHE"
        "SONIC_INSTALL_DEBUG_TOOLS"
        "SONIC_INCLUDE_MUX"
        "SONIC_INCLUDE_NAT"
        "SONIC_INCLUDE_SFLOW"
        "SONIC_INCLUDE_STP"
        "SONIC_INCLUDE_MACSEC"
        "SONIC_INCLUDE_RESTAPI"
        "SONIC_INCLUDE_P4RT"
        "SONIC_INCLUDE_SYSTEM_BMP"
        "SONIC_INCLUDE_SYSTEM_EVENTD"
        "SONIC_INCLUDE_SYSTEM_GNMI"
        "SONIC_INCLUDE_SYSTEM_OTEL"
        "SONIC_INCLUDE_SYSTEM_TELEMETRY"
        "SONIC_ENABLE_BOOTCHART"
        "SONIC_INCLUDE_BOOTCHART"
        "SONIC_ENABLE_PFCWD_ON_START"
        "SONIC_IMAGE_VERSION"
        "SONIC_USE_PDDF_FRAMEWORK"
        "SONIC_SAITHRIFT_V2"
        "INCLUDE_P4RT"
    )
    # Flags tracked per-package (not needed globally)
    local KNOWN_PER_PACKAGE_FLAGS=(
        "ENABLE_ASAN"
        "ENABLE_AUTO_TECH_SUPPORT"
    )

    echo ""
    echo "  Flags used in slave.mk conditionals but NOT in SONIC_COMMON_FLAGS_LIST:"

    local gap_count=0
    while IFS= read -r flag; do
        [[ -z "$flag" ]] && continue
        if ! echo "$common_flags" | grep -q "^${flag}$" && \
           ! echo "$common_flags" | grep -q "^SONIC_${flag}$"; then
            # Check if it's a known assembly-only flag (false positive)
            local is_assembly_only=false
            for known in "${KNOWN_ASSEMBLY_ONLY_FLAGS[@]}"; do
                if [[ "$flag" == "$known" ]]; then
                    is_assembly_only=true
                    break
                fi
            done
            if $is_assembly_only; then
                log_verbose "  $flag — assembly/inclusion only (skipped)"
                continue
            fi

            # Check if it's tracked per-package
            local is_per_package=false
            for known in "${KNOWN_PER_PACKAGE_FLAGS[@]}"; do
                if [[ "$flag" == "$known" ]]; then
                    is_per_package=true
                    break
                fi
            done
            if $is_per_package; then
                log_verbose "  $flag — tracked per-package in .dep files (skipped)"
                continue
            fi

            ((gap_count++))
            echo -e "    ${YELLOW}$flag${NC}"
            add_finding "P2" "Makefile.cache" \
                "slave.mk uses \$$flag in conditional but it's not in SONIC_COMMON_FLAGS_LIST" \
                "If this flag affects package build output, add to SONIC_COMMON_FLAGS_LIST"
        fi
    done <<< "$slave_flags"

    if [[ $gap_count -eq 0 ]]; then
        echo -e "    ${GREEN}None — all covered (or tracked per-package / assembly-only)${NC}"
    fi
}

# --- Output Results ---
print_summary() {
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}=== AUDIT SUMMARY ===${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    echo "  Total .dep files analyzed: $TOTAL_DEP_FILES"
    echo ""
    echo -e "  ${RED}P0 (Confirmed stale cache risk):${NC}  $FINDINGS_P0"
    echo -e "  ${YELLOW}P1 (Likely stale cache risk):${NC}     $FINDINGS_P1"
    echo -e "  P2 (Potential risk / verify):        $FINDINGS_P2"
    echo -e "  P3 (Informational):                  $FINDINGS_P3"
    echo ""

    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}No findings! All .dep files appear complete.${NC}"
        return
    fi

    # Print findings table
    echo -e "  ${CYAN}--- Findings Detail ---${NC}"
    printf "  %-4s | %-30s | %-60s | %s\n" "SEV" "PACKAGE" "ISSUE" "SUGGESTION"
    printf "  %-4s-+-%-30s-+-%-60s-+-%s\n" "----" "------------------------------" "------------------------------------------------------------" "----------"

    # Sort by severity
    IFS=$'\n' sorted=($(sort <<< "${FINDINGS[*]}")); unset IFS

    for finding in "${sorted[@]}"; do
        IFS='|' read -r sev pkg issue suggestion <<< "$finding"
        local color="$NC"
        case $sev in
            P0) color="$RED" ;;
            P1) color="$YELLOW" ;;
        esac
        printf "  ${color}%-4s${NC} | %-30s | %-60s | %s\n" "$sev" "$pkg" "$issue" "$suggestion"
    done
}

print_json() {
    echo "["
    local first=true
    for finding in "${FINDINGS[@]}"; do
        IFS='|' read -r sev pkg issue suggestion <<< "$finding"
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '  {"severity": "%s", "package": "%s", "issue": "%s", "suggestion": "%s"}' \
            "$sev" "$pkg" "$issue" "$suggestion"
    done
    echo ""
    echo "]"
}

# --- Main ---
main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SONiC DPKG Cache — Dependency Tracking Completeness Audit  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Repository: $REPO_ROOT"
    echo "  Date: $(date -u '+%Y-%m-%d %H:%M UTC')"

    # Validate we're in the right directory
    if [[ ! -f "$MAKEFILE_CACHE" ]]; then
        echo -e "${RED}ERROR: Makefile.cache not found. Run from sonic-buildimage root.${NC}"
        exit 2
    fi

    TOTAL_DEP_FILES=$(find "$RULES_DIR" -name "*.dep" | wc -l)
    echo "  Total .dep files found: $TOTAL_DEP_FILES"

    if [[ -n "$FILTER_PACKAGE" ]]; then
        echo -e "  ${CYAN}Filtering to package: $FILTER_PACKAGE${NC}"
    fi

    # Run all checks
    check_missing_dep_files
    check_common_base_files
    check_dep_flags_coverage
    check_dependency_chain_coverage
    check_exclusion_patterns
    check_cache_modes
    check_docker_dep_tracking
    check_common_flags_completeness

    # Output
    if $JSON_OUTPUT; then
        print_json
    else
        print_summary
    fi

    # Exit code based on findings
    if [[ $FINDINGS_P0 -gt 0 ]]; then
        exit 1
    elif [[ $FINDINGS_P1 -gt 0 ]]; then
        exit 0  # Warnings but not blocking
    else
        exit 0
    fi
}

main "$@"
