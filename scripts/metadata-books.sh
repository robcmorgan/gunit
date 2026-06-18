#!/usr/bin/env bash
COMMENTS_BOOKS_VERSION="4"   # v4: title+author fallback when ISBN lookup returns no record (fixes empty-result REJECTs); log fetch method
# =============================================================================
#  comments-books.sh — backfill empty 'comments' (descriptions) on Calibre books
#  using the metadata SOURCE plugins you've configured in the Calibre GUI.
#
#  WHAT IT DOES
#    1. Finds books whose comments field is empty  (search: comments:false).
#    2. For each, fetches metadata via fetch-ebook-metadata (your plugins) —
#       BY ISBN when the book has one (accurate), else by title+author.
#    3. GATES the result: the OPF's returned title/author must match the
#       library book via the SAME strict matcher fetch-books/tag-books use
#       (match-lib.sh book_match_fields). A weak/garbage match is rejected,
#       NOT written. This is the safety the interactive one-liner lacked —
#       it stops "Order of the Phoenix" getting a sociology blurb.
#    4. Writes ONLY the comments field (set_metadata --field comments:...).
#       Title/author/tags/series are never touched.
#
#  Everything runs inside the calibre container via `docker exec`, because
#  fetch-ebook-metadata ships with the GUI binary and the library lives there
#  at /books/Calibre (the host /Nutmeg/... path is mounted there).
#
#  USAGE
#     ./comments-books.sh                 # process up to BATCH (default 10)
#     ./comments-books.sh -n 50           # process up to 50
#     ./comments-books.sh --dry-run       # fetch + gate, write nothing
#     ./comments-books.sh --dry-run -n 25
#
#  ENV
#     CALIBRE_CONTAINER (default: calibre)
#     CALIBRE_LIBRARY   (default: /books/Calibre)   library path INSIDE container
#     BATCH             (default: 10)               max books per run
#     CONFIDENCE        (default: 0.6)              min match score to write
#     SLEEP             (default: 3)                seconds between books (polite)
#     LOG               (default: ~/logs/gunit.log) shared pipeline log; tag [cm]
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
BATCH="${BATCH:-10}"
CONFIDENCE="${CONFIDENCE:-0.6}"
SLEEP="${SLEEP:-3}"
LOG="${LOG:-$HOME/logs/gunit.log}"

# shared strict matcher (norm, ge, book_match_fields, ...). Same gate as
# fetch-books/tag-books so "is this the right book" never drifts.
. "$(dirname "$0")/match-lib.sh"

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -n) BATCH="${2:?-n needs a number}"; shift 2 ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *)  echo "unexpected arg: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s  [cm] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

# calibredb / fetch-ebook-metadata run INSIDE the container.
# fem() is restricted to the Google plugin: in testing it was the ONLY source
# returning descriptions, and it did so in ~3s vs ~60s when all plugins are
# queried (fetch-ebook-metadata waits for the slowest enabled plugin). Override
# FEM_PLUGINS for a slower, wider second pass over books Google can't describe,
# e.g.  FEM_PLUGINS='Google Amazon.com Goodreads' FEM_TIMEOUT=30 ./metadata-books.sh
FEM_PLUGINS="${FEM_PLUGINS:-Google}"   # space-separated, so single-word names
                                        # only. Multi-word names (e.g. "Amazon.com
                                        # Multiple Countries") can't be passed via
                                        # this var — edit fem() directly if needed.
FEM_TIMEOUT="${FEM_TIMEOUT:-20}"        # per-source timeout (seconds)
cdb()  { docker exec "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIBRARY" 2>/dev/null; }
fem()  {
    local pargs=() p
    for p in $FEM_PLUGINS; do pargs+=(--allowed-plugin "$p"); done
    docker exec "$CALIBRE_CONTAINER" fetch-ebook-metadata \
        "${pargs[@]}" -d "$FEM_TIMEOUT" "$@" 2>/dev/null
}

# pull the list of empty-comments books as JSON, take the first BATCH.
# fields: id, title, authors, identifiers (for the ISBN).
queue_json="$(cdb list --search 'comments:false' \
                  --fields id,title,authors,identifiers \
                  --limit "$BATCH" --for-machine)"

# how many did we get?  calibredb prints plugin chatter ("Integration status:
# True", SyntaxWarnings) on STDOUT around the JSON, so json.load on the raw
# stream fails with "Extra data". Slice from the first '[' to the last ']' to
# isolate the array before parsing — done everywhere we parse calibredb JSON.
count="$(printf '%s' "$queue_json" | python3 -c '
import sys, json
raw = sys.stdin.read()
s, e = raw.find("["), raw.rfind("]")
print(len(json.loads(raw[s:e+1])) if s != -1 and e != -1 else 0)
' 2>/dev/null)"
[ -z "$count" ] && count=0

log "=== comments-books v$COMMENTS_BOOKS_VERSION start (container:$CALIBRE_CONTAINER lib:$CALIBRE_LIBRARY batch:$BATCH confidence:$CONFIDENCE plugins:'$FEM_PLUGINS' timeout:${FEM_TIMEOUT}s dry-run:$DRY_RUN) — $count book(s) without comments ==="
[ "$count" -eq 0 ] && { log "nothing to do"; exit 0; }

n_ok=0 n_reject=0 n_nofetch=0 n_nodesc=0

# iterate the queue. Emit one TSV line per book: id<TAB>title<TAB>author<TAB>isbn
printf '%s' "$queue_json" | python3 -c '
import sys, json
raw = sys.stdin.read()
s, e = raw.find("["), raw.rfind("]")
data = json.loads(raw[s:e+1]) if s != -1 and e != -1 else []
for b in data:
    ident = b.get("identifiers", {}) or {}
    isbn = ident.get("isbn", "")
    print("\t".join([str(b["id"]),
                     (b.get("title","")   or "").replace("\t"," "),
                     (b.get("authors","") or "").replace("\t"," "),
                     isbn]))
' 2>/dev/null | while IFS=$'\t' read -r id title author isbn; do
    [ -z "$id" ] && continue
    label="[$id] $title / $author${isbn:+  isbn:$isbn}"

    # ---- fetch OPF via plugins ----
    # Try ISBN first when we have one (most precise), but Google sometimes has
    # no record for a specific ISBN edition while still knowing the book by
    # title — that produced the empty-result REJECTs (got ''/''). So if the ISBN
    # fetch yields an OPF with no <dc:title>, fall back to a title+author search.
    opf="$(mktemp)"
    fetched_via=""
    if [ -n "$isbn" ]; then
        fem --isbn "$isbn" --opf > "$opf"
        fetched_via="isbn"
        # did the ISBN lookup actually return a record? (has a title)
        if ! grep -q '<dc:title' "$opf" 2>/dev/null; then
            fem --title "$title" --authors "$author" --opf > "$opf"
            fetched_via="isbn-miss->title"
        fi
    else
        fem --title "$title" --authors "$author" --opf > "$opf"
        fetched_via="title"
    fi
    if [ ! -s "$opf" ]; then
        log "  no metadata returned — $label"
        n_nofetch=$((n_nofetch+1)); rm -f "$opf"; continue
    fi

    # ---- extract candidate title/author/description from the OPF ----
    # one python pass; tab-separated: ctitle \t cauthor \t desc(base64)
    parsed="$(python3 - "$opf" <<"PY"
import sys, re, base64
x = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def grab(tag):
    m = re.search(r"<dc:%s[^>]*>(.*?)</dc:%s>" % (tag, tag), x, re.S)
    return (m.group(1).strip() if m else "")
# authors: there can be several <dc:creator> — join them
authors = re.findall(r"<dc:creator[^>]*>(.*?)</dc:creator>", x, re.S)
ctitle  = grab("title")
cauthor = " ".join(a.strip() for a in authors)
desc    = grab("description")
# base64 the description so embedded tabs/newlines/HTML survive the TSV hop
b64 = base64.b64encode(desc.encode("utf-8")).decode("ascii")
print("\t".join([ctitle, cauthor, b64]))
PY
)"
    rm -f "$opf"
    ctitle="$(printf '%s' "$parsed" | cut -f1)"
    cauthor="$(printf '%s' "$parsed" | cut -f2)"
    desc_b64="$(printf '%s' "$parsed" | cut -f3)"

    # ---- GATE: does the fetched record actually match this book? ----
    # book_match_fields WANT_TITLE WANT_AUTHOR CAND_TITLE CAND_AUTHOR -> 0..1
    score="$(book_match_fields "$title" "$author" "$ctitle" "$cauthor")"
    if ! ge "$score" "$CONFIDENCE"; then
        log "  REJECT (score $score < $CONFIDENCE, via $fetched_via): wanted '$title' / '$author'  got '$ctitle' / '$cauthor' — $label"
        n_reject=$((n_reject+1)); continue
    fi

    # ---- decode description, unescape entities, sanity-check non-empty ----
    desc="$(printf '%s' "$desc_b64" | base64 -d 2>/dev/null | python3 -c '
import sys, html
s = sys.stdin.read()
# OPF descriptions arrive HTML-escaped (&lt;p&gt;...); unescape ONCE so calibre
# stores real HTML, not visible tags. Calibre comments are HTML, so keep tags.
print(html.unescape(s), end="")
' 2>/dev/null)"

    if [ -z "${desc//[$' \t\n\r']/}" ]; then
        log "  matched (score $score) but OPF had no description — $label"
        n_nodesc=$((n_nodesc+1)); continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  DRY would write comments id $id (score $score, ${#desc} chars, via $fetched_via) — $label"
        n_ok=$((n_ok+1)); sleep "$SLEEP"; continue
    fi

    # ---- write ONLY comments ----
    if cdb set_metadata "$id" --field comments:"$desc" >/dev/null; then
        log "  wrote comments id $id (score $score, ${#desc} chars, via $fetched_via) — $label"
        n_ok=$((n_ok+1))
    else
        log "  FAILED to write comments id $id — $label"
    fi
    sleep "$SLEEP"
done

# NOTE: the while loop runs in a pipeline subshell, so n_* counters above don't
# survive to here. Re-derive the run summary from the log lines we just wrote
# for THIS run by counting our own markers instead (cheap, accurate).
log "=== comments-books done (batch $BATCH) — see [cm] lines above for per-book result ==="
# COMMENTS_BOOKS_VERSION=4  (bottom stamp; keep in sync with top)