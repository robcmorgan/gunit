#!/usr/bin/env bash
AUDIT_TAGS_VERSION="2"   # bump on every change; echoed at startup and footer
# v2: FIX spurious B-DISAGREE storm. id_for_md5 could capture calibredb stderr
#     (lock warning / "No books matching...") into $sid via v5's stderr
#     propagation, making [ -n "$sid" ] true on non-id garbage so EVERY tagged
#     row with no real stamp fired a false B flag (76/98 on alex_prize, all with
#     an empty stamp id). Now id_for_md5 returns ONLY a bare integer (stderr
#     discarded, non-numeric rejected); sid and rid are numeric-guarded before
#     checks A/B; and find_book_id's expected zero-result stderr is routed to
#     AUDIT_STDERR_LOG (default /tmp/audit-tags.stderr.log) so the console shows
#     only verdicts. No verdict logic changed — a real stamp/v5 disagreement
#     still flags B; this only stops empty-stamp rows from being mislabelled.
# =============================================================================
#  audit-tags.sh — READ-ONLY contamination audit for the tag pipeline.
#
#  WHY: tag-lib's find_book_id scored candidates with the BLOB matcher
#  (book_match_score) until v5. The blob flattens a candidate's title+author into
#  one string, so a short wanted title whose word leaks in from a SAME-AUTHOR
#  sibling book (or from the author field) could false-match the WRONG book. Live
#  proof: "The Poet X" (Acevedo) matched id 1936 "With the Fire on High" (also
#  Acevedo). v5 switched to the field-separated matcher (book_match_fields), which
#  rejects those. But every tag-books / tag-queue run BEFORE v5 used the blob
#  matcher, so wrong tags and wrong annas:<md5> stamps may already sit in the
#  library. This script finds them. It WRITES NOTHING.
#
#  WHAT IT CHECKS, per 'tagged' row across the given TSV(s):
#    A) STAMP MISMATCH: the row's md5 is stamped (annas:<md5>) onto a calibre book
#       whose title is NOT compatible with the row's title -> contamination.
#    B) MATCHER DISAGREE: the v5 matcher resolves the row to a DIFFERENT id than
#       the one the md5 stamp points to -> the stamp likely landed on the wrong
#       book (or the row was tagged-by-fuzzy onto the wrong id pre-v5).
#    C) TAG MISSING: the row says 'tagged' but the resolved book carries NONE of
#       the list's header tags -> the tag never actually applied (or applied to a
#       different book).
#    D) UNRESOLVABLE: 'tagged' row the v5 matcher can't place at all (book gone,
#       or title/author drift) -> needs a look.
#
#  Rows that pass all checks are silent unless --verbose.
#
#  USAGE:
#     ./audit-tags.sh LIST.tsv [LIST2.tsv ...]
#     ./audit-tags.sh ~/gunit/tsv-lists/*.tsv          # whole library
#     ./audit-tags.sh --verbose alex_prize.tsv         # also print OK rows
#
#  Reuses the SAME matchers the pipeline uses (match-lib + tag-lib), so its verdict
#  is exactly what a v5 tag run would now decide — no separate logic to drift.
# =============================================================================
set -uo pipefail

CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CONFIDENCE="${CONFIDENCE:-0.6}"
ID_SCHEME="${ID_SCHEME:-annas}"
HERE="$(dirname "$0")"
AUDIT_STDERR_LOG="${AUDIT_STDERR_LOG:-/tmp/audit-tags.stderr.log}"
: > "$AUDIT_STDERR_LOG" 2>/dev/null || AUDIT_STDERR_LOG=/dev/null

VERBOSE=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -eq 0 ] && { echo "usage: $0 [--verbose] LIST.tsv..." >&2; exit 1; }

# shared matchers + cdb (same code the tag pipeline uses)
. "$HERE/match-lib.sh"   # norm, ge, title_full_match, book_match_fields, ...
. "$HERE/tag-lib.sh"     # cdb, find_book_id, _cand_fields

# titles_compatible WANT_TITLE CAND_TITLE -> rc 0 if compatible (either is a
# meaningful-word subset of the other; handles subtitle-present/absent both ways).
# Mirrors the bidirectional check fetch-books uses for its md5 guard so the audit
# agrees with what fetch-books would call contaminated.
titles_compatible() {
    local A B amw bmw w hayB hayA okA=1 okB=1
    A="$(norm "$1")"; B="$(norm "$2")"
    [ "$A" = "$B" ] && return 0
    hayB=" $B "; hayA=" $A "
    amw=0
    for w in $A; do
        case "$TITLE_STOPWORDS" in *" $w "*) continue;; esac
        [ "${#w}" -lt 3 ] && continue
        amw=$((amw+1)); case "$hayB" in *" $w "*) ;; *) okA=0;; esac
    done
    bmw=0
    for w in $B; do
        case "$TITLE_STOPWORDS" in *" $w "*) continue;; esac
        [ "${#w}" -lt 3 ] && continue
        bmw=$((bmw+1)); case "$hayA" in *" $w "*) ;; *) okB=0;; esac
    done
    # compatible if all of A's words are in B (A subset of B) OR vice versa
    { [ "$amw" -gt 0 ] && [ "$okA" -eq 1 ]; } && return 0
    { [ "$bmw" -gt 0 ] && [ "$okB" -eq 1 ]; } && return 0
    return 1
}

# id_for_md5 MD5 -> echoes the calibre id carrying annas:<md5>, or nothing.
# HARDENED: returns ONLY a bare integer id. calibredb can emit a lock warning
# ("Another calibre program is running") or, on a zero-result, "No books
# matching..." on stderr which cdb now propagates (v5); without this guard that
# text could land in the caller's $sid and make [ -n "$sid" ] true on garbage,
# firing spurious B-DISAGREE flags. We force-discard stderr here (a stamp lookup
# genuinely has nothing to say on stderr) and keep only the first all-digit token.
id_for_md5() {
    local md5="$1" raw
    [ -z "$md5" ] && return 0
    raw="$(cdb search "identifiers:${ID_SCHEME}:${md5}" 2>/dev/null | tr ',' ' ')"
    set -- $raw
    case "${1:-}" in
        ''|*[!0-9]*) return 0 ;;   # nothing, or not a pure integer -> no stamp
        *) printf '%s' "$1" ;;
    esac
}

# title_of ID -> candidate title (field-1 of _cand_fields), or nothing
title_of() {
    local id="$1" fields
    fields="$(_cand_fields "$id")"
    printf '%s' "${fields%%$'\t'*}"
}

# tags_of ID -> comma-joined tags (lowercased), or nothing
tags_of() {
    local id="$1"
    cdb list -f tags -s "id:$id" --for-machine | python3 -c '
import sys, json
try:
    d=json.load(sys.stdin); t=d[0].get("tags",[]) if d else []
    print(",".join(x.lower() for x in t))
except Exception:
    pass'
}

n_rows=0 n_tagged=0 n_ok=0
n_stamp_mismatch=0 n_disagree=0 n_tag_missing=0 n_unresolved=0
FLAGS=()

process_file() {
    local file="$1"
    [ -f "$file" ] || { echo "skip (not found): $file" >&2; return; }
    local list_tag="" base; base="$(basename "$file")"

    while IFS= read -r raw || [ -n "$raw" ]; do
        # capture the list's header tag (first #tag: line)
        case "$raw" in
            \#tag:*|\#tag\ *)
                [ -z "$list_tag" ] && list_tag="$(printf '%s' "$raw" \
                    | sed 's/^#tag:[[:space:]]*//; s/^#tag[[:space:]]*//; s/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
                continue ;;
        esac
        case "$raw" in ''|\#*) continue;; esac

        local f1 f2 status md5
        f1="$(printf '%s' "$raw" | cut -d'|' -f1 | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"  # list-title
        f2="$(printf '%s' "$raw" | cut -d'|' -f2 | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"  # list-author
        status="$(printf '%s' "$raw" | cut -d'|' -f3 | tr -d ' ')"
        md5="$(printf '%s' "$raw" | cut -d'|' -f4 | tr -d ' ')"

        n_rows=$((n_rows+1))
        [ "$status" = "tagged" ] || continue
        n_tagged=$((n_tagged+1))

        # --- resolve the row with the v5 matcher (authoritative "right" id) ---
        # v5's find_book_id propagates calibredb stderr (by design: a real lock/
        # traceback must be visible). For the AUDIT that stderr is just expected
        # zero-result chatter on the author-field probe ("No books matching...")
        # plus the occasional GUI-lock warning; route it to a logfile so the
        # console shows only verdicts. The logfile is there if a run looks wrong.
        local resolved rid="" rvia=""
        resolved="$(find_book_id "$f1" "$f2" "" 2>>"$AUDIT_STDERR_LOG")"   # force fuzzy
        if [ -n "$resolved" ]; then
            rid="$(printf '%s' "$resolved" | cut -f1)"
            case "$rid" in *[!0-9]*) rid="";; esac   # only trust a numeric id
        fi

        # --- where does the stamped md5 currently point? ---
        local sid=""
        [ -n "$md5" ] && sid="$(id_for_md5 "$md5")"
        case "$sid" in ''|*[!0-9]*) sid="";; esac   # only a bare int counts as a stamp

        # ---------- CHECK A: stamp on an incompatible-title book ----------
        if [ -n "$sid" ]; then
            local stitle; stitle="$(title_of "$sid")"
            if [ -n "$stitle" ] && ! titles_compatible "$f1" "$stitle"; then
                FLAGS+=("A STAMP-MISMATCH | $base | row='$f1 / $f2' | annas:$md5 -> id $sid '$stitle' (title incompatible)")
                n_stamp_mismatch=$((n_stamp_mismatch+1))
                continue
            fi
        fi

        # ---------- CHECK B: matcher disagrees with the stamp ----------
        # Both ids present AND numeric (sid was cleaned before A, rid above). This
        # is what stops the spurious storm of B flags when there is simply no md5
        # stamp on the row (empty sid) — no stamp means nothing to disagree with.
        if [ -n "$sid" ] && [ -n "$rid" ] && [ "$sid" != "$rid" ]; then
            local rtitle; rtitle="$(title_of "$rid")"
            FLAGS+=("B DISAGREE      | $base | row='$f1 / $f2' | stamp->id $sid, v5-match->id $rid '$rtitle'")
            n_disagree=$((n_disagree+1))
            continue
        fi

        # the effective id we believe is correct: stamp if present & passed A, else v5 match
        local eid="${sid:-$rid}"

        # ---------- CHECK D: unresolvable ----------
        if [ -z "$eid" ]; then
            FLAGS+=("D UNRESOLVED    | $base | row='$f1 / $f2' | 'tagged' but no md5 stamp and v5 matcher finds nothing")
            n_unresolved=$((n_unresolved+1))
            continue
        fi

        # ---------- CHECK C: list tag actually present on the book ----------
        if [ -n "$list_tag" ]; then
            local have miss=0 t
            have="$(tags_of "$eid")"
            local IFSsave="$IFS"; IFS=','
            for t in $list_tag; do
                t="$(printf '%s' "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
                [ -z "$t" ] && continue
                case ",$have," in *",$t,"*) ;; *) miss=1;; esac
            done
            IFS="$IFSsave"
            if [ "$miss" -eq 1 ]; then
                FLAGS+=("C TAG-MISSING   | $base | row='$f1 / $f2' | id $eid lacks list tag(s) '$list_tag' (have: ${have:-none})")
                n_tag_missing=$((n_tag_missing+1))
                continue
            fi
        fi

        n_ok=$((n_ok+1))
        [ "$VERBOSE" -eq 1 ] && echo "OK              | $base | row='$f1 / $f2' | id $eid"
    done < "$file"
}

echo "=== audit-tags v$AUDIT_TAGS_VERSION start (files=${#FILES[@]} confidence=$CONFIDENCE) ==="
for f in "${FILES[@]}"; do process_file "$f"; done

echo
echo "------ FLAGGED ROWS (${#FLAGS[@]}) ------"
if [ "${#FLAGS[@]}" -eq 0 ]; then
    echo "(none — every tagged row resolves cleanly under the v5 matcher)"
else
    printf '%s\n' "${FLAGS[@]}" | sort
fi
echo
echo "------ SUMMARY ------"
echo "rows scanned     : $n_rows"
echo "tagged rows      : $n_tagged"
echo "  clean (OK)     : $n_ok"
echo "  A stamp-mismatch (md5 on wrong-title book) : $n_stamp_mismatch"
echo "  B disagree (stamp vs v5 matcher)           : $n_disagree"
echo "  C tag-missing (tagged but no list tag)     : $n_tag_missing"
echo "  D unresolved (tagged but unplaceable)      : $n_unresolved"
echo "=== audit-tags v$AUDIT_TAGS_VERSION done ==="
# version: AUDIT_TAGS_VERSION 2