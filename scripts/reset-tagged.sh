#!/usr/bin/env bash
# reset-tagged.sh — flip 'tagged' status back to 'downloaded' so tag-books.sh
# will re-apply tags (it skips rows already marked 'tagged'). Preserves the
# md5 (4th col) and rewrites the date (5th col) to now. Header/#tag: lines,
# blank lines, md5s, and any non-'tagged' rows are left untouched.
#
# Use when you've stripped tags in Calibre and want the tagger to redo them.
#
# USAGE:  ./reset-tagged.sh ../lists/guardian_summer_reads.tsv
#         ./reset-tagged.sh --dry-run ../lists/guardian_summer_reads.tsv
set -uo pipefail

DRY=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -eq 0 ] && { echo "usage: $0 [--dry-run] LIST.tsv..." >&2; exit 1; }

now="$(date '+%Y-%m-%dT%H:%M')"

for file in "${FILES[@]}"; do
    [ -f "$file" ] || { echo "skip (not found): $file" >&2; continue; }
    tmp="$(mktemp)"; n=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac
        status="$(printf '%s' "$raw" | cut -d'|' -f3 | tr -d ' ')"
        if [ "$status" = "tagged" ]; then
            f1="$(printf '%s' "$raw" | cut -d'|' -f1)"
            f2="$(printf '%s' "$raw" | cut -d'|' -f2)"
            md5="$(printf '%s' "$raw" | cut -d'|' -f4 | tr -d ' ')"
            printf '%s|%s|downloaded|%s|%s\n' "$f1" "$f2" "$md5" "$now" >> "$tmp"
            n=$((n+1))
            [ "$DRY" -eq 1 ] && echo "  would reset: $f1 | $f2" >&2
        else
            printf '%s\n' "$raw" >> "$tmp"
        fi
    done < "$file"

    if [ "$DRY" -eq 1 ]; then
        rm -f "$tmp"
        echo "$file — would reset $n tagged row(s) to downloaded"
    else
        cp "$file" "$file.bak.$(date +%s)"
        mv "$tmp" "$file"
        echo "$file — reset $n tagged row(s) to downloaded (backup written)"
    fi
done