#!/bin/bash
SYNC_SHELF_TAGS_VERSION="3"   # bump on every change; echoed at startup
# v3: tolerate both "forKindle" and "for Kindle" shelf spellings. If the
#     configured name isn't found in app.db, the alternate spelling is tried
#     automatically — users.json needn't be consistent about which form is used.
# v2: strip "Integration status: True" suffix calibredb appends to --for-machine
#     output; was corrupting JSON and causing jq to fail, emptying cur and
#     stripping all existing tags from every book touched.
# v1: completed from partial implementation. Fixes: correct default paths
#     (web/users.json, cwa_config/app.db); --dry-run flag; GUNIT_LOG integration;
#     trailing-comma bug in id list; tag search syntax; set_metadata arg order.
# =============================================================================
#  sync-shelf-tags.sh   (SHELF IS BOSS — opposite of sync-tag-to-shelf.sh)
#
#  For each configured user: the calibre-web shelf is the source of truth.
#    - book on the shelf without the tag  -> ADD tag
#    - book with the tag not on the shelf -> REMOVE tag
#
#  Config: MAPPING (default web/users.json) — reads .users[]; entries without
#  both 'shelf' and 'tag' fields are silently skipped, so plain dashboard users
#  are unaffected.
#
#  SAFETY: if a shelf reads as empty and REQUIRE_NONEMPTY=true (the default),
#  the REMOVE phase is skipped for that user — a transient DB hiccup can never
#  strip all tags. Set false only if you genuinely want to clear via an empty shelf.
#
#  USAGE:  ./sync-shelf-tags.sh            # real run, all users with shelf+tag
#          ./sync-shelf-tags.sh --dry-run  # show what would change, no writes
# =============================================================================
set -uo pipefail

# --- config ---
MAPPING="${MAPPING:-/home/robmorgan/gunit/web/users.json}"
CW_APP_DB="${CW_APP_DB:-/home/robmorgan/cwa_config/app.db}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIB="${CALIBRE_LIB:-/books/Calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-true}"
DRY_RUN=0

for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 1 ;;
    esac
done

GUNIT_LOG="${GUNIT_LOG:-/home/robmorgan/logs/gunit.log}"
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null || true
LOG() {
    local ts; ts="$(date '+%F %T')"
    echo "[$ts] $*"
    printf '%s  [st] %s\n' "$ts" "$*" >> "$GUNIT_LOG" 2>/dev/null || true
}

DBRO="file:$CW_APP_DB?mode=ro"

command -v jq      >/dev/null || { LOG "FATAL: jq not installed"; exit 1; }
command -v sqlite3 >/dev/null || { LOG "FATAL: sqlite3 not installed"; exit 1; }
[ -f "$CW_APP_DB" ]           || { LOG "FATAL: app.db not found at $CW_APP_DB"; exit 1; }

cdb() { docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIB"; }

# GUI-lock guard: calibre desktop holds the library lock; skip and let the next
# timer cycle retry rather than fighting it.
if docker exec "$CALIBRE_CONTAINER" pgrep -f '/opt/calibre/bin/calibre$' >/dev/null 2>&1; then
    LOG "calibre GUI holds the library lock — skipping (next cycle will retry)"
    exit 0
fi

LOG "=== sync-shelf-tags v$SYNC_SHELF_TAGS_VERSION starting (dry-run=$DRY_RUN) ==="

while read -r u <&3; do
    cwUser=$(printf '%s' "$u" | jq -r '.email // empty')
    shelf=$(printf '%s'  "$u" | jq -r '.shelf // empty')
    tag=$(printf '%s'    "$u" | jq -r '.tag   // empty')
    # skip users not configured for shelf->tag sync
    [ -z "$cwUser" ] || [ -z "$shelf" ] || [ -z "$tag" ] && continue

    LOG "=== $cwUser | shelf='$shelf' | tag='$tag' ==="

    userid=$(sqlite3 "$DBRO" "SELECT id FROM user WHERE name='$cwUser';")
    [ -z "$userid" ] && { LOG "  user not found in app.db; skip"; continue; }

    shelfid=$(sqlite3 "$DBRO" "SELECT id FROM shelf WHERE name='$shelf' AND user_id=$userid;")
    if [ -z "$shelfid" ]; then
        case "$shelf" in
            "forKindle") alt="for Kindle" ;;
            "for Kindle") alt="forKindle" ;;
            *) alt="" ;;
        esac
        if [ -n "$alt" ]; then
            shelfid=$(sqlite3 "$DBRO" "SELECT id FROM shelf WHERE name='$alt' AND user_id=$userid;")
            [ -n "$shelfid" ] && LOG "  (shelf '$shelf' not found; using alternate spelling '$alt')"
        fi
    fi
    [ -z "$shelfid" ] && { LOG "  shelf '$shelf' not found; skip"; continue; }

    # shelf book ids (calibre book ids)
    shelf_ids=$(sqlite3 "$DBRO" \
        "SELECT book_id FROM book_shelf_link WHERE shelf=$shelfid;" | tr '\n' ' ')
    shelf_ids="${shelf_ids%% }"   # trim trailing space
    shelf_count=$(printf '%s\n' $shelf_ids | grep -c '[0-9]' || true)
    LOG "  shelf has $shelf_count book(s)"

    # ADD: give the tag to every book on the shelf that doesn't already have it
    if [ "$shelf_count" -gt 0 ]; then
        idquery=$(printf '%s' "$shelf_ids" | tr ' ' ',')
        meta=$(cdb list -s "id:=$idquery" -f id,tags --for-machine 2>/dev/null | sed 's/^\].*/]/')
        for id in $shelf_ids; do
            cur=$(printf '%s' "$meta" | jq -r --argjson i "$id" \
                '.[] | select(.id==$i) | (.tags // []) | join(",")')
            case ",$cur," in
                *",$tag,"*) : ;;   # already has the tag
                *)
                    newt="${cur:+$cur,}$tag"
                    if [ "$DRY_RUN" -eq 1 ]; then
                        LOG "  DRY + would tag book $id ('$tag')"
                    else
                        cdb set_metadata "$id" --field "tags:$newt" >/dev/null 2>&1 \
                            && LOG "  + tagged book $id"
                    fi ;;
            esac
        done
    fi

    # REMOVE: strip the tag from books that have it but are no longer on the shelf
    if [ "$shelf_count" -eq 0 ] && [ "$REQUIRE_NONEMPTY" = "true" ]; then
        LOG "  shelf empty + REQUIRE_NONEMPTY=true -> skipping REMOVE phase (safety)"
        continue
    fi

    tagged_ids=$(cdb search "tags:\"$tag\"" 2>/dev/null | tr ',' ' ')
    for id in $tagged_ids; do
        case " $shelf_ids " in
            *" $id "*) : ;;   # still on the shelf — keep tag
            *)
                cur=$(cdb list -s "id:=$id" -f tags --for-machine 2>/dev/null \
                    | sed 's/^\].*/]/' \
                    | jq -r --arg t "$tag" \
                        '.[0].tags // [] | map(select(. != $t)) | join(",")')
                if [ "$DRY_RUN" -eq 1 ]; then
                    LOG "  DRY - would untag book $id (not on shelf)"
                else
                    cdb set_metadata "$id" --field "tags:$cur" >/dev/null 2>&1 \
                        && LOG "  - untagged book $id (off shelf)"
                fi ;;
        esac
    done

    LOG "  done $cwUser"
done 3< <(jq -c '.users[]' "$MAPPING")

LOG "=== sync-shelf-tags done ==="
