#!/usr/bin/env bash
#
# Build tiered DNS wordlists (subdomain / hostname labels)
#
# Usage:
#   ./gen-dns.sh [options]
#
# Options:
#   -o, --outdir DIR    Where to write the lists      (default: ./custom/dns)
#   -w, --source DIR    Directory holding seclists/   (default: .)
#   -s, --small N       Size of the small tier        (default: 5000)
#   -m, --medium N      Cumulative size of medium     (default: 50000)
#   -b, --big N         Cumulative size of big        (default: 500000)
#   -j, --jobs N        Parallelism for sort          (default: nproc)
#   -k, --keep          Keep the temporary work directory
#   -h, --help          Show this help and exit
#
# Produces four disjoint files under --outdir, each holding labels NOT present
# in the smaller tiers, ordered so the most commonly seen come first:
#
#   1_small.txt    most common subdomain labels       (top --small)
#   2_medium.txt   the next band                      (--small .. --medium)
#   3_big.txt      the next band                      (--medium .. --big)
#   4_all.txt      every remaining unique label in the corpus
#

set -Eeuo pipefail
export LC_ALL=C


SOURCE="."
OUTDIR="./custom/dns"
SMALL=5000
MEDIUM=50000
BIG=500000
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

normalize_dns() {
    # Normalize a raw DNS list into bare, lowercase hostname labels: strip CR,
    # trim, drop blanks/comments, drop a "*." wildcard prefix and any leading or
    # trailing dots, then keep only entries that are valid label sequences.
    # Multi-level prefixes ("dev.api") are kept; underscores are kept because
    # service records rely on them (_dmarc, _domainkey).
    awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == ""                { next }
        substr($0, 1, 1) == "#" { next }
        { $0 = tolower($0); sub(/^\*\./, ""); gsub(/^\.+|\.+$/, "") }
        $0 == ""                { next }
        length($0) > 253        { next }
        $0 !~ /^[a-z0-9_.-]+$/  { next }
        $0 !~ /[a-z0-9]/        { next }
        {
            n = split($0, label, ".")
            for (i = 1; i <= n; i++) {
                len = length(label[i])
                if (len == 0 || len > 63)                        next
                if (substr(label[i], 1, 1) == "-")               next
                if (substr(label[i], len, 1) == "-")             next
            }
            print
        }
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

    local DNS="$SOURCE/seclists/Discovery/DNS"
    [[ -d "$DNS" ]] || die "SecLists DNS lists not found at '$DNS' (run ./fetch.sh seclists first?)"

    mkdir -p -- "$OUTDIR"
    OUTDIR="$(cd -- "$OUTDIR" && pwd)"

    WORK="$(mktemp -d "${OUTDIR}/.gen.XXXXXXXX")"
    local sort_opts=(-T "$WORK" -S 50% --parallel="$JOBS")

    # --- 1. ranked backbone -> the tiers ------------------------------------
    # These sources are frequency-ordered (Cloudflare zone stats, bitquark and
    # n0kovo mass-scan hit counts), so the first list a label appears in wins
    # its rank. services-names.txt sits near the top: it is small, curated and
    # high-signal for modern infrastructure.
    local backbone=()
    collect_existing backbone \
        "$DNS/subdomains-top1million-5000.txt" \
        "$DNS/services-names.txt" \
        "$DNS/subdomains-top1million-20000.txt" \
        "$DNS/subdomains-top1million-110000.txt" \
        "$DNS/bitquark-subdomains-top100000.txt" \
        "$DNS/n0kovo_subdomains.txt" \
        "$DNS/shubs-subdomains.txt" \
        "$DNS/combined_subdomains.txt"
    (( ${#backbone[@]} )) || die "No backbone lists found under $DNS"

    info "Ranking labels from ${#backbone[@]} source(s) (top $BIG)..."
    # The dedup awk exits once it has $BIG uniques; feeding it via process
    # substitution keeps the producer's SIGPIPE out of the pipe status.
    awk -v limit="$BIG" '!seen[$0]++ { print; if (++n >= limit) exit }' \
        < <(cat -- "${backbone[@]}" | normalize_dns) \
        > "$WORK/ranked.txt"

    local ranked; ranked="$(count "$WORK/ranked.txt")"
    info "Ranked $ranked unique labels."

    # Clamp the cut points to what the backbone actually yielded.
    local s="$SMALL" m="$MEDIUM"
    (( s > ranked )) && s="$ranked"
    (( m > ranked )) && m="$ranked"

    sed -n "1,${s}p"          "$WORK/ranked.txt" > "$WORK/1_small.txt"
    sed -n "$((s + 1)),${m}p" "$WORK/ranked.txt" > "$WORK/2_medium.txt"
    sed -n "$((m + 1)),\$p"   "$WORK/ranked.txt" > "$WORK/3_big.txt"

    # --- 2. full corpus -> catch-all ----------------------------------------
    # subdomains-top1million-full is shipped as a 7z archive; unpack it into the
    # work dir when a 7z binary is around so it can join the corpus.
    local sevenzip
    sevenzip="$(command -v 7z || command -v 7za || command -v 7zr || true)"
    if [[ -f "$DNS/subdomains-top1million-full.7z" ]]; then
        if [[ -n "$sevenzip" ]]; then
            info "Extracting subdomains-top1million-full.7z..."
            "$sevenzip" e -bso0 -bsp0 -y -o"$WORK" "$DNS/subdomains-top1million-full.7z" >/dev/null
        else
            warning "No 7z binary found -- skipping subdomains-top1million-full.7z"
        fi
    fi

    info "Collecting and de-duplicating the full label corpus (this is the slow part)..."
    {
        find "$DNS" -type f -name '*.txt' -not -name 'tlds.txt' -print0
        find "$WORK" -maxdepth 1 -type f -name 'subdomains-top1million-full.txt' -print0
    } | xargs -0 cat -- \
      | normalize_dns \
      | sort -u "${sort_opts[@]}" \
      > "$WORK/corpus_uniq.txt"

    info "Corpus holds $(count "$WORK/corpus_uniq.txt") unique labels."

    # placed = the ranked entries that landed in tiers 1-3; remove them so the
    # tiers stay disjoint from 4_all.
    sort "${sort_opts[@]}" "$WORK/ranked.txt" > "$WORK/placed_sorted.txt"
    comm -23 "$WORK/corpus_uniq.txt" "$WORK/placed_sorted.txt" > "$WORK/4_all.txt"

    # --- 3. publish ---------------------------------------------------------
    local out outputs=(1_small 2_medium 3_big 4_all)
    for out in "${outputs[@]}"; do
        mv -f -- "$WORK/${out}.txt" "$OUTDIR/${out}.txt"
    done

    success "Wrote to $OUTDIR:"
    for out in "${outputs[@]}"; do
        printf '      %-12s %12s lines\n' "${out}.txt" "$(count "$OUTDIR/${out}.txt")"
    done
}

main "$@"
