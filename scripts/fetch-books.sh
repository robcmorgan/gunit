#!/usr/bin/env bash
FETCH_BOOKS_VERSION="27"   # bump on every change; echoed at startup so you can
                          # confirm the copy on otis matches the latest edit.
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
    local p
    for p in "${CLEANUP_PARTS[@]:-}"; do
        [ -z "$p" ] && continue
        docker exec "${DL_CONTAINER:-qbittorrent}" rm -f "$p" 2>/dev/null || true
    done
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
QUOTA_FLOOR="${QUOTA_FLOOR:-3}"      # stop queuing when fast-download quota would drop to/below this
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
# Tag queue: on each successful download, append {md5,tags,title,author,queued_at}
# here so tag-queue.sh can tag the book once it's imported into calibre. Empty
# tags (no #tag: header, no --tag) means nothing to enqueue. TAG_QUEUE='' disables.
TAG_QUEUE="${TAG_QUEUE:-/home/robmorgan/gunit/config/tag-queue.json}"
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
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

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
    QUOTA_START=""   # learned live from the first real download
    log "fast-download: ACTIVE (key accepted; quota read live during run)"
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
QUOTA_HALT=0

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

    # md5 -> state map as "md5 state" lines
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

    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp"); local n_upd=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac
        local a t s m d
        a="$(printf '%s' "$raw" | cut -d'|' -f1)"
        t="$(printf '%s' "$raw" | cut -d'|' -f2)"
        s="$(printf '%s' "$raw" | cut -d'|' -f3 | tr -d ' ')"
        m="$(printf '%s' "$raw" | cut -d'|' -f4 | tr -d ' ')"
        d="$(printf '%s' "$raw" | cut -d'|' -f5)"
        # don't touch tagged lines or lines without an md5
        if [ "$s" = "tagged" ] || [ -z "$m" ]; then printf '%s\n' "$raw" >> "$tmp"; continue; fi
        local newstate; newstate="$(awk -v k="$m" '$1==k{print $2; exit}' <<< "$map")"
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
    for base in "${mirrors[@]}"; do
        local url payload
        url="${base%/}/search?q=${q}${extfilter}${langfilter}"
        payload="{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":$MAXTIMEOUT}"
        resp="$(docker exec "$CONTAINER" sh -c \
            "wget -qO- --timeout=$(( MAXTIMEOUT/1000 + 15 )) \
             --post-data='$payload' --header='Content-Type: application/json' \
             '$FLARESOLVERR' 2>/dev/null")"
        [ -z "$resp" ] && continue
        [ "$(echo -n "$resp" | wc -c)" -lt "$MIN_GOOD_BYTES" ] && continue

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
        while IFS= read -r line; do
            md5="$(printf '%s' "$line" | cut -f1 | grep -oE '[a-f0-9]{32}' | head -1)"
            [ -z "$md5" ] && continue
            # parsers now emit "md5<TAB>cand_title<TAB>cand_author"
            cand_t="$(printf '%s' "$line" | cut -f2)"
            cand_a="$(printf '%s' "$line" | cut -f3)"
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
    fi
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
already_in_library() {
    local f1="$1" f2="$2" md5="$3"
    [ "$LIB_CHECK" = "1" ] || return 1

    # 1. exact by md5 identifier
    if [ -n "$md5" ]; then
        local ex idn
        ex="$(cdb_ro search "identifiers:${ID_SCHEME}:${md5}")"
        if printf '%s' "$ex" | grep -qi 'Another calibre program\|Traceback'; then
            return 2   # lock/error — unknown, not a clean "absent"
        fi
        # digit-only: calibredb prints "No books matching..." when none found,
        # which must not be parsed as an id.
        idn="$(printf '%s' "$ex" | tr ',' '\n' | grep -oE '^[0-9]+$' | head -1)"
        [ -n "$idn" ] && { echo "$idn"; return 0; }
    fi

    # 2. strict title/author match against library metadata. Loose-search calibre
    # by each field to gather candidates, then score with the shared matcher so a
    # near-miss title can't false-positive (same gate fetch-books uses on Anna's).
    local ids="" field
    for field in "$f1" "$f2"; do
        local h
        h="$(cdb_ro search "title:\"$field\"")"
        printf '%s' "$h" | grep -qi 'Another calibre program\|Traceback' && return 2
        h="$(printf '%s' "$h" | tr ',' ' ')"
        if [ -z "$h" ]; then
            h="$(cdb_ro search "$field")"
            printf '%s' "$h" | grep -qi 'Another calibre program\|Traceback' && return 2
            h="$(printf '%s' "$h" | tr ',' ' ')"
        fi
        ids="${ids} ${h}"
    done
    ids="$(printf '%s\n' $ids | awk 'NF && /^[0-9]+$/ && !seen[$0]++' | tr '\n' ' ')"
    [ -z "$ids" ] && return 1

    local id cand s
    for id in $ids; do
        cand="$(cdb_ro list -f title,authors -s "id:$id" --for-machine \
            | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin); b=d[0] if d else {}
    a=b.get("authors",""); a=" ".join(a) if isinstance(a,list) else a
    print((b.get("title","")+" "+a).strip())
except Exception: pass' 2>/dev/null)"
        [ -z "$cand" ] && continue
        s="$(book_match_score "$f1" "$f2" "$cand")"
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
        python3 -c '
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
' "$TAG_QUEUE" "$md5" "$tags" "$title" "$author" 2>/dev/null \
            && log "    enqueued for tagging: [$tags]" \
            || log "    WARN: enqueue failed (download still OK)"
    ) 8>"$qlock"
}


process_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp")
    local n_done=0 n_skip=0 n_nomatch=0 n_fail=0 n_bad=0
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

        # once the quota guard has halted, write the rest of the file unchanged
        if [ "${QUOTA_HALT:-0}" -eq 1 ]; then
            printf '%s\n' "$raw" >> "$tmp"; continue
        fi

        local author title status md5
        author="$(printf '%s' "$raw" | cut -d'|' -f1)"
        title="$(printf '%s' "$raw" | cut -d'|' -f2)"
        status="$(printf '%s' "$raw" | cut -d'|' -f3)"
        md5="$(printf '%s' "$raw" | cut -d'|' -f4)"

        # trim stray leading/trailing whitespace and CR (lets you write
        # "Author | Title" with readable spaces around the pipe)
        author="$(printf '%s' "$author" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        title="$(printf '%s' "$title"   | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"

        # malformed guard: a data line needs at least author|title. Fewer than 2
        # pipe-fields, or an empty author/title, means the line is malformed.
        local nfields; nfields="$(awk -F'|' '{print NF}' <<< "$raw")"
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
        # error/nomatch -> only re-attempt under --retry; otherwise keep verbatim
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

        local hit best_md5 best_score
        hit="$(search_one "$author" "$title")"

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
            idhit="$(cdb_ro search "identifiers:${ID_SCHEME}:${best_md5}")"
            if printf '%s' "$idhit" | grep -qi 'Another calibre program\|Traceback'; then
                log "    library check unavailable (calibre busy?) — deferring, not downloading"
                printf '%s\n' "$raw" >> "$tmp"
                n_skip=$((n_skip+1)); pace; continue
            fi
            # extract ONLY numeric ids. calibredb prints "No books matching..." to
            # stderr (captured via 2>&1) when nothing is found; word-splitting that
            # raw text grabbed "No" as a fake id. Digit-only extraction avoids it.
            local idn
            idn="$(printf '%s' "$idhit" | tr ',' '\n' | grep -oE '^[0-9]+$' | head -1)"
            if [ -n "$idn" ]; then
                log "    already in library by md5 identifier (calibre id $idn) — not spending a download"
                printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                n_skip=$((n_skip+1))
                pace; continue
            fi
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "    DRY: would download $best_md5 (score $best_score)"
            printf '%s|%s|pending|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            pace; continue
        fi

        # quota guard: if fast-download is on and we'd breach the floor, stop
        # queuing. This matched book is written 'pending' (not lost), and the
        # rest of the file passes through for a later run.
        if ! quota_ok; then
            printf '%s|%s|pending|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            QUOTA_HALT=1
            continue
        fi

        if fast_download_md5 "$best_md5"; then
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
        else
            log "    download failed for $best_md5 (score $best_score)"
            printf '%s|%s|failed|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_fail=$((n_fail+1))
        fi
        pace
    done < "$file"

    mv "$tmp" "$file"
    log "FILE $file — queued:$n_done already-done:$n_skip nomatch:$n_nomatch failed:$n_fail malformed:$n_bad"
}

log "=== fetch-books v$FETCH_BOOKS_VERSION start (mirrors: ${#mirrors[@]}, confidence: $CONFIDENCE, dry-run: $DRY_RUN, retry: $RETRY) ==="
if [ "$DRY_RUN" -eq 0 ]; then
    preflight_fast_download || exit 1
fi
for f in "${FILES[@]}"; do process_file "$f"; done
log "=== fetch-books done ==="