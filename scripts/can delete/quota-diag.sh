#!/usr/bin/env bash
# quota-diag.sh — why does quota_probe return empty? Tests the exact call across
# mirrors and shows the raw response so we can see whether it's a dead mirror, a
# bad md5, or a key problem.
set -u
CONFIG_YAML="${CONFIG_YAML:-$HOME/gunit/stacks_config/config.yaml}"
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
PROBE_MD5="${PROBE_MD5:-d6e1dc51a50726f00ec438af21952a45}"
key="$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
[ -z "$key" ] && { echo "NO KEY in $CONFIG_YAML"; exit 1; }
echo "key: ${key:0:6}…(${#key} chars)   probe md5: $PROBE_MD5"
echo
for d in annas-archive.gd annas-archive.se annas-archive.pk annas-archive.gl annas-archive.org; do
  url="https://${d}/dyn/api/fast_download.json?md5=${PROBE_MD5}&key=${key}"
  echo "=== $d ==="
  resp="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=25 "$url" 2>&1)"
  echo "  bytes: ${#resp}"
  if [ -n "$resp" ]; then
    printf '%s' "$resp" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    print("  error:", d.get("error"))
    i=d.get("account_fast_download_info")
    print("  downloads_left:", i.get("downloads_left") if i else None)
    print("  download_url present:", bool(d.get("download_url")))
except Exception as e:
    print("  parse err:", e); print("  head:", sys.stdin.read()[:120])
' 2>/dev/null || echo "  (non-JSON) head: $(printf '%s' "$resp" | head -c120)"
  fi
  echo
done
