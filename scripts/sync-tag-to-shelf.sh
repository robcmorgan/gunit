#!/bin/bash
SYNC_TAG_SHELF_VERSION="9"   # bump on every change; echoed at startup
# v9: default CONFIG path corrected to web/shelves.json (the deployed location).
#     Was config/tag-shelf-sync.json, which was never deployed there, so the
#     timer-driven sync fataled "config not found" every cycle while manual runs
#     with an explicit CONFIG=… worked. Pure path fix; no logic change. Verified:
#     additive run added the Summer Reads batch with zero erroneous removals.
# v8: also append to shared $GUNIT_LOG (~/logs/gunit.log), tagged [sh]; keeps journal output.
# =============================================================================
#  sync-tag-to-shelf.sh   (TAG IS BOSS — opposite direction to sync-shelf-tags.sh)
#
#  For each configured pair, makes a Calibre-Web SHELF exactly mirror the set of
#  Calibre books carrying a TAG:
#    - book has the tag but is NOT on the shelf  -> ADD to shelf
#    - book is on the shelf but does NOT have the tag -> REMOVE from shelf
#    - book in both -> left alone
#  One-way: the TAG is the source of truth; the shelf is rewritten to match.
#
#  Pairs are configured in tag-shelf-sync.json (NOT users.json) so this never
#  collides with the shelf->tag sync. Each pair: {tag, shelf, user, enabled}.
#  A shelf is identified by NAME + OWNER (shelf names aren't globally unique —
#  e.g. three different users each have a 'forKindle').
#
#  SAFETY: if the TAG query returns ZERO books, the REMOVE phase is SKIPPED for
#  that pair (a transient calibre hiccup or a typo'd tag must never empty a
#  shelf). Override per-run with --allow-empty only if you really mean to clear.
#  Also skips cleanly if the calibre GUI holds the library lock.
#
#  USAGE:  ./sync-tag-to-shelf.sh            # real run, all enabled pairs
#          ./sync-tag-to-shelf.sh --dry-run  # show add/remove diff, no writes
#          ./sync-tag-to-shelf.sh --allow-empty   # permit emptying a shelf
# =============================================================================
set -uo pipefail

# --- config ---
CONFIG="${CONFIG:-/home/robmorgan/gunit/web/shelves.json}"
CW_APP_DB="${CW_APP_DB:-/home/robmorgan/cwa_config/app.db}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
DRY_RUN=0
ALLOW_EMPTY=0
FORCE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --allow-empty) ALLOW_EMPTY=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 1 ;;
    esac
done

GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true
LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [sh] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}
DBRO="file:$CW_APP_DB?mode=ro"

command -v jq >/dev/null      || { LOG "FATAL: jq not installed"; exit 1; }
command -v sqlite3 >/dev/null || { LOG "FATAL: sqlite3 not installed"; exit 1; }
[ -f "$CONFIG" ]    || { LOG "FATAL: config not found at $CONFIG"; exit 1; }
[ -f "$CW_APP_DB" ] || { LOG "FATAL: app.db not found at $CW_APP_DB"; exit 1; }

cdb() { docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIB"; }
# Read-only calibredb run WITHOUT -u (i.e. as the container's default user, root,
# which is the user the always-on GUI app runs as). Running as the SAME user as
# the GUI shares its lock context, so searches succeed even while the GUI holds
# the library lock; running as a different user (2001:2002) is treated as a
# competing program and REFUSED ("Another calibre program is running"). Used only
# for reads (search); writes here go to app.db, not the library, so are unaffected.
cdb_ro() { docker exec "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIB"; }

# GUI-LOCK: the always-on GUI app holds the library lock. calibredb reads run as
# a DIFFERENT user are refused ("Another calibre program is running"), so the
# library search (cdb_ro) runs as root — the GUI's own user — and succeeds under
# the lock. Writes here target app.db (not the library), so are lock-independent.
# Hence we proceed even with the GUI up; the search wrapper aborts the pair if
# calibredb errors anyway, so a lock problem can never empty a shelf.
if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    if docker exec "$CALIBRE_CONTAINER" pgrep -f '/opt/calibre/bin/calibre$' >/dev/null 2>&1; then
        LOG "NOTE: calibre app is running. Library reads run as root to share its"
        LOG "      lock; shelf writes go to app.db. Proceeding. (--force silences this.)"
    fi
fi

sync_pair() {
    local tags="$1" shelf="$2" cwUser="$3"
    LOG "=== tags='$tags' (ALL required) -> shelf='$shelf' (owner $cwUser) ==="

    # resolve owner + shelf id. A shelf is normally identified by name + owner
    # (names aren't globally unique). But a PUBLIC shelf (is_public=1) is visible
    # to all and may be owned by a different user than configured — so if the
    # owner-scoped lookup misses, fall back to a public shelf of that name.
    local userid shelfid
    userid=$(sqlite3 "$DBRO" "SELECT id FROM user WHERE name='$cwUser';")
    [ -z "$userid" ] && { LOG "  user '$cwUser' not found in app.db; skip"; return; }
    shelfid=$(sqlite3 "$DBRO" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
    if [ -z "$shelfid" ]; then
        shelfid=$(sqlite3 "$DBRO" "SELECT id FROM shelf WHERE name='$shelf' AND is_public=1 LIMIT 1;")
        [ -n "$shelfid" ] && LOG "  (using public shelf '$shelf' id=$shelfid; owner differs from $cwUser)"
    fi
    [ -z "$shelfid" ] && { LOG "  shelf '$shelf' not found (owner $cwUser, or public); skip"; return; }

    # --- desired set: books carrying ALL of the listed tags (comma-separated) ---
    # Build an AND of EXACT-match tag terms. Use the SAME form the original
    # single-tag query proved works: tags:="=TAG" (the := is calibre's equality
    # search prefix; the inner ="..." pins the exact tag). A v3 attempt without
    # the := prefix matched zero on spaced tags like "Summer Reads" — this is the
    # form that actually works. A book must have every listed tag (extras fine).
    local query="" t
    local IFSsave="$IFS"; IFS=','
    for t in $tags; do
        t="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"  # trim
        [ -z "$t" ] && continue
        if [ -z "$query" ]; then query="tags:=\"=$t\""
        else query="$query and tags:=\"=$t\""; fi
    done
    IFS="$IFSsave"
    [ -z "$query" ] && { LOG "  no tags configured for this pair; skip"; return; }

    local tagged_csv want_ids want_count
    # capture stderr too so we can tell a LOCK FAILURE apart from a real zero.
    # NOTE: calibredb EXITS NON-ZERO when it simply finds nothing ("No books
    # matching the search expression"), so we must NOT treat a non-zero exit as a
    # failure on its own — that wrongly aborted pairs with zero tagged books. Only
    # genuine error signatures (lock contention, python traceback) count as a
    # failure; "No books matching" is a clean zero and falls through to the guard.
    tagged_csv=$(cdb_ro search "$query" 2>&1)
    if printf '%s' "$tagged_csv" | grep -qi 'Another calibre program\|Traceback\|Permission denied'; then
        LOG "  SEARCH FAILED (calibredb error) — aborting this pair, NOT touching the shelf:"
        LOG "    ${tagged_csv%%$'\n'*}"
        return
    fi
    want_ids=$(printf '%s' "$tagged_csv" | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')
    want_count=$(echo $want_ids | wc -w)
    LOG "  $want_count book(s) carry all of: $tags"

    # --- current set: book ids already on the shelf ---
    local have_ids have_count
    have_ids=$(sqlite3 "$DBRO" "SELECT book_id FROM book_shelf_link WHERE shelf=$shelfid;" \
                | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')
    have_count=$(echo $have_ids | wc -w)
    LOG "  shelf currently has $have_count book(s)"

    # --- diff ---
    local to_add="" to_remove="" id
    for id in $want_ids; do
        case " $have_ids " in *" $id "*) : ;; *) to_add="$to_add $id" ;; esac
    done
    for id in $have_ids; do
        case " $want_ids " in *" $id "*) : ;; *) to_remove="$to_remove $id" ;; esac
    done
    to_add="$(echo $to_add)"; to_remove="$(echo $to_remove)"
    local n_add n_rem
    n_add=$(echo $to_add | wc -w); n_rem=$(echo $to_remove | wc -w)
    LOG "  diff: +$n_add to add, -$n_rem to remove"

    # SAFETY: empty tag set + removals pending = refuse unless --allow-empty.
    if [ "$want_count" -eq 0 ] && [ "$n_rem" -gt 0 ] && [ "$ALLOW_EMPTY" -eq 0 ]; then
        LOG "  tag matched ZERO books but shelf has $have_count — REFUSING to empty shelf"
        LOG "  (transient error or typo'd tag? re-run with --allow-empty if intentional)"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        [ -n "$to_add" ]    && LOG "    [dry-run] would ADD:    $to_add"
        [ -n "$to_remove" ] && LOG "    [dry-run] would REMOVE: $to_remove"
        [ -z "$to_add$to_remove" ] && LOG "    [dry-run] already in sync — nothing to do"
        return
    fi

    # --- apply, under the same shelf-link write lock the watcher uses ---
    local lockfile="${CW_APP_DB}.shelflink.lock"
    (
      flock -w 10 9 || { LOG "  WARN: couldn't acquire shelf write lock; skipping"; exit 1; }
      # ADDs
      for id in $to_add; do
        local newid maxord
        newid=$(sqlite3 "$DBRO" "SELECT COALESCE(MAX(id),0)+1 FROM book_shelf_link;")
        maxord=$(sqlite3 "$DBRO" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM book_shelf_link WHERE shelf=$shelfid;")
        if sqlite3 "$CW_APP_DB" "PRAGMA busy_timeout=5000; INSERT INTO book_shelf_link (id,book_id,\"order\",shelf,date_added) VALUES ($newid,$id,$maxord,$shelfid,datetime('now'));" >/dev/null; then
            LOG "  + added book $id to '$shelf'"
        else
            LOG "  WARN: failed to add book $id (db locked?)"
        fi
      done
      # REMOVEs
      for id in $to_remove; do
        if sqlite3 "$CW_APP_DB" "PRAGMA busy_timeout=5000; DELETE FROM book_shelf_link WHERE shelf=$shelfid AND book_id=$id;" >/dev/null; then
            LOG "  - removed book $id from '$shelf'"
        else
            LOG "  WARN: failed to remove book $id (db locked?)"
        fi
      done
    ) 9>"$lockfile"
    LOG "  done '$shelf'"
}

LOG "=== sync-tag-to-shelf v$SYNC_TAG_SHELF_VERSION starting (dry-run=$DRY_RUN, allow-empty=$ALLOW_EMPTY) ==="
# iterate enabled pairs on FD 3 (docker exec inside loop must not eat the list)
while read -r p <&3; do
    enabled=$(echo "$p" | jq -r '.enabled // true')
    [ "$enabled" = "true" ] || continue
    # prefer new comma-separated 'tags'; fall back to legacy single 'tag'
    tags=$(echo  "$p" | jq -r '.tags // .tag // empty')
    shelf=$(echo "$p" | jq -r '.shelf')
    user=$(echo  "$p" | jq -r '.user')
    [ -z "$tags" ] || [ -z "$shelf" ] || [ -z "$user" ] && { LOG "skip incomplete pair: $p"; continue; }
    sync_pair "$tags" "$shelf" "$user"
done 3< <(jq -c '.pairs[]' "$CONFIG")
LOG "tag->shelf sync complete"
# =============================================================================
#  sync-tag-to-shelf.sh version 9  (footer stamp — must match SYNC_TAG_SHELF_VERSION
#  at top; if these disagree the deployed copy on otis is a stale partial paste.)
# =============================================================================