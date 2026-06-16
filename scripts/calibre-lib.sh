#!/usr/bin/env bash
CALIBRE_LIB_VERSION="3"   # bump on every change (version stamp also at end of file)
# v3: READS REVERTED TO ON-DISK (Option B). The content-server read path (v1/v2)
#     depended on the calibre GUI's embedded server, which proved unreliable — the
#     GUI kept going down (no crash log, not killed once watch/sweep stopped
#     pkilling it), taking the server with it, so reads failed "unreachable" and
#     the pipeline froze. Direct on-disk reads measured 10/10 clean: the library
#     lock is held only in brief rare bursts (free 30/30s sampled; free entirely
#     when the GUI is down, its usual state). So cdb_ro now reads on-disk and the
#     lock-retry helpers cover the rare burst — fewer moving parts, no server, no
#     creds, no GUI dependency. CALIBRE_SERVER_* env + the creds-file auto-source
#     are now unused (left harmless). If on-disk ever proves insufficient, the
#     standalone-calibre-server route can re-add a server path here (Option A).
# v2: cdb_ro fell back to on-disk when the content server was UNREACHABLE (kept
#     for history; superseded by v3 which is on-disk-only).
# v1: shared calibre access for all gunit scripts (cdb_ro server reads, cdb_rw
#     calibredb operations that were previously copy-pasted (and drifting) across
#     fetch-books, tag-books/tag-lib, sweep-books, sync-tag-to-shelf, metadata-
#     books:
#
#       cdb_ro  — READS (list/search). Routed through the calibre CONTENT SERVER
#                 (calibre-server's HTTP API) via --with-library, NOT the on-disk
#                 --library-path. WHY: the always-on calibre GUI container holds
#                 the library lock in frequent bursts; every on-disk read raced
#                 that lock, and a lost race made already_in_library report a book
#                 as "not in library" — sending already-owned books back to Anna's
#                 to be re-downloaded (observed: "Yesteryear: A Novel", id 1189).
#                 The content server shares the GUI's process and does NOT contend
#                 for the lock, so reads through it never hit "Another calibre
#                 program is running". Falls back to on-disk --library-path when
#                 CALIBRE_SERVER_URL is unset (e.g. creds file missing), so this is
#                 safe to source before the server is configured.
#
#       cdb_rw  — WRITES (add/set_metadata/remove). DELIBERATELY left on the on-
#                 disk path as uid:gid $CALIBRE_USER (2001:2002). A write THROUGH
#                 the content server would be performed by the GUI's own user
#                 (abc), changing file/db ownership and breaking the permission
#                 model the pipeline relies on. Writes keep their existing reactive
#                 lock handling in the calling scripts (e.g. sweep-books kills a
#                 lock-holder only on a real add conflict).
#
#     Also hosts the lock helpers (cdb_locked / cdb_ids / cdb_search_ok /
#     cdb_search_retry / cdb_list_retry) that fetch-books v65 defined, so every
#     script shares one copy. With cdb_ro on the server these are mostly a safety
#     net for the on-disk FALLBACK path, but they cost nothing and keep that path
#     robust.
# =============================================================================
#  Source it:   . "$(dirname "$0")/calibre-lib.sh"
#
#  Required env (with sensible defaults; override before sourcing or via the
#  creds file below):
#     CALIBRE_CONTAINER   docker container running calibre   (default: calibre)
#     CALIBRE_LIBRARY     on-disk library path IN-container   (default: /books/Calibre)
#     CALIBRE_USER        uid:gid for writes                  (default: 2001:2002)
#  Content-server config — usually kept in a gitignored creds file that BOTH the
#  interactive shell and the systemd unit source (so manual and timer runs agree):
#     CALIBRE_SERVER_URL  e.g. http://otis.rm:8081/books/#Calibre   (unset => fallback)
#     CALIBRE_SERVER_USER content-server username
#     CALIBRE_SERVER_PASS content-server password
#  This lib will auto-source ~/gunit/config/calibre-server.env if present and the
#  vars aren't already set, so a single `. calibre-lib.sh` is enough in scripts.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "calibre-lib.sh requires bash; source it from a bash script." >&2
    return 1 2>/dev/null || exit 1
fi

# ---- config -----------------------------------------------------------------
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"

# Auto-source the creds file if the server vars aren't already in the environment.
# Keeps the password in ONE gitignored place; both shells and systemd can also set
# these directly, in which case this no-ops.
CALIBRE_SERVER_ENV="${CALIBRE_SERVER_ENV:-$HOME/gunit/config/calibre-server.env}"
if [ -z "${CALIBRE_SERVER_URL:-}" ] && [ -r "$CALIBRE_SERVER_ENV" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CALIBRE_SERVER_ENV"; set +a
fi

CDB_LOCK_RETRIES="${CDB_LOCK_RETRIES:-4}"
CDB_LOCK_WAIT="${CDB_LOCK_WAIT:-2}"

# Provide a no-op `log` if the sourcing script hasn't defined one, so the retry
# helpers below never call an unbound function. A script with its own log()
# (fetch-books, etc.) keeps it — this only fills the gap for scripts without one.
if ! declare -F log >/dev/null 2>&1; then
    log() { printf '%s\n' "$*" >&2; }
fi

# ---- read path: on-disk, with lock-retry (Option B) -------------------------
# cdb_ro ARGS... -> run a calibredb READ against the on-disk library.
#
# HISTORY: we tried routing reads through the calibre GUI's embedded CONTENT
# SERVER (--with-library) to dodge the library lock. But that server lives and
# dies with the GUI, and the GUI proved unreliable (kept going down, taking the
# server with it) — so reads kept failing "unreachable" and the whole pipeline
# froze. Meanwhile direct on-disk reads measured 10/10 clean: the library lock is
# held only in brief, rare bursts by the GUI (free 30/30s when sampled), and is
# free entirely whenever the GUI is down (its common state). So we read on-disk
# and lean on the lock-retry helpers (cdb_search_retry / cdb_list_retry) for the
# rare burst. No server, no creds, no GUI dependency, fewer moving parts.
# stderr is folded into stdout (2>&1) so callers can inspect lock/error banners;
# callers that parse --for-machine JSON must still strip noise (raw_decode).
#
# (CALIBRE_SERVER_* env vars are now unused. Left harmless if still set; the
#  standalone-calibre-server route (Option A) can re-introduce a server path here
#  later if on-disk reads ever prove insufficient.)
cdb_ro() {
    docker exec "$CALIBRE_CONTAINER" calibredb "$@" \
        --library-path "$CALIBRE_LIBRARY" 2>&1
}

# ---- write path: on-disk, as the pipeline's uid:gid (UNCHANGED semantics) ----
# cdb_rw ARGS... -> run a calibredb WRITE (add/set_metadata/remove) as
# $CALIBRE_USER against the on-disk library. Stays off the server on purpose to
# preserve file/db ownership. stderr NOT folded here (callers historically read it
# selectively); pass 2>&1 explicitly in the call site if you want it merged.
cdb_rw() {
    docker exec -u "$CALIBRE_USER" "$CALIBRE_CONTAINER" calibredb "$@" \
        --library-path "$CALIBRE_LIBRARY"
}

# ---- lock / result helpers (shared) -----------------------------------------
# cdb_locked OUTPUT -> 0 (true) if the output shows the library is locked by
# another calibre process. The ONLY hard "can't read" signal we trust. We do NOT
# treat a bare "Traceback" as locked: calibre's page-count worker logs unrelated
# tracebacks onto the same stream as a perfectly good result, so greping for
# "Traceback" turned clean no-matches into false "unavailable". (With cdb_ro on
# the server this rarely fires; it still guards the on-disk fallback.)
cdb_locked() {
    printf '%s' "$1" | grep -qi 'Another calibre program is running'
}

# cdb_ids OUTPUT -> echoes numeric ids from a search result, ignoring everything
# else (worker tracebacks, "No books matching", stray words). Accepts input as $1
# OR piped on stdin (so it works as a pipe stage under set -u).
cdb_ids() {
    local in
    if [ "$#" -ge 1 ]; then in="$1"; else in="$(cat)"; fi
    printf '%s' "$in" | tr -d ' ' | tr ',' '\n' | grep -oE '^[0-9]+$'
}

# cdb_search_ok OUTPUT -> 0 if this looks like a VALID search result (matched ids
# OR an explicit "no books matched"). Distinguishes a real read failure (caller
# returns 2) from a clean result surrounded by worker-traceback noise.
cdb_search_ok() {
    local out="$1"
    cdb_locked "$out" && return 1
    printf '%s' "$out" | grep -qi 'No books matching the search expression' && return 0
    [ -n "$(cdb_ids "$out")" ] && return 0
    return 1
}

# cdb_search_retry QUERY... -> cdb_ro search QUERY..., retrying on a transient
# lock. Echoes the final output; caller still classifies it. (Server path almost
# never locks; retained for the fallback path.)
cdb_search_retry() {
    local out attempt=0
    while :; do
        out="$(cdb_ro search "$@")"
        cdb_locked "$out" || { printf '%s' "$out"; return 0; }
        attempt=$((attempt+1))
        [ "$attempt" -ge "$CDB_LOCK_RETRIES" ] && { printf '%s' "$out"; return 0; }
        log "      calibre locked (GUI busy) — retry $attempt/$CDB_LOCK_RETRIES in ${CDB_LOCK_WAIT}s"
        sleep "$CDB_LOCK_WAIT"
    done
}

# cdb_list_retry ARGS... -> cdb_ro list ARGS..., retrying on a transient lock.
# (See fetch-books v65 history: the per-candidate metadata read used to use a bare
# read with no retry, which under a lock silently dropped the candidate and sent
# in-library books back to Anna's. The server path removes the race; this keeps
# the fallback safe.)
cdb_list_retry() {
    local out attempt=0
    while :; do
        out="$(cdb_ro list "$@")"
        cdb_locked "$out" || { printf '%s' "$out"; return 0; }
        attempt=$((attempt+1))
        [ "$attempt" -ge "$CDB_LOCK_RETRIES" ] && { printf '%s' "$out"; return 0; }
        log "      calibre locked (GUI busy, metadata read) — retry $attempt/$CDB_LOCK_RETRIES in ${CDB_LOCK_WAIT}s"
        sleep "$CDB_LOCK_WAIT"
    done
}

# =============================================================================
# calibre-lib.sh version 3  (footer stamp — must match CALIBRE_LIB_VERSION at top;
# if these disagree the deployed copy on otis is a stale partial paste.)
# =============================================================================