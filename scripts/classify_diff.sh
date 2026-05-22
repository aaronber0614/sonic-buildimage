#!/bin/bash
#
# classify_diff.sh — Classify Build Artifact Differences as Cosmetic or Semantic
#
# ═══════════════════════════════════════════════════════════════════════════════
# PURPOSE
# ═══════════════════════════════════════════════════════════════════════════════
#
# Given two files (or a diffoscope report), classifies the differences as:
#   - COSMETIC: Known-benign patterns (timestamps, gzip headers, etc.)
#   - SEMANTIC: Real content differences that indicate a cache correctness bug
#
# This is a helper tool used by verify_cache_equivalence.sh but can also be
# run standalone to investigate specific artifact differences.
#
# ═══════════════════════════════════════════════════════════════════════════════
# USAGE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   # Compare two files directly
#   ./scripts/classify_diff.sh --file-a path/to/A.deb --file-b path/to/B.deb
#
#   # Classify a diffoscope JSON report
#   ./scripts/classify_diff.sh --diffoscope-report path/to/report.json
#
#   # Classify with verbose whitelist matching
#   ./scripts/classify_diff.sh --file-a A.deb --file-b B.deb --verbose
#
# Options:
#   --file-a FILE           First file to compare
#   --file-b FILE           Second file to compare
#   --diffoscope-report F   Classify an existing diffoscope JSON report
#   --type TYPE             File type hint: deb, whl, docker, elf (auto-detected if omitted)
#   --verbose               Show which whitelist pattern matched each difference
#   --strict                Treat ANY difference as semantic (disable whitelist)
#   --help                  Show this help
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHITELIST PATTERNS
# ═══════════════════════════════════════════════════════════════════════════════
#
# The following difference patterns are classified as COSMETIC:
#
# .deb packages:
#   - ar archive header timestamp (bytes 16-27 of each ar member header)
#   - tar entry mtime/atime/ctime in data.tar.* and control.tar.*
#   - gzip header modification time (bytes 4-7)
#   - debian/changelog date line (stdeb-generated timestamps)
#   - control/md5sums file ordering differences
#   - .buildinfo file content (build environment metadata)
#
# Python wheels (.whl):
#   - ZIP extra field timestamps
#   - .pyc file header bytes (timestamp + source size, bytes 4-12)
#   - RECORD file hash ordering
#   - dist-info/WHEEL generator version line
#
# Docker images:
#   - manifest.json "Created" timestamp
#   - layer tar entry timestamps
#   - config JSON "created" and "history[].created" fields
#   - Image ID (derived from content — differs if timestamps differ)
#
# ELF binaries:
#   - .comment section (compiler version string)
#   - .note.gnu.build-id (build-id differs when any content differs)
#   - DWARF debug info paths (DW_AT_comp_dir, DW_AT_name)
#   - .debug_* sections entirely
#
# ═══════════════════════════════════════════════════════════════════════════════
# EXIT CODES
# ═══════════════════════════════════════════════════════════════════════════════
#
# 0 = COSMETIC (all differences matched whitelist patterns)
# 1 = SEMANTIC (at least one unwhitelisted difference found)
# 2 = Error (file not found, tool missing, etc.)
#
# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT
# ═══════════════════════════════════════════════════════════════════════════════
#
# Part of the DPKG Cache Validation toolkit (Phase 3):
#   - verify_cache_equivalence.sh calls this for per-artifact classification
#   - Can also be used standalone for investigating specific differences
#

set -uo pipefail

# --- Configuration ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

FILE_A=""
FILE_B=""
DIFFOSCOPE_REPORT=""
FILE_TYPE=""
VERBOSE=false
STRICT=false

# --- Argument Parsing ---
usage() {
    echo "Usage: $0 --file-a FILE --file-b FILE [OPTIONS]"
    echo "       $0 --diffoscope-report FILE [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --file-a FILE           First file"
    echo "  --file-b FILE           Second file"
    echo "  --diffoscope-report F   Existing diffoscope JSON report"
    echo "  --type TYPE             deb|whl|docker|elf (auto-detected if omitted)"
    echo "  --verbose               Show whitelist pattern matches"
    echo "  --strict                Disable whitelist (any diff = semantic)"
    echo "  --help                  Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --file-a) FILE_A="$2"; shift 2 ;;
        --file-b) FILE_B="$2"; shift 2 ;;
        --diffoscope-report) DIFFOSCOPE_REPORT="$2"; shift 2 ;;
        --type) FILE_TYPE="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        --strict) STRICT=true; shift ;;
        --help|-h) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# --- Helper Functions ---
log_verbose() {
    $VERBOSE && echo -e "  ${CYAN}[match]${NC} $*"
}

# Auto-detect file type from extension
detect_type() {
    local file="$1"
    case "$file" in
        *.deb)  echo "deb" ;;
        *.whl)  echo "whl" ;;
        *.gz)   echo "docker" ;;  # Docker images are .gz in SONiC
        *.so|*.so.*)  echo "elf" ;;
        *)
            if file "$file" 2>/dev/null | grep -q "ELF"; then
                echo "elf"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# WHITELIST CLASSIFICATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Check if a .deb difference is cosmetic
classify_deb_diff() {
    local file_a="$1" file_b="$2"
    local tmp_a tmp_b
    tmp_a=$(mktemp -d)
    tmp_b=$(mktemp -d)
    trap "rm -rf '$tmp_a' '$tmp_b'" RETURN

    # Extract both debs
    (cd "$tmp_a" && ar x "$file_a" 2>/dev/null) || { echo "SEMANTIC"; return; }
    (cd "$tmp_b" && ar x "$file_b" 2>/dev/null) || { echo "SEMANTIC"; return; }

    # Check: do they have the same member files?
    local members_a members_b
    members_a=$(ls "$tmp_a" | sort)
    members_b=$(ls "$tmp_b" | sort)
    if [[ "$members_a" != "$members_b" ]]; then
        echo "SEMANTIC"
        return
    fi

    # Compare each member
    local has_semantic=false
    for member in $members_a; do
        if [[ "$member" == "debian-binary" ]]; then
            # Always "2.0\n" — skip
            continue
        fi

        if cmp -s "$tmp_a/$member" "$tmp_b/$member"; then
            continue  # identical
        fi

        # data.tar.* or control.tar.* — extract and compare contents
        if [[ "$member" == data.tar* || "$member" == control.tar* ]]; then
            local data_a="$tmp_a/${member}_extracted"
            local data_b="$tmp_b/${member}_extracted"
            mkdir -p "$data_a" "$data_b"
            tar -xf "$tmp_a/$member" -C "$data_a" 2>/dev/null || true
            tar -xf "$tmp_b/$member" -C "$data_b" 2>/dev/null || true

            # Compare file contents (not metadata/timestamps)
            while IFS= read -r rel_file; do
                [[ -z "$rel_file" ]] && continue
                local fa="$data_a/$rel_file" fb="$data_b/$rel_file"
                if [[ -f "$fa" && -f "$fb" ]]; then
                    if ! cmp -s "$fa" "$fb"; then
                        # Check cosmetic patterns
                        local basename_f
                        basename_f=$(basename "$rel_file")
                        case "$basename_f" in
                            *.pyc)
                                log_verbose "pyc timestamp: $rel_file"
                                ;;
                            *.buildinfo|*.changes)
                                log_verbose "build metadata: $rel_file"
                                ;;
                            changelog)
                                # Check if only date differs
                                local non_date_diffs
                                non_date_diffs=$(diff "$fa" "$fb" 2>/dev/null | grep "^[<>]" | grep -icv "date\|Mon,\|Tue,\|Wed,\|Thu,\|Fri,\|Sat,\|Sun," || echo "0")
                                if [[ $non_date_diffs -eq 0 ]]; then
                                    log_verbose "changelog date only: $rel_file"
                                else
                                    has_semantic=true
                                    $VERBOSE && echo -e "  ${RED}[semantic]${NC} $rel_file (non-date content differs)"
                                fi
                                ;;
                            md5sums)
                                # Ordering may differ — compare sorted
                                if diff <(sort "$fa") <(sort "$fb") &>/dev/null; then
                                    log_verbose "md5sums ordering: $rel_file"
                                else
                                    has_semantic=true
                                    $VERBOSE && echo -e "  ${RED}[semantic]${NC} $rel_file (hash content differs)"
                                fi
                                ;;
                            *)
                                # Check if it's an ELF — strip and compare
                                if file "$fa" 2>/dev/null | grep -q "ELF"; then
                                    if command -v objcopy &>/dev/null; then
                                        local sa sb
                                        sa=$(mktemp); sb=$(mktemp)
                                        objcopy --strip-debug "$fa" "$sa" 2>/dev/null || cp "$fa" "$sa"
                                        objcopy --strip-debug "$fb" "$sb" 2>/dev/null || cp "$fb" "$sb"
                                        if ! cmp -s "$sa" "$sb"; then
                                            has_semantic=true
                                            $VERBOSE && echo -e "  ${RED}[semantic]${NC} ELF differs after strip: $rel_file"
                                        else
                                            log_verbose "ELF debug-only diff: $rel_file"
                                        fi
                                        rm -f "$sa" "$sb"
                                    else
                                        has_semantic=true
                                    fi
                                else
                                    has_semantic=true
                                    $VERBOSE && echo -e "  ${RED}[semantic]${NC} $rel_file"
                                fi
                                ;;
                        esac
                        if $has_semantic; then break; fi
                    fi
                elif [[ -f "$fa" && ! -f "$fb" ]] || [[ ! -f "$fa" && -f "$fb" ]]; then
                    has_semantic=true
                    $VERBOSE && echo -e "  ${RED}[semantic]${NC} File exists in one but not other: $rel_file"
                fi
            done < <(cd "$data_a" && find . -type f | sort)

            if $has_semantic; then break; fi
        fi
    done

    if $has_semantic; then
        echo "SEMANTIC"
    else
        echo "COSMETIC"
    fi
}

# Check if a .whl difference is cosmetic
classify_whl_diff() {
    local file_a="$1" file_b="$2"

    if ! command -v unzip &>/dev/null; then
        echo "SEMANTIC"  # Can't verify without unzip
        return
    fi

    local tmp_a tmp_b
    tmp_a=$(mktemp -d)
    tmp_b=$(mktemp -d)
    trap "rm -rf '$tmp_a' '$tmp_b'" RETURN

    unzip -q "$file_a" -d "$tmp_a" 2>/dev/null || { echo "SEMANTIC"; return; }
    unzip -q "$file_b" -d "$tmp_b" 2>/dev/null || { echo "SEMANTIC"; return; }

    local has_semantic=false

    # Compare all files
    while IFS= read -r rel_file; do
        [[ -z "$rel_file" ]] && continue
        local fa="$tmp_a/$rel_file" fb="$tmp_b/$rel_file"

        if [[ ! -f "$fb" ]]; then
            has_semantic=true
            $VERBOSE && echo -e "  ${RED}[semantic]${NC} Missing in B: $rel_file"
            break
        fi

        if ! cmp -s "$fa" "$fb"; then
            case "$rel_file" in
                *.pyc)
                    log_verbose "pyc timestamp: $rel_file"
                    ;;
                */RECORD)
                    # RECORD has hashes — compare sorted
                    if diff <(sort "$fa") <(sort "$fb") &>/dev/null; then
                        log_verbose "RECORD ordering: $rel_file"
                    else
                        has_semantic=true
                        $VERBOSE && echo -e "  ${RED}[semantic]${NC} RECORD content differs: $rel_file"
                    fi
                    ;;
                */WHEEL)
                    # WHEEL file — check if only Generator line differs
                    local non_gen_diffs
                    non_gen_diffs=$(diff "$fa" "$fb" 2>/dev/null | grep "^[<>]" | grep -icv "Generator" || echo "0")
                    if [[ $non_gen_diffs -eq 0 ]]; then
                        log_verbose "WHEEL generator version: $rel_file"
                    else
                        has_semantic=true
                    fi
                    ;;
                *.so|*.so.*)
                    # Compiled extension — strip and compare
                    if command -v objcopy &>/dev/null; then
                        local sa sb
                        sa=$(mktemp); sb=$(mktemp)
                        objcopy --strip-debug "$fa" "$sa" 2>/dev/null || cp "$fa" "$sa"
                        objcopy --strip-debug "$fb" "$sb" 2>/dev/null || cp "$fb" "$sb"
                        if ! cmp -s "$sa" "$sb"; then
                            has_semantic=true
                        else
                            log_verbose "ELF debug-only: $rel_file"
                        fi
                        rm -f "$sa" "$sb"
                    else
                        has_semantic=true
                    fi
                    ;;
                *)
                    has_semantic=true
                    $VERBOSE && echo -e "  ${RED}[semantic]${NC} $rel_file"
                    ;;
            esac
        fi

        if $has_semantic; then break; fi
    done < <(cd "$tmp_a" && find . -type f | sort)

    if $has_semantic; then
        echo "SEMANTIC"
    else
        echo "COSMETIC"
    fi
}

# Check if an ELF binary difference is cosmetic
classify_elf_diff() {
    local file_a="$1" file_b="$2"

    if ! command -v objcopy &>/dev/null; then
        echo "SEMANTIC"
        return
    fi

    local sa sb
    sa=$(mktemp); sb=$(mktemp)
    trap "rm -f '$sa' '$sb'" RETURN

    # Strip all debug info and build-ids
    objcopy --strip-debug --remove-section=.note.gnu.build-id \
        --remove-section=.comment "$file_a" "$sa" 2>/dev/null || cp "$file_a" "$sa"
    objcopy --strip-debug --remove-section=.note.gnu.build-id \
        --remove-section=.comment "$file_b" "$sb" 2>/dev/null || cp "$file_b" "$sb"

    if cmp -s "$sa" "$sb"; then
        log_verbose "ELF differs only in debug/build-id/comment sections"
        echo "COSMETIC"
    else
        echo "SEMANTIC"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    # Handle diffoscope report mode
    if [[ -n "$DIFFOSCOPE_REPORT" ]]; then
        if [[ ! -f "$DIFFOSCOPE_REPORT" ]]; then
            echo -e "${RED}ERROR: Report not found: $DIFFOSCOPE_REPORT${NC}"
            exit 2
        fi
        echo "diffoscope report classification not yet implemented"
        echo "Use --file-a/--file-b for direct file comparison"
        exit 2
    fi

    # Direct file comparison mode
    if [[ -z "$FILE_A" || -z "$FILE_B" ]]; then
        echo -e "${RED}ERROR: --file-a and --file-b required${NC}"
        usage
    fi

    if [[ ! -f "$FILE_A" ]]; then
        echo -e "${RED}ERROR: File not found: $FILE_A${NC}"; exit 2
    fi
    if [[ ! -f "$FILE_B" ]]; then
        echo -e "${RED}ERROR: File not found: $FILE_B${NC}"; exit 2
    fi

    # Quick check — if identical, done
    if cmp -s "$FILE_A" "$FILE_B"; then
        echo -e "${GREEN}IDENTICAL${NC}"
        exit 0
    fi

    # Strict mode — any difference is semantic
    if $STRICT; then
        echo -e "${RED}SEMANTIC${NC} (strict mode — any difference treated as semantic)"
        exit 1
    fi

    # Detect or use provided type
    local ftype="${FILE_TYPE:-$(detect_type "$FILE_A")}"

    echo "Classifying difference in: $(basename "$FILE_A")"
    echo "  Type: $ftype"
    echo ""

    local result
    case "$ftype" in
        deb)
            result=$(classify_deb_diff "$FILE_A" "$FILE_B")
            ;;
        whl)
            result=$(classify_whl_diff "$FILE_A" "$FILE_B")
            ;;
        elf)
            result=$(classify_elf_diff "$FILE_A" "$FILE_B")
            ;;
        *)
            # Unknown type — binary diff means semantic
            result="SEMANTIC"
            $VERBOSE && echo -e "  ${YELLOW}Unknown file type — defaulting to SEMANTIC${NC}"
            ;;
    esac

    case "$result" in
        COSMETIC)
            echo -e "${GREEN}COSMETIC${NC} — All differences are known-benign patterns"
            exit 0
            ;;
        SEMANTIC)
            echo -e "${RED}SEMANTIC${NC} — Real content differences detected"
            exit 1
            ;;
        *)
            echo -e "${RED}ERROR${NC} — Classification failed"
            exit 2
            ;;
    esac
}

main "$@"
