#!/usr/bin/env bash
#
# Usage:
#   ./gen-cmdexec.sh [category ...] [options]
#
# Generate OS command-execution payloads from the templates in ./cmdexec by
# substituting target-specific values, and print them to stdout (one per line).
#
# Categories (default: all templates):
#   reverse            reverse-shell connect-backs      (uses --ip [--port])
#   touch              create a file                    (uses --file)
#   cat                display a file                   (uses --file)
#   all                every template above
#
# Options:
#   -i, --ip IP        listener IP for reverse shells      (default: 127.0.0.1)
#   -p, --port PORT    listener port for reverse shells   (default: 4444)
#   -f, --file PATH    target file for touch / cat        (default: /tmp/coucou.txt)
#   -s, --shell SH     shell for {SHELL} placeholders      (default: /bin/sh)
#   -d, --dir DIR      templates directory      (default: <script dir>/cmdexec)
#   -l, --list         list available categories (and payload counts) and exit.
#   -h, --help         show this help and exit.
#
# Each template file in the templates directory is a category named after the
# file: reverse.txt, touch.txt, cat.txt, ... A template holds raw command
# payloads with placeholders filled in at generation time:
#
#   {IP}     attacker / listener host   (--ip,   reverse shells)
#   {PORT}   attacker / listener port   (--port, reverse shells; default 4444)
#   {FILE}   target file path           (--file, touch / cat)
#   {SHELL}  shell to spawn             (--shell; default /bin/sh)
#
# Examples:
#   ./gen-cmdexec.sh reverse --ip 10.10.14.7 --port 9001 > rev.txt
#   ./gen-cmdexec.sh cat --file /etc/passwd
#   ./gen-cmdexec.sh touch --file /var/www/html/poc.txt
#   ./gen-cmdexec.sh cat --file=/etc/passwd | ffuf -w - ...
#

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IP="127.0.0.1"
PORT="4444"
FILE="/tmp/coucou.txt"
SHELL_="/bin/sh"
DIR="$SCRIPT_DIR/cmdexec"
LIST=0
declare -a CATS=()

log()     { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info()    { log '*' "$@"; }
warning() { log '!' "$@"; }
error()   { log '-' "$@"; }
die() { error "$@"; exit 1; }

usage() {
    sed -n '2,/^$/s/^#\s\?//p' "${BASH_SOURCE[0]}"
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --*=*)      set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
            -i|--ip)    [[ $# -ge 2 ]] || die "$1 requires an argument"; IP="$2";     shift 2 ;;
            -p|--port)  [[ $# -ge 2 ]] || die "$1 requires an argument"; PORT="$2";   shift 2 ;;
            -f|--file)  [[ $# -ge 2 ]] || die "$1 requires an argument"; FILE="$2";   shift 2 ;;
            -s|--shell) [[ $# -ge 2 ]] || die "$1 requires an argument"; SHELL_="$2"; shift 2 ;;
            -d|--dir)   [[ $# -ge 2 ]] || die "$1 requires an argument"; DIR="$2";    shift 2 ;;
            -l|--list)  LIST=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            --)         shift; while (( $# )); do CATS+=("$1"); shift; done ;;
            -*)         die "Unknown option: $1 (try --help)" ;;
            *)          CATS+=("$1"); shift ;;
        esac
    done
}

# Resolve a category name to its template file path.
template_for() { printf '%s/%s.txt' "$DIR" "$1"; }

list_categories() {
    local f name
    shopt -s nullglob
    for f in "$DIR"/*.txt; do
        name="$(basename -- "$f" .txt)"
        printf '  %-10s %4s payloads\n' "$name" \
            "$(grep -vcE '^[[:space:]]*(#|$)' "$f")"
    done
    shopt -u nullglob
}

# Substitute placeholders in a single template line (literal, never eval'd).
fill() {
    local line="$1"
    line="${line//\{IP\}/$IP}"
    line="${line//\{PORT\}/$PORT}"
    line="${line//\{FILE\}/$FILE}"
    line="${line//\{SHELL\}/$SHELL_}"
    printf '%s' "$line"
}

generate() {
    local cat f line
    for cat in "${CATS[@]}"; do
        f="$(template_for "$cat")"
        [[ -f "$f" ]] || die "No template for category '$cat' (looked for $f; try --list)"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            fill "$line"
            printf '\n'
        done < "$f"
    done
}

main() {
    parse_args "$@"

    [[ -d "$DIR" ]] || die "Templates directory not found: $DIR"

    if (( LIST )); then
        info "Available categories in $DIR:"
        list_categories
        exit 0
    fi

    # Default to every template; expand the 'all' alias the same way.
    if (( ${#CATS[@]} == 0 )) || [[ " ${CATS[*]} " == *" all "* ]]; then
        shopt -s nullglob
        local f; CATS=()
        for f in "$DIR"/*.txt; do CATS+=("$(basename -- "$f" .txt)"); done
        shopt -u nullglob
        (( ${#CATS[@]} )) || die "No *.txt templates in $DIR"
    fi

    generate
}

main "$@"
