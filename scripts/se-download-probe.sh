#!/usr/bin/env bash
# se-download-probe.sh — inspect exactly what the SE download URL returns for a
# given slug, WITHOUT moving anything into DEST. Shows the final URL after
# redirects, HTTP status, content-type, size, and the epub's INTERNAL metadata
# (title/author/identifier from the OPF) so we can see if the file is wrong,
# misnamed, or a different edition.
#
# Usage:
#   ./se-download-probe.sh george-eliot/middlemarch
#   SE_FORMAT=compatible ./se-download-probe.sh george-eliot/middlemarch
set -uo pipefail
CONTAINER="${CONTAINER:-gluetun}"
DL_CONTAINER="${DL_CONTAINER:-qbittorrent}"
SE_BASE="${SE_BASE:-https://standardebooks.org}"
SE_FORMAT="${SE_FORMAT:-compatible}"
slug="$1"
[ -z "$slug" ] && { echo "usage: $0 author-slug/title-slug" >&2; exit 1; }

a="$(printf '%s' "$slug" | cut -d/ -f1)"
t="$(printf '%s' "$slug" | cut -d/ -f2)"
fnamebase="${a}_${t}"
case "$SE_FORMAT" in
  compatible) url="${SE_BASE%/}/ebooks/${slug}/downloads/${fnamebase}.epub" ;;
  advanced)   url="${SE_BASE%/}/ebooks/${slug}/downloads/${fnamebase}_advanced.epub" ;;
  azw3)       url="${SE_BASE%/}/ebooks/${slug}/downloads/${fnamebase}.azw3" ;;
  kepub)      url="${SE_BASE%/}/ebooks/${slug}/downloads/${fnamebase}.kepub.epub" ;;
esac
echo "constructed URL: $url"
echo

echo "===== 1. HTTP headers (follow redirects, show final URL) ====="
# -L follow redirects, -I head only, -w final url + code. Run in the VPN netns.
docker exec "$CONTAINER" sh -c "wget --server-response --spider -T 30 '$url' 2>&1" | \
  grep -Ei 'HTTP/|Location:|Content-Type:|Content-Length:' || echo "(no headers — wget --spider unsupported? trying GET below)"
echo

echo "===== 2. download to a scratch file in DL_CONTAINER and inspect ====="
tmp="/tmp/se-probe-$$.epub"
docker exec "$DL_CONTAINER" sh -c "wget -q -T 60 -O '$tmp' '$url'" || { echo "!! download failed"; exit 2; }
echo "size: $(docker exec "$DL_CONTAINER" sh -c "wc -c < '$tmp'") bytes"
echo "file type: $(docker exec "$DL_CONTAINER" sh -c "head -c 4 '$tmp' | od -An -c | tr -d ' \n'")  (PK.. = real zip/epub; '<!DO' or '<htm' = HTML error page)"
echo

echo "===== 3. epub internal metadata (the real title/author inside the file) ====="
# epub is a zip; content.opf holds <dc:title>/<dc:creator>/<dc:identifier>.
docker exec "$DL_CONTAINER" sh -c "
  command -v unzip >/dev/null 2>&1 || { echo '(no unzip in $DL_CONTAINER — skipping internal check)'; exit 0; }
  opf=\$(unzip -p '$tmp' META-INF/container.xml 2>/dev/null | grep -oE 'full-path=\"[^\"]+\"' | head -1 | sed 's/full-path=//; s/\"//g')
  [ -z \"\$opf\" ] && opf='epub/content.opf'
  echo \"  opf path: \$opf\"
  unzip -p '$tmp' \"\$opf\" 2>/dev/null | grep -oE '<dc:(title|creator|identifier)[^>]*>[^<]+</dc:[^>]+>' | head -8
"
echo

echo "===== 4. cleanup ====="
docker exec "$DL_CONTAINER" rm -f "$tmp" && echo "removed $tmp"
