#!/usr/bin/env bash
QUOTA_PROBE_VERSION="3"
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
#  Env: CONFIG_YAML, GLUETUN_CONTAINER, AA_DOMAINS (space-separated, tried in
#       order), PROBE_MD5 (a known-valid md5).
#
#  v3: when the daily quota is EXHAUSTED Anna's returns
#      account_fast_download_info:null with error:"No downloads left". v2 rejected
#      that (no account block) and misreported exhaustion as a probe failure. v3
#      treats it as a valid reading of QP_LEFT=0 (QP_DONE/QP_CAP unknown, left "").
#  v2: (1) use wget --content-on-error — the API returns its JSON body with a
#          non-2xx HTTP status, and plain `wget -q` DISCARDS the body on error,
#          so every probe came back empty ("network/mirror?") even though the
#          download path worked. fetch-books' fast_api_call already did this.
#      (2) try MULTIPLE mirrors in order (AA_DOMAINS) instead of one hardcoded
#          host, so a single down mirror doesn't fail the probe.
# =============================================================================
CONFIG_YAML="${CONFIG_YAML:-$HOME/gunit/stacks_config/config.yaml}"
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
# space-separated mirror list, tried in order (matches fetch-books' AA_DOMAINS).
# AA_DOMAIN (singular) still honoured as a first/only mirror for back-compat.
AA_DOMAINS="${AA_DOMAINS:-${AA_DOMAIN:-annas-archive.se annas-archive.pk annas-archive.gd annas-archive.gl}}"
PROBE_MD5="${PROBE_MD5:-d6e1dc51a50726f00ec438af21952a45}"   # Anna's own doc example md5

quota_probe() {
    local key json parsed d
    key="$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
    [ -z "$key" ] && { echo "quota_probe: no key in $CONFIG_YAML" >&2; return 1; }

    json=""
    local err=""
    for d in $AA_DOMAINS; do
        local url="https://${d}/dyn/api/fast_download.json?md5=${PROBE_MD5}&key=${key}"
        # CRITICAL: --content-on-error. The API returns its JSON (quota/error)
        # with a non-2xx status; plain `wget -q` drops the body on error and
        # yields empty. Fall back to plain wget for builds lacking the flag.
        json="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --content-on-error --timeout=30 "$url" 2>/dev/null)"
        [ -z "$json" ] && json="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=30 "$url" 2>/dev/null)"
        # accept a parseable JSON body that EITHER carries account info OR is the
        # explicit quota-exhausted error. When the daily quota is spent, Anna's
        # returns account_fast_download_info:null with error:"No downloads left",
        # so requiring the account block would misreport exhaustion as a probe
        # failure. Treat that error as a valid reading of ZERO downloads left.
        local kind
        kind="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get("account_fast_download_info"): print("INFO")
    elif "no downloads left" in (d.get("error") or "").lower(): print("EMPTY")
    else: print("OTHER")
except Exception: print("OTHER")' 2>/dev/null)"
        case "$kind" in
            INFO)  QP_DOMAIN_USED="$d"; break ;;
            EMPTY) QP_DOMAIN_USED="$d"; err="exhausted"; break ;;
        esac
        json=""   # OTHER / unparseable -> try next mirror
    done
    [ -z "$json" ] && { echo "quota_probe: no usable response from any mirror ($AA_DOMAINS)" >&2; return 1; }

    # quota exhausted: report a clean zero rather than parsing the (null) account.
    if [ "$err" = "exhausted" ]; then
        QP_LEFT=0; QP_DONE=""; QP_CAP=""; QP_MD5S=""
        return 0
    fi

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
    echo "downloads_done_today: ${QP_DONE:-(unknown — quota exhausted)}"
    echo "downloads_per_day:    ${QP_CAP:-(unknown — quota exhausted)}"
    echo "recent md5s:          $(printf '%s\n' "$QP_MD5S" | grep -c .)"
    echo "mirror used:          ${QP_DOMAIN_USED:-?}"
fi