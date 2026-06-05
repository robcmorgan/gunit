#!/usr/bin/env bash
TAG_LIB_VERSION="1"   # bump on every change
# =============================================================================
#  tag-lib.sh — shared calibre tagging logic for tag-books.sh and tag-queue.sh.
#
#  Source AFTER match-lib.sh (needs book_match_score, ge) and after the caller
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

cdb() { docker exec "$CALIBRE_CONTAINER" calibredb --library-path "$CALIBRE_LIBRARY" "$@"; }

# find a calibre book id. Args: f1 f2 md5. Echoes "<id>\t<via>" (via=id|fuzzy)
# or nothing. md5-identifier exact first, then strict-scored fuzzy fallback.
find_book_id() {
    local f1="$1" f2="$2" md5="$3"
    if [ -n "$md5" ]; then
        local exact
        exact="$(cdb search "identifiers:${ID_SCHEME}:${md5}" 2>/dev/null | tr ',' ' ')"
        set -- $exact
        if [ "$#" -ge 1 ]; then printf '%s\tid\n' "$1"; return 0; fi
    fi
    local ids="" field
    for field in "$f1" "$f2"; do
        local hit
        hit="$(cdb search "title:\"$field\"" 2>/dev/null | tr ',' ' ')"
        [ -z "$hit" ] && hit="$(cdb search "$field" 2>/dev/null | tr ',' ' ')"
        ids="$ids $hit"
    done
    ids="$(printf '%s\n' $ids | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    [ -z "$ids" ] && return 1
    local id best_id="" best_score="0.000" cand
    for id in $ids; do
        cand="$(cdb list -f title,authors -s "id:$id" --for-machine 2>/dev/null \
            | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); b = d[0] if d else {}
    a = b.get("authors", ""); a = " ".join(a) if isinstance(a, list) else a
    print((b.get("title","") + " " + a).strip())
except Exception: pass' 2>/dev/null)"
        [ -z "$cand" ] && continue
        local s; s="$(book_match_score "$f1" "$f2" "$cand")"
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

# apply_tags id taglist md5 via -> merge + set tags + clear rating + stamp md5.
# Returns 0 on success (echoes the merged taglist), 1 on calibredb failure.
apply_tags() {
    local id="$1" taglist="$2" md5="$3" via="${4:-fuzzy}" merged
    merged="$(merge_tags "$id" "$taglist")"
    if cdb set_metadata "$id" --field "tags:$merged" --field "rating:0" >/dev/null 2>&1; then
        # stamp md5 on a fuzzy match so the next lookup is exact
        if [ "$via" = "fuzzy" ] && [ -n "$md5" ]; then stamp_identifier "$id" "$md5"; fi
        printf '%s' "$merged"; return 0
    fi
    return 1
}
