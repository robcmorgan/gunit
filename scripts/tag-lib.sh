#!/usr/bin/env bash
TAG_LIB_VERSION="7"   # bump on every change
# v7: don't retry on "No books matching" — that's a definitive zero-result from
#     calibredb (printed to stderr), not a lock. Was costing 4 retries × 4
#     searches per missing book, making lists heavy with unlibrary'd books
#     extremely slow. Lock errors don't print "No books matching".
# v6: strip "(Series, #N)" from title before calibre title-search. Calibre stores
#     titles without the Goodreads series label, so the full string yields no hits.
#     Original title is kept for fuzzy scoring (book_match_fields is unaffected).
# v5: FIX find_book_id FALSE-POSITIVE on same-author books (blob -> fields).
#     find_book_id scored each candidate with book_match_score, which flattens the
#     candidate's title+authors into ONE blob and runs the title gate against it.
#     For a SHORT wanted title whose meaningful word happens to appear anywhere in
#     a same-author candidate's blob, the gate passes the WRONG book. Live failure:
#     list row "The Poet X / Elizabeth Acevedo" (correct id 1944) was matched to id
#     1936 "With the Fire on High" — a DIFFERENT Acevedo book — because the blob
#     scorer's title gate isn't anchored to the candidate's TITLE field. This is the
#     same contamination class fetch-books fixed (v81/v85) with a title-aware,
#     field-separated check; the tag path had drifted and never received it.
#     Fix: find_book_id now extracts the candidate's title and author SEPARATELY
#     (it already lists `-f title,authors`) and scores with book_match_fields (the
#     structured matcher: wanted-title vs candidate-TITLE, wanted-author vs
#     candidate-AUTHOR, with the short_title_ok start-anchor gate). A word that
#     appears only in the candidate's author or in a sibling title can no longer
#     satisfy a title gate. tag-books and tag-queue both inherit this via the shared
#     lib, so they can't drift from fetch-books again.
#     ALSO: the per-call `2>/dev/null` suppressions inside find_book_id are removed.
#     They hid real lock/traceback errors as "no match" (a book that exists reads as
#     absent and is silently skipped). cdb already strips plugin noise and detects
#     locks via retry; its stderr now propagates so a genuine failure is visible in
#     the log instead of masquerading as a clean miss. A legitimate zero-result
#     (calibredb prints "No books matching..." to stderr, non-zero exit) is NOT an
#     error and is handled by the empty-stdout path exactly as before.
# v4: cdb() now RETRIES with backoff to survive transient library-lock contention
#     with the always-on GUI container. Symptom it fixes: the SAME query returns
#     ids one moment and nothing the next, because the GUI holds metadata.db and a
#     direct --library-path read intermittently loses the race (seen as spurious
#     "NOT FOUND" across a whole link-md / tag-books run). The noise-stripping from
#     v3 is preserved, moved into _cdb_raw; cdb wraps it. Retry policy (tunable via
#     env): CDB_RETRIES (default 4) attempts, CDB_RETRY_SLEEP (default 0.7s) base
#     delay, linear-ish backoff. We retry when the call EITHER (a) errors with a
#     recognised lock signature on stderr, OR (b) yields EMPTY stdout — because an
#     empty read can't be distinguished from a real zero-match, so we give a lock a
#     few chances and, if it's genuinely empty after the last try, return empty
#     (caller treats as no-match exactly as before). A successful non-empty read
#     returns immediately on the first hit — no added latency on the common path.
#     A real zero-match costs only a few short retries, on the miss path only.
# v3: cdb() now FILTERS calibredb's stdout to strip plugin startup noise. The
#     fantastic_fiction plugin prints "calibre_plugins... SyntaxWarning" and
#     "Integration status: True" to STDOUT (not stderr) on every invocation; that
#     text fused with real output (e.g. "True1535") and broke the numeric-id and
#     JSON parsers in lib_find_id / find_book_id, so EVERY library lookup silently
#     returned no match. We now drop only those two unmistakable noise-line
#     patterns from stdout; all real data (id CSVs, --for-machine JSON) passes
#     through untouched. Conservative match: never strips a line that could be data.
# =============================================================================
#  tag-lib.sh — shared calibre tagging logic for tag-books.sh and tag-queue.sh.
#
#  Source AFTER match-lib.sh (needs book_match_fields, ge) and after the caller
#  has set the calibre config vars (CALIBRE_CONTAINER, CALIBRE_LIBRARY,
#  CONFIDENCE, ID_SCHEME, MAX_TAG_LEN, TAG_STOPLIST). Provides:
#     cdb ...                 — run calibredb against the configured library
#     find_book_id f1 f2 md5  — locate a book; echoes "<id>\t<via>" or nothing
#     stamp_identifier id md5 — write annas:<md5> onto a book (best-effort)
#     merge_tags id taglist   — echo the cleaned/merged tag CSV for a book
#     apply_tags id taglist md5 via — set tags+rating:0, stamp md5 if fuzzy
#
#  Extracted verbatim from tag-books v8 so the queue tagger and the manual
#  tagger never drift in what they match or how they merge.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "tag-lib.sh requires bash; source it from a bash script." >&2
    return 1 2>/dev/null || exit 1
fi

# config defaults (callers usually set these; defaults keep the lib usable alone)
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CONFIDENCE="${CONFIDENCE:-0.6}"
ID_SCHEME="${ID_SCHEME:-annas}"
MAX_TAG_LEN="${MAX_TAG_LEN:-40}"
TAG_STOPLIST="${TAG_STOPLIST:-download apple+books books+on+iphone ipad mac kindle iphone calibre unknown}"
# When a book has a BLANK language, calibre-web's default language filter hides
# it from the listing. Set this language when (and only when) the field is empty.
# We never overwrite a non-empty language (so a genuine French/Italian book keeps
# its own). DEFAULT_LANG="" disables the fixup entirely.
DEFAULT_LANG="${DEFAULT_LANG:-eng}"

CDB_RETRIES="${CDB_RETRIES:-4}"        # total attempts on empty/locked result
CDB_RETRY_SLEEP="${CDB_RETRY_SLEEP:-0.7}"  # base seconds between attempts (backs off)

# _cdb_raw: one calibredb call against the configured library, with plugin
# startup noise stripped from STDOUT. stderr is captured by the caller (cdb) so a
# lock signature can be detected. (Noise patterns, see v3 notes:
#   "calibre_plugins.<name>...: SyntaxWarning: ..."  — own line, line-start
#   "Integration status: ..."                         — own line OR fused onto a
#                                                        data line, e.g. "]Integration...")
_cdb_raw() {
    docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@" \
        | { grep -vE '^calibre_plugins\.' || true; } \
        | sed -E 's/Integration status:.*$//'
}

# cdb: _cdb_raw with bounded retry-with-backoff to ride out transient library-lock
# contention with the always-on GUI container. Retries when EITHER the call errors
# with a recognised lock signature on stderr, OR stdout comes back empty (an empty
# read can't be told apart from a real zero-match, so we give a possible lock a few
# chances; if still empty after the last attempt we return empty, and the caller
# treats it as no-match exactly as before). A non-empty result returns immediately.
cdb() {
    local attempt=1 out err rc errfile
    errfile="$(mktemp)"
    while :; do
        # capture stdout in $out, stderr to a temp file (so we can scan it)
        out="$(_cdb_raw "$@" 2>"$errfile")"; rc=$?
        err="$(cat "$errfile" 2>/dev/null)"

        # success path: any non-empty stdout -> done, emit and return.
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            rm -f "$errfile"
            return 0
        fi

        # empty stdout. Fast-path: "No books matching" on stderr is a definitive
        # zero-result from calibredb — not a lock. Return immediately; retrying
        # would only waste time since the answer won't change.
        if printf '%s' "$err" | grep -q 'No books matching'; then
            rm -f "$errfile"
            return "$rc"
        fi

        # Decide whether to retry. Retry if (a) attempts remain AND
        # (b) it plausibly was a lock — i.e. a lock signature on stderr, OR we just
        # treat any empty result as retryable up to the cap (cheap; only on misses).
        if [ "$attempt" -ge "$CDB_RETRIES" ]; then
            # exhausted: return whatever we have (empty) — real zero-match or a
            # persistent lock; caller handles empty as no-match. Surface stderr.
            [ -n "$err" ] && printf '%s\n' "$err" >&2
            rm -f "$errfile"
            return "$rc"
        fi

        # backoff: base * attempt (0.7, 1.4, 2.1, ...). sleep accepts fractions.
        sleep "$(awk "BEGIN{print $CDB_RETRY_SLEEP * $attempt}")" 2>/dev/null \
            || sleep 1
        attempt=$((attempt+1))
    done
}

# _cand_fields ID -> echoes "TITLE<TAB>AUTHOR" for a calibre id, or nothing.
# Structured extraction (NOT a flattened blob) so the caller can score the wanted
# title against the candidate's TITLE and the wanted author against the candidate's
# AUTHOR — see v5 notes. stderr propagates through cdb (no local suppression) so a
# real read failure is visible rather than silently read as "no fields".
_cand_fields() {
    local id="$1"
    cdb list -f title,authors -s "id:$id" --for-machine \
        | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); b = d[0] if d else {}
    a = b.get("authors", ""); a = " ".join(a) if isinstance(a, list) else a
    t = b.get("title", "") or ""
    # TAB-separated so title and author stay distinct fields for book_match_fields
    sys.stdout.write(t + "\t" + (a or ""))
except Exception:
    pass'
}

# find a calibre book id. Args: f1 f2 md5. Echoes "<id>\t<via>" (via=id|fuzzy)
# or nothing.
#   1) exact by md5 identifier (annas:<md5>) when md5 is given;
#   2) else fuzzy: title-search each field, then score each candidate with the
#      STRUCTURED matcher book_match_fields (wanted-title vs candidate TITLE,
#      wanted-author vs candidate AUTHOR). v5: was book_match_score (blob), which
#      false-matched same-author books (Poet X -> With the Fire on High).
# NOTE on field inversion: callers pass f1=list-title, f2=list-author (the
# fetch-books convention). book_match_fields scores BOTH interpretations, so the
# argument order f1,f2 is correct regardless.
find_book_id() {
    local f1="$1" f2="$2" md5="$3"
    if [ -n "$md5" ]; then
        local exact
        # stderr propagates (no 2>/dev/null): a lock/traceback must not look like
        # a clean "no identifier match". cdb already strips plugin noise + retries.
        exact="$(cdb search "identifiers:${ID_SCHEME}:${md5}" | tr ',' ' ')"
        set -- $exact
        if [ "$#" -ge 1 ]; then printf '%s\tid\n' "$1"; return 0; fi
    fi
    local ids="" field sfield
    for field in "$f1" "$f2"; do
        local hit
        # strip "(Series, #N)" for the search query — calibre titles don't carry it
        sfield="$(printf '%s' "$field" | sed 's/ *([^)]*,  *#[0-9][0-9]*) *$//')"
        hit="$(cdb search "title:\"$sfield\"" | tr ',' ' ')"
        [ -z "$hit" ] && hit="$(cdb search "$sfield" | tr ',' ' ')"
        ids="$ids $hit"
    done
    ids="$(printf '%s\n' $ids | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    [ -z "$ids" ] && return 1
    local id best_id="" best_score="0.000" fields ctitle cauthor s
    for id in $ids; do
        # only consider plausible numeric ids (search noise guard)
        case "$id" in ''|*[!0-9]*) continue;; esac
        fields="$(_cand_fields "$id")"
        [ -z "$fields" ] && continue
        ctitle="${fields%%$'\t'*}"
        cauthor="${fields#*$'\t'}"
        [ "$cauthor" = "$fields" ] && cauthor=""   # no TAB -> author empty
        # STRUCTURED score: wanted title vs candidate TITLE, wanted author vs
        # candidate AUTHOR. This is the contamination-safe matcher (v5).
        s="$(book_match_fields "$f1" "$f2" "$ctitle" "$cauthor")"
        if ge "$s" "$best_score"; then best_score="$s"; best_id="$id"; fi
    done
    if [ -n "$best_id" ] && ge "$best_score" "$CONFIDENCE"; then
        printf '%s\tfuzzy\n' "$best_id"; return 0
    fi
    return 1
}

stamp_identifier() {
    local id="$1" md5="$2"
    [ -z "$md5" ] && return 0
    cdb set_metadata "$id" --field "identifiers:${ID_SCHEME}:${md5}" >/dev/null 2>&1 || true
}

# merge_tags id taglist -> echo cleaned, de-duped CSV of existing+new tags.
# Drops overlong (MAX_TAG_LEN) and stoplist junk from EXISTING tags; never drops
# new tags. Falls back to just the new taglist if the merge yields nothing.
merge_tags() {
    local id="$1" taglist="$2" existing_json merged
    existing_json="$(cdb list -f tags -s "id:$id" --for-machine 2>/dev/null)"
    merged="$(printf '%s' "$existing_json" | python3 -c '
import sys, json
maxlen = int(sys.argv[2])
stop = {s.replace("+", " ").strip().lower() for s in sys.argv[3].split() if s.strip()}
try:
    data = json.load(sys.stdin)
    existing = data[0].get("tags", []) if data else []
except Exception:
    existing = []
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
    [ -z "$merged" ] && merged="$taglist"
    printf '%s' "$merged"
}

# If a book's language is BLANK, set it to DEFAULT_LANG (calibre-web hides
# language-less books behind its language filter). Never overwrites a non-empty
# language. No-op if DEFAULT_LANG is empty. Best-effort; echoes a note via the
# caller's logging is left to the caller (this stays quiet to keep the lib clean).
fix_blank_language() {
    local id="$1"
    [ -n "$DEFAULT_LANG" ] || return 0
    local lang_json has_lang
    lang_json="$(cdb list -f languages -s "id:$id" --for-machine 2>/dev/null)"
    has_lang="$(printf '%s' "$lang_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("1" if (d and d[0].get("languages")) else "0")
except Exception:
    print("0")
' 2>/dev/null)"
    if [ "$has_lang" = "0" ]; then
        cdb set_metadata "$id" --field "languages:$DEFAULT_LANG" >/dev/null 2>&1 \
            && return 10   # 10 = "we set it" so caller can log; 0 = nothing to do
    fi
    return 0
}

# apply_tags id taglist md5 via -> merge + set tags + clear rating + stamp md5 +
# fix blank language. Returns 0 on success (echoes the merged taglist), 1 on
# calibredb failure. Sets APPLY_TAGS_SET_LANG=1 if it filled a blank language
# (so the caller can log it); cleared to 0 otherwise.
APPLY_TAGS_SET_LANG=0
apply_tags() {
    local id="$1" taglist="$2" md5="$3" via="${4:-fuzzy}" merged
    APPLY_TAGS_SET_LANG=0
    merged="$(merge_tags "$id" "$taglist")"
    if cdb set_metadata "$id" --field "tags:$merged" --field "rating:0" >/dev/null 2>&1; then
        # stamp md5 on a fuzzy match so the next lookup is exact
        if [ "$via" = "fuzzy" ] && [ -n "$md5" ]; then stamp_identifier "$id" "$md5"; fi
        # fill a blank language so calibre-web doesn't hide the book
        fix_blank_language "$id"; [ "$?" -eq 10 ] && APPLY_TAGS_SET_LANG=1
        printf '%s' "$merged"; return 0
    fi
    return 1
}

# version: TAG_LIB_VERSION 5