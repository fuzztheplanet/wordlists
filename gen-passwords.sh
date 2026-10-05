#!/usr/bin/env bash
#
# Generate tiered password wordlists from the available wordlists.
#
# Usage:
#   ./gen-passwords.sh [options]
#
# Options:
#   -o, --outdir DIR    Where to write the generated lists (default: ./custom)
#   -w, --source DIR    Directory holding seclists/ and pwdb/ (default: .)
#   -s, --small N       Size of the small tier   (default: 10000)
#   -m, --medium N      Cumulative size of medium (default: 100000)
#   -b, --big N         Cumulative size of big    (default: 1000000)
#   -j, --jobs N        Parallelism for sort      (default: nproc)
#   -k, --keep          Keep the temporary work directory instead of deleting it
#   -h, --help          Show this help and exit
#
# It produces four disjoint files, each containing passwords NOT present in the
# smaller tiers, ordered so the most common come first:
#
#   2_small.txt    the most common passwords            (--small)
#   3_medium.txt   the next band                        (--small .. --medium)
#   4_big.txt      the next band                        (--medium .. --big)
#   5_rest.txt     every remaining unique password in the corpus
#
# It also writes one combined list, one level up from --outdir and named after
# the category (custom/passwords.txt with the default --outdir):
#
#   ../passwords.txt   every unique password (all tiers concatenated,
#                      common-first)
#

set -Eeuo pipefail
export LC_ALL=C


SOURCE="."
OUTDIR="./custom/passwords"
NAME="passwords"
SMALL=10000
MEDIUM=100000
BIG=1000000
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

log()     { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info()    { log '*' "$@"; }
success() { log '+' "$@"; }
warning() { log '!' "$@"; }
error()   { log '-' "$@"; }
die() { error "$@"; exit 1; }

usage() {
    sed -n '2,/^$/s/^#\s\?//p' "${BASH_SOURCE[0]}"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

normalize() {
    # Strip trailing CR and drop blank lines. Passwords are case- and
    # character-sensitive, so nothing else is altered. If a line has several words,
    # write a word per line.
    awk '{ sub(/\r$/, ""); for (i = 1; i <= NF; i++) print $i }'
}

# Frequency-ranked backbone, most-common-first. Order matters: the first list a
# password appears in wins its rank.
backbone_files() {
    printf '%s\n' \
        "$SECLISTS/Passwords/Common-Credentials/xato-net-10-million-passwords.txt" \
        "$PWDB/wordlists/ignis-10M.txt" \
        "$SECLISTS/Passwords/Leaked-Databases/rockyou.txt"
}

corpus_files0() {
    # The full password corpus, NUL-delimited.
    find "$SECLISTS/Passwords" -type f -name '*.txt' \
        -print0
    find "$PWDB/wordlists" -type f -name '*.txt' -print0
    printf '%s\0' "${CRACKSTATION}/human.txt"
    [[ -f "$PWDB/mystery-list.txt" ]] && printf '%s\0' "$PWDB/mystery-list.txt"
    return 0
}

count() {
    wc -l < "$1" | tr -d ' '
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --*=*)        set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
            --)           shift; (( $# )) && die "Unexpected argument: $1 (this script takes options only)"; break ;;
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

    SECLISTS="$SOURCE/seclists"
    PWDB="$SOURCE/pwdb"
    CRACKSTATION="$SOURCE/crackstation"

    [[ -d "$SECLISTS" ]] || die "SecLists not found at '$SECLISTS' (run ./fetch.sh first?)"
    [[ -d "$PWDB" ]]     || die "Pwdb not found at '$PWDB' (run ./fetch.sh first?)"

    local f missing=()
    while IFS= read -r f; do
        [[ -f "$f" ]] || missing+=("$f")
    done < <(backbone_files)
    (( ${#missing[@]} == 0 )) || die "Missing backbone list(s): ${missing[*]}"

    mkdir -p -- "$OUTDIR"
    OUTDIR="$(cd -- "$OUTDIR" && pwd)"

    # Work on the same filesystem as the output so sort spills and the final
    # move stay local. cleanup() removes it via the EXIT trap.
    WORK="$(mktemp -d "${OUTDIR}/.gen.XXXXXXXX")"

    local sort_opts=(-T "$WORK" -S 50% --parallel="$JOBS")

    # --- 1. ranked backbone -> the common tiers -----------------------------
    # Tokenize through the SAME normalize() as the corpus so both halves use
    # identical (word-split) units -- otherwise the placed set and 5_rest would
    # not line up. The dedup awk exits once it has $BIG uniques; feeding it via
    # process substitution keeps the producer's SIGPIPE out of the pipe status.
    info "Building frequency-ranked backbone (top $BIG)..."
    local backbone=()
    while IFS= read -r f; do backbone+=("$f"); done < <(backbone_files)
    awk -v limit="$BIG" '!seen[$0]++ { print; if (++n >= limit) exit }' \
        < <(cat -- "${backbone[@]}" | normalize) \
        > "$WORK/ranked.txt"

    local ranked; ranked="$(count "$WORK/ranked.txt")"
    info "Ranked $ranked unique passwords."

    # Clamp the cut points to what the backbone actually yielded.
    local s="$SMALL" m="$MEDIUM"
    (( s > ranked )) && s="$ranked"
    (( m > ranked )) && m="$ranked"

    sed -n "1,${s}p"          "$WORK/ranked.txt" > "$WORK/2_small.txt"
    sed -n "$((s + 1)),${m}p" "$WORK/ranked.txt" > "$WORK/3_medium.txt"
    sed -n "$((m + 1)),\$p"   "$WORK/ranked.txt" > "$WORK/4_big.txt"

    # --- 2. full corpus -> catch-all (everything not already placed) --------
    info "Collecting and de-duplicating the full corpus (this is the slow part)..."
    corpus_files0 \
        | xargs -0 cat -- \
        | normalize \
        | sort -u "${sort_opts[@]}" \
        > "$WORK/corpus_uniq.txt"

    info "Corpus holds $(count "$WORK/corpus_uniq.txt") unique passwords."

    # placed = the ranked entries that landed in tiers 2-4; remove them so the
    # tiers stay disjoint from 5_rest.
    sort "${sort_opts[@]}" "$WORK/ranked.txt" > "$WORK/placed_sorted.txt"
    comm -23 "$WORK/corpus_uniq.txt" "$WORK/placed_sorted.txt" > "$WORK/5_rest.txt"

    # --- 3. combined mega list ----------------------------------------------
    # The tiers are disjoint and together cover the whole unique corpus, so a
    # plain concatenation is already de-duplicated and keeps the common-first
    # ordering (ranked tiers, then the sorted remainder). It is published one
    # level up from --outdir, named after the category (custom/passwords.txt
    # with the default --outdir).
    cat "$WORK/2_small.txt" "$WORK/3_medium.txt" "$WORK/4_big.txt" "$WORK/5_rest.txt" \
        > "$WORK/mega.txt"

    # --- 4. publish ---------------------------------------------------------
    local out
    for out in 2_small 3_medium 4_big 5_rest; do
        mv -f -- "$WORK/${out}.txt" "$OUTDIR/${out}.txt"
    done
    local mega; mega="$(dirname -- "$OUTDIR")/$NAME.txt"
    mv -f -- "$WORK/mega.txt" "$mega"

    success "Wrote to $OUTDIR:"
    for out in 2_small 3_medium 4_big 5_rest; do
        printf '      %-12s %12s lines\n' "${out}.txt" "$(count "$OUTDIR/${out}.txt")" >&2
    done
    success "Combined list: $mega ($(count "$mega") lines)"
}

main "$@"
