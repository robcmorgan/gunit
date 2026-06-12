#!/bin/bash
SWEEP_BOOKS_VERSION="5"   # bump on every change; echoed at startup
#                          (version stamp also at end of file.)
# v5: success now DELETES the processed file (was: move to done/) — the book is
#     in the Calibre library, the loose copy is redundant. Import FAILURES now
#     move to a sibling witherrors/ folder (was: left loose to retry every slot).
#     Rationale: the watcher leaves its own misses loose, and THIS sweep is the
#     retry for them; so a failure HERE is the second attempt failing -> park it
#     for inspection rather than loop on it forever. Move a file out of
#     witherrors/ to retry. find scan now prunes witherrors/ (was done/).
#     Matches watch-downloads.sh v1 (same delete + witherrors convention).
# v4: also append to shared $GUNIT_LOG (~/logs/gunit.log), tagged [s]; keeps
#     journal output too.
# v3: (1) read users.json from web/ (the real path) not the non-existent config/
#     — previously every folder was "unmapped" so NOTHING was shelved/tagged.
#     (2) tag each user's imports with their users.json 'tag' (robm/robw) via
#     calibredb --tags at add (and set_metadata for dup-refused existing books).
#     (3) quieter logs: one outcome line per book, per-book shelve chatter folded
#     into a single "+N shelved" line, idle cycles (nothing to sweep) stay silent,
#     done-move logged only on failure. Every action line names the user.
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
#    * deletes processed files after a successful import; parks FAILED imports in
#      a sibling witherrors/ folder (skipped on re-run) instead of retrying forever.
#
#  Idempotent and safe to run every 15 min: imported files are gone, parked
#  failures (witherrors/) are skipped, only loose (new) files are considered.
#
#  USAGE:  ./sweep-books.sh            # real run
#          ./sweep-books.sh --dry-run  # show what it WOULD do
# =============================================================================
set -uo pipefail

# --- config (match the watcher) ---------------------------------------------
ROOT="${ROOT:-/Nutmeg/Media/Books/incoming/gunit_user_folders}"
# users.json lives under web/ (it's the dashboard's per-user file: greeting,
# shelf, tag — all keyed by the Cloudflare email = folder name = CW username).
# It was previously defaulted to config/users.json, which doesn't exist, so every
# folder was treated as unmapped and NOTHING was shelved or tagged. Point at the
# real path; override with USERS_JSON/MAPPING if it ever moves.
USERS_JSON="${USERS_JSON:-/home/robmorgan/gunit/web/users.json}"
MAPPING="${MAPPING:-$USERS_JSON}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
CW_APP_DB="${CW_APP_DB:-/home/robmorgan/cwa_config/app.db}"
MOUNT_HOST_ROOT="${MOUNT_HOST_ROOT:-/Nutmeg/Media/Books}"
MOUNT_CONTAINER_ROOT="${MOUNT_CONTAINER_ROOT:-/books}"
ERROR_DIR_NAME="${ERROR_DIR_NAME:-witherrors}"   # failed imports parked here
EXTS="${EXTS:-epub azw3 mobi fb2}"            # formats to sweep
# busy-toggle config (identical semantics to watch-downloads.sh)
CALIBRE_BUSY_FLAG="${CALIBRE_BUSY_FLAG:-/tmp/calibre-busy}"
BUSY_TTL_MIN="${BUSY_TTL_MIN:-30}"
BUSY_PREF_EMAIL="${BUSY_PREF_EMAIL:-shops@rob.me.uk}"
# only ONE sweep at a time, and never overlapping a previous slow sweep
SWEEP_LOCK="${SWEEP_LOCK:-/tmp/gunit-sweep.lock}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# LOG: keep stdout (the systemd journal captures it) AND append to the shared
# gunit log on disk, tagged [s]. The journal format stays as-is for
# `journalctl -u sweep-books.service`; the file line is timestamped + tagged.
GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true
LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [s] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}

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

# --- park a file whose import FAILED into a sibling witherrors/ folder, so it
#     isn't re-swept every slot. The watcher leaves its misses loose and this
#     sweep retries them; a failure here is that retry failing -> park for
#     inspection. Move a file back out of witherrors/ to retry. Best-effort: if
#     the move fails, leave it in place rather than lose track of it.
park_error() {
    local file="$1" fname err_dir
    fname="$(basename "$file")"
    err_dir="$(dirname "$file")/${ERROR_DIR_NAME:-witherrors}"
    if mkdir -p "$err_dir" 2>/dev/null && mv "$file" "$err_dir/" 2>/dev/null; then
        LOG "  import FAILED — moved to $ERROR_DIR_NAME/$fname"
    else
        LOG "  import FAILED and could not move to $ERROR_DIR_NAME/ — leaving in place"
    fi
}

import_one() {
    local file="$1"
    local email; email=$(basename "$(dirname "$file")")
    local fname; fname=$(basename "$file")

    # skip temp/partial files (same set as the watcher)
    case "$fname" in *.part|*.crdownload|*.tmp|.*) return 0;; esac

    local shelf; shelf=$(map_get "$email" "shelf")
    [ -z "$shelf" ] && return 0   # unmapped folder — ignore

    # the user's tag from users.json (e.g. robm / robw). Applied to the book at
    # import so each user's downloads are tagged with their own tag. Empty tag =
    # import untagged (still shelved). Tags are comma-separated if ever multiple.
    local usertag; usertag=$(map_get "$email" "tag")

    local do_shelve=1
    toggle_on "$email" || do_shelve=0

    local cpath="${file/#$MOUNT_HOST_ROOT/$MOUNT_CONTAINER_ROOT}"
    LOG "import: '$fname' for $email (shelf=$shelf tag=${usertag:-none} shelve=$do_shelve)"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$do_shelve" -eq 1 ]; then
            LOG "  [dry-run] would import${usertag:+ tagged '$usertag'} + shelve to '$shelf'"
        else
            LOG "  [dry-run] would import${usertag:+ tagged '$usertag'} to library only (kindleSync off — not shelved)"
        fi
        return 0
    fi

    # build the --tags arg only when there's a tag (avoids passing an empty value)
    local tagargs=()
    [ -n "$usertag" ] && tagargs=(--tags "$usertag")

    local out idlist
    out=$(calibredb_add "$cpath" "${tagargs[@]}")
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
            LOG "  already in library (id $idlist) — shelving existing"
            # the existing copy may lack this user's tag — add it (non-destructive,
            # calibredb merges tags) so per-user tagging holds for dup-refused books.
            if [ -n "$usertag" ]; then
                docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb set_metadata \
                    "$idlist" --field tags:"$usertag" --library-path "$CALIBRE_LIB" >/dev/null 2>&1 \
                    || LOG "  WARN: could not add tag '$usertag' to existing id $idlist"
            fi
        else
            LOG "  $hits matches (not confident) — adding fresh copy"
            out=$(calibredb_add "$cpath" --duplicates "${tagargs[@]}")
            idlist=$(echo "$out" | grep -oiE 'Added book ids[: ]+[0-9, ]+' \
                     | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
        fi
        [ -z "$idlist" ] && { LOG "  WARN: could not add/locate '$fname'. calibredb: $out"; return 1; }
    else
        LOG "  imported id(s) $idlist${usertag:+ tagged '$usertag'}"
    fi

    # shelve only if kindleSync on
    if [ "$do_shelve" -eq 1 ]; then
        local userid shelfid
        userid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM user WHERE name='$email';")
        shelfid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
        if [ -z "$userid" ] || [ -z "$shelfid" ]; then
            LOG "  WARN: user/shelf not found (user=$email shelf=$shelf) — imported, not shelved"
        else
            local lockfile="${CW_APP_DB}.shelflink.lock"
            local added=0 already=0 sfail=0
            (
              flock -w 10 8 || { LOG "  WARN: no shelf write lock; skipping shelf insert"; exit 1; }
              local bid
              for bid in $idlist; do
                local exists
                exists=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT 1 FROM book_shelf_link WHERE book_id=$bid AND shelf=$shelfid LIMIT 1;")
                [ -n "$exists" ] && { already=$((already+1)); continue; }
                local newid maxord
                newid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(id),0)+1 FROM book_shelf_link;")
                maxord=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM book_shelf_link WHERE shelf=$shelfid;")
                if sqlite3 "$CW_APP_DB" "PRAGMA busy_timeout=5000; INSERT INTO book_shelf_link (id,book_id,\"order\",shelf,date_added) VALUES ($newid,$bid,$maxord,$shelfid,datetime('now'));" >/dev/null; then
                    added=$((added+1))
                else
                    sfail=$((sfail+1))
                fi
              done
              # one summary line per book (not per shelf-row). Only mention
              # already/failed when non-zero, to keep it quiet on the common path.
              LOG "  shelved to '$shelf' (user $email): +$added${already:+, $already already}${sfail:+, $sfail FAILED}"
            ) 8>"$lockfile"
        fi
    fi

    # processed OK -> delete the loose file (its content is now in the Calibre
    # library, shelved if kindleSync was on). Quiet on success; only log a
    # failure to delete (the case you'd want to know about). Failures never reach
    # here — they return 1 earlier and are parked in witherrors/ by the caller.
    if [ -n "$idlist" ]; then
        rm -f "$file" 2>/dev/null \
            || LOG "  WARN: imported OK but could not delete '$fname' — leaving in place"
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

total=0; ok=0; fail=0
while IFS= read -r -d '' file; do
    case "$file" in */"$ERROR_DIR_NAME"/*) continue;; esac   # don't re-sweep parked failures
    # announce the run only once we actually have a file to import, so an idle
    # 15-min cycle (nothing to sweep) stays silent instead of logging a banner
    # + "considered=0" every time.
    if [ "$total" -eq 0 ]; then
        LOG "=== sweep-books v$SWEEP_BOOKS_VERSION (under $ROOT, formats='$EXTS'${DRY_RUN:+, dry-run}) ==="
    fi
    total=$((total+1))
    if import_one "$file"; then
        ok=$((ok+1))
    else
        fail=$((fail+1))
        # park the failure so it isn't retried every slot (dry-run never gets
        # here — import_one returns 0 on the dry-run path before any add).
        [ "$DRY_RUN" -eq 0 ] && park_error "$file"
    fi
    # re-check busy between files: if you start using the GUI mid-sweep, stop.
    if calibre_is_busy; then
        LOG "calibre became BUSY mid-sweep — stopping; remaining files wait for next slot"
        break
    fi
done < <(find "$ROOT" -type f \( "${find_args[@]}" \) -print0 2>/dev/null | sort -z)

# summarize only if we did something; silent on an idle cycle.
if [ "$total" -gt 0 ]; then
    LOG "sweep done: imported=$ok failed=$fail (of $total)"
    [ "$fail" -gt 0 ] && LOG "failures moved to $ERROR_DIR_NAME/ — inspect, then move back to retry."
fi
exit 0

# version: SWEEP_BOOKS_VERSION 5