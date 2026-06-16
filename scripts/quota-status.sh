#!/usr/bin/env bash
QUOTA_STATUS_VERSION="6"   # (version stamp also at end of file)
# =============================================================================
#  quota-status.sh — Anna's fast-download quota, LIVE and exact.
#
#  Queries the API for the authoritative figure (downloads_left / done_today),
#  which includes the shared key's shelfmark downloads and costs nothing (a JSON
#  query does not spend a slot — only fetching the download_url does). Then it
#  dates as many of the 'recently_downloaded_md5s' as it can from fetch-books'
#  log to project when slots roll off. md5s not in the log are shelfmark's (or
#  manual) — datable count + undatable count are both shown.
#
#  USAGE:  ./quota-status.sh
#          WINDOW_HOURS=18 ./quota-status.sh
#          ./quota-status.sh --targets 5,15,25
#          ./quota-status.sh --no-probe      # offline: use last log reading only
#
#  v6: date EVERY quota spend, not just kept downloads. fetch-books v80 logs a
#      'quota-spend [md5:<hash>]' line for EVERY fast-download API fetch — incl.
#      candidates it then rejects for language/PDF/format. Previously this script
#      built its md5->time map ONLY from 'downloaded -> ' (kept) lines, so the
#      discarded-candidate spends (foreign editions of the same book, PDFs) had no
#      timestamp and were miscounted as 'shelfmark/manual'. The map now also reads
#      the v80 'quota-spend' lines, so all of fetch-books' real spends are datable
#      and the projection horizon extends to the full cap. 'downloaded -> ' lines
#      are still read (older logs predate v80), and a spend+kept pair for the same
#      md5 collapses to one entry (newest epoch wins), so no double-count.
#  v5: read the SHARED log (~/logs/gunit.log) — fetch-books moved there in its
#      v46, leaving this pointed at the now-stale fetch-books.log so 0 downloads
#      were datable. Also parse the explicit [md5:<hash>] field fetch-books v50
#      logs: the filename embeds only a TRUNCATED md5, so the old 32-hex regex
#      matched nothing. Falls back to a 32-hex scan for older lines.
# =============================================================================
set -uo pipefail

LOG="${LOG:-${GUNIT_LOG:-$HOME/logs/gunit.log}}"
WINDOW_HOURS="${WINDOW_HOURS:-18}"
TARGETS="10 20 30 40"
PROBE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --targets) TARGETS="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
        --no-probe) PROBE=0; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[ -f "$LOG" ] || { echo "log not found: $LOG (set LOG=...)" >&2; exit 1; }
here="$(dirname "$0")"
. "$here/lib-time.sh"

now_epoch="$(date +%s)"
window_secs=$(( WINDOW_HOURS * 3600 ))

# ---- live probe (free, exact, includes shelfmark) ----
FREE="" ; DONE="" ; CAP="50" ; RECENT=""
if [ "$PROBE" -eq 1 ] && [ -f "$here/quota-probe.sh" ]; then
    . "$here/quota-probe.sh"
    if quota_probe; then
        FREE="$QP_LEFT"; DONE="$QP_DONE"; CAP="${QP_CAP:-50}"; RECENT="$QP_MD5S"
    else
        echo "(live probe failed — falling back to log; numbers may be stale)" >&2
    fi
fi

echo "=== fast-download quota (rolling ${WINDOW_HOURS}h) ==="
echo "now: $(fmt_friendly "$now_epoch")"

if [ -n "$FREE" ]; then
    echo "FREE NOW: ${FREE}/${CAP}   (live from Anna's — includes shelfmark)"
    echo "used today: ${DONE}/${CAP}"
else
    # offline fallback: most recent logged 'quota left'. Restrict to fetch-books
    # [f] lines so other scripts' shared-log entries don't interfere.
    local_q="$(grep -E '\[f\].*quota left:' "$LOG" | tail -1 | grep -oE 'quota left: [0-9]+' | grep -oE '[0-9]+' || true)"
    lq_ts="$(grep -E '\[f\].*quota left:' "$LOG" | tail -1 | awk '{print $1" "$2}')"
    lq_e="$(date -d "$lq_ts" +%s 2>/dev/null || echo "")"
    if [ -n "$local_q" ] && [ -n "$lq_e" ]; then
        echo "FREE NOW: ~${local_q}/${CAP}  (last LOG reading, $(fmt_ago "$lq_e") — may be stale)"
    else
        echo "FREE NOW: unknown (no probe, no logged reading)"
    fi
fi
echo

# ---- date the recent md5s from the log, for roll-off timing ----
# Build a map md5 -> newest log epoch by scanning fetch-books QUOTA-SPEND lines
# AND kept-download lines. v80 logs 'quota-spend [md5:<hash>]' for EVERY real
# fast-download spend (including candidates later rejected for language/PDF), so
# this captures the discarded-candidate spends that the kept-download line alone
# missed. Older logs (pre-v80) only have 'downloaded -> ', so we still read those;
# a spend+kept pair for the same md5 collapses to one entry (newest epoch wins).
# The full md5 is in an explicit [md5:<hash>] field. For older lines that lack it,
# fall back to a 32-hex scan. Restrict to [f] lines so sweep/tag entries in the
# shared log are ignored.
declare -A MD5_EPOCH
while IFS= read -r line; do
    # explicit field first
    m="$(printf '%s' "$line" | grep -oE '\[md5:[a-f0-9]{32}\]' | head -1 | grep -oE '[a-f0-9]{32}')"
    [ -z "$m" ] && m="$(printf '%s' "$line" | grep -oE '[a-f0-9]{32}' | head -1)"
    [ -z "$m" ] && continue
    ts="$(printf '%s' "$line" | awk '{print $1" "$2}')"
    e="$(date -d "$ts" +%s 2>/dev/null)" || continue
    MD5_EPOCH["$m"]="$e"   # later lines overwrite -> newest wins
done < <(grep -E '\[f\].*(quota-spend|downloaded -> )' "$LOG")

datable=() ; undatable=0
if [ -n "$RECENT" ]; then
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        if [ -n "${MD5_EPOCH[$m]:-}" ]; then
            datable+=("${MD5_EPOCH[$m]}")
        else
            undatable=$(( undatable + 1 ))
        fi
    done <<< "$RECENT"
fi
IFS=$'\n' datable=($(printf '%s\n' "${datable[@]:-}" | grep -E '^[0-9]+$' | sort -n)); unset IFS

if [ -n "$RECENT" ]; then
    echo "of $(printf '%s\n' "$RECENT" | grep -c .) counted downloads: ${#datable[@]} datable from log, ${undatable} not (shelfmark/manual)"
    echo
fi

# ---- projections ----
# free rises as the OLDEST counted downloads roll off (spend + window). We can
# only time the datable ones; undatable (shelfmark) roll-offs are unknown, so
# projections are a LOWER BOUND.
if [ -z "$FREE" ]; then
    echo "(no live free figure — skipping projections)"
    exit 0
fi

echo "time until capacity for (lower bound — shelfmark roll-offs not timed):"
# future roll-off times from the datable set, ascending
future=()
for e in "${datable[@]:-}"; do
    [ -z "$e" ] && continue
    fe=$(( e + window_secs ))
    [ "$fe" -gt "$now_epoch" ] && future+=("$fe")
done
IFS=$'\n' future=($(printf '%s\n' "${future[@]:-}" | grep -E '^[0-9]+$' | sort -n)); unset IFS

for N in $TARGETS; do
    if [ "$N" -le "$FREE" ]; then
        printf '  %2d books:  available now\n' "$N"; continue
    fi
    if [ "$N" -gt "$CAP" ]; then
        printf '  %2d books:  never (exceeds cap of %d)\n' "$N" "$CAP"; continue
    fi
    need=$(( N - FREE ))
    if [ "${#future[@]}" -lt "$need" ]; then
        printf '  %2d books:  not projectable (need %d roll-offs, log can time %d)\n' \
            "$N" "$need" "${#future[@]}"; continue
    fi
    tf="${future[$(( need - 1 ))]}"
    w=$(( tf - now_epoch )); [ "$w" -lt 0 ] && w=0
    printf '  %2d books:  %-20s (at %s)\n' "$N" "$(fmt_timespan "$w")" "$(fmt_friendly "$tf")"
done

echo
echo "note: FREE NOW is Anna's live figure (free to query, includes shelfmark)."
echo "      projection timing uses fetch-books' logged spends (v80: every spend,"
echo "      including rejected candidates); any remaining undatable slots are"
echo "      genuinely shelfmark/manual and roll off at times we can't see."

# =============================================================================
# version: QUOTA_STATUS_VERSION 6
# =============================================================================