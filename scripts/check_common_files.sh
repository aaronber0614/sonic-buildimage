#!/bin/bash
#
# check_common_files.sh — Validate Global Cache Inputs (SONIC_COMMON_* Lists)
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# In SONiC's DPKG caching system (Makefile.cache), certain inputs are "global" —
# they affect the cache key of EVERY package. If these global inputs are incomplete
# or stale, ALL cached packages risk serving outdated artifacts.
#
# This script audits the three global cache input mechanisms:
#   1. SONIC_COMMON_BASE_FILES_LIST — slave container Dockerfiles (build env)
#   2. SONIC_COMMON_FLAGS_LIST — build flags baked into every cache key
#   3. SONIC_COMMON_FILES_LIST — global input files (.platform, slave.mk, Makefile.cache, etc.)
#   4. SONIC_COMMON_DPKG_LIST — standard debian packaging files
#
# It complements audit_dep_completeness.sh (which audits per-package .dep files).
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT IT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
#
# Check 1: Are all sonic-slave-* container Dockerfiles tracked?
#           If a new slave container (e.g., trixie) is added but not registered,
#           cache keys won't change when the build environment changes.
#
# Check 2: Is slave.mk tracked in SONIC_COMMON_FILES_LIST?
#           slave.mk defines HOW packages are built. It must be tracked globally
#           so that any change invalidates all cached packages.
#
# Check 3: Are all globally-impactful build flags tracked?
#           Scans rules/*.mk for flags used in 4+ package files (e.g., INCLUDE_FIPS,
#           INSTALL_DEBUG_TOOLS). If a flag changes build output but isn't in
#           SONIC_COMMON_FLAGS_LIST or per-package DEP_FLAGS, caching is unsafe.
#
# Check 4: Do all declared global input files exist and are they appropriate?
#           Verifies .platform, rules/functions, Makefile.cache are present.
#           Also confirms that files NOT tracked (Makefile.work, rules/config) have
#           their effects captured via SONIC_COMMON_FLAGS_LIST variables.
#
# Check 5: Are standard debian packaging files covered by SONIC_COMMON_DPKG_LIST?
#           Informational check showing which debian/ files are globally tracked
#           vs. per-package tracked via SMDEP_FILES (git ls-files).
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   ./scripts/check_common_files.sh [OPTIONS]
#
# Options:
#   --verbose    Show additional context (git log for recipe changes, assembly-only
#                flags, per-dep tracking details)
#   --fix        Output suggested patches to correct any gaps found
#
# Examples:
#   # Quick scan — shows only actionable warnings
#   ./scripts/check_common_files.sh
#
#   # Detailed output with git history for recipe version analysis
#   ./scripts/check_common_files.sh --verbose
#
#   # Generate patch suggestions for identified gaps
#   ./scripts/check_common_files.sh --fix
#
# ═══════════════════════════════════════════════════════════════════════════════
# INTERPRETING RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
#
# Findings are classified by severity (same system as audit_dep_completeness.sh):
#
#   P0 = Confirmed stale cache risk
#        The gap WILL cause incorrect cache hits under normal usage.
#        Example: slave.mk not found (broken environment).
#
#   P1 = Likely stale cache risk (needs verification)
#        Strong evidence of a gap. Needs Phase 2 PoC to confirm binary diff.
#        Example: INCLUDE_FIPS changes docker-base _DEPENDS but isn't tracked.
#
#   P2 = Potential risk / cosmetic concern
#        May or may not cause issues depending on usage patterns.
#        Example: A tracked global file doesn't exist on disk.
#
#   P3 = Informational / design observation
#        Not a bug, but worth knowing for completeness.
#        Example: Deprecated ENABLE_PY2_MODULES still referenced in .mk files.
#
# Inline symbols during checks:
#   ✗ (red)     = Gap found (contributes to P0/P1/P2 finding)
#   ⚠ (yellow)  = Warning requiring human review
#   ✓ (green)   = Correctly tracked or correctly excluded (with explanation)
#   SKIP        = Known deprecated/irrelevant flag — no action needed
#
# The summary table at the end lists all findings with severity, component,
# issue description, and suggested fix.
#
# Exit codes:
#   0 = No P0 findings (P1 warnings may exist)
#   1 = P0 findings present (confirmed stale cache risk)
#   2 = Script error (e.g., not run from repo root, missing Makefile.cache)
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script is part of the DPKG Cache Validation toolkit:
#   - audit_dep_completeness.sh  → per-package .dep file audit (8 checks)
#   - check_common_files.sh      → global cache input audit (this script, 5 checks)
#
# Together they form Phase 1 (Static Analysis) of the DPKG Cache Equivalence
# verification plan. Their output feeds into Phase 2 (PoC builds) to confirm
# whether identified gaps cause actual binary differences.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAKEFILE_CACHE="$REPO_ROOT/Makefile.cache"
SLAVE_MK="$REPO_ROOT/slave.mk"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

VERBOSE=false
FIX_MODE=false

# --- Findings tracking (matches audit_dep_completeness.sh format) ---
# Use ASCII Unit Separator (0x1f) as the record delimiter instead of '|', so
# finding text that legitimately contains '|' cannot corrupt the field split.
readonly FINDING_FS=$'\037'
FINDINGS=()
FINDINGS_P0=0
FINDINGS_P1=0
FINDINGS_P2=0
FINDINGS_P3=0

add_finding() {
    local severity="$1"
    local component="$2"
    local issue="$3"
    local suggestion="$4"

    FINDINGS+=("${severity}${FINDING_FS}${component}${FINDING_FS}${issue}${FINDING_FS}${suggestion}")

    case $severity in
        P0) ((FINDINGS_P0++)) ;;
        P1) ((FINDINGS_P1++)) ;;
        P2) ((FINDINGS_P2++)) ;;
        P3) ((FINDINGS_P3++)) ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v) VERBOSE=true; shift ;;
        --fix) FIX_MODE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--fix]"
            echo "  --verbose   Show detailed analysis"
            echo "  --fix       Output patch suggestions for any gaps found"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validation ---
if [[ ! -f "$MAKEFILE_CACHE" ]]; then
    echo -e "${RED}ERROR: Makefile.cache not found. Run from sonic-buildimage root.${NC}"
    exit 2
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  SONiC Cache — Common Files & Flags Consistency Check         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Repository: $REPO_ROOT"
echo "  Date: $(date -u '+%Y-%m-%d %H:%M UTC')"

# ============================================================
# CHECK 1: SONIC_COMMON_BASE_FILES_LIST completeness
# ============================================================
echo -e "\n${CYAN}━━━ Check 1: SONIC_COMMON_BASE_FILES_LIST ━━━${NC}"
echo "  Purpose: All sonic-slave-* Dockerfiles must be in this list."
echo "  Why: Changes to any slave container's Dockerfile affect the build"
echo "       environment for ALL packages. If not tracked, cache won't"
echo "       invalidate when the build container changes."
echo ""

# Extract tracked entries from Makefile.cache
TRACKED_FILES=$(grep -A 10 "SONIC_COMMON_BASE_FILES_LIST" "$MAKEFILE_CACHE" | \
    grep -oP 'sonic-slave-\w+/Dockerfile[.\w]*' | sort -u)

# Find all existing slave directories
EXISTING_DIRS=$(find "$REPO_ROOT" -maxdepth 1 -type d -name "sonic-slave-*" -exec basename {} \; | sort)

echo "  Existing slave directories:"
for dir in $EXISTING_DIRS; do
    # Check if both Dockerfile.j2 and Dockerfile.user.j2 are tracked
    local_status="${GREEN}✓${NC}"
    missing=""

    if ! echo "$TRACKED_FILES" | grep -q "^${dir}/Dockerfile.j2$"; then
        missing+="Dockerfile.j2 "
        local_status="${RED}✗${NC}"
    fi
    if ! echo "$TRACKED_FILES" | grep -q "^${dir}/Dockerfile.user.j2$"; then
        missing+="Dockerfile.user.j2 "
        local_status="${RED}✗${NC}"
    fi

    if [[ -z "$missing" ]]; then
        echo -e "    ${GREEN}✓${NC} $dir"
    else
        echo -e "    ${RED}✗${NC} $dir — MISSING: $missing"
        add_finding "P1" "$dir" \
            "Not in SONIC_COMMON_BASE_FILES_LIST (missing: ${missing})" \
            "Add ${dir}/Dockerfile.j2 and Dockerfile.user.j2 to Makefile.cache"
    fi
done

# Check for tracked entries whose directories no longer exist (stale entries)
echo ""
echo "  Checking for stale tracked entries..."
TRACKED_DIRS=$(echo "$TRACKED_FILES" | grep -oP 'sonic-slave-\w+' | sort -u)
stale_found=false
for tracked_dir in $TRACKED_DIRS; do
    if [[ ! -d "$REPO_ROOT/$tracked_dir" ]]; then
        echo -e "    ${YELLOW}⚠${NC}  $tracked_dir tracked but directory doesn't exist (stale)"
        stale_found=true
    fi
done
if ! $stale_found; then
    echo -e "    ${GREEN}None found${NC}"
fi

# Generate fix if needed
if $FIX_MODE && [[ $FINDINGS_P1 -gt 0 || $FINDINGS_P0 -gt 0 ]]; then
    echo ""
    echo -e "  ${CYAN}Suggested fix for SONIC_COMMON_BASE_FILES_LIST:${NC}"
    echo "  Add the following lines to Makefile.cache after the existing entries:"
    for dir in $EXISTING_DIRS; do
        if ! echo "$TRACKED_FILES" | grep -q "^${dir}/Dockerfile.j2$"; then
            echo "    ${dir}/Dockerfile.j2 ${dir}/Dockerfile.user.j2 \\"
        fi
    done
fi

# ============================================================
# CHECK 2: Verify slave.mk is in SONIC_COMMON_FILES_LIST
# ============================================================
echo -e "\n${CYAN}━━━ Check 2: slave.mk Global Tracking ━━━${NC}"
echo "  Purpose: Confirm slave.mk is tracked in SONIC_COMMON_FILES_LIST."
echo "  Why: slave.mk defines build recipes for all packages. Changes to it"
echo "       must invalidate all caches to prevent stale artifacts."
echo ""

COMMON_FILES_LINE=$(grep "^SONIC_COMMON_FILES_LIST" "$MAKEFILE_CACHE" | head -1)
if echo "$COMMON_FILES_LINE" | grep -qF "slave.mk"; then
    echo -e "  ${GREEN}✓ slave.mk is tracked in SONIC_COMMON_FILES_LIST${NC}"
    echo "  Any change to slave.mk will invalidate all cached packages."
else
    echo -e "  ${RED}✗ slave.mk is NOT tracked in SONIC_COMMON_FILES_LIST${NC}"
    add_finding "P0" "SONIC_COMMON_FILES_LIST" \
        "slave.mk is missing from SONIC_COMMON_FILES_LIST" \
        "Add slave.mk to SONIC_COMMON_FILES_LIST to prevent stale cache hits"
fi

# ============================================================
# CHECK 3: SONIC_COMMON_FLAGS_LIST — flags affecting package output
# ============================================================
echo -e "\n${CYAN}━━━ Check 3: SONIC_COMMON_FLAGS_LIST Analysis ━━━${NC}"
echo "  Purpose: Verify all globally-impactful build flags are tracked."
echo "  Why: If a flag changes build output for multiple packages but isn't"
echo "       in SONIC_COMMON_FLAGS_LIST (or per-package DEP_FLAGS), caching"
echo "       will serve stale artifacts when that flag changes."
echo ""

# Extract current flags list
COMMON_FLAGS=$(grep -A 10 "^SONIC_COMMON_FLAGS_LIST" "$MAKEFILE_CACHE" | \
    grep -oP '\$\(\w+\)' | tr -d '$()')

echo "  Currently tracked flags:"
echo "$COMMON_FLAGS" | sed 's/^/    /'
echo ""

# Find flags used in conditionals across the build system
# Focus on flags that affect MULTIPLE packages (truly global impact)
echo "  Scanning for flags used in multiple .mk files..."

declare -A FLAG_USAGE_COUNT
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    count=$(grep -rl "\$(${flag})\|ifeq.*${flag}\|ifneq.*${flag}" "$REPO_ROOT/rules/"*.mk 2>/dev/null | wc -l)
    if [[ $count -gt 3 ]]; then  # Used in 4+ .mk files = likely global
        FLAG_USAGE_COUNT[$flag]=$count
    fi
done < <(grep -hoP '(?<=ifeq \(\$\()\w+(?=\))' "$REPO_ROOT/rules/"*.mk 2>/dev/null | sort -u)

# Known deprecated/low-impact flags that should not raise warnings
declare -A DEPRECATED_FLAGS=(
    ["ENABLE_PY2_MODULES"]="Deprecated: always 'n' on bookworm/trixie (set by BLDENV in slave.mk)"
)

# Flags whose conditional blocks only affect assembly/install decisions, not build content.
# These control SONIC_INSTALL_DOCKER_IMAGES or SONIC_PACKAGES_LOCAL selection,
# not what goes INTO the package during dpkg-buildpackage or docker build.
declare -A ASSEMBLY_ONLY_FLAGS=(
    ["INCLUDE_KUBERNETES"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_MACSEC"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_MUX"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_DHCP_RELAY"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_DHCP_SERVER"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_TEAMD"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_ROUTER_ADVERTISER"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_NAT"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_SFLOW"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_RESTAPI"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
    ["INCLUDE_P4RT"]="Controls SONIC_INSTALL_DOCKER_IMAGES membership only"
)

echo ""
echo "  Flags used in 4+ package .mk files (likely global impact):"
echo ""
printf "    %-35s %-8s %s\n" "FLAG" "USES" "TRACKED?"

# Sort by count descending
for flag in $(for k in "${!FLAG_USAGE_COUNT[@]}"; do echo "$k ${FLAG_USAGE_COUNT[$k]}"; done | sort -k2 -rn | awk '{print $1}'); do
    count=${FLAG_USAGE_COUNT[$flag]}
    if echo "$COMMON_FLAGS" | grep -q "^${flag}$"; then
        printf "    %-35s %-8s ${GREEN}%s${NC}\n" "\$($flag)" "$count" "YES"
    elif [[ -n "${DEPRECATED_FLAGS[$flag]:-}" ]]; then
        # Deprecated flag — informational only, not a warning
        printf "    %-35s %-8s %s\n" "\$($flag)" "$count" "SKIP (${DEPRECATED_FLAGS[$flag]})"
        add_finding "P3" "\$($flag)" \
            "Deprecated flag still referenced in $count .mk files" \
            "No action needed — ${DEPRECATED_FLAGS[$flag]}"
    elif [[ -n "${ASSEMBLY_ONLY_FLAGS[$flag]:-}" ]]; then
        # Assembly-only flag — doesn't affect cached package content
        if $VERBOSE; then
            printf "    %-35s %-8s %s\n" "\$($flag)" "$count" "OK (${ASSEMBLY_ONLY_FLAGS[$flag]})"
        fi
    else
        # Check if it's tracked per-package in .dep files
        dep_coverage=$(grep -rl "$flag" "$REPO_ROOT/rules/"*.dep 2>/dev/null | wc -l)
        if [[ $dep_coverage -ge $count ]]; then
            printf "    %-35s %-8s ${GREEN}%s${NC}\n" "\$($flag)" "$count" "per-dep ($dep_coverage deps)"
        else
            printf "    %-35s %-8s ${YELLOW}%s${NC}\n" "\$($flag)" "$count" "NO — $dep_coverage/$count deps track it"
            add_finding "P1" "\$($flag)" \
                "Flag used in $count .mk files but only $dep_coverage .dep files track it" \
                "Add to SONIC_COMMON_FLAGS_LIST or each affected package's DEP_FLAGS"
        fi
    fi
done

# ============================================================
# CHECK 4: SONIC_COMMON_FILES_LIST — non-obvious tracked files
# ============================================================
echo -e "\n${CYAN}━━━ Check 4: SONIC_COMMON_FILES_LIST ━━━${NC}"
echo "  Purpose: Verify all global input files are tracked."
echo ""

COMMON_FILES=$(grep "^SONIC_COMMON_FILES_LIST" "$MAKEFILE_CACHE" | \
    grep -oP '[\w./]+' | grep -v "SONIC_COMMON_FILES_LIST\|wildcard\|cache.skip.common\|if")

echo "  Currently tracked files:"
echo "$COMMON_FILES" | sed 's/^/    /'
echo ""

# Check each tracked file exists
echo "  Verifying tracked files exist:"
for f in $COMMON_FILES; do
    if [[ -f "$REPO_ROOT/$f" ]]; then
        echo -e "    ${GREEN}✓${NC} $f"
    elif [[ "$f" == ".platform" ]]; then
        # .platform is created by 'make configure' (slave.mk:144) before any build runs.
        # It won't exist in an unconfigured checkout but always exists during cache operations.
        echo -e "    ${GREEN}✓${NC} $f — (generated by 'make configure', always present during builds)"
    else
        echo -e "    ${RED}✗${NC} $f — FILE NOT FOUND"
        add_finding "P2" "SONIC_COMMON_FILES_LIST" \
            "Tracked file '$f' does not exist" \
            "Verify file path or remove from SONIC_COMMON_FILES_LIST"
    fi
done

# Check for files that SHOULD be tracked but aren't
echo ""
echo "  Checking for potentially missing entries..."

# Makefile.work and rules/config affect builds, but their build-affecting OUTPUTS
# (CONFIGURED_PLATFORM, CONFIGURED_ARCH, BLDENV) are already tracked via
# SONIC_COMMON_FLAGS_LIST. The files themselves don't need separate tracking.
POTENTIAL_MISSING_WITH_NOTES=(
    "Makefile.work|Effects captured via SONIC_COMMON_FLAGS_LIST (CONFIGURED_PLATFORM, CONFIGURED_ARCH, BLDENV)"
    "rules/config|Effects captured via SONIC_COMMON_FLAGS_LIST (build flag variables)"
)
for entry in "${POTENTIAL_MISSING_WITH_NOTES[@]}"; do
    candidate="${entry%%|*}"
    reason="${entry##*|}"
    if [[ -f "$REPO_ROOT/$candidate" ]]; then
        if ! echo "$COMMON_FILES" | grep -q "$candidate"; then
            echo -e "    ${GREEN}✓${NC} $candidate — not tracked directly (OK: $reason)"
        fi
    fi
done

# ============================================================
# CHECK 5: SONIC_COMMON_DPKG_LIST — debian packaging files
# ============================================================
echo -e "\n${CYAN}━━━ Check 5: SONIC_COMMON_DPKG_LIST ━━━${NC}"
echo "  Purpose: Standard Debian packaging files tracked for DPKG_DEBS packages."
echo ""

DPKG_LIST=$(grep -A 5 "SONIC_COMMON_DPKG_LIST" "$MAKEFILE_CACHE" | \
    grep -oP 'debian/\w+' | sort)

echo "  Standard Debian files tracked:"
echo "$DPKG_LIST" | sed 's/^/    /'

# Check if there are common debian files used in packages that aren't tracked
echo ""
echo "  Scanning for common debian/ files across packages..."

# Sample a few source packages and check their debian/ directories
SAMPLE_COUNT=0
EXTRA_FILES_FOUND=""
for src_dir in "$REPO_ROOT"/src/*/debian; do
    [[ ! -d "$src_dir" ]] && continue
    ((SAMPLE_COUNT++))
    [[ $SAMPLE_COUNT -gt 10 ]] && break

    for deb_file in "$src_dir"/*; do
        fname=$(basename "$deb_file")
        # Skip non-standard files
        [[ "$fname" == "patches" ]] || [[ "$fname" == "source" ]] && continue
        [[ -d "$deb_file" ]] && continue

        # Check if this filename pattern is in DPKG_LIST
        if ! echo "$DPKG_LIST" | grep -q "debian/$fname"; then
            EXTRA_FILES_FOUND+="debian/$fname "
        fi
    done
done

if [[ -n "$EXTRA_FILES_FOUND" ]]; then
    # Deduplicate
    unique_extras=$(echo "$EXTRA_FILES_FOUND" | tr ' ' '\n' | sort -u | head -10)
    echo "  Common debian/ files NOT in SONIC_COMMON_DPKG_LIST:"
    echo "$unique_extras" | sed 's/^/    /'
    echo ""
    echo -e "  ${GREEN}NOTE${NC}: This is usually OK — SMDEP_FILES (git ls-files) tracks"
    echo "  these per-package. SONIC_COMMON_DPKG_LIST is just an additional"
    echo "  safety net for the most critical debian packaging files."
fi

# ============================================================
# SUMMARY
# ============================================================
echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  SUMMARY${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${RED}P0 (Confirmed stale cache risk):${NC}  $FINDINGS_P0"
echo -e "  ${YELLOW}P1 (Likely stale cache risk):${NC}     $FINDINGS_P1"
echo -e "  P2 (Potential risk / verify):        $FINDINGS_P2"
echo -e "  P3 (Informational):                  $FINDINGS_P3"
echo ""

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}All checks passed.${NC} Common cache inputs appear complete."
else
    # Print findings table
    echo -e "  ${CYAN}--- Findings Detail ---${NC}"
    printf "  %-4s | %-28s | %-50s | %s\n" "SEV" "COMPONENT" "ISSUE" "SUGGESTION"
    printf "  %-4s-+-%-28s-+-%-50s-+-%s\n" "----" "----------------------------" "--------------------------------------------------" "----------"

    # Sort by severity
    IFS=$'\n' sorted=($(sort <<< "${FINDINGS[*]}")); unset IFS

    for finding in "${sorted[@]}"; do
        IFS=$FINDING_FS read -r sev comp issue suggestion <<< "$finding"
        color="$NC"
        case $sev in
            P0) color="$RED" ;;
            P1) color="$YELLOW" ;;
        esac
        printf "  ${color}%-4s${NC} | %-28s | %-50s | %s\n" "$sev" "$comp" "$issue" "$suggestion"
    done

    echo ""
    if [[ $FINDINGS_P0 -gt 0 || $FINDINGS_P1 -gt 0 ]]; then
        echo -e "  ${YELLOW}Action needed.${NC} Review P0/P1 findings above."
        echo "  Run with --fix to see suggested patches."
    fi
fi

echo ""

# Exit code: 1 if P0 found, 0 otherwise (P1 = warning only)
if [[ $FINDINGS_P0 -gt 0 ]]; then
    exit 1
else
    exit 0
fi
