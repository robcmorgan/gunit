#!/usr/bin/env bash
# Reset the mis-matched "The Death of Us" row so fetch-books re-searches it.
# The recorded md5 (e6b1cf93...) is actually "Fortune Cookie Tyrant" — a wrong
# match — so we clear status+md5, dropping the line back to fetchable.
# Usage: ./reset-death-of-us.sh guardian-summer.tsv
set -uo pipefail
f="${1:?usage: $0 LIST.tsv}"
cp "$f" "$f.bak.$(date +%s)"   # safety backup
# match the line by title+author, replace status/md5/date columns
awk -F'|' 'BEGIN{OFS="|"}
  $1=="The Death of Us" && $2=="Abigail Dean" {
     print $1,$2; next }   # back to bare "Title|Author" => fetchable
  {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
echo "reset done; backup at $f.bak.*"
grep -n "Death of Us" "$f"
