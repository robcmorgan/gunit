#!/usr/bin/env bash
FETCH_BOOKS_VERSION="44"   # bump on every change; echoed at startup so you can
                          # confirm the copy on otis matches the latest edit.
# v44: seed the quota floor from the shared quota-probe.sh helper (the same one
#      quota-status.sh uses). It queries the JSON API with a VALID md5, returning
#      an EXACT, shelfmark-inclusive downloads_left WITHOUT spending a slot — more
#      reliable than the invalid-md5 preflight (which may not return account info
#      at all). Sourced like match-lib.sh; fetch-books passes its own container +
#      first mirror to the helper and restores its own PROBE_MD5 afterward. Falls
#      back to the invalid-md5 response, then to live-on-first-download, if the
#      helper is absent or the probe fails.
# v43: quota exhaustion no longer halts the run — Standard Ebooks (free, off-quota)
#      keeps working for the rest of the list. When Anna's daily quota is spent
#      (floor reached, or API refuses mid-run), ANNAS_QUOTA_OUT is set: every
#      remaining book still tries SE first, and only books SE lacks are marked
#      'quota_blocked' (a distinct status, NOT nomatch/failed) for a later run.
#      quota_blocked auto-retries on the next run (no --retry needed) since the
#      quota resets daily. New per-file counter + summary field. (Replaces v42's
#      whole-run halt.)
# v42: fix the fast-download quota FLOOR + clean stop at exhaustion. (1) The floor
#      never engaged at run start because QUOTA_START was empty until the first
#      successful download — so a run beginning with few/zero slots attempted (and
#      failed) downloads instead of stopping. preflight now seeds QUOTA_START from
#      the bad-md5 probe's account_fast_download_info.downloads_left (no quota
#      spent), so the floor (default now 4, was 5) holds from book 1. (2) When a
#      download is refused for quota exhaustion ("no downloads left" / downloads_
#      left=0), fast_download_md5 returns 2 and the run STOPS (remaining books left
#      pending) instead of logging "download failed" for every book and hammering
#      the API.
# v41: JSON-decode the FlareSolverr envelope. Non-ASCII titles/authors were
#      arriving as undecoded JSON unicode escapes ("Pedro Páramo" -> the literal
#      "Pedro P\u00e1ramo") because the parsers did html.unescape but never
#      json-decode. norm() then mangled them, so EVERY accented/non-Latin
#      title silently scored 0.000 (the real Pedro Páramo card) while an
#      unaccented "Pedro Paramo" entry matched. Now decode .solution.response
#      from FlareSolverr's JSON to real HTML once, before stripping comments and
#      parsing — so accent-folding in norm() works. Falls back to raw if a mirror
#      returns HTML directly. (Completes the v38 lazy-load fix.)
# v40: retry transient calibre locks instead of deferring. The library check ran
#      up to 4 calibredb searches per book; if the GUI briefly held the library
#      lock during ANY one of them, that search returned the "Another calibre
#      program is running" message and already_in_library returned 2 (defer the
#      whole book) — even though the same query succeeds moments later (confirmed:
#      title:"Kindred" succeeded while title:"Octavia E. Butler" was locked in the
#      same instant). cdb_search_retry now re-runs a locked search a few times
#      with a short wait (CDB_LOCK_RETRIES=4, CDB_LOCK_WAIT=2s); a lock that
#      truly persists is still treated as unavailable.
# v39: Gemini review fixes. (1) escape embedded double-quotes in the calibre
#      title: search so a title like The "Great" Gatsby doesn't break the query.
#      (2) refresh_file now parses the md5->state map ONCE into a bash assoc array
#      (was forking awk per TSV row) and splits rows with IFS read (was cut x5).
#      (3) use ${#resp} instead of echo -n|wc -c for the mirror size floor (no
#      subshell). (4) chown Anna's downloads to WATCHER_OWNER (=2001:2002) inside
#      the container after the move, so files land owned for the watcher even if
#      qbittorrent's PUID/PGID aren't 2001:2002; logs a hint if chown fails.
# v38: parse Anna's LAZY-LOADED results. Anna's now ships each search-result card
#      inside an HTML comment that client JS un-comments; FlareSolverr returns the
#      pre-JS HTML, so the cards stayed commented and the parser saw 0 results —
#      the only live /md5/ links were the "recent downloads" ticker (decoys). A
#      present book (e.g. Pedro Páramo) looked missing. search_one now strips the
#      <!-- --> markers before parsing, exposing the real cards (0 -> 50 for that
#      query). The field-separated matcher still rejects ticker/decoy entries.
#      This likely improves match rates across the board, not just one book.
# v37: dead-mirror visibility + safe handling. A mirror that returns nothing via
#      FlareSolverr (unreachable now, even if check-mirrors marked it WORKING
#      earlier) was skipped silently, turning "no mirror answered" into an
#      indistinguishable "nomatch" — so findable books (e.g. Pedro Páramo) looked
#      missing. Now: each unreachable/too-small mirror is logged; if NO mirror
#      answers, search_one returns UNREACHABLE and the loop leaves the row PENDING
#      (retry next run) instead of burning it as nomatch.
# v36: handle Standard Ebooks PLACEHOLDER pages (books with a catalogue entry but
#      not yet public domain, so NO download files — e.g. Life and Fate, Invisible
#      Cities). Previously these matched on SE search then failed the download and
#      were marked 'failed', blocking the Anna's fallback for a book SE will never
#      have. se_download now returns 3 for a placeholder (zero /downloads/ links),
#      and the loop falls through to Anna's instead of marking failed. A real page
#      missing only the requested format still returns 1 (failed, no fallback).
# v35: fix two false-positive matches. (1) The library check (already_in_library)
#      scored candidates with book_match_score on a flattened "title author" blob,
#      so the wanted AUTHOR's words could satisfy the TITLE gate — "The
#      Dispossessed / Le Guin" matched the library's "The Lathe of Heaven / Le
#      Guin". Now uses book_match_fields with title/author kept separate. (2) The
#      SE exact-title floor rescued a wrong book when the title was identical but
#      the author contradicted ("The Secret History" Tartt vs Procopius); the
#      floor now applies only when the candidate author is absent or shares a word
#      (misspellings still pass). Requires match-lib v6 (author-contradiction gate
#      in book_match_fields).
# v34: (1) coloured terminal output — log() now colourizes by message type for
#      the terminal only; the logfile stays plain (no escape codes). Auto-off
#      when stderr isn't a TTY (systemd timer) or NO_COLOR is set. (2) Gemini
#      review fixes: parse loops use `IFS=$'\t' read` / `IFS='|' read` instead
#      of forking cut per field; cleanup batches one docker exec for all parts
#      (Ctrl-C no longer hangs); cdb_ids strips spaces before splitting so
#      "12, 34" doesn't drop ids; --dry-run is now strictly read-only (rows kept
#      verbatim, source file not rewritten/touched).
# v33: fix false "library check unavailable" that deferred every book. The lock
#      detector grepped for "Traceback" anywhere in calibredb output, but
#      calibre's background page-count worker logs tracebacks for unrelated
#      corrupt books (e.g. a non-zip EPUB in the library) onto the same stream
#      as the search result. Those coexist with a valid "No books matching"/id
#      result, so the grep turned clean no-matches into deferrals. Now: only the
#      specific lock message "Another calibre program is running" means locked;
#      a result is valid if it has ids OR says no books matched, regardless of
#      worker traceback noise (cdb_locked / cdb_search_ok / cdb_ids helpers).
# v32: SE downloads now WORK. Root cause of the corrupt epub: the bare SE
#      download URL returns an HTML "Your Download Has Started!" interstitial,
#      not the epub — the binary needs ?source=download appended. Also, SE gates
#      direct downloads by IP: through gluetun (Romania) you get the gate page;
#      over otis's own connection you get the file. So ALL SE traffic (search +
#      download) now runs on the HOST via curl/wget, off the VPN. The
#      interstitial carries a honeypot that bans your IP 24h if followed — we
#      never parse it, only request URL+?source=download directly. PK magic-byte
#      check (v31) retained. Files chowned to 2001:2002 for the watcher.
# v31: se_download now validates the downloaded file is a real ZIP/epub (first
#      two bytes "PK") before moving it into DEST. v30 checked only non-empty,
#      so an HTML 404/redirect/rate-limit page got shipped as a ".epub" the
#      reader couldn't open. A non-PK file is now rejected and logged with the
#      URL + first bytes so the cause is visible.
# v30: fix SE result parser to match SE's real RDFa/schema.org markup (title +
#      author now parse correctly; v29 parsed author as blank). Add a title-only
#      SE retry: if "title author" finds nothing, retry with the title alone, so
#      a misspelled/mis-formatted list author (e.g. "George Elliot" vs SE's
#      "George Eliot") still matches. SE-only exact-title acceptance: an EXACT
#      normalized title match (equality, not subset) clears the bar on its own,
#      since match-lib's short-title guard otherwise demands author corroboration
#      a misspelled author can't give. The shared matcher and Anna's path keep
#      the stricter rule. Disable the retry with SE_TITLE_ONLY_RETRY=0.
# v29: per book, try STANDARD EBOOKS (free, public-domain, no key/quota/VPN)
#      BEFORE Anna's Archive. SE is authoritative: a confident SE match that
#      then fails to download is marked 'failed' (no Anna's fallback), so we
#      never spend Anna's quota on a book SE already had. Grabs the Compatible
#      epub. Source recorded as se:<author-slug>/<title-slug> in the md5 column.
#      Disable with SE_FIRST=0.
# =============================================================================
#  fetch-books.sh — feed a list of author | title, search Anna's Archive via
#  FlareSolverr, confidence-match the top hit, queue it in Stacks. Resumable:
#  rewrites each line's status in place (pending -> done|nomatch|failed) so a
#  re-run only retries what hasn't succeeded.
#
#  LIST FORMAT (PIPE-separated '|', one book per line; blank lines & # comments ok):
#     Wolf Hall  |  Hilary Mantel
#     Wolf Hall  |  Hilary Mantel  |  downloaded  |  <md5>  |  <date>   # cols 3-5 added by the script
#  (Fields are Title|Author. The matcher is bidirectional, so Author|Title also
#   works, but the script's own writes use Title|Author.)
#
#  Status values the script writes back:
#     done     queued to Stacks successfully (md5 recorded in 4th column)
#     nomatch  no search result cleared the confidence threshold
#     failed   matched, but the queue POST failed (retry next run)
#     (blank/pending/anything else) -> treated as not-yet-done, will be attempted
#
#  USAGE:
#     ./fetch-books.sh booker.tsv
#     ./fetch-books.sh --dry-run booker.tsv          # search+match, don't queue
#     ./fetch-books.sh --retry booker.tsv            # also re-attempt failed+nomatch
#     ./fetch-books.sh --tag prizewinner booker.tsv  # record tag for later calibre step
#     ./fetch-books.sh --refresh booker.tsv          # update statuses from Stacks
#     CONFIDENCE=0.55 ./fetch-books.sh summer.tsv     # lower the match threshold
#     MAX_PER_HOUR=20 ./fetch-books.sh booker.tsv      # be extra gentle (slower)
#     ./fetch-books.sh *.tsv                          # several lists in one run
#
#  TAGS: a "#tag:" header line (or --tag) sets calibre tags for the whole
#  list; separate multiple with commas (multi-word tags like "Booker Prize" work) ("#tag: prizewinner, booker").
#
#  FILTERS: results are restricted to ebook formats (FORMATS, never pdf) and to
#  English (LANGS=en). Override: FORMATS="epub" or LANGS="en fr" or LANGS="" (any).
#
#  RATE LIMIT: searches are paced to at most MAX_PER_HOUR (default 30) and never
#  faster than DELAY seconds apart, plus 0..JITTER random seconds so the cadence
#  isn't a perfect metronome. Set MAX_PER_HOUR=0 to disable the cap. Downloads
#  are Stacks' job and are self-limited by the slow-mirror servers, so only the
#  search rate is controlled here.
#
#  MIRROR HEALTH: before searching, if the check-mirrors state file is older
#  than STALE_SECS (default 3600s/1h) and check-mirrors.sh is found at
#  $CHECK_MIRRORS, it is run to refresh the WORKING-mirror list. Set the path:
#     CHECK_MIRRORS=~/scripts/check-mirrors.sh ./fetch-books.sh booker.tsv
#  Only mirrors marked WORKING are searched (full built-in list if no state).
#
#  STATUS COLUMN (4th field after author|title): the line lifecycle is
#     queued       -> sent to Stacks' download queue
#     downloading  -> Stacks is fetching it now      (after --refresh)
#     completed    -> Stacks finished the download    (after --refresh)
#     error        -> Stacks failed all mirrors       (after --refresh)
#     tagged       -> calibre tag applied             (set by tag-books.sh)
#     nomatch      -> search found nothing >= CONFIDENCE
#  A 5th 'date' column records when the status last changed.
#  Run with --refresh (any time after queuing) to pull live state from Stacks'
#  /api/status and update the status+date columns. Uses the admin key.
#
#  FAST DOWNLOAD (Anna's membership): if you set fast_download.enabled:true and
#  a key in Stacks' config.yaml, fetch-books verifies via /api/status that the
#  key works and ABORTS if it doesn't (so books aren't silently sent down the
#  flaky free path). No key = free mirror path, used automatically.
#
#  QUOTA: a paid key has a daily download cap. fetch-books reads downloads_left
#  and STOPS queuing before driving it to/below QUOTA_FLOOR (default 5), so one
#  list run can't exhaust your daily allowance. Un-queued books stay 'pending'
#  for a later run. It projects from the starting figure (since Stacks consumes
#  quota as it downloads, lagging our queuing) and re-polls live every
#  QUOTA_RECHECK books (default 10) as a backstop. Set QUOTA_FLOOR=0 to disable.
#
#  RETRY: a normal run attempts only blank/pending lines (done/failed/nomatch
#  are left untouched). --retry additionally re-searches nomatch lines and
#  re-queues failed ones. done lines are never re-attempted.
# =============================================================================
set -uo pipefail

# ---- cleanup on exit/interrupt ---------------------------------------------
# Track temp files (mktemp scratch + in-flight .part downloads) so a Ctrl-C or
# crash doesn't orphan them. CLEANUP_FILES are host paths; CLEANUP_PARTS are
# (container:path) pairs for downloads living inside DL_CONTAINER's mount.
CLEANUP_FILES=()
CLEANUP_PARTS=()
cleanup() {
    [ "${#CLEANUP_FILES[@]}" -gt 0 ] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null
    # one docker exec for ALL parts, not one per file: docker exec has ~0.2-0.5s
    # startup, so a per-part loop made Ctrl-C hang for seconds when many parts
    # were in flight. rm -f takes the whole array at once.
    if [ "${#CLEANUP_PARTS[@]}" -gt 0 ]; then
        docker exec "${DL_CONTAINER:-qbittorrent}" rm -f "${CLEANUP_PARTS[@]}" 2>/dev/null || true
    fi
}
# On a signal (Ctrl-C / kill), clean up AND EXIT. Without the explicit exit, a
# bash INT trap runs the handler then RESUMES the interrupted command, so the
# loop carried on after Ctrl-C — which is why it felt uninterruptible. EXIT runs
# cleanup only (no exit, or it would recurse). 130 = standard "killed by SIGINT".
on_signal() { echo; log "interrupted — cleaning up and stopping."; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal HUP INT TERM

# ---- config (override via env) ---------------------------------------------
STACKS_URL="${STACKS_URL:-http://localhost:7788}"
CONFIG_YAML="${CONFIG_YAML:-/home/robmorgan/gunit/stacks_config/config.yaml}"
FLARESOLVERR="${FLARESOLVERR:-http://localhost:8191/v1}"
CONTAINER="${CONTAINER:-gluetun}"
# Container used for the actual file download + move: it must be BOTH on the VPN
# (gluetun netns) AND have the media volume mounted. gluetun itself has the VPN
# but NOT the disk, so writes vanish. qbittorrent shares gluetun's netns and has
# /Nutmeg mounted, so it can both reach the partner server and write the file.
DL_CONTAINER="${DL_CONTAINER:-qbittorrent}"
# Owner the watcher expects on imported files (host uid:gid = robmorgan:media).
# Both download paths chown to this: SE (host-side) and Anna's (inside the
# container, via docker exec running as root). Set empty to skip chowning.
WATCHER_OWNER="${WATCHER_OWNER:-${SE_CHOWN:-2001:2002}}"
# Direct Anna's fast-download (bypasses Stacks). Reads the key from Stacks'
# config.yaml so you keep it in one place. AA_DOMAIN is the mirror used for the
# fast_download.json API call; DEST is the watched folder the watcher imports.
AA_KEY="${AA_KEY:-$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)}"
# Mirrors to try for the fast_download API, in order — falls through on 502 /
# unreachable so one flaky mirror doesn't abort the run. Override with a single
# or space-separated AA_DOMAINS.
AA_DOMAINS="${AA_DOMAINS:-${AA_DOMAIN:-annas-archive.se annas-archive.pk annas-archive.gd annas-archive.gl}}"
DEST="${DEST:-/Nutmeg/Media/Books/incoming/gunit_user_folders/shops@rob.me.uk}"
# An INVALID md5 used only to probe key/quota at preflight WITHOUT consuming a
# download (a valid md5 would burn one of your daily quota each run). Anna's
# returns the quota info in its error response for a bad md5.
PROBE_MD5="${PROBE_MD5:-00000000000000000000000000000000}"
MAXTIMEOUT="${MAXTIMEOUT:-60000}"
MIN_GOOD_BYTES="${MIN_GOOD_BYTES:-100000}"
MIRROR_STATE="${MIRROR_STATE:-$HOME/.cache/check-mirrors.state}"
CHECK_MIRRORS="${CHECK_MIRRORS:-$HOME/scripts/check-mirrors.sh}"  # set to your path
STALE_SECS="${STALE_SECS:-3600}"     # refresh mirror check if state older than this
CONFIDENCE="${CONFIDENCE:-0.6}"      # 0..1; top hit must score >= this to queue
DELAY="${DELAY:-3}"                  # min seconds between books (floor)
MAX_PER_HOUR="${MAX_PER_HOUR:-0}"    # 0 = no hourly cap; fast-download is quota-limited (50/day) so the search rate isn't the bottleneck. Set e.g. 60 to throttle if Anna's challenges the search.
QUOTA_FLOOR="${QUOTA_FLOOR:-4}"      # stop queuing when fast-download quota would drop to/below this (keep this many in reserve)
QUOTA_RECHECK="${QUOTA_RECHECK:-10}" # re-poll live downloads_left every N queued books
JITTER="${JITTER:-8}"                # +0..JITTER random secs added per wait (anti-metronome)
FORMATS="${FORMATS:-epub azw3 mobi fb2}"  # acceptable ebook formats, in preference order; never pdf
LANGS="${LANGS:-en}"                 # language codes to allow (space-separated); empty = any
# Pre-fetch library check: before spending a download, see if the book is ALREADY
# in calibre (by annas:<md5> identifier, else strict title/author match) and skip
# if so, marking the row as in-library rather than burning a quota slot. Set
# LIB_CHECK=0 to disable (falls back to TSV-status dedup only).
LIB_CHECK="${LIB_CHECK:-1}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"   # run calibredb as abc, not root
ID_SCHEME="${ID_SCHEME:-annas}"             # identifier scheme tag-books stamps md5 under

# ---- Standard Ebooks (free public-domain source, tried before Anna's) -------
# SE is a static public site: no Cloudflare challenge, no membership key, no
# quota, no VPN required. We still route the HTML fetch through CONTAINER and
# the file download through DL_CONTAINER (which owns the disk mount), reusing
# the existing two-container split. SE_FIRST=0 disables and goes straight to
# Anna's. SE_FORMAT picks the download flavour; "compatible" is the plain epub
# (KOReader on Kindle reads it directly). SE match is AUTHORITATIVE: a confident
# match that fails to download is marked 'failed', NOT retried via Anna's.
SE_FIRST="${SE_FIRST:-1}"
SE_BASE="${SE_BASE:-https://standardebooks.org}"
SE_FORMAT="${SE_FORMAT:-compatible}"   # compatible | advanced | azw3 | kepub
# SE traffic runs on the HOST over the direct connection, not through gluetun:
# SE gates direct downloads by IP and the VPN (Romania) exit gets an HTML gate
# page instead of the epub, while otis's own connection gets the binary. Detect
# a host downloader once at startup. curl preferred (cleaner failure codes).
SE_DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then SE_DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then SE_DOWNLOADER="wget"; fi

# se_host_get URL -> echo body fetched on the host (direct connection). Used for
# SE SEARCH (download has its own streaming-to-file path in se_download). Empty
# echo on failure. Honours SE_DOWNLOADER.
se_host_get() {
    local url="$1"
    case "$SE_DOWNLOADER" in
        curl) curl -fsSL --connect-timeout 20 --max-time 60 "$url" 2>/dev/null ;;
        wget) wget -qO- --timeout=60 "$url" 2>/dev/null ;;
        *)    return 1 ;;
    esac
}
# Tag queue: on each successful download, append {md5,tags,title,author,queued_at}
# here so tag-queue.sh can tag the book once it's imported into calibre. Empty
# tags (no #tag: header, no --tag) means nothing to enqueue. TAG_QUEUE='' disables.
TAG_QUEUE="${TAG_QUEUE:-/home/robmorgan/gunit/state/tag-queue.json}"
LOG="${LOG:-$HOME/logs/fetch-books.log}"

ALL_MIRRORS="${MIRRORS:-\
https://annas-archive.gd \
https://annas-archive.gl \
https://annas-archive.pk \
https://annas-archive.li \
https://annas-archive.se}"

DRY_RUN=0
RETRY=0
REFRESH=0
TAG=""

# ---- args ------------------------------------------------------------------
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --retry)   RETRY=1; shift ;;
        --refresh) REFRESH=1; shift ;;
        --tag)
            # guard: shift 2 with no value left fails to advance -> infinite loop.
            [ "$#" -ge 2 ] || { echo "error: --tag requires a value" >&2; exit 1; }
            TAG="$(printf '%s' "$2" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"
            shift 2 ;;
        --help|-h) sed -n '2,48p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 1 ;;
        *)         FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -eq 0 ] && { echo "usage: $0 [--dry-run] [--tag NAME] LIST.tsv..." >&2; exit 1; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null

# ---- coloured logging ------------------------------------------------------
# log() writes a plain line to the logfile AND a (possibly coloured) line to the
# terminal. Colour goes ONLY to the terminal copy — never into the logfile,
# where escape codes would corrupt it. Colour is auto-disabled when stderr is
# not a TTY (e.g. the systemd timer redirects to the log) or when NO_COLOR is
# set (https://no-color.org). The colour is chosen from the message content so
# every existing call site stays unchanged.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_BOLD=''
fi

# pick a colour for a message by matching distinctive substrings. Order matters:
# the first match wins, so errors/warnings are tested before softer states.
_log_colour() {
    case "$1" in
        FATAL*|*FATAL*)                                   printf '%s' "$C_BOLD$C_RED" ;;
        WARNING*|*WARNING*|*"not an epub"*|*"download failed"*|*"move failed"*) printf '%s' "$C_YEL" ;;
        "=== fetch-books"*|"=== refresh"*)                printf '%s' "$C_BOLD$C_CYN" ;;
        "→ "*|*"→ "*)                                     printf '%s' "$C_BOLD$C_BLU" ;;  # a book being processed
        *"SE downloaded"*|*"downloaded ->"*|*"downloaded  ("*) printf '%s' "$C_GRN" ;;     # success
        *"already in library"*|*"already-done"*)          printf '%s' "$C_DIM$C_GRN" ;;
        *nomatch*|*"not on Standard Ebooks"*)             printf '%s' "$C_DIM" ;;
        *"library check unavailable"*|*"deferring"*|*"QUOTA STOP"*|*"quota_blocked"*|*"Anna's paused"*|*"quota exhausted"*|*"floor reached"*) printf '%s' "$C_YEL" ;;
        *"fast-download: ACTIVE"*|*"host downloader"*)    printf '%s' "$C_CYN" ;;
        *"(pacing"*)                                      printf '%s' "$C_DIM" ;;
        *FILE\ *queued:*)                                 printf '%s' "$C_BOLD" ;;        # per-file summary
        *)                                                printf '' ;;
    esac
}

log() {
    local msg="$*" ts; ts="$(date '+%F %T')"
    # plain to logfile
    printf '%s  %s\n' "$ts" "$msg" >> "$LOG"
    # coloured (or plain, if disabled) to terminal
    local col; col="$(_log_colour "$msg")"
    if [ -n "$col" ]; then
        printf '%s  %s%s%s\n' "$ts" "$col" "$msg" "$C_RESET" >&2
    else
        printf '%s  %s\n' "$ts" "$msg" >&2
    fi
}

# ---- api keys --------------------------------------------------------------
# config.yaml has two under "api:":  key (admin) and downloader_key.
# queue/add accepts the downloader key; /api/status needs the admin key.
ADMIN_KEY="$(awk '/^api:/{f=1} f&&/ key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
DOWNLOADER_KEY="$(awk '/^api:/{f=1} f&&/downloader_key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
# the queue uses the downloader key if present, else admin
API_KEY="$DOWNLOADER_KEY"
{ [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; } && API_KEY="$ADMIN_KEY"
if [ -z "${API_KEY:-}" ] || [ "$API_KEY" = "null" ]; then
    log "FATAL: could not read an api key from $CONFIG_YAML"; exit 1
fi

# ---- fetch Stacks status (admin key) ---------------------------------------
fetch_status() {  # echoes the raw JSON from /api/status
    curl -s "${STACKS_URL}/api/status?api_key=${ADMIN_KEY}"
}

# fast_api_call <md5> -> echoes the JSON response from the first mirror that
# returns parseable JSON (not a 502/HTML/empty). Sets FAST_DOMAIN_USED to the
# mirror that worked. Returns 1 if all mirrors fail.
FAST_DOMAIN_USED=""
fast_api_call() {
    local md5="$1" d url resp
    for d in $AA_DOMAINS; do
        url="https://${d}/dyn/api/fast_download.json?md5=${md5}&key=${AA_KEY}"
        # URL passed as a native arg to wget (no sh -c string), so a key with
        # shell metacharacters can't break out. --content-on-error first; if that
        # wget build lacks the flag (empty result), retry plain.
        resp="$(docker exec "$CONTAINER" wget -qO- --content-on-error --timeout=30 "$url" 2>/dev/null)"
        [ -z "$resp" ] && resp="$(docker exec "$CONTAINER" wget -qO- --timeout=30 "$url" 2>/dev/null)"
        # accept only if it parses as JSON
        if printf '%s' "$resp" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
            FAST_DOMAIN_USED="$d"
            printf '%s' "$resp"
            return 0
        fi
        # else try next mirror (502, HTML, empty, etc.)
    done
    return 1
}

# ---- fast-download preflight (direct Anna's API, no Stacks) -----------------
# Confirms the membership key works by calling the live fast_download API. We
# need a key (read from config or AA_KEY) — without one we can't download, so
# this aborts. With one, it reads the real downloads_left to seed the quota
# guard. The probe uses a known md5 with the key; a 200 + quota info = good.
preflight_fast_download() {
    if [ -z "${AA_KEY:-}" ] || [ "$AA_KEY" = "null" ]; then
        log "FATAL: no Anna's fast-download key found (fast_download.key in $CONFIG_YAML,"
        log "       or set AA_KEY=...). Direct download needs a membership key. Aborting."
        return 1
    fi
    # probe the key WITHOUT consuming a download, using an invalid md5, trying
    # mirrors in turn (one mirror's 502 shouldn't abort). Valid JSON with
    # error:"Record not found" proves API reachable AND key accepted (a bad key
    # gives a key/auth error). Bad-md5 probe carries no quota; that's read live.
    local resp err
    resp="$(fast_api_call "$PROBE_MD5")"
    if [ $? -ne 0 ] || [ -z "$resp" ]; then
        log "FATAL: fast-download API unreachable on all mirrors ($AA_DOMAINS)."
        log "       Mirrors may be down (502) or the VPN is blocked. Try again shortly."
        return 1
    fi
    err="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("__BADJSON__")' 2>/dev/null)"
    if [ "$err" = "__BADJSON__" ]; then
        log "FATAL: fast-download API returned unparseable response on $FAST_DOMAIN_USED."
        return 1
    fi
    case "$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')" in
        *key*|*secret*|*member*|*auth*|*account*|*invalid*)
            log "FATAL: fast-download key rejected by Anna's: \"$err\". Check the key/membership."
            return 1 ;;
    esac
    FAST_ACTIVE=1
    # Seed the quota floor NOW with an EXACT live read. The key-validity check
    # above used an invalid md5 (which may NOT return account info); the precise,
    # shelfmark-inclusive quota comes from quota-probe.sh, the shared helper that
    # quota-status.sh also uses. It queries the JSON API with a VALID md5 — which
    # returns account_fast_download_info WITHOUT spending a slot (you're only
    # charged when you fetch the download_url). Sourced like match-lib.sh.
    # Fallbacks: if the helper is missing or the probe fails, try to read quota
    # from the invalid-md5 response we already have; if that's empty too, learn
    # it live from the first download (QUOTA_START stays "").
    QUOTA_START=""
    local _qp="$(dirname "$0")/quota-probe.sh"
    if [ -f "$_qp" ]; then
        # source the shared helper for its quota_probe function. It reads its own
        # env vars via ${VAR:-default}; set them to fetch-books' values FIRST so
        # both agree on container/mirror (the helper won't override a set value).
        # Save + restore fetch-books' own PROBE_MD5 (the helper needs a VALID md5
        # and sets one; our invalid-md5 key-check already ran above, and nothing
        # else should inherit the changed value).
        local _saved_probe_md5="$PROBE_MD5"
        GLUETUN_CONTAINER="$CONTAINER"
        AA_DOMAIN="${AA_DOMAINS%% *}"   # first of fetch-books' mirror list
        unset PROBE_MD5                  # let the helper apply its own valid md5
        # shellcheck disable=SC1090
        . "$_qp"
        if command -v quota_probe >/dev/null 2>&1 && quota_probe 2>/dev/null; then
            QUOTA_START="$QP_LEFT"
            [ -n "${QP_DONE:-}" ] && [ -n "${QP_CAP:-}" ] \
                && log "fast-download: live quota ${QP_LEFT} left (${QP_DONE}/${QP_CAP} used today, incl. shelfmark)"
        fi
        PROBE_MD5="$_saved_probe_md5"
    fi
    if [ -z "$QUOTA_START" ]; then
        QUOTA_START="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
    fi
    if [ -n "$QUOTA_START" ]; then
        log "fast-download: ACTIVE (key accepted; ${QUOTA_START} downloads left, floor ${QUOTA_FLOOR})"
        if [ "$QUOTA_START" -le "$QUOTA_FLOOR" ]; then
            # already at/under the floor: start in SE-only mode. SE (free) still
            # runs for every book; Anna's-only books get marked quota_blocked.
            ANNAS_QUOTA_OUT=1
            log "fast-download: only ${QUOTA_START} left (<= floor ${QUOTA_FLOOR}) — Anna's paused; Standard Ebooks still active."
        fi
    else
        log "fast-download: ACTIVE (key accepted; quota read live during run)"
    fi
    return 0
}

# ---- fast-download quota guard ---------------------------------------------
# Globals: FAST_ACTIVE (1 if fast-download on), QUOTA_START (downloads_left at
# preflight), QUEUED_RUN (count queued this run). The guard stops queuing before
# we'd drive the daily quota to/below QUOTA_FLOOR. Because Stacks consumes quota
# only as it downloads (lagging our queuing), we project from QUOTA_START minus
# what we've queued, AND re-poll the live figure every QUOTA_RECHECK books as a
# backstop. Returns 0 = ok to queue, 1 = stop (quota floor reached).
FAST_ACTIVE=0
QUOTA_START=""
QUEUED_RUN=0
ANNAS_QUOTA_OUT=0   # set once Anna's daily quota is spent; SE (free) still runs,
                    # but Anna's search/download is skipped and books only SE
                    # lacks are marked 'quota_blocked' for a later run.

quota_ok() {
    # only relevant when fast-download is the active path
    [ "$FAST_ACTIVE" -eq 1 ] || return 0
    # the most recent download reports the true remaining quota in QUOTA_LIVE;
    # prefer it over the projection when we have it.
    if [ -n "$QUOTA_LIVE" ]; then
        if [ "$QUOTA_LIVE" -le "$QUOTA_FLOOR" ]; then
            log "  QUOTA STOP: ${QUOTA_LIVE} fast downloads left <= floor ${QUOTA_FLOOR}."
            log "  Remaining books left un-queued — run again after your daily reset."
            return 1
        fi
        return 0
    fi
    # before the first download we only have the projection from preflight
    if [ -n "$QUOTA_START" ]; then
        local projected=$(( ${QUOTA_START:-0} - ${QUEUED_RUN:-0} ))
        if [ "$projected" -le "$QUOTA_FLOOR" ]; then
            log "  QUOTA STOP: projected ${projected} <= floor ${QUOTA_FLOOR} (started ${QUOTA_START})."
            return 1
        fi
    fi
    return 0
}

# ---- refresh mode: update statuses from Stacks, don't fetch ----------------
# Builds an md5 -> state map from /api/status, rewrites each queued line's
# status + date. States use Stacks' own vocabulary: queued / downloading /
# completed / error.
refresh_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    local st; st="$(fetch_status)"
    if [ -z "$st" ] || ! printf '%s' "$st" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        log "FATAL: could not read /api/status (admin key wrong, or Stacks down)"; return 1
    fi

    # md5 -> state map as "md5 state" lines, parsed ONCE into a bash associative
    # array. The old code forked awk per TSV row to look up the map, which on a
    # 500-book list meant 500 awk processes; an in-memory assoc array makes each
    # lookup instant.
    local map
    map="$(printf '%s' "$st" | python3 -c '
import sys, json
s = json.load(sys.stdin)
state = {}
for item in s.get("queue", []):
    if item.get("md5"): state[item["md5"]] = "queued"
for item in s.get("current_downloads", []):
    if item.get("md5"): state[item["md5"]] = "downloading"
for item in s.get("recent_history", []):
    md5 = item.get("md5")
    if not md5: continue
    if item.get("error"): state[md5] = "error"
    elif item.get("completed_at"): state[md5] = "completed"
    else: state[md5] = "queued"
for md5, stt in state.items():
    print(md5, stt)
')"
    declare -A STATEMAP=()
    local _k _v
    while read -r _k _v; do
        [ -n "$_k" ] && STATEMAP["$_k"]="$_v"
    done <<< "$map"

    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp"); local n_upd=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac
        local a t s m d raw_nocr
        # split on '|' with one read instead of five cut forks (matches the
        # process_file parser). strip CR first; trim/strip per field after.
        raw_nocr="${raw%$'\r'}"
        IFS='|' read -r a t s m d <<< "$raw_nocr"
        s="$(printf '%s' "${s:-}" | tr -d '[:space:]')"
        m="$(printf '%s' "${m:-}" | tr -d '[:space:]')"
        # don't touch tagged lines or lines without an md5
        if [ "$s" = "tagged" ] || [ -z "$m" ]; then printf '%s\n' "$raw" >> "$tmp"; continue; fi
        local newstate="${STATEMAP[$m]:-}"
        if [ -n "$newstate" ] && [ "$newstate" != "$s" ]; then
            printf '%s|%s|%s|%s|%s\n' "$a" "$t" "$newstate" "$m" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            log "  $a — $t: $s -> $newstate"
            n_upd=$((n_upd+1))
        else
            printf '%s\n' "$raw" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
    log "FILE $file — $n_upd status update(s)"
}

if [ "$REFRESH" -eq 1 ]; then
    log "=== fetch-books v$FETCH_BOOKS_VERSION --refresh (querying Stacks status) ==="
    for f in "${FILES[@]}"; do refresh_file "$f"; done
    log "=== refresh done ==="
    exit 0
fi

# ---- refresh mirror health if state is stale -------------------------------
refresh_mirrors_if_stale() {
    local age=999999
    if [ -f "$MIRROR_STATE" ]; then
        age=$(( $(date +%s) - $(date -r "$MIRROR_STATE" +%s) ))
    fi
    if [ "$age" -lt "$STALE_SECS" ]; then
        log "mirror state is fresh (${age}s old, threshold ${STALE_SECS}s) — skipping check"
        return
    fi
    if [ ! -x "$CHECK_MIRRORS" ] && [ ! -f "$CHECK_MIRRORS" ]; then
        log "mirror state stale (${age}s) but check-mirrors not found at $CHECK_MIRRORS — using existing state"
        return
    fi
    log "mirror state stale (${age}s old) — running $CHECK_MIRRORS to refresh"
    # run it; its output goes to the log, its state file is what we consume
    NO_COLOR=1 STATE_FILE="$MIRROR_STATE" bash "$CHECK_MIRRORS" >>"$LOG" 2>&1 \
        && log "mirror check complete" \
        || log "mirror check exited non-zero — proceeding with whatever state exists"
}
refresh_mirrors_if_stale

# ---- which mirrors to use --------------------------------------------------
mirrors=()
if [ -n "${MIRRORS:-}" ]; then
    # explicit MIRRORS= on the command line wins over the state file
    read -ra mirrors <<< "$MIRRORS"
    log "using explicit MIRRORS override: ${mirrors[*]}"
elif [ -f "$MIRROR_STATE" ]; then
    while IFS='|' read -r host verdict; do
        [ "$verdict" = "WORKING" ] && mirrors+=("https://$host")
    done < "$MIRROR_STATE"
fi
if [ "${#mirrors[@]}" -eq 0 ]; then
    log "no WORKING mirrors in $MIRROR_STATE — using full built-in list"
    read -ra mirrors <<< "$ALL_MIRRORS"
fi

# ---- helpers ---------------------------------------------------------------
# Shared confidence matcher lives in match-lib.sh (norm, ge, author_match,
# meaningful_words, title_full_match, book_match_score) so fetch-books and
# tag-books agree on what a match is. Sourced here; fetch-specific helpers
# (score, pace, search_one) stay below.
. "$(dirname "$0")/match-lib.sh"

# token-overlap score of needle vs haystack, 0..1 (fraction of needle tokens
# present in haystack). fetch-only; not part of the shared gate.
score() {
    local needle haystack; needle="$(norm "$1")"; haystack=" $(norm "$2") "
    local hit=0 tot=0 w
    for w in $needle; do
        tot=$((tot+1))
        case "$haystack" in *" $w "*) hit=$((hit+1));; esac
    done
    [ "$tot" -eq 0 ] && { echo 0; return; }
    awk -v h="$hit" -v t="$tot" 'BEGIN{printf "%.3f", h/t}'
}


# pace between searches: honour both the DELAY floor and the MAX_PER_HOUR cap,
# plus a small random jitter so the cadence isn't a perfect (bot-like) metronome.
pace() {
    local base="$DELAY"
    if [ "$MAX_PER_HOUR" -gt 0 ]; then
        local by_rate=$(( 3600 / MAX_PER_HOUR ))
        [ "$by_rate" -gt "$base" ] && base="$by_rate"
    fi
    local jit=0
    [ "$JITTER" -gt 0 ] && jit=$(( RANDOM % (JITTER + 1) ))
    local wait=$(( base + jit ))
    log "    (pacing ${wait}s)"
    sleep "$wait"
}

# search one query across mirrors; echo "md5 | result_text" for the best hit
# that clears CONFIDENCE, else echo nothing.
search_one() {
    local author="$1" title="$2"
    local want_t want_a; want_t="$(norm "$title")"; want_a="$(norm "$author")"
    local q resp best_md5="" best_score=0 best_text=""

    # URL-encode the query properly. The old "sed 's/ /+/g'" only handled
    # spaces, so titles with a colon, apostrophe, ampersand, question mark, or
    # any non-ASCII char (curly apostrophe U+2019 etc.) produced a malformed
    # query and Anna's returned nothing -> false nomatch. quote_plus encodes
    # everything safely (space->+, : -> %3A, ' -> %27, & -> %26, ...).
    q="$(printf '%s' "${title} ${author}" | python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.stdin.read().strip()))' 2>/dev/null)"
    [ -z "$q" ] && q="$(echo "${title} ${author}" | sed 's/ /+/g')"   # fallback

    # format filter: Anna's accepts repeated &ext=<fmt>; restrict to ebook
    # formats so PDFs (and other junk) never enter the candidate list.
    local extfilter="" f
    for f in $FORMATS; do extfilter="${extfilter}&ext=${f}"; done

    # language filter: Anna's accepts repeated &lang=<code>; restrict to English
    # (or whatever LANGS lists). Empty LANGS = no language restriction.
    local langfilter="" l
    for l in $LANGS; do langfilter="${langfilter}&lang=${l}"; done

    local base
    local mirrors_answered=0
    for base in "${mirrors[@]}"; do
        local url payload
        url="${base%/}/search?q=${q}${extfilter}${langfilter}"
        payload="{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":$MAXTIMEOUT}"
        resp="$(docker exec "$CONTAINER" sh -c \
            "wget -qO- --timeout=$(( MAXTIMEOUT/1000 + 15 )) \
             --post-data='$payload' --header='Content-Type: application/json' \
             '$FLARESOLVERR' 2>/dev/null")"
        # A dead mirror returns nothing (FlareSolverr can't reach it). Don't skip
        # silently — that turned "no mirror answered" into an indistinguishable
        # "nomatch". Log it so a search miss caused by dead mirrors is visible.
        if [ -z "$resp" ]; then
            log "      mirror unreachable: ${base#https://} (no data via FlareSolverr)"
            continue
        fi
        if [ "${#resp}" -lt "$MIN_GOOD_BYTES" ]; then
            log "      mirror returned too little (<${MIN_GOOD_BYTES}B): ${base#https://}"
            continue
        fi
        mirrors_answered=$((mirrors_answered+1))

        # FlareSolverr returns the page wrapped in a JSON envelope
        # ({"solution":{"response":"<html...>"}}) where non-ASCII chars are JSON
        # unicode escapes (á -> \u00e1). The parsers below do html.unescape but
        # NOT json-decode, so a title like "Pedro Páramo" arrived as the LITERAL
        # 12 chars "Pedro P\u00e1ramo" and norm() mangled it -> score 0.000, while
        # an unaccented "Pedro Paramo" entry matched. EVERY non-ASCII title/author
        # was silently failing. Decode the JSON envelope to real HTML ONCE here, so
        # \u00e1 becomes á and norm()'s accent-folding works. Falls back to the raw
        # string if it isn't JSON (e.g. a mirror that returns HTML directly).
        resp="$(printf '%s' "$resp" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    sol = d.get("solution") or {}
    print(sol.get("response", "") or raw)
except Exception:
    print(raw)
' 2>/dev/null)"
        [ -z "$resp" ] && { log "      mirror returned empty after JSON decode: ${base#https://}"; continue; }

        # Anna's LAZY-LOADS search results: each result card is shipped inside an
        # HTML comment (<!-- ... -->) that client-side JS un-comments and renders.
        # FlareSolverr returns the raw HTML BEFORE that JS runs, so the cards stay
        # commented and the parser found 0 results — while the only LIVE /md5/
        # links on the page were the "recent downloads" ticker (decoy books). A
        # book could thus be present yet invisible (e.g. Pedro Páramo: 0 parsed,
        # but 50 real cards once un-commented). Strip the comment MARKERS only
        # (not content) so the real cards become parseable. Harmless when a mirror
        # doesn't comment-wrap (no markers to strip). The field-separated matcher
        # still rejects ticker/decoy entries (e.g. an author literally named
        # "Pedro Paramo" on unrelated books).
        resp="${resp//<!--/}"
        resp="${resp//-->/}"

        # Extract candidates as "md5<TAB>title author" lines. welib and Anna's
        # structure their result cards differently, so use the right extractor.
        local candidates
        case "$base" in
            *welib*)
                # welib puts clean metadata in attributes: data-title / data-author,
                # near each /md5/<hash>. Parse structurally with python.
                candidates="$(printf '%s' "$resp" | python3 -c '
import sys, re, html
s = sys.stdin.read()
# find each md5 and the nearest data-title/data-author after it
out, seen = [], set()
for m in re.finditer(r"/md5/([a-f0-9]{32})", s):
    md5 = m.group(1)
    if md5 in seen: continue
    window = s[m.end(): m.end()+1200]
    t = re.search(r"data-title=\"([^\"]*)\"", window)
    a = re.search(r"data-author=\"([^\"]*)\"", window)
    if not t:
        # fall back to the <h2> heading text after the link
        h = re.search(r"<h2[^>]*>([^<]+)", window)
        t = h
    title = html.unescape(t.group(1)).strip() if t else ""
    author = html.unescape(a.group(1)).strip() if a else ""
    if title:
        seen.add(md5)
        out.append(f"{md5}\t{title}\t{author}")
for line in out[:12]:
    print(line)
' 2>/dev/null)"
                ;;
            *)
                # Anna's result cards. CRITICAL: the page opens with a
                # "recent downloads" ticker (js-recent-downloads-scroll) full of
                # /md5/ links to UNRELATED books, ~150KB before the real results.
                # Parsing from byte 0 scored the ticker — that mis-matched
                # "The Pretender" to "The Fear of Falling" etc. So we first cut
                # to the results region (anchored on the "aarecord" marker the
                # result cards use) and parse only from there.
                #
                # Each real card carries clean fields:
                #   data-content="<title>"  data-content="<author>"   (in the
                #   fallback-cover block), and a path hint
                #   "<collection>/<author>/<Title>_<id>.<ext>".
                # We emit "md5<TAB>title<TAB>author" so the scorer compares
                # title-to-title and author-to-author — no blob contamination.
                candidates="$(printf '%s' "$resp" | python3 -c '
import sys, re, html
s = sys.stdin.read()
# 1. drop everything before the results region. If the anchor is absent
#    (markup changed), produce NO candidates rather than parse the ticker —
#    a clean nomatch is the safe failure direction.
anchor = s.find("aarecord")
if anchor < 0:
    sys.exit(0)
s = s[anchor:]

seen, out = set(), []
for m in re.finditer(r"/md5/([a-f0-9]{32})", s):
    md5 = m.group(1)
    if md5 in seen: continue
    # window for THIS card: up to the next result md5
    card = s[m.end(): m.end()+2500].split("/md5/")[0]

    title = author = ""
    # primary: the two data-content attributes (title first, author second)
    dc = re.findall(r"data-content=\"([^\"]*)\"", card)
    if len(dc) >= 1: title  = html.unescape(dc[0]).strip()
    if len(dc) >= 2: author = html.unescape(dc[1]).strip()

    # fallback: the path hint  <collection>/<author>/<Title>_<id>.<ext>
    if not title or not author:
        ph = re.search(r"[a-z0-9-]+/[^/<>\"]+/[^/<>\"]+_\d+\.[a-z0-9]+", card)
        if ph:
            parts = ph.group(0).split("/")
            if len(parts) >= 3:
                if not author: author = parts[-2].strip()
                if not title:
                    t = re.sub(r"_\d+\.[a-z0-9]+$", "", parts[-1])
                    title = t.replace("_", " ").strip()

    if title:
        seen.add(md5)
        # pipe-separated fields; author may be empty (scorer handles it)
        out.append(f"{md5}\t{title}\t{author}")

for line in out[:30]:
    print(line)
' 2>/dev/null)"
                ;;
        esac

        # NOTE: no bare-hash fallback here. If the HTML parse yields no
        # candidates, we have no title/author metadata to score against —
        # scoring a bare hash always fails (0.000) and queuing an unscored hash
        # is exactly the wrong-book risk. So an empty parse => clean nomatch.

        local line md5 cand_t cand_a s
        # split tab fields with bash read (parsers emit md5\ttitle\tauthor) — no
        # per-candidate cut forks. Validate md5 shape inline.
        while IFS=$'\t' read -r md5 cand_t cand_a; do
            case "$md5" in
                *[!a-f0-9]*|"") continue ;;     # not a clean hex string
            esac
            [ "${#md5}" -eq 32 ] || continue
            # Score field-to-field, both interpretations of the LIST entry
            # (Author|Title or Title|Author). want_t/want_a are this list line's
            # two fields. book_match_fields compares each candidate field to the
            # right wanted field — no blob, so a stray word elsewhere on the page
            # can't leak in. Title gate is strict; weak title needs author (with
            # the order-or-reversal rule from match-lib).
            s="$(book_match_fields "$want_t" "$want_a" "$cand_t" "$cand_a")"
            if ge "$s" "$best_score"; then
                best_score="$s"; best_md5="$md5"
                best_text="$(printf '%s — %s' "$cand_t" "$cand_a" | cut -c1-80)"
            fi
        done <<< "$candidates"

        # got a confident hit on this mirror? stop; else try next mirror
        if [ -n "$best_md5" ] && ge "$best_score" "$CONFIDENCE"; then
            break
        fi
    done

    if [ -n "$best_md5" ] && ge "$best_score" "$CONFIDENCE"; then
        printf '%s\t%s\t%s\n' "$best_md5" "$best_score" "$best_text"
    elif [ "$mirrors_answered" -eq 0 ]; then
        # no mirror responded at all — this is NOT a clean "book not found", it's
        # an infrastructure miss. Signal it so the caller can leave the row
        # pending (retry later) instead of burning it as nomatch.
        printf 'UNREACHABLE\n'
    fi
}

# ---- Standard Ebooks search ------------------------------------------------
# Search SE for the book; if a card clears CONFIDENCE, echo
#   "<author-slug>/<title-slug>\t<score>\t<cand_title> — <cand_author>"
# else echo nothing.
#
# SE result markup is RDFa/schema.org. Each book is an <li> whose about=
# attribute holds the canonical /ebooks/<author>/<title>[/<translator>] path;
# the title is the first <span property="schema:name"> and the author is the
# first schema:name span inside the <p class="author"> block (so a "Translated
# by" name that follows is ignored). We parse per-card structurally and score
# with the SAME shared matcher Anna's uses, so the gate is identical.
#
# Two passes: first "title author" (precise), then — if that found nothing —
# "title" alone. The title-only retry rescues books whose list author is
# misspelled or formatted differently from SE's (e.g. "George Elliot" vs SE's
# "George Eliot"); it's SAFE because book_match_fields still gates every
# candidate, so a bare-title query can widen what SE returns but cannot queue a
# wrong book. SE_TITLE_ONLY_RETRY=0 disables the second pass.
SE_TITLE_ONLY_RETRY="${SE_TITLE_ONLY_RETRY:-1}"

# parse SE search HTML on stdin -> "slug<TAB>title<TAB>author" candidate lines
se_parse_candidates() {
    python3 -c '
import sys, re, html
s = sys.stdin.read()
out, seen = [], set()
for cm in re.finditer(r"<li\b[^>]*\babout=\"(/ebooks/[^\"]+)\"", s):
    slug = cm.group(1)[len("/ebooks/"):].strip("/")
    if not slug or slug in seen:
        continue
    rest = s[cm.end():]
    nxt = re.search(r"<li\b[^>]*\babout=\"/ebooks/|</ol>", rest)
    card = rest[:nxt.start()] if nxt else rest
    tm = re.search(r"property=\"schema:name\"[^>]*>\s*([^<]+?)\s*<", card)
    title = html.unescape(tm.group(1)).strip() if tm else ""
    author = ""
    pm = re.search(r"<p class=\"author\"[^>]*>(.*?)</p>", card, re.S)
    if pm:
        am = re.search(r"property=\"schema:name\"[^>]*>\s*([^<]+?)\s*<", pm.group(1))
        if am:
            author = html.unescape(am.group(1)).strip()
    if title:
        seen.add(slug)
        out.append((slug, title, author))
for slug, title, author in out[:48]:
    print(f"{slug}\t{title}\t{author}")
' 2>/dev/null
}

# fetch + parse + score one SE query string. Echoes the best
# "slug\tscore\ttext" that clears CONFIDENCE for the wanted title/author, else
# nothing. want_t/want_a are the list's two fields (bidirectional matcher).
se_query_and_score() {
    local query="$1" want_t="$2" want_a="$3"
    local q url resp candidates
    q="$(printf '%s' "$query" | python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.stdin.read().strip()))' 2>/dev/null)"
    [ -z "$q" ] && return 0
    url="${SE_BASE%/}/ebooks?query=${q}&sort=relevance&view=grid&per-page=48"
    # fetch on the host (direct), consistent with se_download — keeps SE entirely
    # off the VPN so a gated exit can't break search either.
    resp="$(se_host_get "$url")"
    [ -z "$resp" ] && return 0
    candidates="$(printf '%s' "$resp" | se_parse_candidates)"
    [ -z "$candidates" ] && return 0

    local best_slug="" best_score=0 best_text="" slug cand_t cand_a sc
    local want_t_norm want_a_norm
    want_t_norm="$(norm "$want_t")"; want_a_norm="$(norm "$want_a")"
    while IFS=$'\t' read -r slug cand_t cand_a; do
        [ -z "$slug" ] && continue
        sc="$(book_match_fields "$want_t" "$want_a" "$cand_t" "$cand_a")"
        # SE-ONLY exact-title acceptance: the shared matcher requires author
        # corroboration for SHORT titles (the "Eragon" subset guard), so a
        # 1-word title like "Middlemarch" scores 0 when the list author is
        # misspelled ("George Elliot" vs SE's "George Eliot"). For SE's small,
        # curated public-domain catalogue an EXACT normalized title match
        # (equality, not subset) is a safe standalone signal — it cannot match a
        # longer different title. The list field order is ambiguous, so accept if
        # the candidate title exactly equals EITHER wanted field. Grant the 0.7
        # title-only floor. SE-only; match-lib and Anna's keep the stricter rule.
        #
        # BUT the floor must NOT override a CONTRADICTING author: an exact title
        # by a DIFFERENT author is a different book (e.g. "The Secret History" by
        # Donna Tartt vs Procopius's "The Secret History"). Only apply the floor
        # when the candidate author is absent, or shares at least one word with a
        # wanted field (which covers misspellings — "Elliot"/"Eliot" share
        # "George"). A present-but-zero-overlap author blocks the floor.
        local cand_t_norm; cand_t_norm="$(norm "$cand_t")"
        if { [ -n "$want_t_norm" ] && [ "$cand_t_norm" = "$want_t_norm" ]; } \
           || { [ -n "$want_a_norm" ] && [ "$cand_t_norm" = "$want_a_norm" ]; }; then
            local author_ok=0
            if [ -z "$(norm "$cand_a")" ]; then
                author_ok=1   # absent author can't contradict
            elif ge "$(author_match "$want_t" "$cand_a")" "0.001" \
              || ge "$(author_match "$want_a" "$cand_a")" "0.001"; then
                author_ok=1   # shares a word (covers misspellings)
            fi
            [ "$author_ok" -eq 1 ] && { ge "$sc" "0.700" || sc="0.700"; }
        fi
        if ge "$sc" "$best_score"; then
            best_score="$sc"; best_slug="$slug"
            best_text="$(printf '%s — %s' "$cand_t" "$cand_a" | cut -c1-80)"
        fi
    done <<< "$candidates"

    if [ -n "$best_slug" ] && ge "$best_score" "$CONFIDENCE"; then
        printf '%s\t%s\t%s\n' "$best_slug" "$best_score" "$best_text"
    fi
}

se_search_one() {
    local f1="$1" f2="$2" hit
    # pass 1: both fields together (precise)
    hit="$(se_query_and_score "${f1} ${f2}" "$f1" "$f2")"
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
    # pass 2: single-field retries. The list field order is ambiguous (the
    # matcher is bidirectional for exactly this reason), so we don't know which
    # field is the title. Query EACH field alone; the one that is the real title
    # will find + accept the book (exact-title path), the other returns nothing.
    # This rescues a misspelled/mis-formatted author: searching the title alone
    # avoids the bad author token that made SE's search return zero results.
    if [ "$SE_TITLE_ONLY_RETRY" = "1" ]; then
        local fld
        for fld in "$f1" "$f2"; do
            [ -z "$fld" ] && continue
            hit="$(se_query_and_score "$fld" "$f1" "$f2")"
            if [ -n "$hit" ]; then
                log "    SE: matched on single-field retry (list author may differ from SE's)"
                printf '%s\n' "$hit"; return 0
            fi
        done
    fi
    return 0
}

# ---- Standard Ebooks download ----------------------------------------------
# Given a slug path (author/title[/translator]), build the epub download URL and
# fetch it into DEST. CRITICAL DETAILS learned the hard way:
#
#  * The bare download URL returns the "Your Download Has Started!" HTML
#    interstitial (Content-Type application/xhtml+xml), NOT the epub. A real
#    browser gets the binary by appending ?source=download — that query param is
#    the bypass and returns Content-Type application/epub+zip. We append it.
#  * That interstitial page carries a honeypot link that BANS YOUR IP FOR 24
#    HOURS if a crawler follows it. We never parse or follow links on it — we
#    only request the known URL + ?source=download directly.
#  * SE gates direct downloads by IP. Through the gluetun VPN (Romania exit) the
#    request returns the interstitial; over otis's OWN direct connection it
#    returns the epub. So SE downloads run ON THE HOST (curl/wget here), NOT
#    through DL_CONTAINER/gluetun. SE is a legal public-domain source, so there's
#    no reason to route it via the VPN anyway.
#  * The host (otis) runs this as uid 2001 / gid 2002 (= the owner the watcher
#    expects), so files land correctly owned; we still chown/chmod defensively.
#
# Same placement discipline as Anna's: temp .part, validate, atomic move. PK
# magic-byte check rejects any non-epub (e.g. an interstitial that slipped
# through). Returns 0 ok, 1 fail.
SE_CHOWN="${SE_CHOWN:-$WATCHER_OWNER}"   # owner to set on SE files (= WATCHER_OWNER); empty = skip

# Map SE_FORMAT to the link LABEL SE uses on the book page, so we scrape the
# correct download href rather than guessing the filename (which differs for
# translated works, where the epub filename includes the translator slug).
se_format_label() {
    case "$1" in
        compatible) echo "Compatible epub" ;;
        advanced)   echo "Advanced epub" ;;
        azw3)       echo "azw3" ;;
        kepub)      echo "kepub" ;;
        *)          echo "" ;;
    esac
}

se_download() {
    local slug="$1"
    local page page_url href url tmp fname label
    label="$(se_format_label "$SE_FORMAT")"
    [ -z "$label" ] && { log "    SE: unknown SE_FORMAT '$SE_FORMAT'"; return 1; }

    # Fetch the book PAGE (host/direct) and extract the real download href for
    # the requested format by its visible label. This is authoritative — no
    # filename guessing, so translated works (3-segment slugs whose epub file
    # includes the translator) resolve correctly. We do NOT follow links on the
    # download interstitial (the honeypot); we read the book page's own list.
    page_url="${SE_BASE%/}/ebooks/${slug}"
    page="$(se_host_get "$page_url")"
    if [ -z "$page" ]; then
        log "    SE: could not fetch book page $page_url"; return 1
    fi
    href="$(printf '%s' "$page" | SE_LABEL="$label" python3 -c '
import sys, re, html, os
s = sys.stdin.read(); want = os.environ["SE_LABEL"].lower()
best = ""
for m in re.finditer(r"<a\b[^>]*href=\"([^\"]*/downloads/[^\"]+)\"[^>]*>(.*?)</a>", s, re.S):
    href = m.group(1)
    text = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip().lower()
    if text == want:
        best = href; break
print(best)
' 2>/dev/null)"
    if [ -z "$href" ]; then
        # Distinguish a PLACEHOLDER page (book not yet public domain — SE has a
        # catalogue entry but NO download links at all) from a real page missing
        # just this one format. A placeholder has zero /downloads/ links and an
        # "ebook-placeholder" article; in that case the book genuinely isn't
        # available on SE, so the caller should fall through to Anna's rather
        # than mark it failed. Return 3 = "not available on SE (placeholder)".
        if ! printf '%s' "$page" | grep -q '/downloads/'; then
            log "    SE: '$slug' is a placeholder (not yet public domain) — no files on SE"
            return 3
        fi
        log "    SE: no '$label' download link on $page_url (this format unavailable)"
        return 1
    fi
    # absolute URL + the ?source=download bypass (bare URL returns the HTML
    # "Your Download Has Started!" interstitial, not the epub).
    case "$href" in
        http*) url="$href" ;;
        /*)    url="${SE_BASE%/}${href}" ;;
        *)     url="${SE_BASE%/}/${href}" ;;
    esac
    case "$url" in *\?*) url="${url}&source=download" ;; *) url="${url}?source=download" ;; esac

    # filename in DEST: SE's own basename, minus any query string
    fname="$(printf '%s' "$url" | sed 's/?.*//; s/&.*//; s#.*/##')"
    [ -z "$fname" ] && fname="$(printf '%s' "$slug" | tr '/' '_').epub"

    tmp="${DEST}/.part-se-$(printf '%s' "$slug" | tr '/' '-')"
    # host-side cleanup (this file lives on the host now, not in a container)
    CLEANUP_FILES+=("$tmp")

    # download on the HOST over the direct connection (NOT via gluetun). Prefer
    # curl, fall back to wget; both are checked at startup (se_host_downloader).
    local dl_rc=0
    if [ "$SE_DOWNLOADER" = "curl" ]; then
        curl -fsSL --connect-timeout 30 --max-time 180 -o "$tmp" "$url" 2>/dev/null || dl_rc=$?
    else
        wget -q --timeout=180 -O "$tmp" "$url" 2>/dev/null || dl_rc=$?
    fi
    if [ "$dl_rc" -ne 0 ]; then
        log "    SE download failed ($SE_DOWNLOADER rc=$dl_rc): $url"
        rm -f "$tmp" 2>/dev/null; return 1
    fi
    if [ ! -s "$tmp" ]; then
        log "    SE download produced empty file"; rm -f "$tmp" 2>/dev/null; return 1
    fi
    # CONTENT CHECK: epub/azw3/kepub are ZIP containers — first two bytes "PK".
    # An interstitial/error HTML page starts with '<'. Reject anything non-PK so
    # a gate page never gets shipped as a ".epub" the reader can't open.
    local magic; magic="$(head -c2 "$tmp" 2>/dev/null)"
    if [ "$magic" != "PK" ]; then
        log "    SE download is NOT an epub (magic='$magic', not 'PK') — got the"
        log "    interstitial/gate page instead of the binary. URL: $url"
        log "    first bytes: $(head -c80 "$tmp" 2>/dev/null | tr -d '\0' | cut -c1-80)"
        rm -f "$tmp" 2>/dev/null; return 1
    fi

    if ! mv "$tmp" "${DEST}/${fname}" 2>/dev/null || [ ! -s "${DEST}/${fname}" ]; then
        log "    SE move failed or dest missing/empty: ${fname}"
        rm -f "$tmp" "${DEST}/${fname}" 2>/dev/null; return 1
    fi
    # ownership/perms so the watcher imports cleanly. We already run as 2001:2002
    # so this is usually a no-op; it's defensive for root-timer runs. Failure is
    # non-fatal (the file is in place; the timer's chown dance can fix perms).
    [ -n "$SE_CHOWN" ] && chown "$SE_CHOWN" "${DEST}/${fname}" 2>/dev/null || true
    chmod 664 "${DEST}/${fname}" 2>/dev/null || true
    log "    SE downloaded -> ${fname}  (standardebooks.org, host/direct, no quota used)"
    return 0
}

# --- pre-fetch library check ------------------------------------------------
# Is this book ALREADY in calibre? Checks (1) the exact annas:<md5> identifier
# (only present if tag-books stamped it), then (2) a strict title/author match
# against the library's stored metadata using the SAME matcher as everything
# else (book_match_score from match-lib). Echoes the calibre id if found (so the
# caller can log it), nothing if not. LIB_CHECK=0 disables.
# Read calibredb as the container's DEFAULT user (root) — the user the always-on
# GUI app runs as — so these reads SHARE its lock context and succeed even while
# the GUI holds the library lock. Running as a different user (2001:2002) is
# refused with "Another calibre program is running", which previously came back
# empty (stderr was hidden) and made already_in_library wrongly report "not in
# library" -> fetch-books then spent a download on a book already owned. We keep
# stderr now so callers can detect a real failure vs a genuine no-match.
cdb_ro() { docker exec "$CALIBRE_CONTAINER" calibredb "$@" --library-path "$CALIBRE_LIBRARY" 2>&1; }

# returns 0 and echoes a calibre id if the book is already present; 1 if not.
# returns 2 if the library check could not run (calibredb error) — caller should
# treat 2 as "unknown", and (to avoid wasting quota on a possible duplicate)
# skip the download rather than assume it's absent.
# cdb_locked OUTPUT -> 0 (true) if the output shows the library is locked by
# another calibre process. This is the ONLY hard "can't read" signal we trust.
# NOTE: we deliberately do NOT treat a bare "Traceback" as locked. calibre's
# background page-count worker logs tracebacks for unrelated corrupt books (e.g.
# a non-zip EPUB already in the library) onto the SAME stream as our search
# result. Those tracebacks coexist with a perfectly good "No books matching" /
# id result, so greping for "Traceback" turned every clean no-match into a false
# "library unavailable" and deferred every book. The lock message is specific
# and unambiguous; use only it.
cdb_locked() {
    printf '%s' "$1" | grep -qi 'Another calibre program is running'
}

# cdb_ids OUTPUT -> echoes space-separated numeric ids found in a search result,
# ignoring everything else (worker tracebacks, the "No books matching" line,
# stray words). calibredb search prints ids comma-separated on success.
cdb_ids() {
    # strip spaces BEFORE splitting on commas: calibredb may emit "12, 34", and
    # the start-anchored digit match would otherwise drop " 34" (leading space).
    printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | grep -oE '^[0-9]+$'
}

# cdb_search_ok OUTPUT -> 0 if this looks like a VALID search result (either it
# matched ids, or it explicitly said no books matched). Used to tell a real
# read failure (return 2) apart from a clean result that merely has worker
# traceback noise around it.
cdb_search_ok() {
    local out="$1"
    cdb_locked "$out" && return 1
    printf '%s' "$out" | grep -qi 'No books matching the search expression' && return 0
    [ -n "$(cdb_ids "$out")" ] && return 0
    return 1
}

# cdb_search_retry QUERY... -> run `cdb_ro search QUERY...`, and if calibre is
# transiently LOCKED (the GUI grabs the library lock briefly for its own ops),
# wait and retry. The lock is almost always momentary, so a few short retries
# turn what used to be an immediate "library unavailable — defer whole book"
# into a successful read. Echoes the final output; the caller still classifies
# it (a lock that PERSISTS past all retries is then correctly treated as
# unavailable). Tunables: CDB_LOCK_RETRIES (default 4), CDB_LOCK_WAIT (default 2s).
CDB_LOCK_RETRIES="${CDB_LOCK_RETRIES:-4}"
CDB_LOCK_WAIT="${CDB_LOCK_WAIT:-2}"
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

already_in_library() {
    local f1="$1" f2="$2" md5="$3"
    [ "$LIB_CHECK" = "1" ] || return 1

    # 1. exact by md5 identifier
    if [ -n "$md5" ]; then
        local ex idn
        ex="$(cdb_search_retry "identifiers:${ID_SCHEME}:${md5}")"
        cdb_locked "$ex" && return 2   # still locked after retries — truly unknown
        # if the result is neither a clean match nor a clean no-match, the read
        # genuinely failed (not just worker noise) — treat as unknown.
        if ! cdb_search_ok "$ex"; then return 2; fi
        idn="$(cdb_ids "$ex" | head -1)"
        [ -n "$idn" ] && { echo "$idn"; return 0; }
    fi

    # 2. strict title/author match against library metadata. Loose-search calibre
    # by each field to gather candidates, then score with the shared matcher so a
    # near-miss title can't false-positive (same gate fetch-books uses on Anna's).
    local ids="" field
    for field in "$f1" "$f2"; do
        local h safe_field
        # escape double quotes for calibre's search grammar: an embedded " in the
        # title (e.g. The "Great" Gatsby) would otherwise close the title:"..."
        # phrase early and break the query. (cdb_ro uses docker exec with "$@",
        # not sh -c, so there's no second shell to worry about — only calibre's
        # own query parser, which the backslash-escaped quote satisfies.)
        safe_field="${field//\"/\\\"}"
        h="$(cdb_search_retry "title:\"$safe_field\"")"
        cdb_locked "$h" && return 2
        if ! cdb_search_ok "$h"; then return 2; fi
        h="$(cdb_ids "$h" | tr '\n' ' ')"
        if [ -z "$h" ]; then
            h="$(cdb_search_retry "$field")"
            cdb_locked "$h" && return 2
            if ! cdb_search_ok "$h"; then return 2; fi
            h="$(cdb_ids "$h" | tr '\n' ' ')"
        fi
        ids="${ids} ${h}"
    done
    ids="$(printf '%s\n' $ids | awk 'NF && /^[0-9]+$/ && !seen[$0]++' | tr '\n' ' ')"
    [ -z "$ids" ] && return 1

    local id cand cand_t cand_a s
    for id in $ids; do
        # emit candidate title and authors as separate TAB fields so we can score
        # with book_match_fields (title-to-title, author-to-author). The old code
        # flattened "title authors" into one blob and used book_match_score, which
        # let the wanted AUTHOR's words satisfy the title gate against the blob —
        # e.g. wanted "The Dispossessed / Ursula K. Le Guin" matched the library's
        # "The Lathe of Heaven / Ursula K. Le Guin" at 1.0 because "Le Guin"
        # matched as a title. Separated fields + book_match_fields fix that.
        cand="$(cdb_ro list -f title,authors -s "id:$id" --for-machine \
            | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin); b=d[0] if d else {}
    a=b.get("authors",""); a=" ".join(a) if isinstance(a,list) else a
    print((b.get("title","") or "")+"\t"+(a or ""))
except Exception: pass' 2>/dev/null)"
        [ -z "$cand" ] && continue
        IFS=$'\t' read -r cand_t cand_a <<< "$cand"
        [ -z "$cand_t" ] && continue
        s="$(book_match_fields "$f1" "$f2" "$cand_t" "$cand_a")"
        if ge "$s" "$CONFIDENCE"; then echo "$id"; return 0; fi
    done
    return 1
}

# Direct Anna's fast-download. Calls fast_download.json with the key, gets the
# download_url, fetches the file to a temp name in DEST, then moves it into
# place on completion (so the watcher never sees a partial). Updates the global
# QUOTA_LIVE from the API's downloads_left. Returns 0 ok, 1 fail.
QUOTA_LIVE=""
fast_download_md5() {
    local md5="$1" resp url err fname tmp
    resp="$(fast_api_call "$md5")"
    if [ $? -ne 0 ] || [ -z "$resp" ]; then
        log "    fast-download API unreachable on all mirrors"; return 1
    fi

    url="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("download_url") or "")
except Exception: print("")' 2>/dev/null)"
    err="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("")' 2>/dev/null)"
    QUOTA_LIVE="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"

    if [ -z "$url" ] || [ "$url" = "null" ]; then
        # Distinguish QUOTA EXHAUSTION from other refusals. When the daily fast-
        # download allowance is spent, Anna's refuses with a "no downloads left"
        # style error AND (usually) downloads_left:0. Continuing to hit the API
        # for every remaining book is pointless and rude — signal the caller to
        # STOP the run (return 2) rather than mark just this one failed (return 1).
        local errlc; errlc="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')"
        case "$errlc" in
            *"no downloads left"*|*"download limit"*|*"quota"*|*"exhausted"*|*"too many"*)
                log "    fast-download refused: ${err} (daily quota exhausted)"
                QUOTA_LIVE=0
                return 2 ;;
        esac
        # also treat a live downloads_left of 0 as exhaustion even if the error
        # text is generic.
        if [ "${QUOTA_LIVE:-}" = "0" ]; then
            log "    fast-download refused: ${err:-no url} (downloads_left=0 — quota exhausted)"
            return 2
        fi
        log "    fast-download refused: ${err:-no download_url returned}"; return 1
    fi

    fname="$(printf '%s' "$url" | sed 's/?.*//; s#.*/##' \
        | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null)"
    [ -z "$fname" ] && fname="${md5}.epub"
    # Truncate to fit the 255-BYTE filesystem limit WITHOUT losing the extension.
    # The old "cut -c1-180" chopped the tail — which is where .epub lives — so
    # long names lost their extension and the watcher (extension-gated) ignored
    # them. Split stem/ext, shorten the stem on a byte budget, reattach the ext.
    # Also guarantee an md5 in the stem so files stay identifiable + unique.
    fname="$(printf '%s' "$fname" | tr -d '/' | python3 -c '
import sys, os
name = sys.stdin.read().strip()
md5 = sys.argv[1]
stem, ext = os.path.splitext(name)
if not ext or len(ext) > 6:        # no real extension found
    stem, ext = name, ".epub"      # default; magic-byte check happens elsewhere
# ensure the md5 is present in the stem so the file is identifiable & unique
if md5 not in stem:
    stem = (stem[:60].rstrip() + " -- " + md5) if stem else md5
# byte-budget: keep total <= 200 bytes (margin under 255 for path safety)
budget = 200 - len(ext.encode("utf-8"))
enc = stem.encode("utf-8")[:budget]
# avoid cutting a multibyte char in half
stem = enc.decode("utf-8", "ignore").rstrip()
print(stem + ext)
' "$md5" 2>/dev/null)"
    [ -z "$fname" ] && fname="${md5}.epub"

    tmp="${DEST}/.part-${md5}"
    CLEANUP_PARTS+=("$tmp")
    if ! docker exec "$DL_CONTAINER" wget -q --timeout=120 -O "$tmp" "$url" 2>/dev/null; then
        log "    download failed (url fetch)"; docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1
    fi
    if ! docker exec "$DL_CONTAINER" sh -c '[ -s "$1" ]' _ "$tmp" 2>/dev/null; then
        log "    download produced empty file"; docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1
    fi
    # verify the move actually succeeded AND the destination exists non-empty
    # before reporting success — a silent mv failure must not log "downloaded".
    # Pass paths as ARGS to sh -c (not interpolated) so a filename with an
    # apostrophe (e.g. "The Handmaid's Tale.epub") can't break the shell string.
    if ! docker exec "$DL_CONTAINER" mv "$tmp" "${DEST}/${fname}" 2>/dev/null \
       || ! docker exec "$DL_CONTAINER" sh -c '[ -s "$1" ]' _ "${DEST}/${fname}" 2>/dev/null; then
        log "    move failed or dest missing/empty: ${fname}"
        docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # ownership/perms for the watcher. The mv ran AS the qbittorrent container's
    # internal user, so unless its compose PUID/PGID are 2001:2002 the file may
    # land owned by root or another uid and the watcher (which expects 2001:2002)
    # could choke. docker exec defaults to root, so it can chown to the numeric
    # owner regardless of the container's PUID. Non-fatal: the file is in place
    # either way. (SE_CHOWN reused as the canonical "watcher owner".)
    if [ -n "${WATCHER_OWNER:-}" ]; then
        docker exec "$DL_CONTAINER" chown "$WATCHER_OWNER" "${DEST}/${fname}" 2>/dev/null \
            || log "    note: could not chown ${fname} to $WATCHER_OWNER (check qbittorrent PUID/PGID)"
    fi
    docker exec "$DL_CONTAINER" chmod 664 "${DEST}/${fname}" 2>/dev/null || true
    log "    downloaded -> ${fname}${QUOTA_LIVE:+  (quota left: $QUOTA_LIVE)}"
    return 0
}

# Append a book to the tag queue so tag-queue.sh tags it once imported. Args:
# md5 tags title author. No-op if TAG_QUEUE is empty or tags is empty. Locked so
# concurrent fetch-books runs don't corrupt the JSON. Best-effort (a queue
# failure must not fail the download, which already succeeded).
enqueue_for_tagging() {
    local md5="$1" tags="$2" title="$3" author="$4"
    [ -z "$TAG_QUEUE" ] && return 0
    [ -z "$tags" ] && return 0
    local qlock="${TAG_QUEUE}.lock"
    (
        flock -w 10 8 || { log "    WARN: could not lock tag queue; not enqueued"; exit 1; }
        local err
        err="$(python3 -c '
import sys, json, os, time
qf, md5, tags, title, author = sys.argv[1:6]
try:
    arr = json.load(open(qf)) if os.path.exists(qf) and os.path.getsize(qf) else []
except Exception:
    arr = []
# de-dupe: if this md5 is already queued, leave it (avoid pile-up on re-runs)
if not any(e.get("md5") == md5 for e in arr if md5):
    arr.append({"md5": md5, "tags": tags, "title": title,
                "author": author, "queued_at": int(time.time())})
    json.dump(arr, open(qf, "w"))
' "$TAG_QUEUE" "$md5" "$tags" "$title" "$author" 2>&1)"
        if [ -n "$err" ]; then
            log "    WARN: enqueue failed (download still OK): ${err##*: }"
        else
            # keep the queue group-writable so the root timer can rewrite it and
            # we can still write it next time (shared-file ownership dance).
            chmod 664 "$TAG_QUEUE" 2>/dev/null || true
            log "    enqueued for tagging: [$tags]"
        fi
    ) 8>"$qlock"
}


process_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp")
    local n_done=0 n_skip=0 n_nomatch=0 n_fail=0 n_bad=0 n_qblock=0
    local file_tag="$TAG"   # --tag wins; else picked up from a #tag: header below

    while IFS= read -r raw || [ -n "$raw" ]; do
        # read a "#tag: ..." header directive (only if --tag didn't set one)
        case "$raw" in
            \#tag:*|\#tag\ *)
                if [ -z "$TAG" ]; then
                    file_tag="$(printf '%s' "$raw" | sed 's/^#tag:[[:space:]]*//; s/^#tag[[:space:]]*//')"
                    # normalise to a canonical comma list: trim space around
                    # commas and at the ends, drop blanks. Spaces WITHIN a tag
                    # are kept, so multi-word tags like "Booker Prize" survive.
                    file_tag="$(printf '%s' "$file_tag" \
                        | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"
                    log "  list tag from header: '$file_tag'"
                fi
                printf '%s\n' "$raw" >> "$tmp"; continue ;;
        esac
        # passthrough blank lines and other comments unchanged
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac

        local author title status md5 rest
        # split on '|' with one read instead of four cut forks. read does NOT
        # trim, so strip CR off the whole line first, then trim each field below.
        # `rest` catches any 5th+ columns (date etc.) so they're preserved when
        # we rewrite. NOTE the Title|Author convention: field1 is the TITLE but
        # the var is named `author` for historical reasons — do not "fix".
        local raw_nocr; raw_nocr="${raw%$'\r'}"
        IFS='|' read -r author title status md5 rest <<< "$raw_nocr"
        # field count for the malformed guard: count '|' separators + 1
        local seps="${raw_nocr//[!|]/}"; local nfields=$(( ${#seps} + 1 ))
        # trim surrounding whitespace on the two fields we match on
        author="$(printf '%s' "${author:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        title="$(printf '%s' "${title:-}"   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        status="$(printf '%s' "${status:-}" | tr -d '[:space:]')"
        md5="$(printf '%s' "${md5:-}"       | tr -d '[:space:]')"

        # malformed guard: a data line needs at least author|title. Fewer than 2
        # pipe-fields, or an empty author/title, means the line is malformed.
        if [ "$nfields" -lt 2 ] || [ -z "$author" ] || [ -z "$title" ]; then
            log "  MALFORMED (expected 'author | title', got $nfields field(s)) — kept verbatim: $(printf '%s' "$raw" | cat -v)"
            printf '%s\n' "$raw" >> "$tmp"; n_bad=$((n_bad+1)); continue
        fi

        # already in-flight or finished -> keep as-is, don't re-fetch.
        # downloaded = fetched this pipeline (or marked present by the library
        # check); queued/downloading/completed/tagged = old Stacks states. All
        # mean "done, don't touch" — and crucially skip BEFORE the calibre library
        # check, so a finished row costs nothing on re-runs.
        case "$status" in
            downloaded|queued|downloading|completed|tagged)
                printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue ;;
        esac
        # error/nomatch -> only re-attempt under --retry; otherwise keep verbatim.
        # NOTE: 'quota_blocked' is deliberately NOT in this list — it means "would
        # have fetched from Anna's but the daily quota was spent", so it should be
        # re-attempted automatically on the next run (after the quota resets), no
        # --retry needed. It simply falls through and is processed normally.
        if [ "$status" = "error" ] || [ "$status" = "failed" ] || [ "$status" = "nomatch" ]; then
            if [ "$RETRY" -eq 0 ]; then
                printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
            fi
            log "  retrying previously-$status line"
        fi
        log "→ $author — $title"

        # PRE-SEARCH LIBRARY CHECK: if the book is already in calibre, skip it
        # entirely — no Anna's search, no download, no quota. This catches books
        # in the library even when Anna's search would miss them (e.g. punctuation
        # or author-format differences), which a post-search check could not.
        # md5 is unknown here, so this is a title/author match only; the exact
        # md5-identifier path still runs post-search as a backstop.
        if [ "$LIB_CHECK" = "1" ]; then
            local prelib prerc
            prelib="$(already_in_library "$author" "$title" "")"; prerc=$?
            if [ "$prerc" -eq 0 ] && [ -n "$prelib" ]; then
                log "    already in library (calibre id $prelib) — skipping (no search, no download)"
                printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                n_skip=$((n_skip+1))
                continue
            elif [ "$prerc" -eq 2 ]; then
                # library check could not run (calibre busy / locked). Don't risk
                # spending a download on a book we might already own — defer this
                # row (leave its current status untouched) and move on.
                log "    library check unavailable (calibre busy?) — deferring, not downloading"
                printf '%s\n' "$raw" >> "$tmp"
                n_skip=$((n_skip+1))
                continue
            fi
        fi

        # STANDARD EBOOKS FIRST: many list books are public-domain classics SE
        # has produced. Try SE before Anna's — it's free, keyless, quota-free.
        # A confident SE match is AUTHORITATIVE: if its download then fails we
        # mark the row 'failed' and do NOT fall through to Anna's (so a public
        # book never spends Anna's quota). DRY_RUN reports the SE hit and skips.
        if [ "$SE_FIRST" = "1" ]; then
            local se_hit se_slug se_score
            se_hit="$(se_search_one "$author" "$title")"
            if [ -n "$se_hit" ]; then
                se_slug="$(printf '%s' "$se_hit" | cut -f1)"
                se_score="$(printf '%s' "$se_hit" | cut -f2)"
                if [ "$DRY_RUN" -eq 1 ]; then
                    log "    DRY: would download from Standard Ebooks: $se_slug (score $se_score)"
                    printf '%s\n' "$raw" >> "$tmp"   # read-only: keep row verbatim
                    pace; continue
                fi
                local se_rc
                se_download "$se_slug"; se_rc=$?
                if [ "$se_rc" -eq 0 ]; then
                    printf '%s|%s|downloaded|se:%s|%s\n' "$author" "$title" "$se_slug" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                    n_done=$((n_done+1))
                    # tag-queue keys on the md5/source token; se:<slug> is unique+stable.
                    enqueue_for_tagging "se:$se_slug" "$file_tag" "$author" "$title"
                    pace; continue
                elif [ "$se_rc" -eq 3 ]; then
                    # placeholder: SE lists it but has no files yet (not public
                    # domain). SE will never have this one, so DON'T mark failed —
                    # fall through to Anna's, which may have it. No `continue`.
                    log "    SE has no file for this book — falling through to Anna's Archive"
                else
                    log "    SE matched ($se_slug) but download failed — marking failed (no Anna's fallback)"
                    printf '%s|%s|failed|se:%s|%s\n' "$author" "$title" "$se_slug" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                    n_fail=$((n_fail+1))
                    pace; continue
                fi
            else
                log "    not on Standard Ebooks — trying Anna's Archive"
            fi
        fi

        # Anna's unavailable (keyless SE-only run) and SE didn't have it: leave
        # the row pending for a later run rather than burning it as nomatch.
        if [ "${ANNAS_AVAILABLE:-1}" -eq 0 ]; then
            log "    Anna's unavailable — leaving pending for a later run"
            printf '%s\n' "$raw" >> "$tmp"
            n_skip=$((n_skip+1)); continue
        fi

        # Anna's daily quota already spent earlier this run: SE was still tried
        # above (free), but this book isn't on SE. Don't hit the Anna's API again
        # — mark it 'quota_blocked' so it's visibly distinct from nomatch/failed
        # and a later run (after the daily reset) picks it up. Keep going so the
        # rest of the list still gets its free SE downloads.
        if [ "$ANNAS_QUOTA_OUT" -eq 1 ]; then
            log "    Anna's quota spent — not on SE, marking quota_blocked for a later run"
            printf '%s|%s|quota_blocked|%s|%s\n' "$author" "$title" "${md5:-}" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_qblock=$((n_qblock+1)); pace; continue
        fi

        local hit best_md5 best_score
        hit="$(search_one "$author" "$title")"

        if [ "$hit" = "UNREACHABLE" ]; then
            # no Anna's mirror answered (FlareSolverr couldn't reach any). This is
            # infrastructure, not a real miss — leave the row pending so a later
            # run (with healthier mirrors) retries it, rather than burning it as
            # nomatch which a normal run would never revisit.
            log "    no Anna's mirror reachable — leaving pending for a later run"
            printf '%s\n' "$raw" >> "$tmp"
            n_skip=$((n_skip+1)); pace; continue
        fi
        if [ -z "$hit" ]; then
            log "    nomatch (no hit >= $CONFIDENCE)"
            printf '%s|%s|nomatch||%s\n' "$author" "$title" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_nomatch=$((n_nomatch+1))
            pace; continue
        fi

        best_md5="$(printf '%s' "$hit" | cut -f1)"
        best_score="$(printf '%s' "$hit" | cut -f2)"

        # POST-SEARCH md5 BACKSTOP: now that we have the matched md5, check the
        # exact annas:<md5> identifier (the pre-search check was title/author only,
        # since md5 wasn't known yet). Catches a book stamped with this md5 even if
        # its stored title/author differ from the list. LIB_CHECK gates it.
        if [ "$LIB_CHECK" = "1" ] && [ -n "$best_md5" ]; then
            local idhit
            idhit="$(cdb_search_retry "identifiers:${ID_SCHEME}:${best_md5}")"
            # only the lock message (or a result that's neither a match nor a
            # clean no-match) means "unavailable" — incidental worker tracebacks
            # do NOT, see cdb_locked/cdb_search_ok.
            if cdb_locked "$idhit" || ! cdb_search_ok "$idhit"; then
                log "    library check unavailable (calibre busy?) — deferring, not downloading"
                printf '%s\n' "$raw" >> "$tmp"
                n_skip=$((n_skip+1)); pace; continue
            fi
            local idn
            idn="$(cdb_ids "$idhit" | head -1)"
            if [ -n "$idn" ]; then
                log "    already in library by md5 identifier (calibre id $idn) — not spending a download"
                printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                n_skip=$((n_skip+1))
                pace; continue
            fi
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "    DRY: would download $best_md5 (score $best_score)"
            printf '%s\n' "$raw" >> "$tmp"   # read-only: keep row verbatim
            pace; continue
        fi

        # quota guard: if fast-download is on and we'd breach the floor, stop
        # using Anna's — but DON'T halt the run. SE (free) keeps working for the
        # rest of the list; this matched book (Anna's-only) is marked
        # 'quota_blocked' for a later run, and ANNAS_QUOTA_OUT skips the Anna's
        # path for subsequent books (they still try SE first).
        if ! quota_ok; then
            log "    fast-download floor reached — Anna's paused; SE still active for remaining books"
            printf '%s|%s|quota_blocked|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            ANNAS_QUOTA_OUT=1
            n_qblock=$((n_qblock+1)); pace; continue
        fi

        local dl_rc
        fast_download_md5 "$best_md5"; dl_rc=$?
        if [ "$dl_rc" -eq 0 ]; then
            printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_done=$((n_done+1))
            QUEUED_RUN=$((QUEUED_RUN+1))
            # enqueue for tagging once it imports (no-op if no tags to apply).
            # NOTE: despite their names, $author holds list field 1 (the TITLE)
            # and $title holds field 2 (the AUTHOR) — the rows are Title|Author.
            # So passing ($author,$title) into the (title,author) params is CORRECT:
            # title<-field1, author<-field2. Do NOT "fix" this by swapping them.
            enqueue_for_tagging "$best_md5" "$file_tag" "$author" "$title"
            # if the API gave us the live remaining quota, trust it over the projection
            [ -n "$QUOTA_LIVE" ] && QUOTA_START=$(( QUOTA_LIVE + QUEUED_RUN ))
        elif [ "$dl_rc" -eq 2 ]; then
            # quota exhausted mid-run (the API refused even though the floor hadn't
            # tripped — e.g. quota dropped faster than projected). Don't halt the
            # run: SE is free and still works for remaining books. Mark THIS book
            # (matched on Anna's at score $best_score, but no quota to fetch) as
            # quota_blocked, set ANNAS_QUOTA_OUT so we skip the Anna's API for the
            # rest of the list, and continue.
            log "    daily fast-download quota exhausted — Anna's paused; SE still active for remaining books"
            printf '%s|%s|quota_blocked|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            ANNAS_QUOTA_OUT=1
            n_qblock=$((n_qblock+1))
            pace; continue
        else
            log "    download failed for $best_md5 (score $best_score)"
            printf '%s|%s|failed|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_fail=$((n_fail+1))
        fi
        pace
    done < "$file"

    # dry-run is strictly read-only: every row was written verbatim, so don't
    # even replace the file (leave mtime/inode untouched).
    if [ "$DRY_RUN" -eq 1 ]; then
        rm -f "$tmp" 2>/dev/null
    else
        mv "$tmp" "$file"
    fi
    log "FILE $file — queued:$n_done already-done:$n_skip nomatch:$n_nomatch failed:$n_fail quota-blocked:$n_qblock malformed:$n_bad"
}

log "=== fetch-books v$FETCH_BOOKS_VERSION start (mirrors: ${#mirrors[@]}, confidence: $CONFIDENCE, dry-run: $DRY_RUN, retry: $RETRY, SE-first: $SE_FIRST) ==="
# SE needs a host downloader (curl/wget). If neither exists, disable SE rather
# than fail every book on a futile SE attempt — Anna's still handles the list.
if [ "$SE_FIRST" = "1" ] && [ -z "$SE_DOWNLOADER" ]; then
    log "WARNING: SE_FIRST=1 but no curl/wget on the host — disabling Standard Ebooks."
    log "         Install one (e.g. apt-get install -y curl) to enable SE downloads."
    SE_FIRST=0
fi
[ "$SE_FIRST" = "1" ] && log "Standard Ebooks: host downloader = $SE_DOWNLOADER (direct connection, off-VPN)"
ANNAS_AVAILABLE=1
if [ "$DRY_RUN" -eq 0 ]; then
    if ! preflight_fast_download; then
        if [ "$SE_FIRST" = "1" ]; then
            # SE is on, so a keyless run is still useful for public-domain books.
            # Disable Anna's rather than abort: SE books download, non-SE books
            # get a clear 'nomatch (Anna's unavailable)' instead of a hard exit.
            ANNAS_AVAILABLE=0
            log "WARNING: Anna's fast-download unavailable — continuing with Standard Ebooks ONLY."
            log "         Books not on SE will be left for a later run (no Anna's quota/key)."
        else
            exit 1
        fi
    fi
fi
for f in "${FILES[@]}"; do process_file "$f"; done
log "=== fetch-books done ==="