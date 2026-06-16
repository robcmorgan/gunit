#!/bin/bash
SWEEP_BOOKS_VERSION="8"   # bump on every change; echoed at startup
#                          (version stamp also at end of file.)
# v8: RUN calibredb AS ROOT (drop -u 2001:2002). The sweep was the ONLY script
#     still invoking calibredb as uid 2001:2002; every other gunit script runs it
#     as root. Against this library that uid STRUCTURALLY collides with the
#     always-on GUI's root-held lock and returns "Another calibre program is
#     running" even when the db is NOT actually locked — so the sweep deferred
#     every add (e.g. 11 witherrors epubs deferred 11x while a root `calibredb
#     add` of the SAME file succeeded instantly). It was never a real lock or a
#     race; it was the forbidden -u invocation. All calibredb calls now go through
#     a single cdb() helper that runs as root (no -u), matching tag-lib.sh et al.
#     The lock-retry logic stays as a genuine-transient-lock backstop, but in
#     practice root adds no longer hit the false lock at all.
#     NOTE: new book files are now written into the library as root (as they
#     already are for every other script's adds) — consistent with the rest of
#     the stack; the old -u was protecting on-disk ownership that root adds across
#     the stack have not found to be a problem.
# v7: DON'T EXILE LOCK-CASUALTIES + SWEEP witherrors/ AS A RETRY SOURCE.
#     Two linked fixes to a v5 regression exposed by a GUI-lock storm:
#     (1) DEFER != FAIL. A deferred add (transient library lock — calibredb_add
#         exhausted its retries) returned non-zero exactly like a genuinely
#         failed add (corrupt/odd file). park_error then moved BOTH to witherrors/,
#         and the find-prune meant witherrors/ files were NEVER retried — so a
#         brief GUI lock permanently exiled perfectly good books. Now import_one
#         distinguishes: rc=2 = DEFERRED (lock) -> file left LOOSE to retry next
#         slot (nothing parked); rc=1 = REAL failure -> parked in witherrors/.
#     (2) SWEEP witherrors/ TOO. witherrors/ is now a retry SOURCE, not a dead
#         letter: each slot also scans it, so even genuinely-parked files get a
#         periodic re-attempt (a later-fixed lock, a re-added epub edition, etc.).
#         A witherrors file that imports is deleted like any other; one that fails
#         for real stays put (re-parked into the same dir = no-op). This makes the
#         sweep the universal safety net for BOTH its own deferrals and anything
#         that lands in witherrors, so nothing strands silently.
#     (3) Tidy: delete AppleDouble '._*' stubs (SMB/AFP cruft from a Mac touching
#         the share) on sight — they're not books and only cause confusion.
#     (4) Banner fix: the v6 startup banner used ${DRY_RUN:+, dry-run}, which
#         appended ", dry-run" whenever DRY_RUN was SET — and "0" is set — so every
#         REAL run mislabelled itself as a dry-run in the log. Cosmetic only (the
#         actual dry-run guards correctly test [ "$DRY_RUN" -eq 1 ]), but it sent
#         debugging down a false path. Now tests the value, not set-ness.
#     (5) EXCLUDE done/ FROM THE SWEEP. Since v5 a successful import DELETES the
#         file (no move to done/), so done/ should not grow — but pre-v5 runs left
#         hundreds of already-imported files in done/, and NOTHING excluded them
#         (v5 swapped the find-prune from done/ to witherrors/). So every sweep was
#         re-importing the entire legacy done/ set each slot — the "imported=350
#         every 15 min" churn, which also kept the library busy enough to feed the
#         lock contention that deferred real new imports. done/ is now skipped
#         again; witherrors/ remains swept. (The legacy done/ files can be deleted
#         at leisure — they're already in the library.)
# v6: STOP KILLING CALIBRE. calibredb_add no longer kills the GUI/server/parallel
#     to break a library lock — it waits and retries instead. WHY: the calibre
#     content server is EMBEDDED in the GUI process, and fetch-books' library
#     check reads THROUGH that server (--with-library). The old pkill killed the
#     GUI to win a write-lock race, which ALSO took down the content server, so
#     fetch-books reads then failed with "library check unavailable — deferring"
#     and the whole pipeline froze until the GUI rebooted. Lock sampling showed
#     the library free 30/30s — held only in brief, rare bursts — so a few short
#     retries clear essentially every real collision without killing anything. On
#     a persistent lock the add returns non-zero and the file is parked/retried
#     next slot. Matches watch-downloads.sh v2 (same no-kill calibredb_add).
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
#    * waits out a transient library lock on add and retries — NEVER kills (v6).
#    * imports to library always; shelves only if the user's kindleSync is ON
#      (matches the watcher's do_shelve logic exactly).
#    * deletes processed files after a successful import. A TRANSIENT-LOCK defer
#      leaves the file LOOSE to retry next slot; a REAL import failure is parked
#      in a sibling witherrors/ folder — which is ITSELF re-swept each slot (v7),
#      so even parked files get periodic retries and nothing strands forever.
#
#  Idempotent and safe to run every 15 min: imported files are gone; loose files
#  (new, or lock-deferred) and witherrors/ files are both reconsidered each slot.
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
ERROR_DIR_NAME="${ERROR_DIR_NAME:-witherrors}"   # failed imports parked here; ALSO re-swept (v7)
EXTS="${EXTS:-epub azw3 mobi fb2}"            # formats to sweep
# Lock-retry tuning: re-attempts for an add that hit a transient library lock,
# and the wait between tries. The lock is rarely held, so these small defaults
# clear almost every collision; a still-locked add after this is deferred (left
# loose, retried next slot) — NOT parked.
LOCK_RETRIES="${LOCK_RETRIES:-5}"
LOCK_WAIT="${LOCK_WAIT:-2}"
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

# --- reactive calibredb add (WAIT OUT a transient lock; NEVER kill) ----------
#     The library lock is held only in brief, rare bursts by the GUI (sampling
#     showed it free 30/30s). The old code killed all calibre processes to break
#     the lock — but the content server is EMBEDDED in the GUI, so that kill took
#     down the server fetch-books reads through, freezing the pipeline. We now
#     wait-and-retry; on a lock that persists past all retries we return the
#     output (no ids) and rc=2 so the caller DEFERS (leaves the file loose for
#     the next slot) rather than parking it. Nothing is ever killed.
#     Return: 0 = add ran (parse output for ids); 2 = lock persisted (defer).
# Single calibredb entry point — runs as ROOT in the container (NO -u), the only
# invocation that co-exists with the always-on GUI's lock. Mirrors tag-lib.sh's
# cdb(). CALIBRE_USER is retained for reference/other uses but is NO LONGER passed
# to calibredb (that was the false-lock bug fixed in v8).
cdb() { docker exec "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIB"; }

calibredb_add() {
    local path="$1"; shift
    local out attempt
    for (( attempt=1; attempt<=LOCK_RETRIES; attempt++ )); do
        out=$(cdb add "$path" "$@" 2>&1)
        # success / any non-lock outcome -> return it for the caller to parse
        echo "$out" | grep -qi 'Another calibre program' || { echo "$out"; return 0; }
        LOG "  library locked (attempt $attempt/$LOCK_RETRIES) — waiting ${LOCK_WAIT}s, NOT killing"
        sleep "$LOCK_WAIT"
    done
    LOG "  library still locked after $LOCK_RETRIES retries — deferring (will re-import next sweep)"
    echo "$out"
    return 2   # v7: distinct 'deferred (lock)' code so the caller leaves the file LOOSE, not parked
}

# --- ensure calibre container up (do NOT kill GUI up front) ------------------
if ! docker ps --filter "name=^${CALIBRE_CONTAINER}$" --filter "status=running" \
        --format '{{.Names}}' | grep -q "^${CALIBRE_CONTAINER}$"; then
    LOG "calibre container not running — starting it"
    docker start "$CALIBRE_CONTAINER" >/dev/null 2>&1 || { LOG "FATAL: can't start $CALIBRE_CONTAINER"; exit 1; }
    sleep 5
fi

# --- park a file whose import REALLY failed (not a lock defer) into a sibling
#     witherrors/ folder. v7: this is only ever called for genuine failures; a
#     transient-lock defer leaves the file loose (handled in the caller). Since
#     v7 also RE-SWEEPS witherrors/, a parked file still gets retried each slot —
#     so parking is "set aside, keep trying" rather than "exile forever".
#     If the file is ALREADY under witherrors/ (a re-swept parked file that
#     failed again), parking is a no-op move onto itself — skip the move, just
#     leave it where it is.
park_error() {
    local file="$1" fname err_dir
    fname="$(basename "$file")"
    # already in a witherrors/ dir? leave it; re-parking onto itself is pointless.
    case "$file" in
        */"$ERROR_DIR_NAME"/*) LOG "  still failing — left in $ERROR_DIR_NAME/$fname (will retry next slot)"; return 0;;
    esac
    err_dir="$(dirname "$file")/${ERROR_DIR_NAME:-witherrors}"
    if mkdir -p "$err_dir" 2>/dev/null && mv "$file" "$err_dir/" 2>/dev/null; then
        LOG "  import FAILED — moved to $ERROR_DIR_NAME/$fname (will retry next slot)"
    else
        LOG "  import FAILED and could not move to $ERROR_DIR_NAME/ — leaving in place"
    fi
}

# import_one return codes (v7):
#   0 = imported OK (or confidently matched existing) — file deleted
#   1 = REAL failure (add ran but produced/located no book) — caller parks it
#   2 = DEFERRED (transient library lock) — caller leaves file LOOSE for next slot
import_one() {
    local file="$1"
    local email fname
    # email = the user folder this file belongs to. For a file under
    # .../<email>/witherrors/<f>, the parent dir is witherrors, so walk up one
    # more level to recover the real email when needed.
    email=$(basename "$(dirname "$file")")
    [ "$email" = "$ERROR_DIR_NAME" ] && email=$(basename "$(dirname "$(dirname "$file")")")
    fname=$(basename "$file")

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

    local out add_rc idlist
    out=$(calibredb_add "$cpath" "${tagargs[@]}"); add_rc=$?
    # v7: a deferred add (lock persisted) is NOT a failure — bail with rc=2 so the
    # caller leaves the file loose for the next slot, instead of parking it.
    if [ "$add_rc" -eq 2 ]; then
        return 2
    fi
    idlist=$(echo "$out" | grep -oiE '(Added book ids|Merged book ids)[: ]+[0-9, ]+' \
             | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')

    if [ -z "$idlist" ]; then
        # duplicate refused -> confident single hard-match shelves existing,
        # else add a fresh copy (failure mode = extra book, never wrong book).
        local base author title
        base="${fname%.*}"; author="${base%% - *}"; title="${base#* - }"
        title="$(echo "$title" | sed -E 's/[[:space:]]*\([0-9]{4}\)[[:space:]]*$//')"
        author="$(echo "$author" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        title="$(echo "$title"  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        local found hits
        found=$(cdb search "authors:\"$author\" and title:\"$title\"" 2>/dev/null)
        hits=$(echo "$found" | grep -oE '[0-9]+' | sort -u | wc -l)
        if [ "$hits" -eq 1 ]; then
            idlist=$(echo "$found" | grep -oE '[0-9]+')
            LOG "  already in library (id $idlist) — shelving existing"
            # the existing copy may lack this user's tag — add it (non-destructive,
            # calibredb merges tags) so per-user tagging holds for dup-refused books.
            if [ -n "$usertag" ]; then
                cdb set_metadata "$idlist" --field tags:"$usertag" >/dev/null 2>&1 \
                    || LOG "  WARN: could not add tag '$usertag' to existing id $idlist"
            fi
        else
            LOG "  $hits matches (not confident) — adding fresh copy"
            out=$(calibredb_add "$cpath" --duplicates "${tagargs[@]}"); add_rc=$?
            if [ "$add_rc" -eq 2 ]; then
                return 2   # lock came back on the duplicates add — defer, don't park
            fi
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
    # here — they return 1/2 earlier and are parked/deferred by the caller.
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

# v7: opportunistically delete AppleDouble '._*' stubs (SMB/AFP cruft a Mac
# leaves when it touches the share). They're not books, they confuse listings,
# and the importer skips dotfiles anyway — so just remove them up front. Quiet.
while IFS= read -r -d '' stub; do
    [ "$DRY_RUN" -eq 1 ] && { LOG "  [dry-run] would remove AppleDouble stub: $(basename "$stub")"; continue; }
    rm -f "$stub" 2>/dev/null || true
done < <(find "$ROOT" -type f -name '._*' -print0 2>/dev/null)

total=0; ok=0; fail=0; deferred=0
# dry-run banner label. Use a value test, not ${DRY_RUN:+...} — that expansion
# fires whenever DRY_RUN is merely SET ("0" is set), which is why the v6 banner
# mislabelled every real run as ", dry-run". Test the actual value.
drylbl=""; [ "$DRY_RUN" -eq 1 ] && drylbl=", dry-run"
# v7: scan BOTH loose files AND witherrors/ files. witherrors/ is no longer
# pruned — it's a retry source. A successfully-imported parked file is deleted;
# one that fails again is left in place (park_error no-ops on a witherrors path).
# Everything else (busy re-check, one-at-a-time, dedupe) is unchanged.
while IFS= read -r -d '' file; do
    # Skip the legacy done/ folders. Since v5, a successful import DELETES the
    # file rather than moving it to done/, so done/ should no longer accumulate —
    # but pre-v5 runs left hundreds of already-imported files there, and nothing
    # excluded them, so every sweep was re-importing the whole legacy done/ set
    # (the "imported=350 every slot" churn). done/ is processed-and-finished;
    # never re-sweep it. (witherrors/, by contrast, IS swept — it's a retry source.)
    case "$file" in */done/*) continue;; esac
    # announce the run only once we actually have a file to import, so an idle
    # 15-min cycle (nothing to sweep) stays silent instead of logging a banner
    # + "considered=0" every time.
    if [ "$total" -eq 0 ]; then
        LOG "=== sweep-books v$SWEEP_BOOKS_VERSION (under $ROOT, formats='$EXTS', incl. $ERROR_DIR_NAME/$drylbl) ==="
    fi
    total=$((total+1))
    import_one "$file"; rc=$?
    case "$rc" in
        0) ok=$((ok+1)) ;;
        2) deferred=$((deferred+1)) ;;   # transient lock — leave loose, retry next slot
        *) fail=$((fail+1))
           # park genuine failures (no-op if already under witherrors/). dry-run
           # never reaches here (import_one returns 0 on the dry-run path).
           [ "$DRY_RUN" -eq 0 ] && park_error "$file" ;;
    esac
    # re-check busy between files: if you start using the GUI mid-sweep, stop.
    if calibre_is_busy; then
        LOG "calibre became BUSY mid-sweep — stopping; remaining files wait for next slot"
        break
    fi
done < <(find "$ROOT" -type f \( "${find_args[@]}" \) -print0 2>/dev/null | sort -z)

# summarize only if we did something; silent on an idle cycle.
if [ "$total" -gt 0 ]; then
    LOG "sweep done: imported=$ok deferred=$deferred failed=$fail (of $total)"
    [ "$deferred" -gt 0 ] && LOG "$deferred deferred on a library lock — left loose, will retry next slot."
    [ "$fail" -gt 0 ] && LOG "failures in $ERROR_DIR_NAME/ — re-swept each slot; inspect if one persists."
fi
exit 0

# version: SWEEP_BOOKS_VERSION 8