#!/usr/bin/env bash
TAG_QUEUE_VERSION="5"   # bump on every change; echoed at startup
# v5: REMOVE the GUI-lock skip. v4 (and earlier) bailed ("calibre app holds the
#     library lock — skipping tag-queue this cycle") whenever the always-on Calibre
#     GUI was running — which is ALWAYS — so the tag queue NEVER drained and
#     downloaded books stayed untagged. Same false-lock lesson as sweep-books v8
#     and sync-tag-to-shelf: the GUI's lock is shareable when calibredb runs AS
#     ROOT, which cdb() (from tag-lib.sh) already does. So the GUI is not a reason
#     to skip — removed that guard. The explicit calibre_is_busy FLAG check (a real
#     "heavy op in progress" signal, set via the homepage toggle / flag file) is
#     KEPT — that's intentional and distinct from the idle GUI.
# v4: also append to shared $GUNIT_LOG (~/logs/gunit.log), tagged [tq]; keeps journal output.
# =============================================================================
#  tag-queue.sh — drain the tag queue that fetch-books fills.
#
#  fetch-books appends {md5, tags, title, author, queued_at} to the queue file
#  for every book it downloads. This drains it: for each entry, find the book in
#  calibre (md5 identifier, else strict title/author match — shared tag-lib), and
#  if found, apply the tags and DROP the entry. Entries whose book isn't imported
#  yet stay queued for the next cycle. Entries older than EXPIRE_HOURS are dropped
#  (the download failed / never imported) so the queue can't accumulate zombies.
#
#  Designed to run right after sweep-books in the same service: the sweep imports
#  whatever's waiting, then this tags it — same cycle, no inter-run lag.
#
#  BUSY-AWARE: aborts if the calibre GUI is flagged BUSY (homepage toggle / flag
#  file), same as the sweep, so it never fights an active desktop session. NOTE
#  (v5): it does NOT abort merely because the GUI process is running — calibredb
#  runs as root and shares the GUI's library lock, so the queue drains while the
#  GUI is up.
#
#  USAGE:  ./tag-queue.sh            # drain the queue
#          ./tag-queue.sh --dry-run  # show what it WOULD tag, no writes
# =============================================================================
set -uo pipefail

# --- config ---
QUEUE="${TAG_QUEUE:-/home/robmorgan/gunit/config/tag-queue.json}"
# the queue is shared between root (timer) and the gunit user (fetch-books); we
# normalise ownership after each rewrite so neither locks the other out.
QUEUE_OWNER="${QUEUE_OWNER:-robmorgan}"
QUEUE_GROUP="${QUEUE_GROUP:-robmorgan}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CONFIDENCE="${CONFIDENCE:-0.6}"
ID_SCHEME="${ID_SCHEME:-annas}"
MAX_TAG_LEN="${MAX_TAG_LEN:-40}"
TAG_STOPLIST="${TAG_STOPLIST:-download apple+books books+on+iphone ipad mac kindle iphone calibre unknown}"
DEFAULT_LANG="${DEFAULT_LANG:-eng}"   # set this language when a book's language is blank (calibre-web hides blank-language books); empty disables
EXPIRE_HOURS="${EXPIRE_HOURS:-24}"     # drop entries older than this (never imported)
# busy-toggle (same semantics as sweep-books / watch-downloads)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
QUEUE_LOCK="${QUEUE_LOCK:-/run/gunit-tagqueue.lock}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true
LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [tq] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}
HERE="$(dirname "$0")"

command -v jq >/dev/null      || { LOG "FATAL: jq not installed"; exit 1; }
command -v python3 >/dev/null || { LOG "FATAL: python3 not installed"; exit 1; }
. "$HERE/match-lib.sh"   # book_match_score, ge, norm
. "$HERE/tag-lib.sh"     # find_book_id, apply_tags, cdb (uses the config above)

# single-instance guard (robust open, same pattern as sweep-books)
if ! exec 9>"$QUEUE_LOCK" 2>/dev/null; then
    QUEUE_LOCK="/tmp/gunit-tagqueue.$(id -u).lock"
    exec 9>"$QUEUE_LOCK" 2>/dev/null || QUEUE_LOCK=""
fi
if [ -n "$QUEUE_LOCK" ] && ! flock -n 9; then
    LOG "another tag-queue run is active — skipping"; exit 0
fi

# nothing to do if no queue file or empty queue
if [ ! -s "$QUEUE" ]; then
    exit 0
fi

# --- busy check (abort whole run; next cycle retries) ---
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
if calibre_is_busy; then
    LOG "calibre flagged BUSY — skipping tag-queue this cycle"; exit 0
fi

# v5: NO GUI-lock skip. The always-on GUI holds the library lock continuously;
# calibredb run as root (via cdb() / find_book_id / apply_tags from tag-lib.sh)
# shares that lock fine — proven by sweep-books v8 and sync-tag-to-shelf. The old
# guard here ("calibre app holds the library lock — skipping") meant the queue
# NEVER drained while the GUI was up (i.e. always), leaving books untagged. If a
# read genuinely hits a transient lock, find_book_id/apply_tags handle it per
# entry (a failed tag is kept in the queue for next cycle); we no longer abort the
# whole run for the mere existence of the GUI process.

LOG "=== tag-queue v$TAG_QUEUE_VERSION start (queue=$QUEUE dry-run=$DRY_RUN expire=${EXPIRE_HOURS}h) ==="

# read the queue as TSV lines: md5 \t tags \t title \t author \t queued_at(epoch)
mapfile -t entries < <(jq -r '.[] | [.md5, .tags, .title, .author, (.queued_at|tostring)] | @tsv' "$QUEUE" 2>/dev/null)
total="${#entries[@]}"
[ "$total" -eq 0 ] && { LOG "queue empty"; exit 0; }
LOG "queue has $total entr$([ "$total" -eq 1 ] && echo y || echo ies)"

now_epoch="$(date +%s)"
expire_secs=$(( EXPIRE_HOURS * 3600 ))
n_tagged=0 n_wait=0 n_expired=0

# we rebuild the kept-entries list as JSON; entries are kept unless tagged or expired
keep_json="$(mktemp)"
echo "[]" > "$keep_json"

for line in "${entries[@]}"; do
    IFS=$'\t' read -r md5 tags title author qat <<< "$line"
    [ -z "$md5" ] && [ -z "$title" ] && continue

    # try to locate the book
    local_found="$(find_book_id "$title" "$author" "$md5" 2>/dev/null)"
    if [ -n "$local_found" ]; then
        id="$(printf '%s' "$local_found" | cut -f1)"
        via="$(printf '%s' "$local_found" | cut -f2)"
        if [ "$DRY_RUN" -eq 1 ]; then
            LOG "  DRY: would tag id $id [$via] ($title — $author) += [$tags]"
            n_tagged=$((n_tagged+1))
            continue   # in dry-run, treat as satisfied for the count (don't keep)
        fi
        merged="$(apply_tags "$id" "$tags" "$md5" "$via")"
        if [ -n "$merged" ]; then
            LOG "  tagged id $id [$via] ($title — $author) -> [$merged]"
            [ "${APPLY_TAGS_SET_LANG:-0}" -eq 1 ] && LOG "    set language id $id -> $DEFAULT_LANG (was blank)"
            n_tagged=$((n_tagged+1))
            continue   # satisfied -> drop from queue (don't add to keep_json)
        else
            LOG "  FAILED to tag id $id ($title — $author) — keeping in queue"
            # fall through to keep
        fi
    else
        # not in library yet — check expiry
        if [ -n "$qat" ] && [ "$qat" -gt 0 ] 2>/dev/null; then
            age=$(( now_epoch - qat ))
            if [ "$age" -gt "$expire_secs" ]; then
                LOG "  EXPIRED ($((age/3600))h old, never imported): $title — $author — dropping"
                n_expired=$((n_expired+1))
                continue   # expired -> drop
            fi
        fi
        n_wait=$((n_wait+1))
    fi

    # keep this entry (waiting or failed-to-tag)
    keep_json="$(python3 -c '
import sys, json
f=sys.argv[1]
arr=json.load(open(f))
arr.append({"md5":sys.argv[2],"tags":sys.argv[3],"title":sys.argv[4],"author":sys.argv[5],"queued_at":int(sys.argv[6] or 0)})
json.dump(arr, open(f,"w"))
print(f)
' "$keep_json" "$md5" "$tags" "$title" "$author" "${qat:-0}")"
done

if [ "$DRY_RUN" -eq 0 ]; then
    # atomically replace the queue with the kept entries
    cp "$QUEUE" "${QUEUE}.bak" 2>/dev/null
    mv "$keep_json" "$QUEUE"
    # The queue is written by BOTH this script (often as root via the timer) and
    # fetch-books (as the normal user). mv installs a root-owned mktemp file,
    # which then blocks the user's next enqueue (PermissionError). Make it
    # owner+group writable and hand it to the configured owner so either can
    # write. QUEUE_OWNER/QUEUE_GROUP default to the gunit user.
    chmod 664 "$QUEUE" 2>/dev/null || true
    chown "${QUEUE_OWNER:-robmorgan}:${QUEUE_GROUP:-robmorgan}" "$QUEUE" 2>/dev/null || true
else
    rm -f "$keep_json"
fi

LOG "tag-queue done: tagged=$n_tagged waiting=$n_wait expired=$n_expired (of $total)"
# =============================================================================
# version: TAG_QUEUE_VERSION 5
# =============================================================================