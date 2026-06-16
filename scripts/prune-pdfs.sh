#!/usr/bin/env bash
PRUNE_PDFS_VERSION="1"   # bump on every change; echoed at startup (stamp also at end)
# =============================================================================
#  prune-pdfs.sh — strip the PDF format from books in the Calibre library.
#
#  WHAT IT DOES
#  For every book whose formats include PDF, and which does NOT carry the
#  keep-pdf tag, remove the PDF format (calibredb remove_format <id> PDF). A book
#  that also has an epub keeps the epub and just loses its PDF. A book that was
#  PDF-ONLY is left with zero formats; what happens to that empty record is your
#  choice (see --empty below).
#
#  SAFETY: DRY-RUN BY DEFAULT. With no --commit it only PRINTS what it would do
#  and changes nothing. Review the list, then re-run with --commit.
#
#  KEEP A PDF: add the tag 'keep-pdf' (KEEP_TAG) to the book in Calibre. Tagged
#  books are skipped entirely — their PDF is never touched. Because the default
#  is "remove", forgetting to tag a keeper means it shows up in the dry-run list
#  for you to catch BEFORE committing — it is never silently deleted.
#
#  EMPTY RECORDS: removing the PDF from a PDF-only book leaves a record with no
#  formats (metadata only — a phantom book in calibre-web you can't open).
#    --empty delete   (default) also delete the whole record when removing the
#                     PDF would leave it with zero formats.
#    --empty keep     remove only the format; leave the empty record in place.
#
#  USAGE:
#    ./prune-pdfs.sh                 # dry-run: list every PDF that would be pruned
#    ./prune-pdfs.sh --commit        # actually remove them (--empty delete default)
#    ./prune-pdfs.sh --empty keep    # dry-run, but would leave empty records
#    ./prune-pdfs.sh --commit --empty keep
#    KEEP_TAG=save-pdf ./prune-pdfs.sh
#
#  Env:
#    CALIBRE_CONTAINER (default: calibre)        docker container running calibredb
#    CALIBRE_LIBRARY   (default: /books/Calibre) library path inside the container
#    KEEP_TAG          (default: keep-pdf)       books with this tag are spared
#    LOG               (default: ~/logs/gunit.log) shared log; lines tagged [p]
#
#  NOTE: calibredb runs as ROOT inside the container (no -u), so it shares the
#  always-on GUI's lock context. Running as a non-root uid triggers "Another
#  calibre program is running" with stderr silenced -> false empty results.
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
KEEP_TAG="${KEEP_TAG:-keep-pdf}"
LOG="${LOG:-${GUNIT_LOG:-$HOME/logs/gunit.log}}"

COMMIT=0
EMPTY="delete"   # delete | keep

while [ $# -gt 0 ]; do
    case "$1" in
        --commit) COMMIT=1; shift ;;
        --empty)
            [ "$#" -ge 2 ] || { echo "error: --empty requires 'delete' or 'keep'" >&2; exit 1; }
            case "$2" in
                delete|keep) EMPTY="$2" ;;
                *) echo "error: --empty must be 'delete' or 'keep', got '$2'" >&2; exit 1 ;;
            esac
            shift 2 ;;
        -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { local ts; ts="$(date '+%F %T')"; printf '%s  [p] %s\n' "$ts" "$*" >> "$LOG"; printf '%s  %s\n' "$ts" "$*" >&2; }

# calibredb against the configured library, as root in the container (lock-safe).
cdb() { docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@"; }

# Pull id, title, authors, formats, tags for EVERY book as machine JSON. The
# fantastic_fiction plugin prints a SyntaxWarning (and an "Integration status:"
# trailer) to stdout that contaminates the output, so we slice the first valid
# JSON value with raw_decode and ignore anything around it (the same trick the
# tag-lib readers use). Emits one TSV row per book that HAS a pdf format:
#     id <TAB> has_keep(0|1) <TAB> nonpdf_format_count <TAB> title <TAB> authors
scan_pdf_books() {
    local raw
    raw="$(cdb list -f title,authors,formats,tags --for-machine 2>/dev/null)"
    printf '%s' "$raw" | KEEP_TAG="$KEEP_TAG" python3 -c '
import sys, os, json, re
keep_tag = os.environ.get("KEEP_TAG", "keep-pdf").strip().lower()
raw = sys.stdin.read()
i = raw.find("[")
if i < 0:
    sys.exit(0)
try:
    data, _ = json.JSONDecoder().raw_decode(raw[i:])
except Exception:
    sys.exit(0)
for b in data:
    fmts = b.get("formats", []) or []
    # formats are usually full paths like ".../Title - Author.pdf"; reduce each
    # to its lowercase extension so we can count pdf vs non-pdf reliably.
    exts = []
    for f in fmts:
        ext = os.path.splitext(str(f))[1].lower().lstrip(".")
        if ext:
            exts.append(ext)
    if "pdf" not in exts:
        continue
    nonpdf = sum(1 for e in exts if e != "pdf")
    tags = b.get("tags", []) or []
    if isinstance(tags, str):
        tags = [tags]
    has_keep = 1 if any(str(t).strip().lower() == keep_tag for t in tags) else 0
    bid = b.get("id", "")
    title = (b.get("title", "") or "").replace("\t", " ").replace("\n", " ")
    authors = b.get("authors", "")
    if isinstance(authors, list):
        authors = ", ".join(authors)
    authors = (authors or "").replace("\t", " ").replace("\n", " ")
    print(f"{bid}\t{has_keep}\t{nonpdf}\t{title}\t{authors}")
' 2>/dev/null
}

log "=== prune-pdfs v$PRUNE_PDFS_VERSION start (container:$CALIBRE_CONTAINER lib:$CALIBRE_LIBRARY keep-tag:'$KEEP_TAG' empty:$EMPTY commit:$COMMIT) ==="

# Quick sanity: make sure calibredb is reachable and not locked. An empty result
# could mean "no pdf books" OR "couldn't read the library" — distinguish them by
# probing a trivial query first.
probe="$(cdb list -f title --for-machine 2>&1 | tr -d '\n')"
case "$probe" in
    *"Another calibre program"*|*"is locked"*|*"Traceback"*)
        log "ERROR: calibre library is locked or unreadable — aborting (no changes). Detail: $(printf '%s' "$probe" | cut -c1-160)"
        exit 2 ;;
esac

mapfile -t ROWS < <(scan_pdf_books)

if [ "${#ROWS[@]}" -eq 0 ]; then
    log "no books with a PDF format found — nothing to do."
    log "=== prune-pdfs done ==="
    exit 0
fi

n_total=0 n_keep=0 n_strip=0 n_recdel=0 n_emptyleft=0 n_fail=0
to_strip=()        # ids to remove_format PDF
to_recdel=()       # ids to remove entirely (pdf-only AND --empty delete)

for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id has_keep nonpdf title authors <<< "$row"
    [ -z "$id" ] && continue
    n_total=$((n_total+1))
    if [ "$has_keep" = "1" ]; then
        n_keep=$((n_keep+1))
        log "  KEEP  id $id — $title — $authors  (has '$KEEP_TAG')"
        continue
    fi
    if [ "$nonpdf" -gt 0 ]; then
        # has an epub (or other real format) too: strip only the PDF, keep record
        to_strip+=("$id")
        n_strip=$((n_strip+1))
        log "  STRIP id $id — $title — $authors  (pdf + $nonpdf other format(s); remove pdf only)"
    else
        # pdf-only: stripping leaves an empty record
        if [ "$EMPTY" = "delete" ]; then
            to_recdel+=("$id")
            n_recdel=$((n_recdel+1))
            log "  DELETE id $id — $title — $authors  (PDF-only; remove whole record)"
        else
            to_strip+=("$id")
            n_emptyleft=$((n_emptyleft+1))
            log "  STRIP id $id — $title — $authors  (PDF-only; remove pdf, leave empty record)"
        fi
    fi
done

log "---"
log "SUMMARY: $n_total pdf book(s): keep:$n_keep  strip-pdf:$n_strip  delete-record:$n_recdel  empty-left:$n_emptyleft"

if [ "$COMMIT" -eq 0 ]; then
    log "DRY-RUN: no changes made. Re-run with --commit to apply. (Tag any keepers with '$KEEP_TAG' in Calibre first.)"
    log "=== prune-pdfs done ==="
    exit 0
fi

# ---- commit ----
# remove_format PDF for the strip set, one id at a time so a single failure
# doesn't abort the batch. calibredb remove_format takes a single id + fmt.
for id in "${to_strip[@]:-}"; do
    [ -z "$id" ] && continue
    if cdb remove_format "$id" PDF >/dev/null 2>&1; then
        log "  removed PDF format from id $id"
    else
        log "  FAILED to remove PDF format from id $id"
        n_fail=$((n_fail+1))
    fi
done

# remove whole records for the pdf-only + --empty delete set. calibredb remove
# accepts a comma-separated id list, but we go one-by-one for clear per-id logging
# and so one failure is isolated.
for id in "${to_recdel[@]:-}"; do
    [ -z "$id" ] && continue
    if cdb remove "$id" >/dev/null 2>&1; then
        log "  deleted record id $id (was PDF-only)"
    else
        log "  FAILED to delete record id $id"
        n_fail=$((n_fail+1))
    fi
done

log "COMMIT done: stripped:$n_strip deleted:$n_recdel failed:$n_fail"
log "note: TSV rows for these books now point at books no longer in Calibre. Run"
log "      fetch-books.sh --force-retry <list>.tsv to reconcile them to pdf-only."
log "=== prune-pdfs done ==="

# =============================================================================
# version: PRUNE_PDFS_VERSION 1
# =============================================================================
