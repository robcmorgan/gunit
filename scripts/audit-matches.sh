#!/usr/bin/env bash
AUDIT_VERSION="1"
# =============================================================================
#  audit-matches.sh — find rows where fetch-books downloaded the WRONG book.
#
#  The ticker-parsing bug (fixed in fetch-books v20) meant some rows got an md5
#  for a completely different book. This finds them by cross-referencing, for
#  every row that carries an md5:
#     - what the ROW wanted        (its title|author)
#     - what was ACTUALLY fetched  (the "downloaded -> NAME ... <md5>" log line)
#     - the MATCHER's verdict      (does the fetched name match the wanted row?)
#
#  The download filename in the log is the ground truth of what each md5 is. We
#  score the wanted title/author against that filename; a low score means the
#  md5 is a wrong book and the row should be reset.
#
#  USAGE:
#     ./audit-matches.sh LIST.tsv [LIST2.tsv ...]
#     LOG=~/logs/fetch-books.log ./audit-matches.sh booker.tsv
#     ./audit-matches.sh --reset LIST.tsv     # also rewrite bad rows to fetchable
#
#  Output columns:  VERDICT  score  md5  | wanted  ||  fetched
#     OK       fetched book matches the row
#     WRONG    fetched book does NOT match — md5 is a different book (reset it)
#     NOLOG    md5 in the row but no "downloaded ->" line found (can't verify)
#  --reset rewrites WRONG rows back to bare "f1|f2" so a v20 re-fetch retries them
#  (a timestamped .bak is written first). NOLOG rows are reported, never reset.
# =============================================================================
set -uo pipefail

LOG="${LOG:-$HOME/logs/fetch-books.log}"
CONFIDENCE="${CONFIDENCE:-0.6}"
RESET=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --reset) RESET=1; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -eq 0 ] && { echo "usage: $0 [--reset] LIST.tsv..." >&2; exit 1; }
[ -f "$LOG" ] || { echo "log not found: $LOG (set LOG=...)" >&2; exit 1; }

. "$(dirname "$0")/match-lib.sh"

# For a given md5, pull the most recent "downloaded -> <name> ... <md5>" line
# from the log and return the <name> portion (the real fetched filename, which
# embeds "Title -- Author -- ...").  Empty if none.
fetched_name() {
    local md5="$1"
    grep -F "$md5" "$LOG" 2>/dev/null \
        | grep -F "downloaded -> " \
        | tail -1 \
        | sed 's/.*downloaded -> //; s/  *(quota left.*$//'
}

audit_one() {
    local file="$1"
    [ -f "$file" ] || { echo "skip (not found): $file" >&2; return; }
    echo "==== $file ===="
    local tmp; tmp="$(mktemp)"
    local n_ok=0 n_wrong=0 n_nolog=0 n_skip=0

    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac

        local f1 f2 status md5
        f1="$(printf '%s' "$raw" | cut -d'|' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
        f2="$(printf '%s' "$raw" | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
        status="$(printf '%s' "$raw" | cut -d'|' -f3 | tr -d ' ')"
        md5="$(printf '%s' "$raw" | cut -d'|' -f4 | tr -d ' ')"

        # nothing to audit without an md5
        if [ -z "$md5" ]; then
            printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
        fi

        local name; name="$(fetched_name "$md5")"
        if [ -z "$name" ]; then
            printf 'NOLOG    -      %s  | %s | %s\n' "$md5" "$f1" "$f2"
            printf '%s\n' "$raw" >> "$tmp"; n_nolog=$((n_nolog+1)); continue
        fi

        # score the wanted row (both fields) against the fetched filename as a
        # blob — the filename has "Title -- Author -- publisher -- md5 -- src".
        local s; s="$(book_match_score "$f1" "$f2" "$name")"
        if ge "$s" "$CONFIDENCE"; then
            printf 'OK       %s  %s  | %s | %s\n' "$s" "$md5" "$f1" "$f2"
            printf '%s\n' "$raw" >> "$tmp"; n_ok=$((n_ok+1))
        else
            printf 'WRONG    %s  %s  | %s | %s\n' "$s" "$md5" "$f1" "$f2"
            printf '             fetched: %s\n' "$name"
            if [ "$RESET" -eq 1 ]; then
                printf '%s|%s\n' "$f1" "$f2" >> "$tmp"   # back to fetchable
            else
                printf '%s\n' "$raw" >> "$tmp"
            fi
            n_wrong=$((n_wrong+1))
        fi
    done < "$file"

    if [ "$RESET" -eq 1 ] && [ "$n_wrong" -gt 0 ]; then
        cp "$file" "$file.bak.$(date +%s)"
        mv "$tmp" "$file"
        echo "---- reset $n_wrong row(s); backup written ----"
    else
        rm -f "$tmp"
    fi
    echo "---- $file: ok:$n_ok WRONG:$n_wrong nolog:$n_nolog no-md5:$n_skip ----"
    echo
}

for f in "${FILES[@]}"; do audit_one "$f"; done