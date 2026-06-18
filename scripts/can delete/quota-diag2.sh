#!/usr/bin/env bash
# quota-diag2.sh — confirm whether --content-on-error is what makes the quota
# API return a body. Tests plain wget vs --content-on-error on the SAME mirror.
set -u
CONFIG_YAML="${CONFIG_YAML:-$HOME/gunit/stacks_config/config.yaml}"
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
PROBE_MD5="${PROBE_MD5:-d6e1dc51a50726f00ec438af21952a45}"
key="$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
for d in annas-archive.se annas-archive.gd annas-archive.pk; do
  url="https://${d}/dyn/api/fast_download.json?md5=${PROBE_MD5}&key=${key}"
  echo "=== $d ==="
  a="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --timeout=25 "$url" 2>/dev/null)"
  b="$(docker exec "$GLUETUN_CONTAINER" wget -qO- --content-on-error --timeout=25 "$url" 2>/dev/null)"
  echo "  plain wget bytes:            ${#a}"
  echo "  --content-on-error bytes:    ${#b}"
  [ -n "$b" ] && printf '%s' "$b" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); i=d.get("account_fast_download_info")
    print("  -> error:", d.get("error"), " downloads_left:", i.get("downloads_left") if i else None)
except Exception as e: print("  -> parse:", e)' 2>/dev/null
  echo
done
