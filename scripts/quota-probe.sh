#!/usr/bin/env bash
QUOTA_PROBE_VERSION="1"
# =============================================================================
#  quota-probe.sh — query Anna's fast-download quota LIVE without spending a slot.
#
#  The JSON API returns account_fast_download_info when queried with a VALID md5.
#  You are only charged when you FETCH the returned download_url — querying the
#  JSON does not decrement. So this is a free, exact, current quota read that
#  includes ALL downloads on the shared key (fetch-books AND shelfmark).
#
#  Source it for the function, or run standalone for the raw numbers:
#       . "$(dirname "$0")/quota-probe.sh"; quota_probe; echo "$QP_LEFT"
#       ./quota-probe.sh
#
#  When sourced + quota_probe succeeds, populates:
#     QP_LEFT  downloads_left      QP_DONE  downloads_done_today
#     QP_CAP   downloads_per_day   QP_MD5S  newline-separated recent md5s
#  Returns nonzero on failure (no network, bad key, parse error).
#
#  Env: CONFIG_YAML, GLUETUN_CONTAINER, AA_DOMAIN, PROBE_MD5 (a known-valid md5).
# =============================================================================
CONFIG_YAML="${CONFIG_YAML:-$HOME/gunit/stacks_config/config.yaml}"
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
AA_DOMAIN="${AA_DOMAIN:-annas-archive.gd}"
PROBE_MD5="${PROBE_MD5:-d6e1dc51a50726f00ec438af21952a45}"   # Anna's own doc example md5

quota_probe() {
    local key json parsed
    key="$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
    [ -z "$key" ] && { echo "quota_probe: no key in $CONFIG_YAML" >&2; return 1; }

    json="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=30 \
        "https://${AA_DOMAIN}/dyn/api/fast_download.json?md5=${PROBE_MD5}&key=${key}" 2>/dev/null)"
    [ -z "$json" ] && { echo "quota_probe: empty response (network/mirror?)" >&2; return 1; }

    parsed="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    info = json.load(sys.stdin).get("account_fast_download_info")
    if not info:
        print("ERR no account_fast_download_info"); sys.exit(1)
    print("QP_LEFT="+str(info.get("downloads_left","")))
    print("QP_DONE="+str(info.get("downloads_done_today","")))
    print("QP_CAP="+str(info.get("downloads_per_day","")))
    print("QP_MD5S_BEGIN")
    print("\n".join(info.get("recently_downloaded_md5s",[])))
    print("QP_MD5S_END")
except Exception as e:
    print("ERR "+str(e)); sys.exit(1)
' 2>/dev/null)"
    case "$parsed" in ERR*|"") echo "quota_probe: parse failed (${parsed:-empty})" >&2; return 1;; esac

    QP_LEFT="$(printf '%s\n' "$parsed" | sed -n 's/^QP_LEFT=//p')"
    QP_DONE="$(printf '%s\n' "$parsed" | sed -n 's/^QP_DONE=//p')"
    QP_CAP="$(printf '%s\n' "$parsed"  | sed -n 's/^QP_CAP=//p')"
    QP_MD5S="$(printf '%s\n' "$parsed" | sed -n '/QP_MD5S_BEGIN/,/QP_MD5S_END/p' | sed '1d;$d')"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    quota_probe || exit 1
    echo "downloads_left:       $QP_LEFT"
    echo "downloads_done_today: $QP_DONE"
    echo "downloads_per_day:    $QP_CAP"
    echo "recent md5s:          $(printf '%s\n' "$QP_MD5S" | grep -c .)"
fi