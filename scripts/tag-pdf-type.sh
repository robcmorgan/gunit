#!/bin/bash
TAG_PDF_TYPE_VERSION="5"   # bump on every change; echoed at startup. (Also at EOF.)
# v5: drop the Reflowable bucket — genuinely-reflowable (tagged) PDFs don't exist
#     in this library (every one is Tagged:no; the single pass was a false
#     positive). Now just Text (good, born-digital) vs Scan (bad), with Mixed as
#     a rare escape hatch. Removed the tagged/StructTree signal entirely.
# v4: three buckets — Reflowable / Text / Scan (+ Mixed fallback), erring toward
#     Scan. Adds the OCR/scanner PRODUCER signal (ClearScan/ABBYY/Paper Capture
#     etc. in pdfinfo) which catches vectorised-OCR scans that have no page image
#     and a text layer (e.g. book 898). Reflowable requires pdfinfo Tagged:yes AND
#     not an OCR producer. text-but-non-embedded-font now errs to Scan.
# v3: fix the image-coverage column bug. pdfimages -list has type in column 3
#     (page num type width height ...), but v2 matched column 2 — so NO page ever
#     registered as image-dominated and OCR'd scans fell through to Mixed. Now
#     type=$3, width=$4, height=$5: a scan with a big image on every page is
#     correctly classified Scan even with an OCR text layer (e.g. book 815).
# v2: catch OCR'd scans. v1 read a scanned PDF with an OCR text layer as "Text"
#     (it had a font + extractable text). v2 adds an IMAGE-COVERAGE signal: if most
#     sampled pages carry a large image it's a Scan regardless of any OCR text,
#     and only EMBEDDED fonts count (the non-embedded OCR overlay font no longer
#     reads as a real font).
# =============================================================================
#  tag-pdf-type.sh — classify every PDF in the Calibre library as Text / Scan /
#  Mixed and record it in the custom column #pdf_type, so a frontend (Calibre-Web,
#  Kavita) can filter out scanner-dump PDFs that have no usable text layer.
#
#  WHY: Calibre has no built-in "is this scanned?" attribute — the format is just
#  "PDF" whether the pages are real text or flat JPEGs. This derives it.
#
#  METHOD (two signals, in the calibre container where poppler + the files live):
#    - pdffonts : a text PDF embeds fonts; a pure image scan embeds none.
#    - pdftotext: a text PDF yields extractable characters; a scan yields ~none.
#    Combined ->
#       Text  : has fonts AND substantial extractable text
#       Scan  : no fonts AND essentially no text
#       Mixed : anything else (OCR'd scan = images+text; or a mostly-image PDF
#               with a few decorative fonts). Flagged for you to eyeball rather
#               than forced into a wrong bucket.
#
#  ONE-TIME SETUP (can't be scripted reliably — do it once in the Calibre GUI):
#    Preferences > Add your own columns > Add:
#       Lookup name: pdf_type   Heading: PDF Type   Type: Text (shown in tag browser)
#    then restart Calibre. The column is addressed here as #pdf_type.
#
#  USAGE:  ./tag-pdf-type.sh            # classify PDFs not yet classified
#          ./tag-pdf-type.sh --recheck  # re-classify ALL pdfs (ignore existing)
#          ./tag-pdf-type.sh --dry-run  # show what it WOULD set, no writes
#          ./tag-pdf-type.sh --limit N  # stop after N books (testing)
#
#  Designed to be timer-friendly later (respects the calibre-busy toggle, idempotent
#  by default), but ships standalone — run it by hand when you want.
# =============================================================================
set -uo pipefail

# ---- config (same conventions as the other gunit scripts) ------------------
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
PDF_COL="${PDF_COL:-pdf_type}"          # custom column lookup name (addressed as #pdf_type)
# detection thresholds
MIN_TEXT_CHARS="${MIN_TEXT_CHARS:-200}" # chars of extractable text (first pages) to count as "has text"
# busy-toggle (same semantics as sweep-books / watch-downloads)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
# shared log
GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true

DRY_RUN=0; RECHECK=0; LIMIT=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --recheck) RECHECK=1 ;;
        --limit)   : ;;                       # handled below (needs value)
        --limit=*) LIMIT="${a#--limit=}" ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $a" >&2; exit 1 ;;
    esac
done
# --limit N (space-separated form)
prev=""; for a in "$@"; do [ "$prev" = "--limit" ] && LIMIT="$a"; prev="$a"; done

LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [p] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}

# ---- busy check (verbatim semantics from sweep-books) ----------------------
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

# reads/writes share the always-on GUI container's lock context (no -u).
cdb() { docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@"; }
# run a command inside the calibre container (where poppler + the files live).
cin() { docker exec "$CALIBRE_CONTAINER" "$@"; }

LOG "=== tag-pdf-type v$TAG_PDF_TYPE_VERSION start (col=#$PDF_COL dry-run=$DRY_RUN recheck=$RECHECK limit=${LIMIT:-0}) ==="

if calibre_is_busy; then
    LOG "calibre flagged BUSY — skipping pdf-type scan this run"
    exit 0
fi

# confirm the custom column exists; if not, bail with the setup hint (don't guess).
if ! cdb custom_columns 2>/dev/null | grep -qiE "(^|[^a-z])${PDF_COL}([^a-z]|:)"; then
    LOG "FATAL: custom column '#$PDF_COL' not found. Create it once in the Calibre GUI:"
    LOG "  Preferences > Add your own columns > lookup '$PDF_COL', type Text, then restart Calibre."
    exit 1
fi

# fetch all books that have a PDF format, as JSON (robust vs pipe-splitting).
# 'formats' gives the real on-disk (container) path of each format file.
# '*pdf_type' pulls the current custom-column value so we can skip done ones.
books_json="$(cdb list -f "formats,*${PDF_COL}" --for-machine 2>/dev/null)"
if [ -z "$books_json" ]; then
    LOG "FATAL: calibredb list returned nothing (lock? wrong library path?)"
    exit 1
fi

# parse: emit "id<TAB>pdfpath<TAB>existing_type" for books with a pdf format.
mapfile -t rows < <(printf '%s' "$books_json" | python3 -c '
import sys, json
col = "'"$PDF_COL"'"
try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("json parse failed: %s\n" % e); sys.exit(1)
for b in data:
    fmts = b.get("formats") or []
    pdf = next((f for f in fmts if isinstance(f,str) and f.lower().endswith(".pdf")), None)
    if not pdf: continue
    existing = b.get("*"+col) or b.get(col) or ""
    # tab-separated; paths from calibre do not contain tabs
    print("%s\t%s\t%s" % (b.get("id"), pdf, existing))
' 2>>"$GUNIT_LOG")

total="${#rows[@]}"
LOG "found $total book(s) with a PDF format"
[ "$total" -eq 0 ] && { LOG "nothing to do"; exit 0; }

# classify one PDF (container path). echoes Text|Scan|Mixed, or empty on error.
#
# An OCR'd scan defeats a naive font+text test: it has a (non-embedded) OCR font
# AND an extractable text layer, so it looks like "Text" — yet every page is a
# scanned bitmap. The reliable discriminator is IMAGE COVERAGE: a scan carries a
# large image on (nearly) every page. We sample the first SAMPLE_PAGES pages and
# count how many are "image-dominated" (carry an image whose pixel area is a big
# fraction of the page). If most are, it's a Scan no matter what the text layer
# says. Only when pages are NOT image-dominated do we fall back to the font/text
# signals for Text vs Mixed vs Scan.
SAMPLE_PAGES="${SAMPLE_PAGES:-6}"             # leading pages to inspect
IMG_PAGE_FRACTION="${IMG_PAGE_FRACTION:-70}"  # % of sampled pages image-dominated -> Scan
classify_pdf() {
    local cpath="$1"

    # --- real embedded fonts (exclude the non-embedded OCR overlay font) -------
    # pdffonts columns: ... emb sub uni objID. "emb" = yes means a real embedded
    # font (born-digital). A lone non-embedded Courier is the OCR-layer signature.
    local emb_fonts
    emb_fonts="$(cin pdffonts "$cpath" 2>/dev/null | tail -n +3 \
                 | awk '$0 ~ /yes/ {c++} END{print c+0}')"
    [ -z "$emb_fonts" ] && emb_fonts=0

    # --- text density over sampled pages ---------------------------------------
    local chars
    chars="$(cin pdftotext -f 1 -l "$SAMPLE_PAGES" "$cpath" - 2>/dev/null | tr -d '[:space:]' | wc -c)"
    [ -z "$chars" ] && chars=0
    local has_text=0
    [ "$chars" -ge "$MIN_TEXT_CHARS" ] && has_text=1

    # --- image-coverage: how many of the sampled pages are image-dominated? -----
    # pdfimages -list gives one row per image: page, type, width, height, ...
    # We treat a page as image-dominated if it carries an image >= ~600x800 px
    # (a real scanned page is ~2000x3000; thumbnails/icons are far smaller). We
    # ignore 'smask' rows (they're masks attached to an image, not separate art).
    # pdfimages -list columns are: page(1) num(2) type(3) width(4) height(5) ...
    # (v2 had these off by one — matched $2 for the type, so NO page ever counted
    # and every scan fell through to Mixed. type is $3, width $4, height $5.)
    local img_pages page_count
    img_pages="$(cin pdfimages -list -f 1 -l "$SAMPLE_PAGES" "$cpath" 2>/dev/null \
        | awk 'NR>2 && $3=="image" {
                 w=$4+0; h=$5+0;
                 if (w>=600 && h>=800) seen[$1]=1
               } END { n=0; for (p in seen) n++; print n+0 }')"
    [ -z "$img_pages" ] && img_pages=0
    # how many distinct pages did we actually sample? (book may be shorter)
    page_count="$(cin pdfinfo "$cpath" 2>/dev/null | awk '/^Pages:/{print $2}')"
    [ -z "$page_count" ] && page_count="$SAMPLE_PAGES"
    local sampled="$SAMPLE_PAGES"
    [ "$page_count" -lt "$sampled" ] && sampled="$page_count"
    [ "$sampled" -lt 1 ] && sampled=1

    # fraction (integer %) of sampled pages that are image-dominated
    local img_pct=$(( img_pages * 100 / sampled ))

    # --- producer/creator: the strongest "this is a scan" tell ------------------
    # ClearScan, "Paper Capture", ABBYY FineReader, "Scan", Kofax etc. in the
    # Producer/Creator metadata mean the PDF was scanned then OCR'd — even when it
    # has NO page-image (ClearScan vectorises the text, so image-coverage misses
    # it) and a text layer (so font/text misses it). Book 898 is exactly this:
    # Producer "Adobe Acrobat ... Paper Capture Plug-in with ClearScan".
    local info ocr_producer=0
    info="$(cin pdfinfo "$cpath" 2>/dev/null)"
    if printf '%s' "$info" | grep -iqE 'clearscan|paper capture|abbyy|finereader|scanned|scansoft|kofax|readiris|omnipage|tesseract|capture plug-?in'; then
        ocr_producer=1
    fi

    # --- decision (err toward Scan) --------------------------------------------
    # Two real buckets for this library: Scan (bad — scans/OCR) and Text (fine —
    # born-digital, readable). Genuinely-reflowable PDFs don't exist here (every
    # one is Tagged:no, and the one that passed was a false positive), so there's
    # no Reflowable bucket — "Text" is the good bucket. Mixed is a rare escape
    # hatch for the genuinely-ambiguous.
    # 1) OCR/scanner producer -> Scan, regardless of images/fonts/text. This is the
    #    catch-all for vectorised OCR (ClearScan) that has no page image.
    if [ "$ocr_producer" -eq 1 ]; then
        echo "Scan"; return
    fi
    # 2) image-dominated on most pages -> Scan (a normal scanned bitmap, OCR or not).
    if [ "$img_pct" -ge "$IMG_PAGE_FRACTION" ]; then
        echo "Scan"; return
    fi
    # 3) clean born-digital: real embedded font AND real text -> Text (fixed layout
    #    but sharp/selectable; not a scan).
    if [ "$emb_fonts" -gt 0 ] && [ "$has_text" -eq 1 ]; then
        echo "Text"; return
    fi
    # 4) no embedded font and no text -> Scan (image-only, no usable text).
    if [ "$emb_fonts" -eq 0 ] && [ "$has_text" -eq 0 ]; then
        echo "Scan"; return
    fi
    # 5) ambiguous (text but no embedded font, or fonts but sparse text). Erring
    #    toward Scan per preference: a non-embedded-font text layer is usually OCR.
    if [ "$has_text" -eq 1 ] && [ "$emb_fonts" -eq 0 ]; then
        echo "Scan"; return
    fi
    echo "Mixed"
}

n_text=0; n_scan=0; n_mixed=0; n_skip=0; n_err=0; n_done=0
for row in "${rows[@]}"; do
    IFS=$'\t' read -r id pdfpath existing <<< "$row"
    [ -z "$id" ] && continue
    # idempotent: skip already-classified unless --recheck
    if [ "$RECHECK" -eq 0 ] && [ -n "$existing" ]; then
        n_skip=$((n_skip+1)); continue
    fi
    verdict="$(classify_pdf "$pdfpath")"
    if [ -z "$verdict" ]; then
        LOG "  id $id: could not read PDF ($pdfpath) — skipping"
        n_err=$((n_err+1)); continue
    fi
    case "$verdict" in
        Text)       n_text=$((n_text+1)) ;;
        Scan)       n_scan=$((n_scan+1)) ;;
        Mixed)      n_mixed=$((n_mixed+1)) ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        LOG "  [dry-run] id $id -> $verdict${existing:+ (was '$existing')}"
    else
        if cdb set_custom "$PDF_COL" "$id" "$verdict" >/dev/null 2>&1; then
            LOG "  id $id -> $verdict"
            n_done=$((n_done+1))
        else
            LOG "  WARN: id $id classified $verdict but set_custom failed (lock?)"
            n_err=$((n_err+1))
        fi
    fi
    # re-check busy between books so an active GUI session stops us mid-run.
    if calibre_is_busy; then
        LOG "calibre became BUSY mid-scan — stopping; rerun later to finish"
        break
    fi
    # optional cap for testing
    if [ "${LIMIT:-0}" -gt 0 ]; then
        processed=$(( n_text + n_scan + n_mixed ))
        [ "$processed" -ge "$LIMIT" ] && { LOG "reached --limit $LIMIT — stopping"; break; }
    fi
done

LOG "pdf-type scan done: Text=$n_text Scan=$n_scan Mixed=$n_mixed written=$n_done skipped(already)=$n_skip errors=$n_err"
exit 0

# =============================================================================
# version: TAG_PDF_TYPE_VERSION 5
# =============================================================================