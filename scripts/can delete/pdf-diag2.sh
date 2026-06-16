#!/usr/bin/env bash
# pdf-diag2.sh — show EXACTLY what v2's classify_pdf computes for one book, so we
# can see why the image-coverage branch didn't fire. Run: ./pdf-diag2.sh 815
set -u
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
SAMPLE_PAGES="${SAMPLE_PAGES:-6}"
id="${1:?usage: pdf-diag2.sh <calibre_id>}"
cin(){ docker exec "$CALIBRE_CONTAINER" "$@"; }
cpath="$(docker exec "$CALIBRE_CONTAINER" calibredb list -f formats --for-machine -s "id:$id" \
  --library-path "$CALIBRE_LIBRARY" 2>/dev/null | python3 -c 'import sys,json
for b in json.load(sys.stdin):
    for f in (b.get("formats") or []):
        if f.lower().endswith(".pdf"): print(f); break')"
echo "pdf: $cpath"
echo
echo "=== raw pdfimages -list (first $SAMPLE_PAGES pages) ==="
cin pdfimages -list -f 1 -l "$SAMPLE_PAGES" "$cpath" 2>/dev/null

echo
echo "=== what v2's awk counts (image rows >=600x800, distinct pages) ==="
cin pdfimages -list -f 1 -l "$SAMPLE_PAGES" "$cpath" 2>/dev/null \
  | awk 'NR>2 && $2 ~ /^image$/ { w=$4+0; h=$5+0;
           printf "  page %s  type=%s  %sx%s  big=%s\n", $1,$2,w,h,(w>=600&&h>=800)?"YES":"no";
           if (w>=600 && h>=800) seen[$1]=1 }
         END { n=0; for (p in seen) n++; print "  distinct big-image pages:", n+0 }'

echo
echo "=== column check: is \$2 really 'type' and \$4/\$5 width/height? ==="
cin pdfimages -list -f 1 -l 1 "$cpath" 2>/dev/null | head -3 | cat -A | head -3
