#!/usr/bin/env bash
#
# Build tiered web-enumeration wordlists (URL paths + API endpoints) from the
# downloaded SecLists set, enriched with the webenum sources fetched by
# ./fetch.sh (Assetnote, OneListForAll, Kiterunner).
#
# Usage:
#   ./gen-web.sh [options]
#
# Options:
#   -o, --outdir DIR    Where to write the lists      (default: ./custom/web)
#   -w, --source DIR    Directory holding seclists/ (and webenum/) (default: .)
#   -s, --small N       Size of the small tier        (default: 5000)
#   -m, --medium N      Cumulative size of medium     (default: 30000)
#   -b, --big N         Cumulative size of big        (default: 100000)
#   -j, --jobs N        Parallelism for sort          (default: nproc)
#   -k, --keep          Keep the temporary work directory
#   -h, --help          Show this help and exit
#
# The tiers hold both paths and API endpoints, ranked most-useful-first so the
# small tiers are the most efficient to run. Produces, under --outdir:
#
#   2_small.txt          most useful paths + API endpoints    (top --small)
#   3_medium.txt         the next band                        (--small .. --medium)
#   4_big.txt            the next band                        (--medium .. --big)
#   5_rest.txt           every remaining unique path/endpoint in the corpus
#   api.txt              dedicated API endpoint list (Assetnote + Kiterunner + SecLists)
#   extensions.txt       file extensions for -x/--extensions fuzzing
#
# It also writes one combined list, one level up from --outdir and named after
# the category (custom/web.txt with the default --outdir):
#
#   ../web.txt           every unique path + endpoint (all tiers concatenated,
#                        most-useful first; extensions kept separate)
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

# Filled in by main(): resolved source dirs and the pre-extracted Kiterunner
# route files. Kept global so the small stream helpers can see them.
WC=""
WEBENUM=""
STRINGS_BIN=""
KITE_SMALL=""
KITE_LARGE=""

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

count() {
    wc -l < "$1" | tr -d ' '
}

sanitize_path() {
    # Normalize any raw path / API endpoint into a clean, fuzzable token so the
    # different sources line up and dedup cleanly:
    #   * strip trailing CR and surrounding whitespace
    #   * drop blank lines and comments
    #   * drop any query string (everything from the first '?')
    #   * collapse repeated slashes, strip leading/trailing slashes
    #   * reject anything containing whitespace or control characters
    #   * keep only URL-path characters -- unreserved plus a few sub-delims and
    #     the {template} braces used by API route lists; drop everything else
    #     (so junk like <, >, [, ], \, quotes, commas from noisy sources goes)
    #   * require at least one alphanumeric so pure punctuation is dropped
    awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == ""                { next }
        substr($0, 1, 1) == "#" { next }
        { sub(/\?.*/, ""); gsub(/\/+/, "/"); sub(/^\/+/, ""); sub(/\/+$/, "") }
        $0 == ""                { next }
        /[[:space:]]/           { next }
        /[[:cntrl:]]/           { next }
        $0 !~ /[A-Za-z0-9]/     { next }
        $0 ~ /[^A-Za-z0-9._~:@%+{}\/-]/ { next }
        { print }
    '
}

normalize_ext() {
    # Lenient normalization for file extensions: strip CR, trim, drop blanks and
    # comments, reject whitespace/control. Extensions keep their punctuation
    # (leading dots, IIS ";" tricks, ...) so they are NOT run through
    # sanitize_path.
    awk '
        { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == ""            { next }
        substr($0, 1, 1) == "#" { next }
        /[[:space:]]/       { next }
        /[[:cntrl:]]/       { next }
        { print }
    '
}

cat_existing() {
    # cat the given files in order, silently skipping any that do not exist (an
    # empty path -- e.g. an unset Kiterunner file -- counts as missing). Never
    # fails the pipeline just because a source is absent.
    local f
    for f in "$@"; do
        [[ -n "$f" && -f "$f" ]] && cat -- "$f"
    done
    return 0
}

kite_routes() {
    # Extract plain route paths from a compiled Kiterunner .kite file. Routes are
    # stored as length-prefixed UTF-8 strings that begin with "/", so `strings`
    # isolates them; every other token (32-hex route hashes, HTTP method names)
    # is dropped because it does not start with "/". Needs `strings` (binutils);
    # without it the routes are simply skipped.
    local f="$1"
    [[ -f "$f" ]] || return 0
    if [[ -z "$STRINGS_BIN" ]]; then
        warning "No 'strings' binary found -- skipping $(basename "$f")"
        return 0
    fi
    "$STRINGS_BIN" -- "$f" | grep '^/' || true
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

    WC="$SOURCE/seclists/Discovery/Web-Content"
    WEBENUM="$SOURCE/webenum"
    [[ -d "$WC" ]] || die "SecLists Web-Content not found at '$WC' (run ./fetch.sh seclists first?)"

    if [[ -d "$WEBENUM" ]]; then
        info "Using webenum extras from $WEBENUM"
    else
        info "No webenum/ dir -- building from SecLists only (fetch 'webenum' for more)"
    fi

    STRINGS_BIN="$(command -v strings || true)"

    mkdir -p -- "$OUTDIR"
    OUTDIR="$(cd -- "$OUTDIR" && pwd)"

    WORK="$(mktemp -d "${OUTDIR}/.gen.XXXXXXXX")"
    local sort_opts=(-T "$WORK" -S 50% --parallel="$JOBS")

    # --- 0. pre-extract Kiterunner routes (once, reused everywhere) ----------
    # Running `strings` over the large .kite is not cheap, so materialize the raw
    # routes to the work dir and treat them as ordinary source files afterwards.
    if [[ -f "$WEBENUM/routes-small.kite" ]]; then
        info "Extracting Kiterunner small routes..."
        kite_routes "$WEBENUM/routes-small.kite" > "$WORK/kite-small.txt"
        [[ -s "$WORK/kite-small.txt" ]] && KITE_SMALL="$WORK/kite-small.txt"
    fi
    if [[ -f "$WEBENUM/routes-large.kite" ]]; then
        info "Extracting Kiterunner large routes..."
        kite_routes "$WEBENUM/routes-large.kite" > "$WORK/kite-large.txt"
        [[ -s "$WORK/kite-large.txt" ]] && KITE_LARGE="$WORK/kite-large.txt"
    fi

    # --- 1. ranked backbone -> the tiers ------------------------------------
    # Priority order == usefulness order: the first list a token appears in wins
    # its rank, so the small tiers are the highest-signal. Curated/common paths
    # and the top real-world (Assetnote httparchive) directories & API routes
    # lead; the broad RAFT/OneListForAll/Kiterunner-large sets fill in behind.
    # Everything runs through sanitize_path so paths and endpoints share units.
    local backbone=(
        "$WC/common.txt"                          # curated high-hit paths
        "$WC/quickhits.txt"                       # high-signal specific files (.git, .env, ...)
        "$WEBENUM/assetnote-directories.txt"      # top real-world directories
        "$WEBENUM/assetnote-apiroutes.txt"        # top real-world API routes
        "$WC/raft-large-directories.txt"
        "$WC/raft-large-files.txt"
        "$WC/api/api-seen-in-wild.txt"            # curated API endpoints
        "$WC/api/api-endpoints.txt"
        "$KITE_SMALL"                             # Kiterunner curated API routes
        "$WC/raft-large-words.txt"
        "$WEBENUM/onelistforallmicro.txt"         # OneListForAll (curated)
        "$WEBENUM/onelistforallshort.txt"         # OneListForAll (broad)
        "$KITE_LARGE"                             # Kiterunner broad API routes
    )

    info "Ranking paths + API endpoints (top $BIG)..."
    # The dedup awk exits once it has $BIG uniques; feeding it via process
    # substitution keeps the producer's SIGPIPE out of the pipe status.
    awk -v limit="$BIG" '!seen[$0]++ { print; if (++n >= limit) exit }' \
        < <(cat_existing "${backbone[@]}" | sanitize_path) \
        > "$WORK/ranked.txt"

    local ranked; ranked="$(count "$WORK/ranked.txt")"
    info "Ranked $ranked unique paths/endpoints."

    local s="$SMALL" m="$MEDIUM"
    (( s > ranked )) && s="$ranked"
    (( m > ranked )) && m="$ranked"

    sed -n "1,${s}p"          "$WORK/ranked.txt" > "$WORK/2_small.txt"
    sed -n "$((s + 1)),${m}p" "$WORK/ranked.txt" > "$WORK/3_medium.txt"
    sed -n "$((m + 1)),\$p"   "$WORK/ranked.txt" > "$WORK/4_big.txt"

    # --- 2. full corpus -> catch-all ----------------------------------------
    # Everything under Web-Content (API dir included now that the tiers mix
    # paths and endpoints), plus every webenum extra and the Kiterunner routes.
    info "Collecting and de-duplicating the full corpus (this is the slow part)..."
    {
        find "$WC" -type f -name '*.txt' -print0 | xargs -0 cat --
        cat_existing \
            "$WEBENUM/assetnote-directories.txt" \
            "$WEBENUM/assetnote-apiroutes.txt" \
            "$WEBENUM/onelistforallmicro.txt" \
            "$WEBENUM/onelistforallshort.txt" \
            "$KITE_SMALL" \
            "$KITE_LARGE"
    } | sanitize_path \
      | sort -u "${sort_opts[@]}" \
      > "$WORK/corpus_uniq.txt"

    info "Corpus holds $(count "$WORK/corpus_uniq.txt") unique paths/endpoints."

    # placed = the ranked entries that landed in tiers 2-4; remove them so the
    # tiers stay disjoint from 5_rest.
    sort "${sort_opts[@]}" "$WORK/ranked.txt" > "$WORK/placed_sorted.txt"
    comm -23 "$WORK/corpus_uniq.txt" "$WORK/placed_sorted.txt" > "$WORK/5_rest.txt"

    # --- 3. combined mega list ----------------------------------------------
    # The tiers are disjoint and together cover the whole unique corpus, so a
    # plain concatenation is already de-duplicated and keeps the most-useful
    # first ordering. Published one level up from --outdir, named after the
    # category (custom/web.txt with the default --outdir).
    cat "$WORK/2_small.txt" "$WORK/3_medium.txt" \
        "$WORK/4_big.txt"   "$WORK/5_rest.txt" \
        > "$WORK/mega.txt"

    # --- 4. dedicated API endpoint list -------------------------------------
    # A focused, frequency-ordered API list (kept alongside the mixed tiers for
    # API-only runs, e.g. ffuf/kr against a known API base). First occurrence
    # wins, so the order is preserved rather than sorted.
    info "Building dedicated API endpoint list..."
    local api_backbone=(
        "$WEBENUM/assetnote-apiroutes.txt"
        "$KITE_SMALL"
        "$WC/api/api-seen-in-wild.txt"
        "$WC/api/api-endpoints.txt"
        "$WC/api/api-endpoints-res.txt"
        "$WC/api/objects.txt"
        "$WC/api/actions.txt"
        "$KITE_LARGE"
    )
    cat_existing "${api_backbone[@]}" | sanitize_path | awk '!seen[$0]++' > "$WORK/api.txt"
    [[ -s "$WORK/api.txt" ]] || warning "No API sources found."

    # --- 5. extensions ------------------------------------------------------
    # raft-large-extensions is frequency-ordered (.php, .html, ... first), so
    # dedup in place rather than sorting -- the ordering is the useful part.
    if [[ -f "$WC/raft-large-extensions.txt" ]]; then
        normalize_ext < "$WC/raft-large-extensions.txt" | awk '!seen[$0]++' > "$WORK/extensions.txt"
    else
        : > "$WORK/extensions.txt"
    fi

    # --- 6. publish ---------------------------------------------------------
    local out outputs=(2_small 3_medium 4_big 5_rest api extensions)
    for out in "${outputs[@]}"; do
        mv -f -- "$WORK/${out}.txt" "$OUTDIR/${out}.txt"
    done
    local mega; mega="$(dirname -- "$OUTDIR")/$NAME.txt"
    mv -f -- "$WORK/mega.txt" "$mega"

    success "Wrote to $OUTDIR:"
    for out in "${outputs[@]}"; do
        printf '      %-18s %12s lines\n' "${out}.txt" "$(count "$OUTDIR/${out}.txt")" >&2
    done
    success "Combined list: $mega ($(count "$mega") lines)"
}

main "$@"
