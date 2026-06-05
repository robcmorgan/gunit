#!/bin/bash
# =============================================================================
#  sync-shelf-tags.sh   (SHELF IS BOSS)
#  For each user: the calibre-web shelf is the single source of truth.
#    - every book on the shelf gets the user's tag
#    - every book WITH the tag that is NOT on the shelf loses the tag
#
#  SAFETY: if a shelf read fails or returns empty *unexpectedly*, the REMOVE
#  phase is skipped for that user, so a transient DB hiccup can never strip all
#  tags. (An intentionally empty shelf is handled via REQUIRE_NONEMPTY below.)
# =============================================================================

set -uo pipefail

# --- config (override via env or a sourced config file) ---
MAPPING="${MAPPING:-/home/robmorgan/gunit/config/users.json}"
CW_APP_DB="${CW_APP_DB:-/data/compose/1/calibre_web_config/app.db}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
# If true, refuse to run the REMOVE phase when a shelf reads as empty (assume
# error, not a genuinely empty shelf). Set false only if you really do empty
# shelves to clear tags.
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-true}"
LOG() { echo "[$(date '+%F %T')] $*"; }

DBRO="file:$CW_APP_DB?mode=ro"     # read-only handle for all app.db reads

command -v jq >/dev/null      || { LOG "FATAL: jq not installed"; exit 1; }
command -v sqlite3 >/dev/null || { LOG "FATAL: sqlite3 not installed"; exit 1; }
[ -f "$CW_APP_DB" ]           || { LOG "FATAL: app.db not found at $CW_APP_DB"; exit 1; }

CALIBRE_USER="${CALIBRE_USER:-2001:2002}"   # run calibredb as abc, not root (see watcher notes)
cdb() { docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIB"; }

# GUI-LOCK: the calibre app locks the library and makes set_metadata fail. We
# do NOT kill it (it may be serving OPDS / content server / other things). If
# locked, skip this run cleanly — the next timer cycle (15 min) will retry.
if docker exec "$CALIBRE_CONTAINER" pgrep -f '/opt/calibre/bin/calibre$' >/dev/null 2>&1; then
    LOG "calibre app is running and holds the library lock — skipping this run."
    LOG "Close the calibre GUI/app and the next timer cycle (within 15 min) will catch up."
    exit 0
fi

# iterate users from the mapping.
# NOTE: we read the loop on FD 3 (not stdin) because commands inside the loop
# run `docker exec` — reading the user list on FD 3 keeps it isolated from any
# command stdin inside the loop.
while read -r u <&3; do
    cwUser=$(echo "$u" | jq -r '.email')
    shelf=$(echo  "$u" | jq -r '.shelf')
    tag=$(echo    "$u" | jq -r '.tag')
    LOG "=== $cwUser | shelf='$shelf' | tag='$tag' ==="

    userid=$(sqlite3 "$DBRO" "SELECT id FROM user WHERE name='$cwUser';")
    [ -z "$userid" ] && { LOG "  user not found; skip"; continue; }
    shelfid=$(sqlite3 "$DBRO" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
    [ -z "$shelfid" ] && { LOG "  shelf not found; skip"; continue; }

    # --- shelf book ids (calibre book ids) ---
    shelf_ids=$(sqlite3 "$DBRO" "SELECT book_id FROM book_shelf_link WHERE shelf=$shelfid;" | tr '\n' ' ')
    shelf_count=$(echo $shelf_ids | wc -w)
    LOG "  shelf has $shelf_count book(s)"

    # ADD: ensure each shelf book has the tag. Batch the read of current tags.
    if [ "$shelf_count" -gt 0 ]; then
        # one calibredb call to get tags for all shelf ids
        idquery=$(echo $shelf_ids | sed 's/ /,/g')   # comma list
        meta=$(cdb list -s "id:=$idquery" -f id,tags --for-machine 2>/dev/null)
        for id in $shelf_ids; do
            cur=$(echo "$meta" | jq -r --argjson i "$id" '.[] | select(.id==$i) | (.tags // []) | join(",")')
            case ",$cur," in
                *",$tag,"*) : ;;                                 # already tagged
                *) newt="${cur:+$cur,}$tag"
                   cdb set_metadata -f "tags:$newt" "$id" >/dev/null 2>&1 \
                       && LOG "  + tagged book $id" ;;
            esac
        done
    fi

    # REMOVE: books that have the tag but are not on the shelf lose the tag.
    tagged_csv=$(cdb search "tags:=\"=$tag\"" 2>/dev/null)
    # SAFETY GUARD: if the shelf is empty and we require non-empty, skip removals.
    if [ "$shelf_count" -eq 0 ] && [ "$REQUIRE_NONEMPTY" = "true" ]; then
        LOG "  shelf empty + REQUIRE_NONEMPTY -> skipping REMOVE phase (safety)"
        continue
    fi
    for id in ${tagged_csv//,/ }; do
        case " $shelf_ids " in
            *" $id "*) : ;;                                      # still on shelf
            *) cur=$(cdb list -s "id:=$id" -f tags --for-machine 2>/dev/null \
                       | jq -r --arg t "$tag" '.[0].tags // [] | map(select(.!=$t)) | join(",")')
               cdb set_metadata -f "tags:$cur" "$id" >/dev/null 2>&1 \
                   && LOG "  - untagged book $id (off shelf)" ;;
        esac
    done
    LOG "  done $cwUser"
done 3< <(jq -c '.users[]' "$MAPPING")
LOG "sync complete"