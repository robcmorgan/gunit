#!/bin/bash
CHECK_MIRRORS_VERSION="2"   # bump on every change; echoed at startup
# =============================================================================
#  check-mirrors.sh — find which Anna's Archive mirrors actually work, report
#  the active list, and flag changes since the last run.
#
#  TWO-STAGE CHECK (v2):
#   1. DISCOVERY via SLUM (open-slum.pages.dev/api/data): a maintained uptime
#      monitor that knows which Anna's domains currently exist and are up. This
#      catches new/rotated domains your hardcoded list wouldn't know about, and
#      drops dead ones — so the candidate list is never stale. SLUM only checks
#      that a homepage responds, though, which is a WEAK signal (a mirror can be
#      "up" but return no search results), so we don't trust it alone.
#   2. VERIFY via FlareSolverr: run a REAL search against each candidate and
#      count /md5/ book links — the strong "this mirror actually works for us"
#      signal. Only mirrors passing BOTH stages are marked WORKING.
#
#  If SLUM is unreachable, falls back to the hardcoded MIRRORS list below so the
#  check still runs. Candidates = SLUM's up Anna's domains UNION the hardcoded
#  list (deduped), so a domain SLUM misses but you know about is still tested.
#
#  CHANGE DETECTION, COLOUR, STATE FILE: as before. State is what fetch-books
#  reads. Run on OTIS (FlareSolverr reachable via gluetun).
#
#  USAGE:
#    ./check-mirrors.sh
#    QUERY="dune" ./check-mirrors.sh
#    NO_COLOR=1 ./check-mirrors.sh
#    NO_SLUM=1 ./check-mirrors.sh          # skip SLUM, use hardcoded list only
#    MIRRORS="https://annas-archive.gd" ./check-mirrors.sh   # force a list
# =============================================================================
set -uo pipefail

# Hardcoded fallback / union list (used if SLUM is down, and merged with SLUM's)
MIRRORS="${MIRRORS:-\
https://annas-archive.gd \
https://annas-archive.gl \
https://annas-archive.pk \
https://annas-archive.se}"

SLUM_URL="${SLUM_URL:-https://open-slum.pages.dev/api/data}"
QUERY="${QUERY:-simenon}"
FLARESOLVERR="${FLARESOLVERR:-http://localhost:8191/v1}"
CONTAINER="${CONTAINER:-gluetun}"
MAXTIMEOUT="${MAXTIMEOUT:-60000}"
MIN_GOOD_BYTES="${MIN_GOOD_BYTES:-100000}"
STATE_FILE="${STATE_FILE:-$HOME/.cache/check-mirrors.state}"

# --- colour setup -----------------------------------------------------------
if [ -n "${NO_COLOR:-}" ]; then USE_COLOR=0
elif [ -n "${FORCE_COLOR:-}" ]; then USE_COLOR=1
elif [ -t 1 ]; then USE_COLOR=1
else USE_COLOR=0; fi
if [ "$USE_COLOR" -eq 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_GREY=$'\e[90m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_GREY=''
fi

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

declare -A PREV
if [ -f "$STATE_FILE" ]; then
    while IFS='|' read -r h v; do [ -n "$h" ] && PREV["$h"]="$v"; done < "$STATE_FILE"
fi

echo "${C_BOLD}${C_CYAN}===============================================================${C_RESET}"
echo "${C_BOLD} Anna's Archive mirror health (v$CHECK_MIRRORS_VERSION)  —  $(date '+%F %T')${C_RESET}"
echo " query: '${C_BOLD}$QUERY${C_RESET}'"
if [ -f "$STATE_FILE" ]; then
    echo " ${C_DIM}(comparing against last run: $(date -r "$STATE_FILE" '+%F %T'))${C_RESET}"
else
    echo " ${C_DIM}(no previous run on record — this becomes the baseline)${C_RESET}"
fi
echo "${C_BOLD}${C_CYAN}===============================================================${C_RESET}"

# ---------------------------------------------------------------------------
# STAGE 1: DISCOVERY via SLUM
# ---------------------------------------------------------------------------
slum_domains=""
slum_status="skipped"
if [ -z "${NO_SLUM:-}" ]; then
    slum_json="$(docker exec "$CONTAINER" wget -qO- --timeout=20 "$SLUM_URL" 2>/dev/null)"
    if [ -n "$slum_json" ]; then
        # extract Anna's-archive monitors that are up; map key -> domain
        slum_domains="$(printf '%s' "$slum_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    mons = d.get("monitors", {})
except Exception:
    sys.exit(0)
for key, m in mons.items():
    if not key.startswith("annas_archive"):
        continue
    if not m.get("up"):
        continue
    tld = key.split("_")[-1]          # annas_archive_gl -> gl
    print("https://annas-archive." + tld)
' 2>/dev/null)"
        if [ -n "$slum_domains" ]; then
            slum_status="ok"
        else
            slum_status="no annas mirrors up"
        fi
    else
        slum_status="unreachable"
    fi
fi

echo
echo "${C_BOLD}── SLUM DISCOVERY ──────────────────────────────────────────────${C_RESET}"
case "$slum_status" in
    ok)   echo "  ${C_GREEN}✓${C_RESET} SLUM reports these Anna's mirrors UP:";
          for d in $slum_domains; do echo "      $d"; done ;;
    skipped)      echo "  ${C_DIM}(skipped via NO_SLUM)${C_RESET}" ;;
    unreachable)  echo "  ${C_YELLOW}! SLUM unreachable — falling back to hardcoded list${C_RESET}" ;;
    *)            echo "  ${C_YELLOW}! SLUM returned no up Anna's mirrors — using hardcoded list${C_RESET}" ;;
esac

# candidate set = SLUM up-domains UNION hardcoded MIRRORS, deduped
declare -A seen_c
candidates=""
for m in $slum_domains $MIRRORS; do
    key="${m%/}"
    if [ -z "${seen_c[$key]:-}" ]; then seen_c[$key]=1; candidates="$candidates $key"; fi
done

# ---------------------------------------------------------------------------
# STAGE 2: VERIFY each candidate with a real FlareSolverr search
# ---------------------------------------------------------------------------
echo
echo "${C_BOLD}── VERIFY (real search via FlareSolverr) ───────────────────────${C_RESET}"
printf '%-26s %-7s %-9s %-7s %s\n' "MIRROR" "HTTP" "SIZE" "BOOKS" "VERDICT"
echo "${C_GREY}----------------------------------------------------------------${C_RESET}"

declare -A NOW
active_list=""
for base in $candidates; do
    host=$(echo "$base" | sed 's|https\?://||; s|/$||')
    url="${base%/}/search?q=${QUERY}"
    payload="{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":$MAXTIMEOUT}"
    resp=$(docker exec "$CONTAINER" sh -c \
        "wget -qO- --timeout=$(( MAXTIMEOUT/1000 + 15 )) \
         --post-data='$payload' --header='Content-Type: application/json' \
         '$FLARESOLVERR' 2>/dev/null")

    if [ -z "$resp" ]; then
        printf '%-26s %-7s %-9s %-7s %s\n' "$host" "-" "0" "0" "${C_RED}✗ no response${C_RESET}"
        NOW["$host"]="DEAD"; continue
    fi
    http_status=$(echo "$resp" | grep -oE '"status": *[0-9]+' | head -1 | grep -oE '[0-9]+$')
    size=$(echo "$resp" | wc -c)
    md5count=$(echo "$resp" | grep -oE '/md5/' | wc -l)

    if [ "$md5count" -gt 0 ] && [ "$size" -ge "$MIN_GOOD_BYTES" ]; then
        printf '%-26s %-7s %-9s %-7s %s\n' "$host" "${http_status:-?}" "$size" "$md5count" "${C_GREEN}✓ WORKING${C_RESET}"
        NOW["$host"]="WORKING"; active_list="$active_list $base"
    elif [ "$md5count" -gt 0 ]; then
        printf '%-26s %-7s %-9s %-7s %s\n' "$host" "${http_status:-?}" "$size" "$md5count" "${C_YELLOW}~ partial${C_RESET}"
        NOW["$host"]="WORKING"; active_list="$active_list $base"
    else
        printf '%-26s %-7s %-9s %-7s %s\n' "$host" "${http_status:-?}" "$size" "$md5count" "${C_RED}✗ no results${C_RESET}"
        NOW["$host"]="DEAD"
    fi
done

# ---------------------------------------------------------------------------
# active list
# ---------------------------------------------------------------------------
echo
echo "${C_BOLD}── CURRENTLY ACTIVE (verified working) ─────────────────────────${C_RESET}"
if [ -n "$active_list" ]; then
    for m in $active_list; do echo "  ${C_GREEN}✓${C_RESET} $m"; done
else
    echo "  ${C_RED}(none verified — check FlareSolverr/gluetun, or all mirrors down)${C_RESET}"
fi

# ---------------------------------------------------------------------------
# changes since last run
# ---------------------------------------------------------------------------
echo
echo "${C_BOLD}── CHANGES SINCE LAST RUN ──────────────────────────────────────${C_RESET}"
changes=0
for host in "${!NOW[@]}"; do
    prev="${PREV[$host]:-NEW}"
    if [ "$prev" = "NEW" ]; then
        echo "  ${C_CYAN}+ $host${C_RESET} : newly seen — now ${NOW[$host]}"; changes=$((changes+1))
    elif [ "$prev" != "${NOW[$host]}" ]; then
        if [ "${NOW[$host]}" = "WORKING" ]; then
            echo "  ${C_GREEN}↑ $host${C_RESET} : was DEAD, now WORKING"
        else
            echo "  ${C_RED}↓ $host${C_RESET} : was WORKING, now DEAD"
        fi
        changes=$((changes+1))
    fi
done
for host in "${!PREV[@]}"; do
    if [ -z "${NOW[$host]:-}" ]; then
        echo "  ${C_GREY}- $host : no longer checked${C_RESET}"; changes=$((changes+1))
    fi
done
[ "$changes" -eq 0 ] && echo "  ${C_DIM}(no changes — same as last run)${C_RESET}"

: > "$STATE_FILE"
for host in "${!NOW[@]}"; do echo "$host|${NOW[$host]}" >> "$STATE_FILE"; done

echo
echo "${C_BOLD}${C_CYAN}===============================================================${C_RESET}"
echo " ${C_DIM}state saved to $STATE_FILE (read by fetch-books)${C_RESET}"
echo "${C_BOLD}${C_CYAN}===============================================================${C_RESET}"