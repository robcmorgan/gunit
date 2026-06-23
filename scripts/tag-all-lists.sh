#!/usr/bin/env bash
TAG_ALL_LISTS_VERSION="1"
# v1: initial — loop over every TSV in tsv-lists/ that has a #tag: header and
#     run tag-books.sh on it. Called from sweep-books.service so the TSV status
#     is updated (downloaded -> tagged) automatically each cycle.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSV_DIR="${TSV_DIR:-$SCRIPT_DIR/../tsv-lists}"
TAG_BOOKS="${TAG_BOOKS:-$SCRIPT_DIR/tag-books.sh}"

GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [ta] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}

found=0
for tsv in "$TSV_DIR"/*.tsv; do
    [ -f "$tsv" ] || continue
    grep -q "^#tag:" "$tsv" 2>/dev/null || continue
    found=$((found+1))
    LOG "--- tag-all-lists: processing $(basename "$tsv") ---"
    "$TAG_BOOKS" "$tsv" || LOG "  WARN: tag-books exited non-zero for $(basename "$tsv")"
done

if [ "$found" -eq 0 ]; then LOG "tag-all-lists: no TSV files with #tag: header found in $TSV_DIR"; fi
