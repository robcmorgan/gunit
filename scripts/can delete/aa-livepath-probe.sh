#!/usr/bin/env bash
# aa-livepath-probe.sh — run the EXACT live search path for one book: same query,
# comment-strip, and parser fetch-books uses, then show candidates + scores.
# Reveals why a book that IS on Anna's still nomatches.
# Usage: ./aa-livepath-probe.sh "Pedro Páramo" "Juan Rulfo"
set -u
CONTAINER="${CONTAINER:-gluetun}"
FLARESOLVERR="${FLARESOLVERR:-http://localhost:8191/v1}"
MAXTIMEOUT="${MAXTIMEOUT:-60000}"
FORMATS="${FORMATS:-epub}"
LANGS="${LANGS:-en}"
MIRROR_STATE="${MIRROR_STATE:-$HOME/.cache/check-mirrors.state}"
MATCHLIB="${MATCHLIB:-$HOME/gunit/scripts/match-lib.sh}"
CONFIDENCE="${CONFIDENCE:-0.6}"
TITLE="${1:-Pedro Páramo}"; AUTHOR="${2:-Juan Rulfo}"
printf '%s' "aW1wb3J0IHN5cywgcmUsIGh0bWwKcyA9IHN5cy5zdGRpbi5yZWFkKCkKYW5jaG9yID0gcy5maW5kKCJhYXJlY29yZCIpCmlmIGFuY2hvciA8IDA6CiAgICBwcmludCgiTk9fQUFSRUNPUkRfQU5DSE9SIiwgZmlsZT1zeXMuc3RkZXJyKTsgc3lzLmV4aXQoMCkKcyA9IHNbYW5jaG9yOl0Kc2Vlbiwgb3V0ID0gc2V0KCksIFtdCmZvciBtIGluIHJlLmZpbmRpdGVyKHIiL21kNS8oW2EtZjAtOV17MzJ9KSIsIHMpOgogICAgbWQ1ID0gbS5ncm91cCgxKQogICAgaWYgbWQ1IGluIHNlZW46IGNvbnRpbnVlCiAgICBjYXJkID0gc1ttLmVuZCgpOiBtLmVuZCgpKzI1MDBdLnNwbGl0KCIvbWQ1LyIpWzBdCiAgICB0aXRsZSA9IGF1dGhvciA9ICIiCiAgICBkYyA9IHJlLmZpbmRhbGwocidkYXRhLWNvbnRlbnQ9IihbXiJdKikiJywgY2FyZCkKICAgIGlmIGxlbihkYykgPj0gMTogdGl0bGUgID0gaHRtbC51bmVzY2FwZShkY1swXSkuc3RyaXAoKQogICAgaWYgbGVuKGRjKSA+PSAyOiBhdXRob3IgPSBodG1sLnVuZXNjYXBlKGRjWzFdKS5zdHJpcCgpCiAgICBpZiBub3QgdGl0bGUgb3Igbm90IGF1dGhvcjoKICAgICAgICBwaCA9IHJlLnNlYXJjaChyJ1thLXowLTktXSsvW14vPD4iXSsvW14vPD4iXStfXGQrXC5bYS16MC05XSsnLCBjYXJkKQogICAgICAgIGlmIHBoOgogICAgICAgICAgICBwYXJ0cyA9IHBoLmdyb3VwKDApLnNwbGl0KCIvIikKICAgICAgICAgICAgaWYgbGVuKHBhcnRzKSA+PSAzOgogICAgICAgICAgICAgICAgaWYgbm90IGF1dGhvcjogYXV0aG9yID0gcGFydHNbLTJdLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIG5vdCB0aXRsZToKICAgICAgICAgICAgICAgICAgICB0ID0gcmUuc3ViKHInX1xkK1wuW2EtejAtOV0rJCcsICcnLCBwYXJ0c1stMV0pCiAgICAgICAgICAgICAgICAgICAgdGl0bGUgPSB0LnJlcGxhY2UoIl8iLCAiICIpLnN0cmlwKCkKICAgIGlmIHRpdGxlOgogICAgICAgIHNlZW4uYWRkKG1kNSkKICAgICAgICBvdXQuYXBwZW5kKGYie21kNX1cdHt0aXRsZX1cdHthdXRob3J9IikKcHJpbnQoZiJQQVJTRUQge2xlbihvdXQpfSBjYW5kaWRhdGVzIiwgZmlsZT1zeXMuc3RkZXJyKQpmb3IgbGluZSBpbiBvdXRbOjMwXToKICAgIHByaW50KGxpbmUpCg==" | base64 -d > /tmp/live_parser.py
. "$MATCHLIB" 2>/dev/null || { echo "cannot source $MATCHLIB"; exit 1; }

# mirrors fetch-books would use (WORKING from state, else built-in)
mirrors=()
if [ -f "$MIRROR_STATE" ]; then
  while IFS='|' read -r host verdict; do [ "$verdict" = "WORKING" ] && mirrors+=("https://$host"); done < "$MIRROR_STATE"
fi
[ "${#mirrors[@]}" -eq 0 ] && mirrors=("https://annas-archive.gd")
echo "mirrors: ${mirrors[*]}"

enc(){ printf '%s' "$1" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote_plus(sys.stdin.read().strip()))'; }
ext=""; for f in $FORMATS; do ext="${ext}&ext=${f}"; done
lang=""; for l in $LANGS; do lang="${lang}&lang=${l}"; done

want_t="$(norm "$TITLE")"; want_a="$(norm "$AUTHOR")"
for base in "${mirrors[@]}"; do
  url="${base%/}/search?q=$(enc "$TITLE $AUTHOR")${ext}${lang}"
  echo "==== $base ===="
  echo "  url: $url"
  p="{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":$MAXTIMEOUT}"
  resp="$(docker exec "$CONTAINER" sh -c "wget -qO- --timeout=$((MAXTIMEOUT/1000+15)) --post-data='$p' --header='Content-Type: application/json' '$FLARESOLVERR' 2>/dev/null")"
  echo "  raw bytes: ${#resp}"
  resp="${resp//<!--/}"; resp="${resp//-->/}"
  echo "  bytes after comment-strip: ${#resp}"
  cands="$(printf '%s' "$resp" | python3 /tmp/live_parser.py)"
  echo "  --- candidates (md5 | title | author) + score ---"
  while IFS=$'\t' read -r md5 ct ca; do
    [ -z "$md5" ] && continue
    s="$(book_match_fields "$TITLE" "$AUTHOR" "$ct" "$ca")"
    flag=""; ge "$s" "$CONFIDENCE" && flag=" <== MATCH"
    echo "    ${md5:0:8} s=$s T=[${ct:0:45}] A=[${ca:0:25}]$flag"
  done <<< "$cands"
  echo
done
