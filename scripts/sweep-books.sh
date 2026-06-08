#!/bin/bash
SWEEP_BOOKS_VERSION="2"   # bump on every change; echoed at startup
# =============================================================================
#  sweep-books.sh — periodic catch-up importer for files the inotify watcher
#  missed (events lost while the service was down, or writes the host inotify
#  never saw). Designed to run on a 15-min timer ALONGSIDE watch-downloads.sh.
#
#  WHY (vs backfill-books.sh): backfill kills the Calibre desktop GUI UNCONDITION-
#  ALLY up front and only handles *.epub. That fights the calibreBusy toggle you
#  built to protect GUI sessions, and ignores azw3/mobi/fb2. This sweep instead:
#    * ABORTS the whole run if calibre is flagged busy (homepage toggle or flag
#      file) — never disturbs an active GUI session.
#    * handles ALL ebook formats (epub azw3 mobi fb2, configurable).
#    * imports STRICTLY ONE AT A TIME (no concurrency, no library-lock collisions).
#    * reuses the watcher's REACTIVE lock handling: only kills a lock-holder if an
#      add actually fails with "Another calibre program", and only when NOT busy.
#    * imports to library always; shelves only if the user's kindleSync is ON
#      (matches the watcher's do_shelve logic exactly).
#    * moves processed files to per-user done/ (skipped on re-run); failures stay.
#
#  Idempotent and safe to run every 15 min: done/ files are skipped, only loose
#  (new/failed) files are considered, so no duplicate imports.
#
#  USAGE:  ./sweep-books.sh            # real run
#          ./sweep-books.sh --dry-run  # show what it WOULD do
# =============================================================================
set -uo pipefail

# --- config (match the watcher) ---------------------------------------------
ROOT="${ROOT:-/Nutmeg/Media/Books/incoming/gunit_user_folders}"
USERS_JSON="${USERS_JSON:-/home/robmorgan/gunit/web/users.json}"
MAPPING="${MAPPING:-/home/robmorgan/gunit/web/users.json}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
CW_APP_DB="${CW_APP_DB:-/home/robmorgan/cwa_config/app.db}"
MOUNT_HOST_ROOT="${MOUNT_HOST_ROOT:-/Nutmeg/Media/Books}"
MOUNT_CONTAINER_ROOT="${MOUNT_CONTAINER_ROOT:-/books}"
DONE_DIR_NAME="${DONE_DIR_NAME:-done}"
EXTS="${EXTS:-epub azw3 mobi fb2}"            # formats to sweep
# busy-toggle config (identical semantics to watch-downloads.sh)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
# only ONE sweep at a time, and never overlapping a previous slow sweep
SWEEP_LOCK="${SWEEP_LOCK:-/tmp/gunit-sweep.lock}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

LOG() { echo "[$(date '+%F %T')] $*"; }

command -v jq >/dev/null      || { LOG "FATAL: jq not installed"; exit 1; }
command -v sqlite3 >/dev/null || { LOG "FATAL: sqlite3 not installed"; exit 1; }
[ -f "$MAPPING" ] || { LOG "FATAL: users.json not found at $MAPPING"; exit 1; }

# --- single-instance guard: if a prior sweep is still running, exit quietly --
# Use a lock path that's stable regardless of who runs the script (root via the
# timer, or you by hand). Open the FD explicitly and distinguish "couldn't open
# the lock file" (permission/path problem — warn, don't silently mis-skip) from
# "lock is held by a live sweep" (the real contention case).
SWEEP_LOCK="${SWEEP_LOCK:-/run/gunit-sweep.lock}"
if ! exec 9>"$SWEEP_LOCK" 2>/dev/null; then
    # /run may not be writable in some contexts; fall back to /tmp with a
    # user-qualified name so root and you don't collide on ownership.
    SWEEP_LOCK="/tmp/gunit-sweep.$(id -u).lock"
    if ! exec 9>"$SWEEP_LOCK" 2>/dev/null; then
        LOG "WARN: cannot open lock file ($SWEEP_LOCK) — running without single-instance guard"
        SWEEP_LOCK=""
    fi
fi
if [ -n "$SWEEP_LOCK" ]; then
    if ! flock -n 9; then
        LOG "another sweep is still running — skipping this slot"; exit 0
    fi
fi

# --- busy check (verbatim semantics from watch-downloads.sh) ----------------
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

# ABORT THE WHOLE RUN if busy — do not touch calibre at all. The next 15-min
# slot will try again; once you clear the toggle, the backlog sweeps in.
if calibre_is_busy; then
    LOG "calibre flagged BUSY (homepage toggle / flag) — skipping sweep this slot"
    exit 0
fi

# --- mapping lookups ---------------------------------------------------------
map_get() { jq -r --arg e "$1" --arg k "$2" '.users[] | select(.email==$e) | .[$k] // empty' "$MAPPING"; }
toggle_on() {
    local email="$1" safe f v
    safe=$(echo "$email" | sed 's/[^a-zA-Z0-9@._-]/_/g')
    f="$PREFS_DIR/$safe.json"
    [ -f "$f" ] || return 1
    v=$(jq -r '.kindleSync // false' "$f" 2>/dev/null)
    [ "$v" = "true" ]
}

# --- reactive calibredb add (kill lock-holders ONLY on real conflict, and only
#     because we already confirmed NOT busy above) -----------------------------
calibredb_add() {
    local path="$1"; shift
    local out
    out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$path" \
            --library-path "$CALIBRE_LIB" "$@" 2>&1)
    if echo "$out" | grep -qi 'Another calibre program'; then
        # not busy (checked at top) — safe to clear the lock-holder and retry once
        LOG "  library lock held — killing lock-holders (not busy) and retrying"
        docker exec "$CALIBRE_CONTAINER" sh -c \
            "pkill -f '/opt/calibre/bin/calibre(\$| )'; pkill -f 'calibre-server'; pkill -f 'calibre-parallel'" 2>/dev/null
        sleep 3
        out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$path" \
                --library-path "$CALIBRE_LIB" "$@" 2>&1)
    fi
    echo "$out"
}

# --- ensure calibre container up (do NOT kill GUI up front) ------------------
if ! docker ps --filter "name=^${CALIBRE_CONTAINER}$" --filter "status=running" \
        --format '{{.Names}}' | grep -q "^${CALIBRE_CONTAINER}$"; then
    LOG "calibre container not running — starting it"
    docker start "$CALIBRE_CONTAINER" >/dev/null 2>&1 || { LOG "FATAL: can't start $CALIBRE_CONTAINER"; exit 1; }
    sleep 5
fi

import_one() {
    local file="$1"
    local email; email=$(basename "$(dirname "$file")")
    local fname; fname=$(basename "$file")

    # skip temp/partial files (same set as the watcher)
    case "$fname" in *.part|*.crdownload|*.tmp|.*) return 0;; esac

    local shelf; shelf=$(map_get "$email" "shelf")
    [ -z "$shelf" ] && return 0   # unmapped folder — ignore

    local do_shelve=1
    toggle_on "$email" || do_shelve=0

    local cpath="${file/#$MOUNT_HOST_ROOT/$MOUNT_CONTAINER_ROOT}"
    LOG "  importing: $fname  (user=$email shelf=$shelf shelve=$do_shelve)"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$do_shelve" -eq 1 ]; then
            LOG "    [dry-run] would import + shelve to '$shelf'"
        else
            LOG "    [dry-run] would import to library only (kindleSync off — not shelved)"
        fi
        return 0
    fi

    local out idlist
    out=$(calibredb_add "$cpath")
    idlist=$(echo "$out" | grep -oiE '(Added book ids|Merged book ids)[: ]+[0-9, ]+' \
             | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')

    if [ -z "$idlist" ]; then
        # duplicate refused -> confident single hard-match shelves existing,
        # else add a fresh copy (failure mode = extra book, never wrong book)
        local base author title
        base="${fname%.*}"; author="${base%% - *}"; title="${base#* - }"
        title="$(echo "$title" | sed -E 's/[[:space:]]*\([0-9]{4}\)[[:space:]]*$//')"
        author="$(echo "$author" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        title="$(echo "$title"  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        local found hits
        found=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb search \
                  "authors:\"$author\" and title:\"$title\"" --library-path "$CALIBRE_LIB" 2>/dev/null)
        hits=$(echo "$found" | grep -oE '[0-9]+' | sort -u | wc -l)
        if [ "$hits" -eq 1 ]; then
            idlist=$(echo "$found" | grep -oE '[0-9]+')
            LOG "    confident single match -> shelving existing book $idlist"
        else
            LOG "    $hits matches (not confident) -> adding fresh copy with --duplicates"
            out=$(calibredb_add "$cpath" --duplicates)
            idlist=$(echo "$out" | grep -oiE 'Added book ids[: ]+[0-9, ]+' \
                     | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
        fi
        [ -z "$idlist" ] && { LOG "    WARN: could not add/locate. calibredb: $out"; return 1; }
    else
        LOG "    imported as book id(s): $idlist"
    fi

    # shelve only if kindleSync on
    if [ "$do_shelve" -eq 1 ]; then
        local userid shelfid
        userid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM user WHERE name='$email';")
        shelfid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
        if [ -z "$userid" ] || [ -z "$shelfid" ]; then
            LOG "    WARN: user/shelf not found (user=$email shelf=$shelf) — imported, not shelved"
        else
            local lockfile="${CW_APP_DB}.shelflink.lock"
            (
              flock -w 10 8 || { LOG "    WARN: no shelf write lock; skipping shelf insert"; exit 1; }
              local bid
              for bid in $idlist; do
                local exists
                exists=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT 1 FROM book_shelf_link WHERE book_id=$bid AND shelf=$shelfid LIMIT 1;")
                [ -n "$exists" ] && { LOG "    book $bid already on '$shelf' — skip"; continue; }
                local newid maxord
                newid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(id),0)+1 FROM book_shelf_link;")
                maxord=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM book_shelf_link WHERE shelf=$shelfid;")
                if sqlite3 "$CW_APP_DB" "PRAGMA busy_timeout=5000; INSERT INTO book_shelf_link (id,book_id,\"order\",shelf,date_added) VALUES ($newid,$bid,$maxord,$shelfid,datetime('now'));" >/dev/null; then
                    LOG "    ✔ added book $bid to shelf '$shelf' (user $email)"
                else
                    LOG "    WARN: failed shelf insert for book $bid (db locked?)"
                fi
              done
            ) 8>"$lockfile"
        fi
    else
        LOG "    (kindleSync off) imported $idlist to library — not shelved"
    fi

    # move processed file to per-user done/ (only on success)
    if [ -n "$idlist" ]; then
        local done_dir; done_dir="$(dirname "$file")/$DONE_DIR_NAME"
        if mkdir -p "$done_dir" 2>/dev/null && mv "$file" "$done_dir/" 2>/dev/null; then
            LOG "    moved to: $DONE_DIR_NAME/$fname"
        else
            LOG "    WARN: imported OK but could not move to $DONE_DIR_NAME/ — leaving in place"
        fi
    fi
    return 0
}

# build the find expression for all extensions
find_args=()
first=1
for e in $EXTS; do
    if [ "$first" -eq 1 ]; then find_args+=( -iname "*.$e" ); first=0
    else find_args+=( -o -iname "*.$e" ); fi
done

LOG "=== sweep-books v$SWEEP_BOOKS_VERSION starting under $ROOT (dry-run=$DRY_RUN, formats='$EXTS') ==="
total=0; ok=0; fail=0
while IFS= read -r -d '' file; do
    case "$file" in */"$DONE_DIR_NAME"/*) continue;; esac
    total=$((total+1))
    if import_one "$file"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    # re-check busy between files: if you start using the GUI mid-sweep, stop.
    if calibre_is_busy; then
        LOG "calibre became BUSY mid-sweep — stopping; remaining files wait for next slot"
        break
    fi
done < <(find "$ROOT" -type f \( "${find_args[@]}" \) -print0 2>/dev/null | sort -z)

LOG "sweep complete. considered=$total ok=$ok failed=$fail"
[ "$fail" -gt 0 ] && LOG "failures left in place; will retry next slot."
exit 0