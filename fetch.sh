#!/usr/bin/env bash
#
# Fetch popular password wordlists and cracking rules in parallel.
#
# Usage:
#   ./fetch.sh [options] [wordlist ...]
#
# Options:
#   -o, --outdir DIR   Where to place the wordlists (default: current directory)
#   -f, --force        Re-download wordlists that are already present
#   -l, --list         List the available wordlists and exit
#   -q, --quiet        Only print warnings and errors
#   -h, --help         Show this help and exit
#
# Available wordlists: crackstation, hashcat-rules, pwdb, seclists, webenum.
#
# With no wordlist arguments, every available target is fetched.
#
# Examples:
#   ./fetch.sh                          # everything, into $PWD
#   ./fetch.sh -o /opt/wordlists        # everything, into /opt/wordlists
#   ./fetch.sh seclists pwdb            # only these two
#   ./fetch.sh -f hashcat-rules         # redownload just the hashcat / One Rule rules
#

set -Eeuo pipefail

AVAILABLE_WORDLISTS=(
    crackstation
    pwdb
    seclists
    hashcat-rules
    webenum
)

ASSETNOTE_APIROUTES_URL="https://wordlists-cdn.assetnote.io/data/automated/httparchive_apiroutes_2024_05_28.txt"
ASSETNOTE_DIRS_URL="https://wordlists-cdn.assetnote.io/data/automated/httparchive_directories_1m_2024_05_28.txt"
CRACKSTATION_FULL_URL="https://crackstation.net/files/crackstation.txt.gz"
CRACKSTATION_HUMAN_URL="https://crackstation.net/files/crackstation-human-only.txt.gz"
HASHCAT_URL="https://github.com/hashcat/hashcat/archive/refs/heads/master.tar.gz"
ONELISTFORALL_MICRO_URL="https://raw.githubusercontent.com/six2dez/OneListForAll/main/onelistforallmicro.txt"
ONE_RULE_ALL_URL="https://raw.githubusercontent.com/NotSoSecure/password_cracking_rules/master/OneRuleToRuleThemAll.rule"
ONE_RULE_STILL_URL="https://raw.githubusercontent.com/stealthsploit/OneRuleToRuleThemStill/main/OneRuleToRuleThemStill.rule"
PWDB_URL="https://github.com/ignis-sec/Pwdb-Public/archive/refs/heads/master.tar.gz"
SECLISTS_URL="https://github.com/danielmiessler/SecLists/archive/refs/heads/master.tar.gz"

# Defaults
OUTDIR="$PWD"
FORCE=0
QUIET=0
LOG_PREFIX=""
CHILD_PIDS=()


### Helpers
log() {
    local marker="$1" stream="$2"
    shift 2

    local prefix=""
    [[ -n "$LOG_PREFIX" ]] && prefix="${LOG_PREFIX}: "

    printf '[%s] %s%s\n' "$marker" "$prefix" "$*" >&"$stream"
}

info()    { (( QUIET )) || log '*' 1 "$@"; }
success() { (( QUIET )) || log '+' 1 "$@"; }
warning() { log '!' 2 "$@"; }
error()   { log '-' 2 "$@"; }
die()     { error "$@"; exit 1; }

usage() {
    # Print the comment block at the top of this file minus the shebang
    sed -n '2,/^$/s/^#\s\?//p' "${BASH_SOURCE[0]}"
}

is_available() {
    # Return 0 if wordlist exists, 1 otherwise
    local candidate="$1" name
    for name in "${AVAILABLE_WORDLISTS[@]}"; do
        [[ "$name" == "$candidate" ]] && return 0
    done
    return 1
}

download() {
    local url="$1"
    local outfile="$2"

    info "Downloading $(basename "$outfile")"
    curl --fail --silent --show-error --location \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 30 \
        --continue-at - \
        --output "$outfile" \
        "$url"
}


### Fetchers
fetch_crackstation() {
    local dir="$1"

    download "$CRACKSTATION_HUMAN_URL" "$dir/human.txt.gz"
    gzip -df "$dir/human.txt.gz"

    download "$CRACKSTATION_FULL_URL" "$dir/complete.txt.gz"
    gzip -df "$dir/complete.txt.gz"
}

fetch_pwdb() {
    local dir="$1"

    download "$PWDB_URL" "$dir/pwdb.tar.gz"
    tar -xf "$dir/pwdb.tar.gz" -C "$dir" --strip-components=1
    rm -rf "$dir/pwdb.tar.gz"
}

fetch_seclists() {
    local dir="$1"

    download "$SECLISTS_URL" "$dir/seclists.tar.gz"
    tar -xf "$dir/seclists.tar.gz" -C "$dir" --strip-components=1
    rm -rf "$dir/seclists.tar.gz"

    # Extract rockyou
    local rockyou
    rockyou="$(find "$dir" -type f -name 'rockyou.txt.tar.gz' -print -quit)"
    if [[ -n "$rockyou" ]]; then
        info "Extracting rockyou.txt"
        tar -xf "$rockyou" -C "$(dirname "$rockyou")"
        rm -f "$rockyou"
    else
        warning "rockyou.txt.tar.gz not found in SecLists"
    fi
}

fetch_hashcat-rules() {
    local dir="$1"

    # Official Hashcat rules
    download "$HASHCAT_URL" "$dir/hashcat.tar.gz"
    mkdir -p "$dir/hashcat"
    tar -xzf "$dir/hashcat.tar.gz" -C "$dir/hashcat" \
        --strip-components=2 hashcat-master/rules
    rm -f "$dir/hashcat.tar.gz"

    # OneRuleToRuleThem*
    download "$ONE_RULE_ALL_URL"   "$dir/OneRuleToRuleThemAll.rule"
    download "$ONE_RULE_STILL_URL" "$dir/OneRuleToRuleThemStill.rule"
}

fetch_webenum() {
    local dir="$1"

    download "$ASSETNOTE_DIRS_URL"      "$dir/assetnote-directories.txt"
    download "$ASSETNOTE_APIROUTES_URL" "$dir/assetnote-apiroutes.txt"
    download "$ONELISTFORALL_MICRO_URL" "$dir/onelistforallmicro.txt"
}


### Run jobs
run_job() {
    # Run fetch_$1 in a temporary directory
    local name="$1"
    local final="$OUTDIR/$name"
    local staging

    LOG_PREFIX="$name"

    staging="$(mktemp -d "$OUTDIR/.${name}.XXXXXXXX")"
    # staging="$(mktemp -d)"
    trap 'rm -rf -- "$staging"' EXIT

    "fetch_${name}" "$staging"

    chmod 755 "$staging"
    rm -rf -- "$final"
    mv -- "$staging" "$final"

    trap - EXIT

    success "done ($(du -sh "$final" | cut -f1))"
}

terminate_children() {
    # Kill outstanding processes
    local pid
    for pid in "${CHILD_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}

on_interrupt() {
    # Cleanup on interrupt
    trap - INT TERM
    error "Interrupted, stopping downloads"
    terminate_children
    exit 130
}


### Argument parsing & Main
parse_args() {
    local -n _selected="$1"
    shift

    while (( $# )); do
        case "$1" in
            -o|--outdir)
                [[ $# -ge 2 ]] || die "--outdir requires an argument"
                OUTDIR="$2"
                shift 2
                ;;
            --outdir=*) OUTDIR="${1#*=}"; shift ;;
            -f|--force) FORCE=1; shift ;;
            -q|--quiet) QUIET=1; shift ;;
            -l|--list)
                printf '%s\n' "${AVAILABLE_WORDLISTS[@]}"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --) shift; _selected+=("$@"); break ;;
            -*) die "Unknown option: $1 (try --help)" ;;
            *)  _selected+=("$1"); shift ;;
        esac
    done
}

main() {
    local selected=()
    local name

    parse_args selected "$@"

    if (( ${#selected[@]} == 0 )); then
        selected=("${AVAILABLE_WORDLISTS[@]}")
    else
        for name in "${selected[@]}"; do
            is_available "$name" \
                || die "Unknown wordlist '$name' (available: ${AVAILABLE_WORDLISTS[*]})"
        done
    fi

    mkdir -p -- "$OUTDIR"
    OUTDIR="$(cd -- "$OUTDIR" && pwd)"

    info "Output directory: $OUTDIR"

    trap on_interrupt INT TERM

    local pids=() names=()

    for name in "${selected[@]}"; do
        if [[ -d "$OUTDIR/$name" && $FORCE -eq 0 ]]; then
            info "$name already present, skipping (use --force to re-download)"
            continue
        fi

        info "Starting $name..."
        run_job "$name" &
        pids+=("$!")
        names+=("$name")
    done

    if (( ${#pids[@]} == 0 )); then
        success "Nothing to do."
        return 0
    fi

    CHILD_PIDS=("${pids[@]}")

    info "Waiting for ${#pids[@]} download(s) to finish..."

    local i failed=()

    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            success "${names[$i]} completed."
        else
            error "${names[$i]} failed."
            failed+=("${names[$i]}")
        fi
    done

    trap - INT TERM

    if (( ${#failed[@]} )); then
        die "Failed: ${failed[*]} (re-run with those names to retry)"
    fi

    success "All requested wordlists downloaded in $(( SECONDS / 60 ))m $(( SECONDS % 60 ))s."
}

main "$@"
