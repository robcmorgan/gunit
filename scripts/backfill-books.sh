#!/bin/bash
# =============================================================================
#  backfill-books.sh — sequentially import every book sitting in the per-user
#  download folders into Calibre and add it to the user's shelf.
#
#  WHY THIS EXISTS (separate from the watcher):
#  The watcher is EVENT-driven and processes files in PARALLEL (one backgrounded
#  job per inotify event). That's fine for normal use (shelfmark delivers books
#  one at a time), but when you re-trigger MANY files at once (touch *.epub),
#  ~25 calibredb processes run simultaneously and collide on calibre's single-
#  writer library lock ("Another calibre program is running") — so most fail.
#
#  This script does the opposite: it walks the folders and imports books
#  STRICTLY ONE AT A TIME, fully finishing each (add -> dedupe -> shelve) before
#  starting the next. No locks needed because there's no concurrency. It also
#  kills the calibre GUI app ONCE up front and keeps it down for the whole run.
#
#  It reuses the watcher's exact add/dedupe/shelve logic, so results match.
#
#  USAGE (on otis):
#    ./backfill-books.sh                 # process all users' folders
#    ./backfill-books.sh --dry-run       # show what it WOULD do, no changes
#
#  DONE-HANDLING: after a book is successfully imported AND shelved, this MOVES
#  it into a per-user "done/" subfolder (created if absent), e.g.
#    gunit_user_folders/alice@x.com/Book.epub
#      -> gunit_user_folders/alice@x.com/done/Book.epub
#  Files already inside a done/ folder are skipped. So you can re-run this
#  safely — processed books are out of the way, only un-moved (new or failed)
#  books are considered, so no duplicate imports and no need to worry about
#  what's already been handled. Failures are LEFT IN PLACE (not moved), so a
#  re-run retries exactly the ones that failed once you've fixed the cause.
#
#  NOTE: the live watcher (watch-downloads.sh) must EXCLUDE these done/ folders
#  from its inotify watches, otherwise moving a file into done/ would trigger a
#  re-import. The watcher's --exclude is updated to ignore /done/.
# =============================================================================
set -uo pipefail

# --- config (match the watcher) ---------------------------------------------
ROOT="${ROOT:-/Nutmeg/Media/Books/incoming/gunit_user_folders}"
USERS_JSON="${USERS_JSON:-/home/robmorgan/gunit/web/users.json}"
PREFS_DIR="${PREFS_DIR:-/home/robmorgan/gunit/userprefs}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
CW_APP_DB="${CW_APP_DB:-/data/compose/1/calibre_web_config/app.db}"
MOUNT_HOST_ROOT="${MOUNT_HOST_ROOT:-/Nutmeg/Media/Books}"
MOUNT_CONTAINER_ROOT="${MOUNT_CONTAINER_ROOT:-/books}"
DONE_DIR_NAME="${DONE_DIR_NAME:-done}"  # processed files moved here (per-user subfolder)
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

LOG() { echo "[$(date '+%F %T')] $*"; }

command -v sqlite3 >/dev/null || { LOG "FATAL: sqlite3 not installed"; exit 1; }
[ -f "$USERS_JSON" ] || { LOG "FATAL: users.json not found at $USERS_JSON"; exit 1; }

# --- ensure calibre container is up, then kill the GUI app ONCE --------------
if ! docker ps --filter "name=^${CALIBRE_CONTAINER}$" --filter "status=running" \
        --format '{{.Names}}' | grep -q "^${CALIBRE_CONTAINER}$"; then
    LOG "calibre container not running — starting it"
    docker start "$CALIBRE_CONTAINER" >/dev/null 2>&1 || { LOG "FATAL: can't start $CALIBRE_CONTAINER"; exit 1; }
    sleep 5
fi
LOG "killing calibre GUI app once, up front (keeps the library lock free for the run)"
docker exec "$CALIBRE_CONTAINER" pkill -f '/opt/calibre/bin/calibre$' 2>/dev/null
sleep 2

# Resolve a folder name (== email == calibre-web username) to its shelf via
# users.json. Falls back to 'forKindle' if not found.
shelf_for_user() {
    local email="$1"
    python3 - "$USERS_JSON" "$email" <<'PY' 2>/dev/null || echo "forKindle"
import json,sys
data=json.load(open(sys.argv[1]))
email=sys.argv[2]
# users.json is email-keyed OR a list; handle both
def find(d):
    if isinstance(d,dict):
        if email in d: return d[email]
        for v in d.values():
            r=find(v)
            if r: return r
    if isinstance(d,list):
        for v in d:
            if isinstance(v,dict) and v.get('email')==email: return v
    return None
u=find(data) or {}
print(u.get('shelf','forKindle'))
PY
}

import_one() {
    local file="$1" email="$2" shelf="$3"
    local cpath="${file/#$MOUNT_HOST_ROOT/$MOUNT_CONTAINER_ROOT}"
    LOG "  importing: $(basename "$file")  (user=$email shelf=$shelf)"
    [ "$DRY_RUN" -eq 1 ] && { LOG "    [dry-run] would import + shelve"; return 0; }

    local out idlist
    out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$cpath" \
            --library-path "$CALIBRE_LIB" 2>&1)
    idlist=$(echo "$out" | grep -oiE '(Added book ids|Merged book ids)[: ]+[0-9, ]+' \
             | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')

    if [ -z "$idlist" ]; then
        local base author title
        base=$(basename "$file"); base="${base%.*}"
        author="${base%% - *}"; title="${base#* - }"
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
            out=$(docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb add "$cpath" \
                    --library-path "$CALIBRE_LIB" --duplicates 2>&1)
            idlist=$(echo "$out" | grep -oiE 'Added book ids[: ]+[0-9, ]+' \
                     | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
        fi
        [ -z "$idlist" ] && { LOG "    WARN: could not add/locate. calibredb said: $out"; return 1; }
    else
        LOG "    imported as book id(s): $idlist"
    fi

    # shelve each id in calibre-web's app.db
    local userid shelfid
    userid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM user WHERE name='$email';")
    shelfid=$(sqlite3 "file:$CW_APP_DB?mode=ro" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
    if [ -z "$userid" ] || [ -z "$shelfid" ]; then
        LOG "    WARN: user/shelf not found (user=$email shelf=$shelf) — imported but not shelved"
        return 1
    fi
    local bid
    for bid in $idlist; do
        local exists
        exists=$(sqlite3 "$CW_APP_DB" "SELECT 1 FROM book_shelf_link WHERE book_id=$bid AND shelf=$shelfid LIMIT 1;")
        if [ -n "$exists" ]; then
            LOG "    book $bid already on shelf '$shelf' — skip"
            continue
        fi
        local newid maxord
        newid=$(sqlite3 "$CW_APP_DB" "SELECT COALESCE(MAX(id),0)+1 FROM book_shelf_link;")
        maxord=$(sqlite3 "$CW_APP_DB" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM book_shelf_link WHERE shelf=$shelfid;")
        sqlite3 "$CW_APP_DB" "INSERT INTO book_shelf_link (id,book_id,\"order\",shelf,date_added) \
                              VALUES ($newid,$bid,$maxord,$shelfid,datetime('now'));"
        LOG "    ✔ added book $bid to shelf '$shelf' (user $email)"
    done
    return 0
}

# --- walk the folders, one file at a time ------------------------------------
LOG "backfill starting under $ROOT  (dry-run=$DRY_RUN, done-folder='$DONE_DIR_NAME')"
total=0; ok=0; skip=0; fail=0
while IFS= read -r -d '' file; do
    # skip anything already inside a done/ folder
    case "$file" in */"$DONE_DIR_NAME"/*) continue;; esac
    total=$((total+1))
    # the immediate parent folder name is the user's email
    email=$(basename "$(dirname "$file")")
    shelf=$(shelf_for_user "$email")
    if import_one "$file" "$email" "$shelf"; then
        ok=$((ok+1))
        if [ "$DRY_RUN" -eq 0 ]; then
            # move the processed book into the per-user done/ folder
            done_dir="$(dirname "$file")/$DONE_DIR_NAME"
            mkdir -p "$done_dir" 2>/dev/null
            if mv "$file" "$done_dir/" 2>/dev/null; then
                LOG "    moved to: $DONE_DIR_NAME/$(basename "$file")"
            else
                LOG "    WARN: imported+shelved OK but could NOT move to $DONE_DIR_NAME/ (check perms) — leaving in place"
            fi
        fi
    else
        fail=$((fail+1))
        LOG "    left in place for retry (not moved to $DONE_DIR_NAME/)"
    fi
done < <(find "$ROOT" -type f -name '*.epub' -print0 | sort -z)

echo "------------------------------------------------------------"
LOG "backfill complete. processed=$total  ok=$ok  failed=$fail"
[ "$fail" -gt 0 ] && LOG "failures stay in place; fix the cause and re-run to retry only those (done ones are moved away)."