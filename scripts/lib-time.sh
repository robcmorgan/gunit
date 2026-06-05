#!/usr/bin/env bash
LIB_TIME_VERSION="1"
# =============================================================================
#  lib-time.sh — human-friendly time formatting for the gunit bash scripts.
#  Ported from Core.ps1 (Format-Timespan, Get-TimeFriendly) to keep the same
#  output style across the PowerShell and bash sides. Source it:
#       . "$(dirname "$0")/lib-time.sh"
#  Requires bash (and GNU date for fmt_friendly's epoch handling).
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "lib-time.sh requires bash; source it from a bash script." >&2
    return 1 2>/dev/null || exit 1
fi

# fmt_timespan SECONDS [--short] [NOW_THRESHOLD]
# Duration as natural language. Mirrors Core.ps1 Format-Timespan:
#   <=30s -> "just now"/"now"; <60s -> "N seconds"; <59.5m -> "N minutes"
#   (rounded); <24h -> "N hours[, M minutes]"; >=24h -> "N days[, M hours]".
# --short uses "1h 19m" instead of "1 hour, 19 minutes".
fmt_timespan() {
    local secs="${1:-0}" short=0 nowthr=30 a
    shift || true
    for a in "$@"; do
        case "$a" in
            --short) short=1 ;;
            ''|*[!0-9]*) ;;        # ignore non-numeric
            *) nowthr="$a" ;;
        esac
    done
    # round to nearest integer second
    secs="$(awk -v s="$secs" 'BEGIN{printf "%d", (s<0?-s:s)+0.5}')"

    local s_s s_m s_h s_d andp
    if [ "$short" -eq 1 ]; then
        s_s="s"; s_m="m"; s_h="h"; s_d="d"; andp=" "
    else
        s_s=" second"; s_m=" minute"; s_h=" hour"; s_d=" day"; andp=", "
    fi
    # pluralise helper: $1 value, $2 unit-word; adds 's' unless value==1 or short
    _pl() { if [ "$short" -eq 1 ] || [ "$1" -eq 1 ]; then printf '%s' "$2"; else printf '%ss' "$2"; fi; }

    if [ "$secs" -le "$nowthr" ]; then
        [ "$short" -eq 1 ] && echo "now" || echo "just now"; return
    elif [ "$secs" -lt 60 ]; then
        echo "${secs}$(_pl "$secs" "$s_s")"; return
    elif [ "$secs" -lt 3570 ]; then
        local m=$(( (secs + 30) / 60 ))
        echo "${m}$(_pl "$m" "$s_m")"; return
    elif [ "$secs" -lt 86400 ]; then
        local h=$(( (secs + 30) / 3600 )) rm=$(( ((secs + 30) % 3600) / 60 ))
        local out="${h}$(_pl "$h" "$s_h")"
        [ "$rm" -gt 0 ] && out="${out}${andp}${rm}$(_pl "$rm" "$s_m")"
        echo "$out"; return
    else
        local d=$(( secs / 86400 )) rh=$(( (secs % 86400) / 3600 ))
        local out="${d}$(_pl "$d" "$s_d")"
        [ "$rh" -gt 0 ] && out="${out}${andp}${rh}$(_pl "$rh" "$s_h")"
        echo "$out"; return
    fi
}

# fmt_clock EPOCH  -> "3.45pm" (lowercase, dot separator) — Core.ps1 'h.mmtt'
fmt_clock() {
    # %-I = hour 1-12 no pad; %M minutes; %P am/pm lowercase (GNU date)
    date -d "@$1" '+%-I.%M%P' 2>/dev/null
}

# fmt_friendly EPOCH  -> relative string, mirrors Core.ps1 Get-TimeFriendly:
#   "3.45pm today" / "10.00am yesterday" / "9.00am tomorrow"
#   within 6 days (past or future): "Tuesday at 2.30pm"
#   exactly +/-7 days: "Last/Next Monday at 9.00am"
#   else: "14 Mar 2024 (Thu)"
fmt_friendly() {
    local e="$1"
    local now; now="$(date +%s)"
    # midnight (date-only) epochs for day-difference math
    local d_in d_now
    d_in="$(date -d "@$e" '+%Y-%m-%d')"
    d_now="$(date '+%Y-%m-%d')"
    local e_in_mid e_now_mid daydiff
    e_in_mid="$(date -d "$d_in 00:00:00" +%s)"
    e_now_mid="$(date -d "$d_now 00:00:00" +%s)"
    daydiff=$(( (e_in_mid - e_now_mid) / 86400 ))

    local t dow
    t="$(fmt_clock "$e")"
    dow="$(date -d "@$e" '+%A')"

    if   [ "$daydiff" -eq 0 ];  then echo "$t today"
    elif [ "$daydiff" -eq -1 ]; then echo "$t yesterday"
    elif [ "$daydiff" -eq 1 ];  then echo "$t tomorrow"
    elif [ "$daydiff" -lt 0 ] && [ "$daydiff" -gt -6 ]; then echo "$dow at $t"
    elif [ "$daydiff" -gt 0 ] && [ "$daydiff" -lt 6 ];  then echo "$dow at $t"
    elif [ "$daydiff" -eq -7 ]; then echo "Last $dow at $t"
    elif [ "$daydiff" -eq 7 ];  then echo "Next $dow at $t"
    else date -d "@$e" '+%d %b %Y (%a)'
    fi
}

# fmt_ago EPOCH  -> "5 minutes ago" / "in 2 hours" using fmt_timespan
fmt_ago() {
    local e="$1" now; now="$(date +%s)"
    local diff=$(( now - e ))
    if [ "$diff" -ge 0 ]; then
        echo "$(fmt_timespan "$diff") ago"
    else
        echo "in $(fmt_timespan "$(( -diff ))")"
    fi
}