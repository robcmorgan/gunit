#!/usr/bin/env bash
# pdf-reflow-diag.sh — inspect signals relevant to "is this PDF reflowable like an
# EPUB?" for one calibre id. Run: ./pdf-reflow-diag.sh 898  (compare vs 789 etc.)
set -u
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
id="${1:?usage: pdf-reflow-diag.sh <calibre_id>}"
cin(){ docker exec "$CALIBRE_CONTAINER" "$@"; }
cpath="$(docker exec "$CALIBRE_CONTAINER" calibredb list -f formats --for-machine -s "id:$id" \
  --library-path "$CALIBRE_LIBRARY" 2>/dev/null | python3 -c 'import sys,json
for b in json.load(sys.stdin):
    for f in (b.get("formats") or []):
        if f.lower().endswith(".pdf"): print(f); break')"
echo "id $id pdf: $cpath"
echo

echo "=== pdfinfo (look for: Tagged=yes, UserProperties, page size) ==="
cin pdfinfo "$cpath" 2>/dev/null | grep -iE 'tagged|pages|page size|producer|creator|javascript|form|structure|optimized'

echo
echo "=== is it a TAGGED pdf? (structure tree = the thing that enables reflow) ==="
# tagged PDFs carry /StructTreeRoot and /MarkInfo<</Marked true>>; grep the raw pdf
cin sh -c 'grep -a -c "/StructTreeRoot" "$1" 2>/dev/null' _ "$cpath" | sed 's/^/  StructTreeRoot hits: /'
cin sh -c 'grep -a -o "/Marked[[:space:]]*true" "$1" 2>/dev/null | head -1' _ "$cpath" | sed 's/^/  MarkInfo: /'
cin sh -c 'grep -a -o "/Tagged[[:space:]]*/Document" "$1" 2>/dev/null | head -1' _ "$cpath" | sed 's/^/  Tagged: /'

echo
echo "=== images per first 6 pages (scan signal) ==="
cin pdfimages -list -f 1 -l 6 "$cpath" 2>/dev/null \
  | awk 'NR>2 && $3=="image"{w=$4+0;h=$5+0; if(w>=600&&h>=800) seen[$1]=1}
         END{n=0;for(p in seen)n++; print "  big-image pages (of 6):", n+0}'

echo
echo "=== text density first 6 pages ==="
c="$(cin pdftotext -f 1 -l 6 "$cpath" - 2>/dev/null | tr -d '[:space:]' | wc -c)"
echo "  chars: ${c:-0}"

echo
echo "=== embedded fonts ==="
cin pdffonts "$cpath" 2>/dev/null | tail -n +3 | awk '{emb=$( NF-3 ); print "  "$1" emb="emb}' | head
