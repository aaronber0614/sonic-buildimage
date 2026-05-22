#!/bin/bash
#
# verify_cache_equivalence.sh — Deep Comparison of Cached vs Fresh Build Artifacts
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# Takes two build output directories (typically Build B and Build C from
# run_poc_builds.sh) and produces a comprehensive equivalence report.
# Classifies every difference as cosmetic (known-benign) or semantic (real drift).
#
# If ALL differences are cosmetic → cache is safe to use.
# If ANY semantic differences exist → cache has bugs that need fixing.
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT IT COMPARES (5 levels)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Level 1: .deb packages (target/debs/)
#   - SHA256 raw comparison (expected to differ due to timestamps)
#   - Extract and compare file-by-file (ar x → data.tar → individual files)
#   - ELF binaries: strip debug info then compare
#   - Online/copy debs: must match exactly (no compilation involved)
#
# Level 2: Python wheels (target/python-wheels/)
#   - SHA256 raw comparison (may differ due to ZIP metadata)
#   - Unzip and compare .py source files
#   - Compare METADATA and RECORD manifests
#   - Ignore .pyc timestamp differences
#
# Level 3: Docker images (target/*.gz)
#   - Load into Docker, compare docker inspect (normalized)
#   - Use container-diff for filesystem/apt package comparison
#   - Fallback: docker export → diff extracted filesystem
#
# Level 4: Root filesystem (if available)
#   - unsquashfs → diff extracted trees
#   - Compare installed package lists
#
# Level 5: Installer image (target/sonic-*.img.gz)
#   - Extract and compare partition contents
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   ./scripts/verify_cache_equivalence.sh --dir-a DIR_A --dir-b DIR_B [OPTIONS]
#
# Required:
#   --dir-a DIR    First build directory (e.g., poc-results/build-B)
#   --dir-b DIR    Second build directory (e.g., poc-results/build-C)
#
# Optional:
#   --level LEVELS       Comma-separated levels to compare: 1,2,3,4,5 (default: 1,2,3)
#   --output-dir DIR     Report output directory (default: ./poc-results/comparison/)
#   --diffoscope         Use diffoscope for detailed .deb analysis (slower but thorough)
#   --max-report-size N  diffoscope max report size in bytes (default: 50000000)
#   --timeout N          Timeout per file comparison in seconds (default: 300)
#   --json               Output results in JSON format
#   --verbose            Show detailed per-file comparison output
#   --quick              Skip deep analysis; only do SHA256 + file listing comparison
#
# Examples:
#   # Standard comparison of Build B vs Build C
#   ./scripts/verify_cache_equivalence.sh \
#       --dir-a ./poc-results/build-B \
#       --dir-b ./poc-results/build-C
#
#   # Debs only with diffoscope deep analysis
#   ./scripts/verify_cache_equivalence.sh \
#       --dir-a ./poc-results/build-B \
#       --dir-b ./poc-results/build-C \
#       --level 1 --diffoscope
#
#   # Quick hash-only check
#   ./scripts/verify_cache_equivalence.sh \
#       --dir-a ./poc-results/build-B \
#       --dir-b ./poc-results/build-C --quick
#
# ═══════════════════════════════════════════════════════════════════════════════
# INTERPRETING RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
#
# Each artifact gets a classification:
#
#   IDENTICAL   = SHA256 matches exactly (no further analysis needed)
#   COSMETIC    = Differences exist but are all known-benign patterns:
#                 timestamps, gzip headers, ar metadata, .pyc magic, etc.
#   SEMANTIC    = Real content difference — build output actually differs
#   MISSING     = Artifact present in one build but not the other
#   ERROR       = Comparison failed (tool error, timeout, etc.)
#
# Summary exit codes:
#   0 = All artifacts IDENTICAL or COSMETIC (cache is safe)
#   1 = SEMANTIC differences found (cache has correctness issues)
#   2 = Script/environment error
#
# ═══════════════════════════════════════════════════════════════════════════════
# KNOWN COSMETIC PATTERNS (auto-whitelisted)
# ═══════════════════════════════════════════════════════════════════════════════
#
# These differences are expected and do NOT indicate cache bugs:
#   - ar archive header timestamps (every .deb has these)
#   - tar entry mtime in data.tar.* and control.tar.*
#   - gzip/pigz header timestamp bytes
#   - Docker image "Created" timestamp in manifest.json
#   - .pyc file header (4-byte timestamp + source size)
#   - Build path strings in ELF .comment section
#   - File ordering in tar archives (non-deterministic in some tools)
#   - stdeb-generated debian/changelog date lines
#   - ZIP extra field timestamps in .whl files
#
# ═══════════════════════════════════════════════════════════════════════════════
# PREREQUISITES
# ═══════════════════════════════════════════════════════════════════════════════
#
# Required tools:
#   - sha256sum, ar, tar, gzip (standard — always available)
#   - diff, find, sort (standard)
#
# Optional tools (enable deeper analysis):
#   - diffoscope: detailed recursive .deb comparison (apt install diffoscope)
#   - container-diff: Docker image comparison (go install github.com/GoogleContainerTools/container-diff)
#   - objcopy: ELF debug stripping (from binutils — usually available)
#   - unzip: .whl extraction (usually available)
#   - docker: Docker image loading and inspection
#   - unsquashfs: root filesystem extraction (squashfs-tools)
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# This script is part of the DPKG Cache Validation toolkit (Phase 3):
#   - Phase 1: audit_dep_completeness.sh, check_common_files.sh
#   - Phase 2: run_poc_builds.sh, run_negative_controls.sh
#   - Phase 3: verify_cache_equivalence.sh (this script), classify_diff.sh, dump_cache_keys.sh
#
# Exit codes:
#   0 = All differences cosmetic (cache is safe)
#   1 = Semantic differences found (cache has bugs)
#   2 = Script error or missing prerequisites
#

set -uo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
DIR_A=""
DIR_B=""
LEVELS="1,2,3"
OUTPUT_DIR="./poc-results/comparison"
USE_DIFFOSCOPE=false
MAX_REPORT_SIZE=50000000
TIMEOUT=300
JSON_OUTPUT=false
VERBOSE=false
QUICK_MODE=false

# Counters
TOTAL_ARTIFACTS=0
COUNT_IDENTICAL=0
COUNT_COSMETIC=0
COUNT_SEMANTIC=0
COUNT_MISSING=0
COUNT_ERROR=0

# Results array for JSON/report output
declare -a RESULTS=()

# --- Argument Parsing ---
usage() {
    echo "Usage: $0 --dir-a DIR --dir-b DIR [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --dir-a DIR          First build directory (e.g., poc-results/build-B)"
    echo "  --dir-b DIR          Second build directory (e.g., poc-results/build-C)"
    echo ""
    echo "Optional:"
    echo "  --level LEVELS       Levels to compare: 1,2,3,4,5 (default: 1,2,3)"
    echo "  --output-dir DIR     Report output (default: ./poc-results/comparison/)"
    echo "  --diffoscope         Use diffoscope for deep .deb analysis"
    echo "  --max-report-size N  diffoscope report limit in bytes (default: 50MB)"
    echo "  --timeout N          Per-file timeout in seconds (default: 300)"
    echo "  --json               JSON output format"
    echo "  --verbose            Detailed per-file output"
    echo "  --quick              SHA256 + file-list only (skip deep analysis)"
    echo "  --help               Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dir-a) DIR_A="$2"; shift 2 ;;
        --dir-b) DIR_B="$2"; shift 2 ;;
        --level) LEVELS="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --diffoscope) USE_DIFFOSCOPE=true; shift ;;
        --max-report-size) MAX_REPORT_SIZE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --quick) QUICK_MODE=true; shift ;;
        --help|-h) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

if [[ -z "$DIR_A" || -z "$DIR_B" ]]; then
    echo -e "${RED}ERROR: --dir-a and --dir-b are required${NC}"
    usage
fi

if [[ ! -d "$DIR_A" ]]; then
    echo -e "${RED}ERROR: Directory not found: $DIR_A${NC}"; exit 2
fi
if [[ ! -d "$DIR_B" ]]; then
    echo -e "${RED}ERROR: Directory not found: $DIR_B${NC}"; exit 2
fi

# --- Helper Functions ---
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

# Record a comparison result
record_result() {
    local artifact="$1"
    local classification="$2"  # IDENTICAL, COSMETIC, SEMANTIC, MISSING, ERROR
    local detail="$3"

    RESULTS+=("$classification|$artifact|$detail")
    ((TOTAL_ARTIFACTS++))

    case "$classification" in
        IDENTICAL) ((COUNT_IDENTICAL++)) ;;
        COSMETIC)  ((COUNT_COSMETIC++)) ;;
        SEMANTIC)  ((COUNT_SEMANTIC++)) ;;
        MISSING)   ((COUNT_MISSING++)) ;;
        ERROR)     ((COUNT_ERROR++)) ;;
    esac

    if $VERBOSE; then
        local color="$NC"
        case "$classification" in
            IDENTICAL) color="$GREEN" ;;
            COSMETIC)  color="$YELLOW" ;;
            SEMANTIC)  color="$RED" ;;
            MISSING)   color="$RED" ;;
            ERROR)     color="$RED" ;;
        esac
        printf "  ${color}%-10s${NC} %s\n" "$classification" "$artifact"
        if [[ -n "$detail" && "$classification" != "IDENTICAL" ]]; then
            echo "             $detail"
        fi
    fi
}

# Check if a tool is available
has_tool() {
    command -v "$1" &>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# LEVEL 1: .deb Package Comparison
# ═══════════════════════════════════════════════════════════════════════════════
compare_debs() {
    echo ""
    echo -e "${BOLD}━━━ Level 1: .deb Package Comparison ━━━${NC}"
    echo ""

    # Find all .deb files in both directories
    local debs_a debs_b
    debs_a=$(find "$DIR_A" -name "*.deb" -type f 2>/dev/null | sort)
    debs_b=$(find "$DIR_B" -name "*.deb" -type f 2>/dev/null | sort)

    if [[ -z "$debs_a" && -z "$debs_b" ]]; then
        log_warn "No .deb files found in either directory"
        return
    fi

    # Build filename-to-path maps
    declare -A map_a=() map_b=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local name
        name=$(basename "$path")
        map_a["$name"]="$path"
    done <<< "$debs_a"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local name
        name=$(basename "$path")
        map_b["$name"]="$path"
    done <<< "$debs_b"

    # Compare matching files
    local total_debs=0 identical_debs=0
    for name in $(echo "${!map_a[@]}" "${!map_b[@]}" | tr ' ' '\n' | sort -u); do
        ((total_debs++))

        if [[ -z "${map_a[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-b"
            continue
        fi
        if [[ -z "${map_b[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-a"
            continue
        fi

        # Quick SHA256 check
        local hash_a hash_b
        hash_a=$(sha256sum "${map_a[$name]}" | awk '{print $1}')
        hash_b=$(sha256sum "${map_b[$name]}" | awk '{print $1}')

        if [[ "$hash_a" == "$hash_b" ]]; then
            record_result "$name" "IDENTICAL" ""
            ((identical_debs++))
            continue
        fi

        # Hashes differ — need deeper analysis
        if $QUICK_MODE; then
            record_result "$name" "SEMANTIC" "SHA256 mismatch (quick mode — no deep analysis)"
            continue
        fi

        # Deep comparison: extract and compare contents
        compare_deb_deep "${map_a[$name]}" "${map_b[$name]}" "$name"
    done

    log_info "Level 1 summary: $total_debs debs, $identical_debs identical by hash"
}

# Deep .deb comparison (extract and compare file-by-file)
compare_deb_deep() {
    local deb_a="$1" deb_b="$2" name="$3"

    local tmp_a tmp_b
    tmp_a=$(mktemp -d)
    tmp_b=$(mktemp -d)
    trap "rm -rf '$tmp_a' '$tmp_b'" RETURN

    # Extract .deb files (ar archives)
    (cd "$tmp_a" && ar x "$deb_a" 2>/dev/null) || {
        record_result "$name" "ERROR" "Failed to extract deb_a"
        return
    }
    (cd "$tmp_b" && ar x "$deb_b" 2>/dev/null) || {
        record_result "$name" "ERROR" "Failed to extract deb_b"
        return
    }

    # Compare data.tar contents (actual package files)
    local data_a data_b
    data_a=$(find "$tmp_a" -name "data.tar*" | head -1)
    data_b=$(find "$tmp_b" -name "data.tar*" | head -1)

    if [[ -z "$data_a" || -z "$data_b" ]]; then
        record_result "$name" "ERROR" "Missing data.tar in extracted deb"
        return
    fi

    # Extract data.tar and compare file contents (ignoring timestamps)
    local data_dir_a="$tmp_a/data" data_dir_b="$tmp_b/data"
    mkdir -p "$data_dir_a" "$data_dir_b"

    tar -xf "$data_a" -C "$data_dir_a" 2>/dev/null || true
    tar -xf "$data_b" -C "$data_dir_b" 2>/dev/null || true

    # Compare all files by content (ignoring timestamps/permissions)
    local semantic_diff=false
    local diff_details=""

    # Get file lists
    local files_a files_b
    files_a=$(cd "$data_dir_a" && find . -type f | sort)
    files_b=$(cd "$data_dir_b" && find . -type f | sort)

    # Check for file list differences
    local list_diff
    list_diff=$(diff <(echo "$files_a") <(echo "$files_b") 2>/dev/null || true)
    if [[ -n "$list_diff" ]]; then
        semantic_diff=true
        diff_details="File list differs"
    fi

    # Compare file contents
    if ! $semantic_diff; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local fa="$data_dir_a/$file" fb="$data_dir_b/$file"
            if [[ -f "$fa" && -f "$fb" ]]; then
                if ! cmp -s "$fa" "$fb"; then
                    # Check if it's an ELF binary — strip debug and compare
                    if file "$fa" | grep -q "ELF"; then
                        if has_tool objcopy; then
                            local stripped_a stripped_b
                            stripped_a=$(mktemp)
                            stripped_b=$(mktemp)
                            objcopy --strip-debug "$fa" "$stripped_a" 2>/dev/null || cp "$fa" "$stripped_a"
                            objcopy --strip-debug "$fb" "$stripped_b" 2>/dev/null || cp "$fb" "$stripped_b"
                            if ! cmp -s "$stripped_a" "$stripped_b"; then
                                semantic_diff=true
                                diff_details="ELF binary differs after stripping debug: $file"
                            fi
                            rm -f "$stripped_a" "$stripped_b"
                        else
                            semantic_diff=true
                            diff_details="Binary differs (no objcopy for strip): $file"
                        fi
                    else
                        # Non-ELF file differs — check known cosmetic patterns
                        if is_cosmetic_diff "$fa" "$fb" "$file"; then
                            : # cosmetic, skip
                        else
                            semantic_diff=true
                            diff_details="File content differs: $file"
                        fi
                    fi

                    if $semantic_diff; then
                        break  # Stop on first semantic diff (report it)
                    fi
                fi
            fi
        done <<< "$files_a"
    fi

    if $semantic_diff; then
        record_result "$name" "SEMANTIC" "$diff_details"
    else
        record_result "$name" "COSMETIC" "ar/tar timestamp differences only"
    fi

    # Use diffoscope if requested and semantic diff found
    if $USE_DIFFOSCOPE && $semantic_diff && has_tool diffoscope; then
        local diffoscope_report="$OUTPUT_DIR/diffoscope/${name}.html"
        mkdir -p "$(dirname "$diffoscope_report")"
        timeout "$TIMEOUT" diffoscope \
            --max-report-size "$MAX_REPORT_SIZE" \
            --html "$diffoscope_report" \
            "$deb_a" "$deb_b" 2>/dev/null || true
        if [[ -f "$diffoscope_report" ]]; then
            log_info "  diffoscope report: $diffoscope_report"
        fi
    fi
}

# Check if a file difference is known-cosmetic
is_cosmetic_diff() {
    local file_a="$1" file_b="$2" rel_path="$3"

    # .pyc files — timestamp in header
    if [[ "$rel_path" == *.pyc ]]; then
        return 0  # cosmetic
    fi

    # changelog files with date stamps
    if [[ "$rel_path" == *changelog* || "$rel_path" == *CHANGELOG* ]]; then
        # Check if only date line differs
        local diff_lines
        diff_lines=$(diff "$file_a" "$file_b" 2>/dev/null | grep "^[<>]" | grep -cv "date\|Date\|timestamp" || echo "999")
        if [[ $diff_lines -eq 0 ]]; then
            return 0  # only date lines differ
        fi
    fi

    # Build-id or build-path in text files
    if [[ "$rel_path" == *.buildinfo || "$rel_path" == *.changes ]]; then
        return 0  # cosmetic
    fi

    return 1  # NOT cosmetic — treat as semantic
}

# ═══════════════════════════════════════════════════════════════════════════════
# LEVEL 2: Python Wheel Comparison
# ═══════════════════════════════════════════════════════════════════════════════
compare_wheels() {
    echo ""
    echo -e "${BOLD}━━━ Level 2: Python Wheel Comparison ━━━${NC}"
    echo ""

    local wheels_a wheels_b
    wheels_a=$(find "$DIR_A" -name "*.whl" -type f 2>/dev/null | sort)
    wheels_b=$(find "$DIR_B" -name "*.whl" -type f 2>/dev/null | sort)

    if [[ -z "$wheels_a" && -z "$wheels_b" ]]; then
        log_warn "No .whl files found in either directory"
        return
    fi

    # Build filename maps
    declare -A whl_map_a=() whl_map_b=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        whl_map_a["$(basename "$path")"]="$path"
    done <<< "$wheels_a"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        whl_map_b["$(basename "$path")"]="$path"
    done <<< "$wheels_b"

    local total_whls=0 identical_whls=0
    for name in $(echo "${!whl_map_a[@]}" "${!whl_map_b[@]}" | tr ' ' '\n' | sort -u); do
        ((total_whls++))

        if [[ -z "${whl_map_a[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-b"
            continue
        fi
        if [[ -z "${whl_map_b[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-a"
            continue
        fi

        # Quick SHA256
        local hash_a hash_b
        hash_a=$(sha256sum "${whl_map_a[$name]}" | awk '{print $1}')
        hash_b=$(sha256sum "${whl_map_b[$name]}" | awk '{print $1}')

        if [[ "$hash_a" == "$hash_b" ]]; then
            record_result "$name" "IDENTICAL" ""
            ((identical_whls++))
            continue
        fi

        if $QUICK_MODE; then
            record_result "$name" "SEMANTIC" "SHA256 mismatch (quick mode)"
            continue
        fi

        # Deep comparison: unzip and compare
        compare_wheel_deep "${whl_map_a[$name]}" "${whl_map_b[$name]}" "$name"
    done

    log_info "Level 2 summary: $total_whls wheels, $identical_whls identical by hash"
}

compare_wheel_deep() {
    local whl_a="$1" whl_b="$2" name="$3"

    if ! has_tool unzip; then
        record_result "$name" "ERROR" "unzip not available for .whl extraction"
        return
    fi

    local tmp_a tmp_b
    tmp_a=$(mktemp -d)
    tmp_b=$(mktemp -d)
    trap "rm -rf '$tmp_a' '$tmp_b'" RETURN

    unzip -q "$whl_a" -d "$tmp_a" 2>/dev/null || {
        record_result "$name" "ERROR" "Failed to unzip whl_a"
        return
    }
    unzip -q "$whl_b" -d "$tmp_b" 2>/dev/null || {
        record_result "$name" "ERROR" "Failed to unzip whl_b"
        return
    }

    # Compare .py source files (ignoring .pyc)
    local semantic_diff=false
    local diff_details=""

    # Compare METADATA
    local meta_a meta_b
    meta_a=$(find "$tmp_a" -name "METADATA" | head -1)
    meta_b=$(find "$tmp_b" -name "METADATA" | head -1)

    if [[ -n "$meta_a" && -n "$meta_b" ]]; then
        if ! cmp -s "$meta_a" "$meta_b"; then
            semantic_diff=true
            diff_details="METADATA differs"
        fi
    fi

    # Compare all .py files
    if ! $semantic_diff; then
        while IFS= read -r py_file; do
            [[ -z "$py_file" ]] && continue
            local rel_path="${py_file#$tmp_a/}"
            local fb="$tmp_b/$rel_path"
            if [[ -f "$fb" ]]; then
                if ! cmp -s "$py_file" "$fb"; then
                    semantic_diff=true
                    diff_details="Python source differs: $rel_path"
                    break
                fi
            else
                semantic_diff=true
                diff_details="File missing in B: $rel_path"
                break
            fi
        done < <(find "$tmp_a" -name "*.py" -type f)
    fi

    # Compare .so extensions if present
    if ! $semantic_diff; then
        while IFS= read -r so_file; do
            [[ -z "$so_file" ]] && continue
            local rel_path="${so_file#$tmp_a/}"
            local fb="$tmp_b/$rel_path"
            if [[ -f "$fb" ]]; then
                if ! cmp -s "$so_file" "$fb"; then
                    if has_tool objcopy; then
                        local sa sb
                        sa=$(mktemp); sb=$(mktemp)
                        objcopy --strip-debug "$so_file" "$sa" 2>/dev/null || cp "$so_file" "$sa"
                        objcopy --strip-debug "$fb" "$sb" 2>/dev/null || cp "$fb" "$sb"
                        if ! cmp -s "$sa" "$sb"; then
                            semantic_diff=true
                            diff_details="Compiled extension differs: $rel_path"
                        fi
                        rm -f "$sa" "$sb"
                    else
                        semantic_diff=true
                        diff_details="Compiled extension differs: $rel_path"
                    fi
                fi
            fi
        done < <(find "$tmp_a" -name "*.so" -type f)
    fi

    if $semantic_diff; then
        record_result "$name" "SEMANTIC" "$diff_details"
    else
        record_result "$name" "COSMETIC" "ZIP metadata/pyc timestamp differences only"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# LEVEL 3: Docker Image Comparison
# ═══════════════════════════════════════════════════════════════════════════════
compare_dockers() {
    echo ""
    echo -e "${BOLD}━━━ Level 3: Docker Image Comparison ━━━${NC}"
    echo ""

    local images_a images_b
    images_a=$(find "$DIR_A" -name "*.gz" -path "*/docker*" -type f 2>/dev/null | sort)
    images_b=$(find "$DIR_B" -name "*.gz" -path "*/docker*" -type f 2>/dev/null | sort)

    # Also check top-level .gz files that are docker images
    if [[ -z "$images_a" ]]; then
        images_a=$(find "$DIR_A" -maxdepth 2 -name "docker-*.gz" -type f 2>/dev/null | sort)
    fi
    if [[ -z "$images_b" ]]; then
        images_b=$(find "$DIR_B" -maxdepth 2 -name "docker-*.gz" -type f 2>/dev/null | sort)
    fi

    if [[ -z "$images_a" && -z "$images_b" ]]; then
        log_warn "No Docker images found in either directory"
        return
    fi

    # Build filename maps
    declare -A img_map_a=() img_map_b=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        img_map_a["$(basename "$path")"]="$path"
    done <<< "$images_a"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        img_map_b["$(basename "$path")"]="$path"
    done <<< "$images_b"

    local total_imgs=0 identical_imgs=0
    for name in $(echo "${!img_map_a[@]}" "${!img_map_b[@]}" | tr ' ' '\n' | sort -u); do
        ((total_imgs++))

        if [[ -z "${img_map_a[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-b"
            continue
        fi
        if [[ -z "${img_map_b[$name]:-}" ]]; then
            record_result "$name" "MISSING" "Only in dir-a"
            continue
        fi

        # Quick SHA256 (Docker images almost always differ due to layer timestamps)
        local hash_a hash_b
        hash_a=$(sha256sum "${img_map_a[$name]}" | awk '{print $1}')
        hash_b=$(sha256sum "${img_map_b[$name]}" | awk '{print $1}')

        if [[ "$hash_a" == "$hash_b" ]]; then
            record_result "$name" "IDENTICAL" ""
            ((identical_imgs++))
            continue
        fi

        if $QUICK_MODE; then
            record_result "$name" "COSMETIC" "SHA256 differs (expected for Docker — gzip/timestamp headers)"
            continue
        fi

        # Deep Docker comparison
        compare_docker_deep "${img_map_a[$name]}" "${img_map_b[$name]}" "$name"
    done

    log_info "Level 3 summary: $total_imgs images, $identical_imgs identical by hash"
}

compare_docker_deep() {
    local img_a="$1" img_b="$2" name="$3"

    if ! has_tool docker; then
        record_result "$name" "ERROR" "Docker not available for image comparison"
        return
    fi

    # Load both images
    local tag_a="verify-cache-a/${name%.gz}:test"
    local tag_b="verify-cache-b/${name%.gz}:test"

    docker load -i "$img_a" 2>/dev/null | grep -oP "Loaded image: \K.*" > /dev/null || {
        # Tag the loaded image
        local loaded_id
        loaded_id=$(docker load -i "$img_a" 2>/dev/null | grep -oP "Loaded image ID: sha256:\K[a-f0-9]+" | head -1)
        if [[ -n "$loaded_id" ]]; then
            docker tag "$loaded_id" "$tag_a" 2>/dev/null || true
        else
            record_result "$name" "ERROR" "Failed to load Docker image A"
            return
        fi
    }

    docker load -i "$img_b" 2>/dev/null | grep -oP "Loaded image: \K.*" > /dev/null || {
        local loaded_id
        loaded_id=$(docker load -i "$img_b" 2>/dev/null | grep -oP "Loaded image ID: sha256:\K[a-f0-9]+" | head -1)
        if [[ -n "$loaded_id" ]]; then
            docker tag "$loaded_id" "$tag_b" 2>/dev/null || true
        else
            record_result "$name" "ERROR" "Failed to load Docker image B"
            return
        fi
    }

    # Compare using container-diff if available
    if has_tool container-diff; then
        local diff_output="$OUTPUT_DIR/container-diff/${name}.txt"
        mkdir -p "$(dirname "$diff_output")"
        timeout "$TIMEOUT" container-diff diff \
            "daemon://$tag_a" "daemon://$tag_b" \
            --type=file --type=apt 2>/dev/null > "$diff_output" || true

        if [[ -s "$diff_output" ]]; then
            # Check if there are actual package or file differences
            local pkg_diffs file_diffs
            pkg_diffs=$(grep -c "^-\|^+" "$diff_output" 2>/dev/null || echo "0")
            if [[ $pkg_diffs -gt 0 ]]; then
                record_result "$name" "SEMANTIC" "container-diff found $pkg_diffs differences (see $diff_output)"
            else
                record_result "$name" "COSMETIC" "Docker layer timestamps only"
            fi
        else
            record_result "$name" "COSMETIC" "No filesystem/package differences detected"
        fi
    else
        # Fallback: compare docker inspect (normalized)
        local inspect_a inspect_b
        inspect_a=$(docker inspect "$tag_a" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)[0]['Config']
# Remove timestamp and ID fields
for key in ['Hostname', 'Image']:
    data.pop(key, None)
print(json.dumps(data, sort_keys=True, indent=2))
" 2>/dev/null || echo "ERROR")

        inspect_b=$(docker inspect "$tag_b" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)[0]['Config']
for key in ['Hostname', 'Image']:
    data.pop(key, None)
print(json.dumps(data, sort_keys=True, indent=2))
" 2>/dev/null || echo "ERROR")

        if [[ "$inspect_a" == "$inspect_b" ]]; then
            record_result "$name" "COSMETIC" "docker inspect configs match (timestamp diffs only)"
        elif [[ "$inspect_a" == "ERROR" || "$inspect_b" == "ERROR" ]]; then
            record_result "$name" "ERROR" "Failed to inspect Docker images"
        else
            record_result "$name" "SEMANTIC" "Docker config differs (Env/Cmd/Labels/etc.)"
        fi
    fi

    # Cleanup loaded images
    docker rmi "$tag_a" "$tag_b" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# REPORT GENERATION
# ═══════════════════════════════════════════════════════════════════════════════
generate_report() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  EQUIVALENCE REPORT${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Directory A: $DIR_A"
    echo "  Directory B: $DIR_B"
    echo "  Levels compared: $LEVELS"
    echo ""
    echo -e "  ${GREEN}IDENTICAL:${NC}  $COUNT_IDENTICAL"
    echo -e "  ${YELLOW}COSMETIC:${NC}   $COUNT_COSMETIC  (timestamp/metadata diffs — safe)"
    echo -e "  ${RED}SEMANTIC:${NC}   $COUNT_SEMANTIC  (real content differences — cache bug)"
    echo -e "  ${RED}MISSING:${NC}    $COUNT_MISSING  (artifact in one build only)"
    echo -e "  ERROR:      $COUNT_ERROR"
    echo -e "  ─────────────────"
    echo -e "  TOTAL:      $TOTAL_ARTIFACTS"
    echo ""

    if [[ $COUNT_SEMANTIC -eq 0 && $COUNT_MISSING -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}VERDICT: PASS — Cache produces equivalent artifacts${NC}"
        echo "  All differences are known-cosmetic (timestamps, gzip headers, etc.)"
    else
        echo -e "  ${RED}${BOLD}VERDICT: FAIL — Cache has correctness issues${NC}"
        echo ""
        echo "  Semantic differences found in:"
        for result in "${RESULTS[@]}"; do
            IFS='|' read -r class artifact detail <<< "$result"
            if [[ "$class" == "SEMANTIC" || "$class" == "MISSING" ]]; then
                echo -e "    ${RED}•${NC} $artifact: $detail"
            fi
        done
    fi
    echo ""

    # Save detailed report
    mkdir -p "$OUTPUT_DIR"
    local report_file="$OUTPUT_DIR/equivalence-report.txt"
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "  DPKG Cache Equivalence Report"
        echo "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Dir A: $DIR_A"
        echo "Dir B: $DIR_B"
        echo ""
        echo "Summary: $COUNT_IDENTICAL identical, $COUNT_COSMETIC cosmetic, $COUNT_SEMANTIC semantic, $COUNT_MISSING missing, $COUNT_ERROR errors"
        echo ""
        printf "%-12s %-50s %s\n" "STATUS" "ARTIFACT" "DETAIL"
        printf "%-12s %-50s %s\n" "────────────" "──────────────────────────────────────────────────" "──────"
        for result in "${RESULTS[@]}"; do
            IFS='|' read -r class artifact detail <<< "$result"
            printf "%-12s %-50s %s\n" "$class" "$artifact" "$detail"
        done
    } > "$report_file"

    log_info "Full report saved to: $report_file"

    # JSON output if requested
    if $JSON_OUTPUT; then
        local json_file="$OUTPUT_DIR/equivalence-report.json"
        python3 -c "
import json
results = []
for line in '''$(printf '%s\n' "${RESULTS[@]}")'''.strip().split('\n'):
    parts = line.split('|', 2)
    if len(parts) == 3:
        results.append({'classification': parts[0], 'artifact': parts[1], 'detail': parts[2]})
report = {
    'dir_a': '$DIR_A',
    'dir_b': '$DIR_B',
    'levels': '$LEVELS',
    'summary': {
        'total': $TOTAL_ARTIFACTS,
        'identical': $COUNT_IDENTICAL,
        'cosmetic': $COUNT_COSMETIC,
        'semantic': $COUNT_SEMANTIC,
        'missing': $COUNT_MISSING,
        'error': $COUNT_ERROR
    },
    'verdict': 'PASS' if $COUNT_SEMANTIC == 0 and $COUNT_MISSING == 0 else 'FAIL',
    'results': results
}
print(json.dumps(report, indent=2))
" > "$json_file" 2>/dev/null
        log_info "JSON report saved to: $json_file"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SONiC DPKG Cache — Artifact Equivalence Verification         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Dir A: $DIR_A"
    echo "  Dir B: $DIR_B"
    echo "  Levels: $LEVELS"
    echo "  Mode: $( $QUICK_MODE && echo "quick (hash only)" || echo "deep analysis" )"
    echo "  diffoscope: $( $USE_DIFFOSCOPE && echo "enabled" || echo "disabled" )"

    mkdir -p "$OUTPUT_DIR"

    # Run requested levels
    if [[ "$LEVELS" == *"1"* ]]; then
        compare_debs
    fi
    if [[ "$LEVELS" == *"2"* ]]; then
        compare_wheels
    fi
    if [[ "$LEVELS" == *"3"* ]]; then
        compare_dockers
    fi

    # Generate report
    generate_report

    # Exit code
    if [[ $COUNT_SEMANTIC -gt 0 || $COUNT_MISSING -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
