#!/usr/bin/env bash
TAG_FORMAT_FLAG_VERSION="1"   # bump on every change; echoed at startup. (Also at EOF.)
# =============================================================================
#  tag-format-flag.sh — record each book's CONTAINER FORMAT quality in the custom
#  column #format_flag, so you can filter the library (incl. Calibre-Web) by what
#  kind of file a book actually is and find the oddballs to convert/replace.
#
#  Calibre-Web has no format filter, so this surfaces format quality as a browsable
#  category (same approach as #pdf_type, which covers PDF internals: Text vs Scan).
#
#  VALUES (a book gets ONE, by its BEST format — priority Kindle > Epub > PDF > Odd):
#     Kindle : mobi / azw3 / azw / kepub          (reads natively on Kindle)
#     Epub   : epub / fb2                          (standard, convertible)
#     PDF    : only a PDF                          (see #pdf_type for scan-vs-text)
#     Odd    : zip / lit / rtf / prc / anything else (review: convert or remove)
#   (prc is deliberately Odd, not Kindle — you'd rather convert it.)
#
#  ONE-TIME SETUP (in the Calibre GUI, like #pdf_type):
#     Preferences > Add your own columns > lookup 'format_flag',
#        heading 'Format', type 'Text, shown in the tag browser', then restart.
#
#  USAGE:  ./tag-format-flag.sh            # flag books not yet flagged
#          ./tag-format-flag.sh --recheck  # re-flag ALL books
#          ./tag-format-flag.sh --dry-run  # report, write nothing
#          ./tag-format-flag.sh --limit N  # stop after N (testing)
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
FMT_COL="${FMT_COL:-format_flag}"
# busy-toggle (same semantics as sweep-books / tag-pdf-type)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true

DRY_RUN=0; RECHECK=0; LIMIT=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --recheck) RECHECK=1 ;;
        --limit=*) LIMIT="${a#--limit=}" ;;
        --limit)   : ;;
        --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $a" >&2; exit 1 ;;
    esac
done
prev=""; for a in "$@"; do [ "$prev" = "--limit" ] && LIMIT="$a"; prev="$a"; done

LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [ff] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}

calibre_is_busy() {
    local safe pref until now
    safe=$(echo "$BUSY_PREF_EMAIL" | sed 's/[^a-zA-Z0-9@._-]/_/g')
    pref="$PREFS_DIR/$safe.json"
    if [ -f "$pref" ]; then
        until=$(jq -r '.calibreBusyUntil // 0' "$pref" 2>/dev/null)
        now=$(date +%s)
        if [ -n "$until" ] && [ "$until" -gt "$now" ] 2>/dev/null; then return 0; fi
    fi
    [ -f "$CALIBRE_BUSY_FLAG" ] || return 1
    if find "$CALIBRE_BUSY_FLAG" -mmin "-${BUSY_TTL_MIN}" 2>/dev/null | grep -q .; then return 0; fi
    rm -f "$CALIBRE_BUSY_FLAG" 2>/dev/null
    return 1
}

cdb() { docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@"; }

LOG "=== tag-format-flag v$TAG_FORMAT_FLAG_VERSION start (col=#$FMT_COL dry-run=$DRY_RUN recheck=$RECHECK limit=${LIMIT:-0}) ==="

if calibre_is_busy; then
    LOG "calibre flagged BUSY — skipping format-flag scan this run"
    exit 0
fi

if ! cdb custom_columns 2>/dev/null | grep -qiE "(^|[^a-z])${FMT_COL}([^a-z]|:)"; then
    LOG "FATAL: custom column '#$FMT_COL' not found. Create it once in the Calibre GUI:"
    LOG "  Preferences > Add your own columns > lookup '$FMT_COL', type Text, then restart Calibre."
    exit 1
fi

# all books with their formats + current flag value, as JSON.
books_json="$(cdb list -f "formats,*${FMT_COL}" --for-machine 2>/dev/null)"
if [ -z "$books_json" ]; then
    LOG "FATAL: calibredb list returned nothing (lock? wrong library path?)"
    exit 1
fi

# classify every book in python (pure metadata — fast, no file inspection), emit
# "id<TAB>flag<TAB>existing" for each book. Priority Kindle>Epub>PDF>Odd.
mapfile -t rows < <(printf '%s' "$books_json" | python3 -c '
import sys, json, os
col = "'"$FMT_COL"'"
KINDLE = {"mobi","azw3","azw","kepub"}   # prc deliberately excluded -> Odd
EPUBY  = {"epub","fb2"}
data = json.load(sys.stdin)
for b in data:
    exts = set()
    for f in (b.get("formats") or []):
        if isinstance(f,str):
            e = os.path.splitext(f)[1].lower().lstrip(".")
            if e: exts.add(e)
    if exts & KINDLE:      flag = "Kindle"
    elif exts & EPUBY:     flag = "Epub"
    elif exts == {"pdf"}:  flag = "PDF"
    elif "pdf" in exts and not (exts - {"pdf"}): flag = "PDF"
    else:                  flag = "Odd"
    existing = b.get("*"+col) or b.get(col) or ""
    print("%s\t%s\t%s" % (b.get("id"), flag, existing))
' 2>>"$GUNIT_LOG")

total="${#rows[@]}"
LOG "found $total book(s)"
[ "$total" -eq 0 ] && { LOG "nothing to do"; exit 0; }

n_kindle=0; n_epub=0; n_pdf=0; n_odd=0; n_skip=0; n_err=0; n_done=0
for row in "${rows[@]}"; do
    IFS=$'\t' read -r id flag existing <<< "$row"
    [ -z "$id" ] && continue
    if [ "$RECHECK" -eq 0 ] && [ -n "$existing" ]; then
        n_skip=$((n_skip+1)); continue
    fi
    case "$flag" in
        Kindle) n_kindle=$((n_kindle+1)) ;;
        Epub)   n_epub=$((n_epub+1)) ;;
        PDF)    n_pdf=$((n_pdf+1)) ;;
        Odd)    n_odd=$((n_odd+1)) ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        # name the Odd ones so they're visible in the dry-run without a calibre query
        if [ "$flag" = "Odd" ]; then
            LOG "  [dry-run] id $id -> Odd${existing:+ (was '$existing')}"
        fi
    else
        if cdb set_custom "$FMT_COL" "$id" "$flag" >/dev/null 2>&1; then
            [ "$flag" = "Odd" ] && LOG "  id $id -> Odd"
            n_done=$((n_done+1))
        else
            LOG "  WARN: id $id ($flag) set_custom failed (lock?)"
            n_err=$((n_err+1))
        fi
    fi
    if calibre_is_busy; then
        LOG "calibre became BUSY mid-scan — stopping; rerun later to finish"
        break
    fi
    if [ "${LIMIT:-0}" -gt 0 ]; then
        processed=$(( n_kindle + n_epub + n_pdf + n_odd ))
        [ "$processed" -ge "$LIMIT" ] && { LOG "reached --limit $LIMIT — stopping"; break; }
    fi
done

LOG "format-flag done: Kindle=$n_kindle Epub=$n_epub PDF=$n_pdf Odd=$n_odd written=$n_done skipped(already)=$n_skip errors=$n_err"
exit 0

# =============================================================================
# version: TAG_FORMAT_FLAG_VERSION 1
# =============================================================================
