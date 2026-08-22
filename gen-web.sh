#!/usr/bin/env bash
#
# Build tiered web-enumeration wordlists (URL paths + API routes) from the
# downloaded SecLists set, optionally enriched with the webenum sources
# (Assetnote, OneListForAll) fetched by ./fetch.sh.
#
# Usage:
#   ./gen-web.sh [options]
#
# Options:
#   -o, --outdir DIR    Where to write the lists      (default: ./custom/web)
#   -w, --source DIR    Directory holding seclists/ (and webenum/) (default: .)
#   -s, --small N       Size of the small path tier   (default: 5000)
#   -m, --medium N      Cumulative size of medium     (default: 30000)
#   -b, --big N         Cumulative size of big        (default: 100000)
#   -j, --jobs N        Parallelism for sort          (default: nproc)
#   -k, --keep          Keep the temporary work directory
#   -h, --help          Show this help and exit
#
# Produces, under --outdir:
#
#   2_small.txt          most common content-discovery paths (top --small)
#   3_medium.txt         the next band                       (--small .. --medium)
#   4_big.txt            the next band                       (--medium .. --big)
#   5_rest.txt           every remaining unique path in the corpus
#   api.txt              merged, de-noised API endpoint list
#   extensions.txt       file extensions for -x/--extensions fuzzing
#
# It also writes one combined path list, one level up from --outdir and named
# after the category (custom/web.txt with the default --outdir):
#
#   ../web.txt           every unique path (all path tiers concatenated,
#                        common-first; api/extensions are kept separate)
#

set -Eeuo pipefail
export LC_ALL=C


SOURCE="."
OUTDIR="./custom/web"
NAME="web"
SMALL=5000
MEDIUM=30000
BIG=100000
JOBS="$(nproc 2>/dev/null || echo 4)"
KEEP=0
WORK=""

cleanup() {
    # Keep or remove working directory
    [[ -z "$WORK" ]] && return
    if (( KEEP )); then
        info "Keeping work directory: $WORK"
    else
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

log()     { printf '[%s] %s\n' "$1" "${*:2}"; }
info()    { log '*' "$@"; }
success() { log '+' "$@"; }
warning() { log '!' "$@" >&2; }
error()   { log '-' "$@" >&2; }
die() { error "$@"; exit 1; }

usage() {
    sed -n '2,/^$/s/^#\s\?//p' "${BASH_SOURCE[0]}"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

count() {
    wc -l < "$1" | tr -d ' '
}

normalize_path() {
    # Normalize a raw path list: strip CR, trim, drop blanks/comments, remove a
    # leading "/", and reject lines with whitespace or control chars. Leading
    # dots are kept.
    awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == ""            { next }
        substr($0, 1, 1) == "#" { next }
        { sub(/^\/+/, "") }
        $0 == ""            { next }
        /[[:space:]]/       { next }
        /[[:cntrl:]]/       { next }
        { print }
    '
}

normalize_api() {
    # Stricter filter for API endpoints: same as above, but keep only tokens
    # that look like real routes (must contain only URL-path-ish chars).
    awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == ""            { next }
        substr($0, 1, 1) == "#" { next }
        { sub(/^\/+/, "") }
        $0 == ""            { next }
        $0 !~ /[A-Za-z0-9]/ { next }
        $0 ~ /[^A-Za-z0-9._~:{}\/?=&%+-]/ { next }
        { print }
    '
}

collect_existing() {
    # Append each argument to the named array only if it is an existing file.
    local -n _out="$1"; shift
    local f
    for f in "$@"; do
        [[ -f "$f" ]] && _out+=("$f")
    done
    return 0
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -o|--outdir)  [[ $# -ge 2 ]] || die "$1 requires an argument"; OUTDIR="$2";  shift 2 ;;
            -w|--source)  [[ $# -ge 2 ]] || die "$1 requires an argument"; SOURCE="$2";  shift 2 ;;
            -s|--small)   [[ $# -ge 2 ]] || die "$1 requires an argument"; SMALL="$2";   shift 2 ;;
            -m|--medium)  [[ $# -ge 2 ]] || die "$1 requires an argument"; MEDIUM="$2";  shift 2 ;;
            -b|--big)     [[ $# -ge 2 ]] || die "$1 requires an argument"; BIG="$2";     shift 2 ;;
            -j|--jobs)    [[ $# -ge 2 ]] || die "$1 requires an argument"; JOBS="$2";    shift 2 ;;
            -k|--keep)    KEEP=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            die "Unknown argument: $1 (try --help)" ;;
        esac
    done
}

main() {
    parse_args "$@"

    local v
    for v in SMALL MEDIUM BIG JOBS; do
        is_uint "${!v}" || die "--${v,,} must be a non-negative integer (got '${!v}')"
    done
    (( SMALL <= MEDIUM )) || die "--small ($SMALL) must be <= --medium ($MEDIUM)"
    (( MEDIUM <= BIG ))   || die "--medium ($MEDIUM) must be <= --big ($BIG)"

    local WC="$SOURCE/seclists/Discovery/Web-Content"
    local WEBENUM="$SOURCE/webenum"
    [[ -d "$WC" ]] || die "SecLists Web-Content not found at '$WC' (run ./fetch.sh seclists first?)"

    if [[ -d "$WEBENUM" ]]; then
        info "Using webenum extras from $WEBENUM"
    else
        info "No webenum/ dir -- building from SecLists only (fetch 'webenum' for more)"
    fi

    mkdir -p -- "$OUTDIR"
    OUTDIR="$(cd -- "$OUTDIR" && pwd)"

    WORK="$(mktemp -d "${OUTDIR}/.gen.XXXXXXXX")"
    local sort_opts=(-T "$WORK" -S 50% --parallel="$JOBS")

    # --- 1. ranked backbone -> the path tiers -------------------------------
    # RAFT lists are frequency-ordered; common.txt seeds the very top. First
    # occurrence wins the rank. Only existing files are used.
    local backbone=()
    collect_existing backbone \
        "$WC/common.txt" \
        "$WEBENUM/assetnote-directories.txt" \
        "$WC/raft-large-directories.txt" \
        "$WC/raft-large-files.txt" \
        "$WC/raft-large-words.txt"
    (( ${#backbone[@]} )) || die "No backbone lists found under $WC"

    info "Ranking common paths from ${#backbone[@]} source(s) (top $BIG)..."
    awk -v limit="$BIG" '!seen[$0]++ { print; if (++n >= limit) exit }' \
        < <(cat -- "${backbone[@]}" | normalize_path) \
        > "$WORK/ranked.txt"

    local ranked; ranked="$(count "$WORK/ranked.txt")"
    info "Ranked $ranked unique paths."

    local s="$SMALL" m="$MEDIUM"
    (( s > ranked )) && s="$ranked"
    (( m > ranked )) && m="$ranked"

    sed -n "1,${s}p"          "$WORK/ranked.txt" > "$WORK/2_small.txt"
    sed -n "$((s + 1)),${m}p" "$WORK/ranked.txt" > "$WORK/3_medium.txt"
    sed -n "$((m + 1)),\$p"   "$WORK/ranked.txt" > "$WORK/4_big.txt"

    # --- 2. full path corpus -> catch-all -----------------------------------
    # Everything under Web-Content except the API dir (handled separately),
    # plus the optional webenum extras.
    info "Collecting and de-duplicating the full path corpus..."
    local corpus_extra=()
    collect_existing corpus_extra \
        "$WEBENUM/assetnote-directories.txt" \
        "$WEBENUM/onelistforallmicro.txt"
    {
        find "$WC" -type f -name '*.txt' -not -path '*/api/*' -print0
        # `if` (not `&&`) so an empty extras list leaves the group's exit
        # status at 0 -- otherwise set -e/pipefail would abort the run.
        if (( ${#corpus_extra[@]} )); then
            printf '%s\0' "${corpus_extra[@]}"
        fi
    } | xargs -0 cat -- \
      | normalize_path \
      | sort -u "${sort_opts[@]}" \
      > "$WORK/corpus_uniq.txt"

    sort "${sort_opts[@]}" "$WORK/ranked.txt" > "$WORK/placed_sorted.txt"
    comm -23 "$WORK/corpus_uniq.txt" "$WORK/placed_sorted.txt" > "$WORK/5_rest.txt"

    # Combined mega path list. The path tiers are disjoint and together cover
    # the whole unique path corpus, so a plain concatenation is already
    # de-duplicated and keeps the common-first ordering. api/extensions are a
    # different unit and stay in their own files. Published one level up from
    # --outdir, named after the category (custom/web.txt with the default).
    cat "$WORK/2_small.txt" "$WORK/3_medium.txt" \
        "$WORK/4_big.txt"   "$WORK/5_rest.txt" \
        > "$WORK/mega.txt"

    # --- 3. API endpoints ---------------------------------------------------
    info "Building API endpoint list..."
    local api_sources=()
    collect_existing api_sources \
        "$WEBENUM/assetnote-apiroutes.txt" \
        "$WC/api/api-endpoints.txt" \
        "$WC/api/api-endpoints-res.txt" \
        "$WC/api/api-seen-in-wild.txt" \
        "$WC/api/objects.txt" \
        "$WC/api/actions.txt"

    if (( ${#api_sources[@]} )); then
        cat -- "${api_sources[@]}" | normalize_api | awk '!seen[$0]++' > "$WORK/api.txt"
    else
        : > "$WORK/api.txt"
        warning "No API sources found."
    fi

    # --- 4. extensions ------------------------------------------------------
    # raft-large-extensions is frequency-ordered (.php, .html, ... first), so
    # dedup in place rather than sorting -- the ordering is the useful part.
    if [[ -f "$WC/raft-large-extensions.txt" ]]; then
        normalize_path < "$WC/raft-large-extensions.txt" | awk '!seen[$0]++' > "$WORK/extensions.txt"
    else
        : > "$WORK/extensions.txt"
    fi

    # --- 5. publish ---------------------------------------------------------
    local out outputs=(2_small 3_medium 4_big 5_rest api extensions)
    for out in "${outputs[@]}"; do
        mv -f -- "$WORK/${out}.txt" "$OUTDIR/${out}.txt"
    done
    local mega; mega="$(dirname -- "$OUTDIR")/$NAME.txt"
    mv -f -- "$WORK/mega.txt" "$mega"

    success "Wrote to $OUTDIR:"
    for out in "${outputs[@]}"; do
        printf '      %-18s %12s lines\n' "${out}.txt" "$(count "$OUTDIR/${out}.txt")"
    done
    success "Combined list: $mega ($(count "$mega") lines)"
}

main "$@"
