#!/usr/bin/env bash
# format-inventory.sh — list every file format in the Calibre library with a
# count of how many books have each, so we can decide what to keep/ban. Read-only.
set -u
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"

echo "=== format inventory (books per format) ==="
docker exec "$CALIBRE_CONTAINER" calibredb list -f formats --for-machine \
    --library-path "$CALIBRE_LIBRARY" 2>/dev/null \
| python3 -c '
import sys, json, os, collections
data = json.load(sys.stdin)
ext_books = collections.Counter()   # books that HAVE >=1 file of this ext
ext_files = collections.Counter()   # total files of this ext
total_books = len(data)
books_with_any = 0
for b in data:
    fmts = b.get("formats") or []
    if fmts: books_with_any += 1
    exts = set()
    for f in fmts:
        if not isinstance(f, str): continue
        ext = os.path.splitext(f)[1].lower().lstrip(".") or "(none)"
        ext_files[ext] += 1
        exts.add(ext)
    for e in exts:
        ext_books[e] += 1

print(f"total books: {total_books}  (with >=1 format file: {books_with_any})\n")
print("%-12s%8s%8s" % ("format", "books", "files"))
print("-"*28)
for ext, n in sorted(ext_books.items(), key=lambda kv: (-kv[1], kv[0])):
    print("%-12s%8d%8d" % (ext, n, ext_files[ext]))

# books whose ONLY format is a non-ebook (candidates to worry about)
print("\n=== books whose ONLY format is each ext (no other format to fall back on) ===")
only = collections.Counter()
for b in data:
    exts = set(os.path.splitext(f)[1].lower().lstrip(".") for f in (b.get("formats") or []) if isinstance(f,str))
    if len(exts) == 1:
        only[next(iter(exts))] += 1
for ext, n in sorted(only.items(), key=lambda kv:(-kv[1], kv[0])):
    print(f"  {ext:<10} sole-format books: {n}")
'
