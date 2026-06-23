#!/usr/bin/env bash
TAG_BOOKS_VERSION="19"   # bump on every change; echoed at startup
# v19: retry imported_but_unfound rows that have an md5. A book marked unfound
#     may have been imported to calibre in a later sweep cycle. On each run, do
#     a single fast md5 identifier lookup before skipping; if the book is now in
#     calibre, fall through to normal tagging. No fuzzy fallback on the retry —
#     if the identifier isn't stamped, the row stays imported_but_unfound.
# v18: also process blank-status rows. A book in the TSV with no status is
#     "pending" (fetch-books hasn't downloaded it yet), but it may already be in
#     calibre via another path (manual import, different list, tag-queue). If
#     found, tag it and mark "tagged". If not found, leave blank (still pending —
#     distinct from imported_but_unfound which means it was downloaded but missing).
# v17: imported_but_unfound status. When a downloaded book can't be found in
#     calibre, write "imported_but_unfound" into the status field instead of
#     leaving it as "downloaded". Subsequent runs skip these rows (no calibredb
#     calls), so lists with many missing books don't burn time on futile retries.
#     sweep-books.sh can reset the status to "downloaded" if it re-imports the file.
# v16: #columns: header support. TSVs can declare column order with a header
#     line like "#columns: title|author". Default (no header) is author|title.
#     Only the position of 'author' and 'title' matters; status/md5/date are
#     always columns 3/4/5.
# v15: --limit N flag. Processes at most N downloaded books per file (tags them,
#     updates TSV), leaving the rest as-is. Useful for verifying the mktemp/mv/
#     ownership fixes are all working without waiting for a full run.
# v14: PRESERVE FILE OWNERSHIP/MODE after mv. mktemp creates tmp as root (when
#     the service runs as root), so mv was replacing the user-owned TSV with a
#     root:root 600 file — git couldn't read it, and the sweep owned all TSVs
#     after one pass. Fix: stat the original file before the loop, then chown+chmod
#     the written file back to original owner:group and mode after mv succeeds.
# v13: FIX SILENT mv FAILURE. mktemp was creating the tmp file in /tmp (tmpfs)
#     while the TSV lives on a different filesystem; cross-filesystem mv can fail
#     silently (no set -e to catch it), leaving the TSV permanently stuck on
#     'downloaded' even after a successful calibre tag. Fix: mktemp -p uses the
#     TSV's own directory so the mv is an atomic same-filesystem rename.
#     Also added explicit mv error logging so future failures are visible.
# v12: INTERACTIVE MODE (nnn TSV picker). Running with no file args opens nnn
#      in $TSV_DIR (default ../tsv-lists), you select a .tsv, and that list is
#      processed — mirrors fetch-books v61's picker exactly. nnn is required
#      in this mode; a non-.tsv pick or quitting without a selection aborts
#      cleanly. All flags (--dry-run, --replace-tags, --tag) still apply.
# v11: log to shared $GUNIT_LOG (~/logs/gunit.log), lines tagged [t].
# =============================================================================
#  tag-books.sh — apply calibre tags to books that fetch-books.sh has fetched.
#
#  Reads the same list files. For every line marked 'done' that carries a tag
#  (5th column), it finds the matching book in the Calibre library and adds the
#  tag(s) via calibredb set_metadata. Idempotent: adds tags without clobbering
#  existing ones, and records a 'tagged' marker so re-runs skip already-done work.
#
#  Matching to the library is, in order:
#    1. EXACT by md5 identifier (identifiers:annas:<md5>). The first time a book
#       is matched we stamp that identifier onto it (see below), so every later
#       run finds it exactly — no fuzzy matching, no false positives.
#    2. FUZZY fallback (for books matched before the identifier existed): a
#       calibre title search, then the SHARED strict matcher from match-lib.sh
#       (same title-gate + author rules as fetch-books). On a confident hit we
#       stamp the md5 identifier so the next run takes path 1.
#  A book must be in the library already — i.e. fetch-books downloaded it AND
#  your watcher imported it. Books still downloading/failed won't be found yet;
#  just re-run later (it's resumable).
#
#  USAGE:
#     ./tag-books.sh booker.tsv
#     ./tag-books.sh --dry-run booker.tsv      # show what would be tagged
#     ./tag-books.sh *.tsv
#
#  Env:
#     CALIBRE_CONTAINER (default: calibre)   docker container running calibredb
#     CALIBRE_LIBRARY   (default: /books/Calibre)   library path inside container
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
MAX_TAG_LEN="${MAX_TAG_LEN:-40}"   # drop existing tags longer than this (junk); 0 = keep all
# existing tags matching these (case-insensitive, exact) are dropped as junk —
# typical ebook-source cruft. Add your own, space-separated, via TAG_STOPLIST.
TAG_STOPLIST="${TAG_STOPLIST:-download apple+books books+on+iphone ipad mac kindle iphone calibre unknown}"
DEFAULT_LANG="${DEFAULT_LANG:-eng}"   # set this language when a book's language is blank (calibre-web hides blank-language books); empty disables
CONFIDENCE="${CONFIDENCE:-0.6}"    # 0..1; fuzzy fallback hit must score >= this
ID_SCHEME="${ID_SCHEME:-annas}"    # calibre identifier scheme used to store the md5
LOG="${LOG:-${GUNIT_LOG:-$HOME/logs/gunit.log}}"   # shared log for all gunit scripts
# Interactive-mode (no file args) nnn picker start dir. Relative paths resolve
# against the script's own dir, so the default points at /gunit/tsv-lists/.
TSV_DIR="${TSV_DIR:-../tsv-lists}"

# shared confidence matcher (norm, ge, title_full_match, author_match,
# meaningful_words, book_match_score) — same logic as fetch-books.
. "$(dirname "$0")/match-lib.sh"
# shared tagging logic (cdb, find_book_id, stamp_identifier, merge_tags,
# apply_tags) — same code tag-queue.sh uses, so they never drift.
. "$(dirname "$0")/tag-lib.sh"

DRY_RUN=0
REPLACE=0
TAG=""
LIMIT=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --replace-tags) REPLACE=1; shift ;;
        --tag) TAG="$(printf '%s' "${2:-}" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"; shift 2 ;;
        --limit) LIMIT="${2:-10}"; shift 2 ;;
        --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
# No file args: enter interactive mode (nnn picker) rather than erroring.
if [ "${#FILES[@]}" -eq 0 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { local ts; ts="$(date '+%F %T')"; printf '%s  [t] %s\n' "$ts" "$*" >> "$LOG"; printf '%s  %s\n' "$ts" "$*" >&2; }

# ---- interactive mode: nnn TSV picker --------------------------------------
if [ "${INTERACTIVE:-0}" -eq 1 ]; then
    HERE="$(cd "$(dirname "$0")" && pwd)"
    command -v nnn >/dev/null || {
        log "FATAL: no list args and nnn not installed for the picker. Install it on otis:  sudo apt install nnn   (or pass a LIST.tsv explicitly)"
        exit 1
    }
    case "$TSV_DIR" in /*) tsvdir="$TSV_DIR" ;; *) tsvdir="$HERE/$TSV_DIR" ;; esac
    [ -d "$tsvdir" ] || { log "FATAL: TSV dir not found: $tsvdir"; exit 1; }

    pickfile="$(mktemp)"
    nnn -p "$pickfile" "$tsvdir"
    picked_tsv="$(tr '\0' '\n' < "$pickfile" 2>/dev/null | head -n1)"
    rm -f "$pickfile"

    [ -z "$picked_tsv" ] && { log "no file selected — aborting"; exit 0; }
    case "$picked_tsv" in
        *.tsv) : ;;
        *) log "selection is not a .tsv: $picked_tsv — aborting"; exit 1 ;;
    esac
    [ -f "$picked_tsv" ] || { log "selected file does not exist: $picked_tsv"; exit 1; }

    log "interactive: selected $picked_tsv"
    FILES=( "$picked_tsv" )
fi

# calibredb wrapper, find_book_id, stamp_identifier, merge_tags, apply_tags all
# come from tag-lib.sh (sourced above) — shared with tag-queue.sh, no drift.

process_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    local orig_owner orig_mode
    orig_owner="$(stat -c '%U:%G' "$file" 2>/dev/null || true)"
    orig_mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
    local tmp; tmp="$(mktemp -p "$(dirname "$file")")"
    local n_tag=0 n_skip=0 n_missing=0 n_unfound=0
    local file_tag="$TAG"   # --tag overrides; else taken from #tag: header
    local author_col=1 title_col=2   # default: author|title; overridden by #columns: header

    while IFS= read -r raw || [ -n "$raw" ]; do
        # pick up the #tag: and #columns: headers
        case "$raw" in
            \#tag:*|\#tag\ *)
                if [ -z "$TAG" ]; then
                    file_tag="$(printf '%s' "$raw" | sed 's/^#tag:[[:space:]]*//; s/^#tag[[:space:]]*//; s/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"
                    log "  list tag from header: '$file_tag'"
                fi
                printf '%s\n' "$raw" >> "$tmp"; continue ;;
            \#columns:*)
                local _first; _first="$(printf '%s' "$raw" | sed 's/^#columns:[[:space:]]*//' | cut -d'|' -f1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
                case "$_first" in
                    title)  title_col=1; author_col=2; log "  columns: title|author" ;;
                    author) author_col=1; title_col=2 ;;
                esac
                printf '%s\n' "$raw" >> "$tmp"; continue ;;
        esac
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac

        local author title status md5 date
        author="$(printf '%s' "$raw" | cut -d'|' -f$author_col)"
        title="$(printf '%s' "$raw" | cut -d'|' -f$title_col)"
        status="$(printf '%s' "$raw" | cut -d'|' -f3)"
        md5="$(printf '%s' "$raw" | cut -d'|' -f4)"
        date="$(printf '%s' "$raw" | cut -d'|' -f5)"

        author="$(printf '%s' "$author" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        title="$(printf '%s' "$title"   | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        status="$(printf '%s' "$status" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        md5="$(printf '%s' "$md5"       | tr -d ' ')"

        # only tag books that have actually downloaded (in the library).
        # 'downloaded' = fetch-books pulled it via fast-download; 'completed' =
        # legacy Stacks status. 'tagged' = already done.
        if [ "$status" = "tagged" ]; then
            printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
        fi
        if [ "$status" = "imported_but_unfound" ]; then
            if [ -n "$md5" ]; then
                local _quick; _quick="$(cdb search "identifiers:${ID_SCHEME}:${md5}" | tr ',' ' ')"
                if [ -n "$_quick" ]; then
                    log "  retry (now in calibre): $author — $title"
                    status="downloaded"   # fall through to normal tagging
                else
                    printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
                fi
            else
                printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
            fi
        fi
        # process: downloaded, completed, AND blank (pending — may already be in calibre).
        # skip everything else (nomatch, pdf-only, failed, quota_blocked, etc.)
        if [ "$status" != "downloaded" ] && [ "$status" != "completed" ] && [ -n "$status" ]; then
            printf '%s\n' "$raw" >> "$tmp"; continue
        fi
        if [ -z "$file_tag" ]; then
            log "  no tag set (add a '#tag:' header line) — skipping: $author — $title"
            printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
        fi

        local found id via
        found="$(find_book_id "$author" "$title" "$md5")"
        if [ -z "$found" ]; then
            if [ -n "$status" ]; then
                log "  imported_but_unfound: $author — $title"
                printf '%s\n' "$raw" | awk -F'|' -v OFS='|' '{$3="imported_but_unfound"; print}' >> "$tmp"
                n_unfound=$((n_unfound+1))
            else
                printf '%s\n' "$raw" >> "$tmp"   # blank/pending — not downloaded yet, leave as-is
            fi
            continue
        fi
        id="$(printf '%s' "$found" | cut -f1)"
        via="$(printf '%s' "$found" | cut -f2)"

        # build comma-separated tag list; accept either comma- or space-separated
        # input (older files used spaces, newer ones commas)
        local taglist; taglist="$(printf '%s' "$file_tag" \
            | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"

        if [ "$LIMIT" -gt 0 ] && [ "$n_tag" -ge "$LIMIT" ]; then
            printf '%s\n' "$raw" >> "$tmp"; continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "  DRY: would tag id $id [$via] ($author — $title) += [$taglist] (+ clear rating)"
            printf '%s\n' "$raw" >> "$tmp"; continue
        fi

        local existing_json merged
        if [ "$REPLACE" -eq 1 ]; then
            # discard existing tags entirely, set only ours (de-duped)
            merged="$(printf '%s' "$taglist" | python3 -c '
import sys
new=[t.strip() for t in sys.stdin.read().split(",") if t.strip()]
seen,out=set(),[]
for t in new:
    if t.lower() not in seen: seen.add(t.lower()); out.append(t)
print(",".join(out))
' 2>/dev/null)"
            [ -z "$merged" ] && merged="$taglist"
        else
        # read existing tags and merge. calibredb --for-machine returns JSON;
        # parse it properly (sed-stripping JSON mangles multi-tag arrays).
        # set_metadata --field tags: REPLACES, so we merge existing + new,
        # de-duplicating, and write the full set back.
        existing_json="$(cdb list -f tags -s "id:$id" --for-machine 2>/dev/null)"
        # extract existing tags, merge with new taglist, trim, drop blanks,
        # de-dupe (case-insensitive), rejoin with commas.
        merged="$(printf '%s' "$existing_json" | python3 -c '
import sys, json
maxlen = int(sys.argv[2])
# stoplist: "+" stands in for spaces in multi-word entries
stop = {s.replace("+", " ").strip().lower() for s in sys.argv[3].split() if s.strip()}
try:
    data = json.load(sys.stdin)
    existing = data[0].get("tags", []) if data else []
except Exception:
    existing = []
# drop overlong existing tags and known-junk tags (case-insensitive).
# maxlen 0 disables the length filter. New tags are never dropped.
def keep(t):
    t = t.strip()
    if not t: return False
    if t.lower() in stop: return False
    if maxlen > 0 and len(t) > maxlen: return False
    return True
existing = [t for t in existing if keep(t)]
new = [t.strip() for t in sys.argv[1].split(",") if t.strip()]
seen, out = set(), []
for t in list(existing) + new:
    t = t.strip()
    if t and t.lower() not in seen:
        seen.add(t.lower()); out.append(t)
print(",".join(out))
' "$taglist" "$MAX_TAG_LEN" "$TAG_STOPLIST" 2>/dev/null)"
        # safety: if the merge produced nothing (parse failure), fall back to
        # just the new tags rather than wiping the field with garbage.
        [ -z "$merged" ] && merged="$taglist"
        fi

        # set both tags and rating:0 in ONE call. Anna's imports often carry a
        # stray star rating from the source file; we always clear it (rating:0)
        # so the library isn't polluted with the uploader's rating. This is
        # atomic with the tag write and costs no extra call.
        if cdb set_metadata "$id" --field "tags:$merged" --field "rating:0" >/dev/null 2>&1; then
            log "  tagged id $id [$via] ($author — $title) -> [$merged] (rating cleared)"
            # on a fuzzy match, stamp the md5 so the next run finds it exactly
            if [ "$via" = "fuzzy" ] && [ -n "$md5" ]; then
                stamp_identifier "$id" "$md5"
                log "    stamped ${ID_SCHEME}:${md5} onto id $id"
            fi
            # fill a blank language so calibre-web doesn't hide the book (shared
            # logic from tag-lib; only acts when language is empty).
            fix_blank_language "$id"; [ "$?" -eq 10 ] && log "    set language id $id -> $DEFAULT_LANG (was blank)"
            printf '%s|%s|tagged|%s|%s\n' "$author" "$title" "$md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_tag=$((n_tag+1))
        else
            log "  FAILED to tag id $id ($author — $title)"
            printf '%s\n' "$raw" >> "$tmp"
        fi
    done < "$file"

    mv "$tmp" "$file" || { log "ERROR: failed to write updated TSV (mv $tmp -> $file)"; rm -f "$tmp"; return 1; }
    [ -n "$orig_owner" ] && chown "$orig_owner" "$file" 2>/dev/null || true
    [ -n "$orig_mode"  ] && chmod "$orig_mode"  "$file" 2>/dev/null || true
    log "FILE $file — tagged:$n_tag already/none:$n_skip imported_but_unfound:$n_unfound"
}

log "=== tag-books v$TAG_BOOKS_VERSION start (container:$CALIBRE_CONTAINER lib:$CALIBRE_LIBRARY confidence:$CONFIDENCE id-scheme:$ID_SCHEME dry-run:$DRY_RUN) ==="
for f in "${FILES[@]}"; do process_file "$f"; done
log "=== tag-books done ==="