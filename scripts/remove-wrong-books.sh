#!/usr/bin/env bash
REMOVE_WRONG_VERSION="1"
# =============================================================================
#  remove-wrong-books.sh — map audit "WRONG" rows to Calibre ids and (with
#  --remove) delete those wrongly-fetched books from the library.
#
#  For every TSV row carrying an md5, it does what audit-matches.sh does — scores
#  the wanted title|author against what the log says was actually downloaded —
#  and for the ones that DON'T match (the ticker-bug mis-fetches), it locates the
#  offending book in Calibre and reports:
#       id | stored-title (— authors) | row-wanted | fetched-name
#  so you can eyeball each before deleting. Lookup order:
#     1. identifiers:annas:<md5>      (exact, if tag-books v7 stamped it)
#     2. title search on the FETCHED title (what the md5 really is)
#  A row is only auto-removable when exactly ONE calibre book is found for it.
#
#  USAGE:
#     ./remove-wrong-books.sh LIST.tsv            # report only (safe; default)
#     ./remove-wrong-books.sh --remove LIST.tsv   # actually delete found books
#     LOG=~/logs/fetch-books.log ./remove-wrong-books.sh booker.tsv
#
#  Env: CALIBRE_CONTAINER (calibre), CALIBRE_LIBRARY (/books/Calibre),
#       ID_SCHEME (annas), CONFIDENCE (0.6), LOG (~/logs/fetch-books.log)
#
#  This NEVER edits the TSV. After you've removed the wrong books, run
#  audit-matches.sh --reset to make the rows fetchable again.
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
ID_SCHEME="${ID_SCHEME:-annas}"
CONFIDENCE="${CONFIDENCE:-0.6}"
LOG="${LOG:-$HOME/logs/fetch-books.log}"

REMOVE=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --remove) REMOVE=1; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -eq 0 ] && { echo "usage: $0 [--remove] LIST.tsv..." >&2; exit 1; }
[ -f "$LOG" ] || { echo "log not found: $LOG (set LOG=...)" >&2; exit 1; }

. "$(dirname "$0")/match-lib.sh"

cdb() { docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@"; }

# the most recent "downloaded -> NAME ... <md5>" filename for an md5
fetched_name() {
    grep -F "$1" "$LOG" 2>/dev/null | grep -F "downloaded -> " | tail -1 \
        | sed 's/.*downloaded -> //; s/  *(quota left.*$//'
}

# print "id<TAB>title<TAB>authors" rows for a calibre search expression
cdb_rows() {
    cdb list -s "$1" -f id,title,authors --for-machine 2>/dev/null | python3 -c '
import sys, json
try: data = json.load(sys.stdin)
except Exception: data = []
for b in data:
    a = b.get("authors","")
    if isinstance(a, list): a = " & ".join(a)
    print(f"{b.get(\"id\",\"\")}\t{b.get(\"title\",\"\")}\t{a}")
'
}

process_file() {
    local file="$1"
    [ -f "$file" ] || { echo "skip (not found): $file" >&2; return; }
    echo "==== $file ===="
    local n_wrong=0 n_removed=0 n_ambig=0 n_notfound=0

    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) continue;; esac
        local f1 f2 md5
        f1="$(printf '%s' "$raw" | cut -d'|' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
        f2="$(printf '%s' "$raw" | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
        md5="$(printf '%s' "$raw" | cut -d'|' -f4 | tr -d ' ')"
        [ -z "$md5" ] && continue

        local name; name="$(fetched_name "$md5")"
        [ -z "$name" ] && continue   # no log line — audit reports as NOLOG; skip here

        # is it a mismatch? score wanted-row vs fetched filename
        local s; s="$(book_match_score "$f1" "$f2" "$name")"
        ge "$s" "$CONFIDENCE" && continue   # OK match, leave it

        n_wrong=$((n_wrong+1))
        local ftitle; ftitle="$(printf '%s' "$name" | sed 's/ -- .*//')"
        echo "WRONG row: [$f1 | $f2]"
        echo "   fetched: $name"

        # locate in calibre: identifier first, then fetched-title search
        local rows
        rows="$(cdb_rows "identifiers:${ID_SCHEME}:${md5}")"
        [ -z "$rows" ] && rows="$(cdb_rows "title:\"$ftitle\"")"

        if [ -z "$rows" ]; then
            echo "   calibre: NOT FOUND (already removed, or never imported)"
            n_notfound=$((n_notfound+1)); echo; continue
        fi

        # show all candidates
        local count; count="$(printf '%s\n' "$rows" | grep -c .)"
        printf '%s\n' "$rows" | while IFS=$'\t' read -r id t a; do
            echo "   calibre id $id: $t — $a"
        done

        if [ "$count" -ne 1 ]; then
            echo "   -> $count matches; NOT auto-removing (resolve by hand)"
            n_ambig=$((n_ambig+1)); echo; continue
        fi

        local id; id="$(printf '%s' "$rows" | cut -f1)"
        if [ "$REMOVE" -eq 1 ]; then
            if cdb remove "$id" >/dev/null 2>&1; then
                echo "   -> REMOVED id $id"
                n_removed=$((n_removed+1))
            else
                echo "   -> remove FAILED for id $id"
            fi
        else
            echo "   -> would remove id $id  (run with --remove)"
        fi
        echo
    done < "$file"

    echo "---- $file: wrong:$n_wrong removed:$n_removed ambiguous:$n_ambig not-found:$n_notfound ----"
    [ "$REMOVE" -eq 0 ] && echo "(report only — re-run with --remove to delete the single-match books)"
    echo
}

for f in "${FILES[@]}"; do process_file "$f"; done