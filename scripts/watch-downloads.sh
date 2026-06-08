#!/bin/bash
# =============================================================================
#  watch-downloads.sh
#  Watches shelfmark's /books/<folder> subdirs. When a NEW book settles:
#    1. map the folder -> user (from users.json)
#    2. check that user's kindleSync toggle in userprefs/<prefEmail>.json
#    3. if ON: `calibredb add` the file (capturing the new book ID)
#    4. add that book ID to the user's calibre-web shelf
#
#  Shelf-is-boss design: this script only ADDS to the shelf. Tag mirroring is
#  done separately by the shelf<->tag sync, which runs on the shelf state.
#
#  "Settled file" = size unchanged for SETTLE_SECS (safe regardless of whether
#  shelfmark writes in place or via .part rename). If you confirm shelfmark
#  uses a temp name + rename, you can switch the inotify events to 'moved_to'
#  and drop the settle loop — cleaner, but this works either way.
# =============================================================================

set -uo pipefail

# --- config (override via env) ---
BOOKS_ROOT="${BOOKS_ROOT:-/Nutmeg/Media/Books/incoming/gunit_user_folders}"   # HOST path watched for new downloads
# How the books volume is mounted into the calibre container. The watcher sees
# files under the HOST root; calibredb (in the container) sees them under the
# CONTAINER root. Translation replaces one prefix with the other — this must be
# the MOUNT root, not BOOKS_ROOT, so it stays correct however deep BOOKS_ROOT is.
MOUNT_HOST_ROOT="${MOUNT_HOST_ROOT:-/Nutmeg/Media/Books}"
MOUNT_CONTAINER_ROOT="${MOUNT_CONTAINER_ROOT:-/books}"
MAPPING="${MAPPING:-/home/robmorgan/gunit/config/users.json}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CW_APP_DB="${CW_APP_DB:-/data/compose/1/calibre_web_config/app.db}"
SETTLE_SECS="${SETTLE_SECS:-15}"                          # size must be stable this long
# calibre library target for calibredb (TEST THIS — see notes in chat):
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
# Run calibredb as the SAME user the calibre app uses (abc), NOT root. Otherwise
# `docker exec` defaults to root (uid 0) and creates root-owned book files that
# the calibre GUI (running as abc) then cannot delete. abc == PUID/PGID here.
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
# Global import lock: serialises calibredb writes so concurrent imports queue
# instead of colliding on calibre's single-writer library lock.
IMPORT_LOCK="${IMPORT_LOCK:-/tmp/gunit-import.lock}"
# Processed books are moved into this per-user subfolder after import+shelve.
# The inotify --exclude below ignores it so the move doesn't retrigger.
DONE_DIR_NAME="${DONE_DIR_NAME:-done}"
LOG() { echo "[$(date '+%F %T')] $*"; }

command -v inotifywait >/dev/null || { LOG "FATAL: inotifywait not installed (apt install inotify-tools)"; exit 1; }
command -v jq >/dev/null          || { LOG "FATAL: jq not installed"; exit 1; }

# --- look up a mapping field by email: map_get <email> <field> ---
map_get() {
    jq -r --arg e "$1" --arg k "$2" \
        '.users[] | select(.email==$e) | .[$k] // empty' "$MAPPING"
}

# --- is kindleSync on for this prefEmail? ---
toggle_on() {
    local email="$1"
    local safe; safe=$(echo "$email" | sed 's/[^a-zA-Z0-9@._-]/_/g')
    local f="$PREFS_DIR/$safe.json"
    [ -f "$f" ] || { LOG "  no prefs file ($f) -> treat as OFF"; return 1; }
    local v; v=$(jq -r '.kindleSync // false' "$f" 2>/dev/null)
    [ "$v" = "true" ]
}

# --- wait until a file's size is stable, then return 0 (settled) / 1 (gone) ---
wait_settle() {
    local path="$1" last=-1 cur
    while true; do
        [ -f "$path" ] || return 1
        cur=$(stat -c %s "$path" 2>/dev/null) || return 1
        if [ "$cur" = "$last" ] && [ "$cur" -gt 0 ]; then return 0; fi
        last="$cur"
        sleep "$SETTLE_SECS"
    done
}

# --- is the user actively working in Calibre? -------------------------------
#  Two ways to signal "I'm using the Calibre desktop GUI, don't kill it":
#   1. The gunit homepage toggle (shops@rob.me.uk only) writes an EXPIRY
#      timestamp `calibreBusyUntil` (epoch seconds) into the user's prefs JSON;
#      busy iff that timestamp is in the future. Auto-expires (2h) by design.
#   2. A manual flag file (touch $CALIBRE_BUSY_FLAG), auto-expiring after
#      BUSY_TTL_MIN, as a terminal fallback.
#  (Automatic activity detection was tried — CPU/mtime/WAL/netstat — and none
#  were reliable in this container, so we use these explicit signals instead.)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
# Whose prefs carry the homepage busy toggle (only the desktop-GUI user).
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
calibre_is_busy() {
    # 1. homepage toggle: calibreBusyUntil epoch in the future?
    local safe pref until now
    safe=$(echo "$BUSY_PREF_EMAIL" | sed 's/[^a-zA-Z0-9@._-]/_/g')
    pref="$PREFS_DIR/$safe.json"
    if [ -f "$pref" ]; then
        until=$(jq -r '.calibreBusyUntil // 0' "$pref" 2>/dev/null)
        now=$(date +%s)
        if [ -n "$until" ] && [ "$until" -gt "$now" ] 2>/dev/null; then
            return 0   # busy via homepage toggle
        fi
    fi
    # 2. manual flag file, fresh within BUSY_TTL_MIN?
    [ -f "$CALIBRE_BUSY_FLAG" ] || return 1
    if find "$CALIBRE_BUSY_FLAG" -mmin "-${BUSY_TTL_MIN}" 2>/dev/null | grep -q .; then
        return 0
    fi
    rm -f "$CALIBRE_BUSY_FLAG" 2>/dev/null
    return 1
}

# --- run `calibredb add`, killing any lock-holder and retrying if the library
#     lock blocks us. Echoes calibredb's output; caller parses the ids.
#     Extra args (e.g. --duplicates) are passed through.
#     The lock can be held by the desktop GUI (/opt/calibre/bin/calibre), the
#     content server (calibre-server), or calibre-parallel — launched however
#     (incl. via Selkies). We can't reliably predict which, so we react: if the
#     add fails with calibre's "Another calibre program is running" message, we
#     kill those lock-holders (NOT calibredb itself) and retry once.
calibredb_add() {
    local path="$1"; shift
    local extra=( "$@" )
    local out
    out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$path" \
            --library-path "$CALIBRE_LIB" "${extra[@]}" 2>&1)

    # If a calibre program holds the library lock, decide what to do.
    if echo "$out" | grep -qi 'Another calibre program'; then
        if calibre_is_busy; then
            # The user has flagged that they're actively using Calibre — do NOT
            # kill. Signal a deferral; the caller leaves the book in place and
            # the periodic sweep retries later (once the flag expires / is cleared).
            LOG "  library locked AND calibre-busy flag is set — NOT killing; deferring '$path' for a later sweep"
            echo "__GUNIT_DEFER__"
            return 0
        fi
        LOG "  library lock held by a calibre program (no busy flag) — killing lock-holders and retrying"
        # Kill GUI / server / parallel workers, but NOT calibredb (our importer).
        docker exec "$CALIBRE_CONTAINER" sh -c \
            "pkill -f '/opt/calibre/bin/calibre(\$| )'; \
             pkill -f 'calibre-server'; \
             pkill -f 'calibre-parallel'" 2>/dev/null
        sleep 3   # let the lock release
        out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$path" \
                --library-path "$CALIBRE_LIB" "${extra[@]}" 2>&1)
        if echo "$out" | grep -qi 'Another calibre program'; then
            LOG "  WARN: library still locked after kill+retry — something is persistently holding it"
        fi
    fi
    echo "$out"
}

process_file() {
    local path="$1"
    local event="${2:-}"
    # The download folder name IS the user's email (Cloudflare login == folder
    # == Calibre-Web username == prefs filename basis). One identifier, end to end.
    local email; email=$(basename "$(dirname "$path")")
    local file;  file=$(basename "$path")

    # ignore temp/partial files outright
    case "$file" in
        *.part|*.crdownload|*.tmp|.*) LOG "  skip temp file: $file"; return ;;
    esac

    local shelf tag
    shelf=$(map_get "$email" "shelf")
    tag=$(map_get   "$email" "tag")
    if [ -z "$shelf" ]; then return; fi   # not a mapped user folder — ignore silently

    # email is the CW username too
    local cwUser="$email"

    # kindleSync toggle controls SHELVING ONLY — every download is still imported
    # into the Calibre library. If the toggle is off, we import as normal but skip
    # adding the book to the user's Kindle shelf. (Evaluated here, applied below.)
    local do_shelve=1
    if ! toggle_on "$email"; then
        do_shelve=0
        LOG "  kindleSync OFF for $email -> will import to library but NOT shelve '$file'"
    fi

    # DEDUP: multiple inotify events can fire for one file (observed: 3 concurrent
    # imports of the same book). Take a per-file lock (non-blocking) so only ONE
    # process handles a given path; duplicate events bail immediately.
    local pf_lock="/tmp/gunit-watch.$(echo "$path" | md5sum | cut -d' ' -f1).lock"
    exec 8>"$pf_lock"
    if ! flock -n 8; then
        LOG "  already processing '$file' (duplicate event) — skipping"
        return
    fi
    # lock held on FD 8 for the rest of this function; released on return/exit.

    # moved_to means an atomic rename INTO the folder: the file is already
    # complete, so don't wait. close_write means it may have been written in
    # place, so settle-check to be safe. (shelfmark appears to move-in, so the
    # fast path is the norm.)
    if [ "$event" = "MOVED_TO" ]; then
        LOG "  arrived atomically (moved_to) — no settle needed"
    else
        LOG "  written in place (close_write) — settling: $path"
        if ! wait_settle "$path"; then LOG "  file vanished before settle: $path"; return; fi
    fi
    LOG "  importing to Calibre: $file"

    # The watcher sees the HOST path (under $BOOKS_ROOT), but calibredb runs
    # INSIDE the calibre container where that same dir is mounted at /books.
    # Translate host path -> container path before handing it to calibredb.
    local cpath="${path/#$MOUNT_HOST_ROOT/$MOUNT_CONTAINER_ROOT}"
    LOG "  host path:      $path"
    LOG "  container path: $cpath"

    # GLOBAL IMPORT LOCK: calibredb allows only ONE writer at a time. If many
    # files arrive at once (e.g. a batch re-trigger, or a burst of downloads),
    # parallel process_file instances would all run calibredb simultaneously and
    # collide ("Another calibre program is running"), failing most imports. Take
    # a BLOCKING global lock so imports queue and run one at a time. (Real usage
    # delivers books one-at-a-time so this rarely waits; it just prevents the
    # thundering-herd failure when many fire together.)
    exec 7>"$IMPORT_LOCK"
    flock 7        # blocks until we hold it (no -n: we WANT to wait our turn)

    # CONTAINER CHECK: the import runs `docker exec calibre calibredb ...`, which
    # REQUIRES the calibre container to be running. If it's stopped, every import
    # fails with "container is not running" and the book is stranded. Check first
    # and fail loudly (don't silently strand). Try to start it; if that fails,
    # skip this file — the periodic sweep (if installed) or a re-drop will retry.
    if ! docker ps --filter "name=^${CALIBRE_CONTAINER}$" --filter "status=running" \
            --format '{{.Names}}' | grep -q "^${CALIBRE_CONTAINER}$"; then
        LOG "  calibre container '$CALIBRE_CONTAINER' is NOT running — attempting to start it"
        if docker start "$CALIBRE_CONTAINER" >/dev/null 2>&1; then
            sleep 5   # let it come up before we exec calibredb
            LOG "  started '$CALIBRE_CONTAINER'"
        else
            LOG "  ERROR: could not start '$CALIBRE_CONTAINER' — skipping '$file' (will retry on re-drop/sweep)"
            flock -u 7 2>/dev/null
            return
        fi
    fi

    # GUI-LOCK is now handled REACTIVELY: instead of trying to predict and kill
    # the lock-holder up front (which missed cases — calibre-server, GUI launched
    # via a different path through Selkies, etc.), we run calibredb and, IF it
    # fails with "Another calibre program is running", kill the lock-holders and
    # retry. See calibredb_add() above. This works regardless of HOW the GUI/server
    # got started, and only kills when there's an actual conflict.

    local out idlist
    out=$(calibredb_add "$cpath")

    # If the import was deferred (calibre busy + flag set), leave the book in
    # place (not shelved, not moved to done/) so the periodic sweep retries it.
    if echo "$out" | grep -q '__GUNIT_DEFER__'; then
        LOG "  deferred '$file' (calibre busy) — left in place for the sweep"
        flock -u 7 2>/dev/null
        return
    fi

    # Parse the clean "Added book ids: N" line (new book — the common case).
    idlist=$(echo "$out" \
        | grep -oiE '(Added book ids|Merged book ids)[: ]+[0-9, ]+' \
        | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')

    if [ -z "$idlist" ]; then
        # Refused as a duplicate. Try a HARD match (exact author AND title) to
        # find THE existing copy — but only dedupe if we're CONFIDENT (exactly
        # one hit). Zero or multiple hits => not confident => add a fresh copy
        # with --duplicates. Failure mode is always "an extra book", never
        # "the wrong book shelved". (Author+title both come from the filename
        # convention "Author - Title (year)".)
        local base author title
        base=$(basename "$file"); base="${base%.*}"           # drop extension
        author="${base%% - *}"                                # text before first " - "
        title="${base#* - }"                                  # text after first " - "
        title="$(echo "$title" | sed -E 's/[[:space:]]*\([0-9]{4}\)[[:space:]]*$//')"  # drop trailing (year)
        author="$(echo "$author" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        title="$(echo "$title"  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        LOG "  duplicate refused. Hard-matching author='$author' title='$title'"

        local found hits
        found=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb search \
                  "authors:\"$author\" and title:\"$title\"" \
                  --library-path "$CALIBRE_LIB" 2>/dev/null)
        # count matches (comma-separated id list)
        hits=$(echo "$found" | grep -oE '[0-9]+' | sort -u | wc -l)

        if [ "$hits" -eq 1 ]; then
            idlist=$(echo "$found" | grep -oE '[0-9]+')
            LOG "  confident single match -> shelving existing book $idlist"
        else
            LOG "  $hits matches (not confident) -> adding a fresh copy with --duplicates"
            out=$(calibredb_add "$cpath" --duplicates)
            idlist=$(echo "$out" \
                | grep -oiE 'Added book ids[: ]+[0-9, ]+' \
                | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
            LOG "  added fresh copy as book id(s): $idlist"
        fi

        if [ -z "$idlist" ]; then
            LOG "  WARN: could not add or locate book. calibredb said: $out"
            flock -u 7 2>/dev/null   # release import lock before returning
            return
        fi
    else
        LOG "  imported as book id(s): $idlist"
    fi

    # calibredb work is done — release the global import lock so the next queued
    # import can begin. Shelving below writes calibre-web's app.db (separate lock).
    flock -u 7 2>/dev/null

    # SHELVING — only if kindleSync is on for this user. Either way the book is
    # already imported into the library above; this just controls the Kindle shelf.
    if [ "$do_shelve" -eq 1 ]; then
        # add to the user's shelf by writing book_shelf_link in calibre-web's db.
        # (calibre-web has no CLI; the shelf link lives in app.db.)
        local userid shelfid
        userid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM user WHERE name='$cwUser';")
        shelfid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
        if [ -z "$userid" ] || [ -z "$shelfid" ]; then
            LOG "  WARN: user/shelf not found in app.db (user='$cwUser' shelf='$shelf'); imported but not shelved"
        else
            # Serialise our own backgrounded writers with a flock, AND set a SQLite
            # busy_timeout so we also wait politely if calibre-web itself is mid-write.
            local lockfile="${CW_APP_DB}.shelflink.lock"
            (
              flock -w 10 9 || { LOG "  WARN: couldn't acquire write lock; skipping shelf insert"; exit 1; }
              for bookid in $idlist; do
                local already
                already=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT 1 FROM book_shelf_link WHERE shelf=$shelfid AND book_id=$bookid LIMIT 1;")
                if [ -n "$already" ]; then LOG "  book $bookid already on shelf '$shelf' — skip"; continue; fi
                local nextorder nextid
                nextorder=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM book_shelf_link WHERE shelf=$shelfid;")
                nextid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(id),0)+1 FROM book_shelf_link;")
                if sqlite3 "$CW_APP_DB" "PRAGMA busy_timeout=5000; INSERT INTO book_shelf_link (id, book_id, shelf, \"order\", date_added) VALUES ($nextid, $bookid, $shelfid, $nextorder, datetime('now'));" >/dev/null; then
                    LOG "  ✔ added book $bookid to shelf '$shelf' (user $cwUser)"
                else
                    LOG "  WARN: failed to insert shelf link for book $bookid (db locked?)"
                fi
              done
            ) 9>"$lockfile"
        fi
    else
        LOG "  (kindleSync off) imported book id(s):$idlist to library — not added to shelf"
    fi

    # NOTE: previously we triggered sync-shelf-tags here so the Calibre tag was
    # applied immediately after a new shelf entry. That's no longer urgent: OPDS
    # exposes calibre-web shelves DIRECTLY (per-user), so the shelf is what the
    # Kindle sees — the Calibre tag is just organisational metadata. The 15-min
    # sync timer keeps tags eventually-consistent; no need for an instant trigger.

    # Move the processed book into a per-user done/ folder, so it's out of the
    # active queue and a later backfill run won't re-import it. (The inotify
    # watcher EXCLUDES /done/ so this move does not trigger a fresh event.)
    # Only move if we actually have ids (i.e. it imported); failures stay put.
    if [ -n "$idlist" ]; then
        local done_dir="$(dirname "$path")/${DONE_DIR_NAME:-done}"
        local mverr mvrc
        mverr=$( { mkdir -p "$done_dir" && mv "$path" "$done_dir/"; } 2>&1 ); mvrc=$?
        if [ "$mvrc" -eq 0 ]; then
            LOG "  moved to: ${DONE_DIR_NAME:-done}/$file"
        else
            LOG "  WARN: imported OK but could not move to ${DONE_DIR_NAME:-done}/ — leaving in place. Error: $mverr"
        fi
    fi
}

LOG "watch-downloads starting. Watching $BOOKS_ROOT (settle=${SETTLE_SECS}s)"
LOG "mapping=$MAPPING  prefs=$PREFS_DIR  calibre=$CALIBRE_CONTAINER"

# -m monitor, -r recursive. moved_to = atomic rename-in (complete by definition);
# close_write = file written in place (may need a settle check). We capture the
# event so process_file can skip waiting when the file arrived atomically.
# Exclude Calibre's own structural dirs and hidden files — otherwise we'd fire
# on every metadata.db / notes.db write Calibre makes, which is noise AND a
# feedback risk (our imports update metadata.db -> more events). We only care
# about files dropped into the per-user download subfolders.
#   --exclude is a POSIX-extended regex matched against the full path.
inotifywait -m -r -e close_write -e moved_to \
    --exclude '/(Calibre|done|\.calnotes|metadata\.db|metadata_db_prefs_backup\.json|\.[^/]+)(/|$)' \
    --format '%e|%w%f' "$BOOKS_ROOT" |
while IFS='|' read -r event path; do
    [ -f "$path" ] || continue
    LOG "event[$event]: $path"
    process_file "$path" "$event" &     # background so a long settle doesn't block the queue
done