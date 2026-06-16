#!/usr/bin/env bash
MATCH_LIB_VERSION="7"   # bump on every change (version stamp also at end of file)
# v7: SUBTITLE-TOLERANT title gate, merged ON TOP of v6's author-contradiction
#     gate (both kept). title_full_match requires every meaningful word of the
#     WANTED title in the candidate; a subtitle on the WANTED side (curated lists
#     carry full titles like "Romeo and/or Juliet: A Choosable-Path Adventure"
#     while shadow-lib entries store only "Romeo and/or Juliet") sinks an
#     otherwise-perfect match. book_match_fields now retries the gate on the MAIN
#     title (pre-subtitle) when the full gate fails — but ONLY if the author also
#     matches, so it can't loosen into a prefix false positive. New helper
#     main_title splits on the first subtitle separator (colon / spaced dash).
#     ORDER MATTERS: the fallback runs AFTER v6's contradiction gate, and its own
#     author requirement means a contradicting-author exact-title (which v6
#     zeroes) can never be rescued — verified by test.
# v6: book_match_fields now rejects an exact-title match when the candidate
#     author is PRESENT and contradicts (zero author overlap) — an identical
#     title by a different author is a different book (e.g. "The Secret History"
#     by Donna Tartt vs Procopius). Absent/misspelled authors still pass via the
#     title-only floor (a missing author cannot contradict).
# =============================================================================
#  match-lib.sh — shared confidence matcher for fetch-books.sh and tag-books.sh.
#
#  Source it:   . "$(dirname "$0")/match-lib.sh"
#
#  These functions were lifted verbatim from fetch-books.sh v18 so the two
#  scripts agree on what "this candidate is the right book" means. The scoring
#  is content-agnostic: it compares a wanted string (needle) against candidate
#  text (haystack), so it works equally on Anna's result cards (fetch-books) and
#  on a calibre title+authors string (tag-books).
#
#  The exported entry point most callers want is:
#     book_match_score WANT_FIELD1 WANT_FIELD2 CANDIDATE_TEXT
#  which scores BOTH interpretations (field1=title or field2=title) and echoes
#  the better 0..1 score. A score of 0 means "not a match"; callers compare it
#  Requires bash (uses arrays in author_match_strict). Both scripts are bash and
#  source this into a bash process, so this is satisfied in normal use.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "match-lib.sh requires bash (arrays); source it from a bash script." >&2
    return 1 2>/dev/null || exit 1
fi

# normalise for matching: fold Unicode to ASCII (accents -> base letter via NFKD
# decomposition, smart quotes/dashes handled), lowercase, strip remaining
# punctuation to spaces, squeeze. The Unicode fold is the important part: without
# it "Szabó" matched neither "Szabo" nor itself cleanly. We use python's
# unicodedata (NFKD + drop combining marks) because it's locale-INDEPENDENT —
# iconv //TRANSLIT silently DROPS accented letters under the C locale (so ó
# vanished instead of becoming o). The apostrophe is deleted (not spaced) so
# "Earth's" -> "earths", matching the accentless "Earths". One python call per
# norm; negligible next to the network/calibre round-trips a match already costs.
norm() {
    printf '%s' "$1" | python3 -c '
import sys, unicodedata, re
s = sys.stdin.read()
# NFKD splits accented chars into base+combining; drop the combining marks
s = unicodedata.normalize("NFKD", s)
s = "".join(c for c in s if not unicodedata.combining(c))
s = s.lower()
# delete apostrophe-like chars (straight, curly, backtick) so "Earth\u0027s" ->
# "earths" rather than splitting into "earth s". chr() avoids quoting them here.
for ch in ("\u2019", "\u2018", chr(39), chr(96)):
    s = s.replace(ch, "")
s = re.sub(r"[^a-z0-9 ]", " ", s)      # any remaining non-ascii/punct -> space
s = re.sub(r"\s+", " ", s).strip()
print(s)
' 2>/dev/null
}

# numeric a >= b ?  (works on the "0.000".."1.000" strings these fns emit)
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# main_title: the part of a title BEFORE its first subtitle separator. Curated
# lists carry full titles with subtitles ("Romeo and/or Juliet: A Choosable-Path
# Adventure") while shadow-library entries frequently store only the main title
# ("Romeo and/or Juliet"). title_full_match requires EVERY meaningful WANTED word
# in the candidate, so the extra subtitle words sink an otherwise-perfect match.
# book_match_fields uses this to retry the gate on the main title alone — but
# ONLY when the author also matches, so it can't loosen into false positives.
# Operates on the RAW string (norm strips the colon by match time). Separators
# recognised: colon, en/em dash surrounded by spaces, " - " hyphen. Returns the
# input unchanged when no separator is present (so non-subtitled titles are
# unaffected and the caller can detect "no subtitle" by string equality).
main_title() {
    printf '%s' "$1" | python3 -c '
import sys, re
s = sys.stdin.read()
# split on the FIRST subtitle separator: colon, or a spaced dash (-, en, em).
m = re.split(r"\s*[:\u2013\u2014]\s*|\s+-\s+", s, maxsplit=1)
sys.stdout.write(m[0].strip() if m and m[0].strip() else s.strip())
' 2>/dev/null
}

# author_match: confirms the author field against candidate text, with strictness
# scaled to how many words the author has (case-insensitive, words >= 3 chars):
#   1 word    -> that word must appear
#   2-3 words -> ANY single word matches (forgiving of partial/variant names)
#   4+ words  -> at least TWO words must match
# Returns 1.000 on match, else 0.000.
author_match() {
    local want hay w; want="$(norm "$1")"; hay=" $(norm "$2") "
    local nwords=0 hits=0
    for w in $want; do
        [ "${#w}" -lt 3 ] && continue
        nwords=$((nwords+1))
        case "$hay" in *" $w "*) hits=$((hits+1));; esac
    done
    if [ "$nwords" -eq 0 ]; then
        echo "1.000"; return
    fi
    local need
    if [ "$nwords" -eq 1 ]; then need=1
    elif [ "$nwords" -le 3 ]; then need=1
    else need=2
    fi
    if [ "$hits" -ge "$need" ]; then echo "1.000"; else echo "0.000"; fi
}

# author_match_strict: used ONLY when the title is weak (<2 meaningful words),
# where the title alone can't identify the book and the author must carry it.
# Stricter than author_match: requires EVERY author word (>=3 chars) to appear,
# AND in the given order, OR as an exact adjacent reversal ("Surname, Given" =>
# "given surname" reversed). This rejects coincidental surname collisions where
# the matched word is actually a different person's FIRST name:
#   want "Abigail Dean" vs "...Dean Wesley Smith"  -> "abigail" absent -> 0.000
#   want "Abigail Dean" vs "...Abigail Dean"       -> in order        -> 1.000
#   want "Abigail Dean" vs "...Dean, Abigail"      -> exact reversal  -> 1.000
# 0/1 significant words -> fall back to author_match (can't do order on one word).
author_match_strict() {
    local want hay w; want="$(norm "$1")"; hay=" $(norm "$2") "
    # significant words only (>=3 chars), preserving order
    local sig=() ; for w in $want; do [ "${#w}" -ge 3 ] && sig+=("$w"); done
    local n="${#sig[@]}"
    # need at least two words to do an order check; otherwise defer to the
    # forgiving matcher (a lone surname is all we have).
    if [ "$n" -lt 2 ]; then author_match "$1" "$2"; return; fi
    # every word must be present at all
    for w in "${sig[@]}"; do
        case "$hay" in *" $w "*) ;; *) echo "0.000"; return;; esac
    done
    # build the in-order pattern (words in given order, any gap between) and the
    # exact-reversal pattern (words reversed, single separator between), test both.
    local fwd rev i
    fwd=""; for w in "${sig[@]}"; do fwd="${fwd}${fwd:+.*[^a-z0-9]}$w"; done
    # reversal: words in exact reverse order, adjacent (one separator between)
    rev=""; for (( i=n-1; i>=0; i-- )); do rev="${rev}${rev:+[^a-z0-9]+}${sig[$i]}"; done
    if printf '%s' "$hay" | grep -Eq "[^a-z0-9]$fwd[^a-z0-9]"; then echo "1.000"; return; fi
    if printf '%s' "$hay" | grep -Eq "[^a-z0-9]$rev[^a-z0-9]"; then echo "1.000"; return; fi
    echo "0.000"
}

TITLE_STOPWORDS=" the a an and or of in on to for with at by from is as "

# meaningful_words: count title words >=3 chars and not stopwords. A "weak" title
# (0-1 meaningful words, e.g. "Gunk") can't identify a book alone, so the author
# must also match for that interpretation.
meaningful_words() {
    local want w n=0; want="$(norm "$1")"
    for w in $want; do
        case "$TITLE_STOPWORDS" in *" $w "*) continue;; esac
        [ "${#w}" -lt 3 ] && continue
        n=$((n+1))
    done
    echo "$n"
}

# title_full_match: returns 1.0 only if EVERY meaningful title word appears in
# the candidate text (strict gate). Subtitles on the candidate side are harmless.
# If the title has no meaningful words, require the whole normalised string.
title_full_match() {
    local want hay w meaningful=0
    want="$(norm "$1")"; hay=" $(norm "$2") "
    for w in $want; do
        case "$TITLE_STOPWORDS" in *" $w "*) continue;; esac
        [ "${#w}" -lt 3 ] && continue
        meaningful=$((meaningful+1))
        case "$hay" in *" $w "*) ;; *) echo "0.000"; return;; esac
    done
    if [ "$meaningful" -eq 0 ]; then
        case "$hay" in *" $want "*) echo "1.000"; return;; *) echo "0.000"; return;; esac
    fi
    echo "1.000"
}

# book_match_score WANT1 WANT2 CANDIDATE_TEXT
# Score both interpretations (which of WANT1/WANT2 is the title) against the
# candidate text and echo the higher 0..1 score. Title gate is strict; a weak
# title (<2 meaningful words) requires the author to match too. Mirrors exactly
# the s1/s2 logic in fetch-books' search_one.
book_match_score() {
    local want1="$1" want2="$2" text="$3"
    local s1 s2 mw1 mw2 a1 a2
    mw1="$(meaningful_words "$want1")"
    mw2="$(meaningful_words "$want2")"
    # author score per interp: when THIS interp's title is weak (<2 meaningful
    # words) the title can't identify the book, so demand the stricter author
    # match (all words, in order or exact reversal). Strong title keeps the
    # forgiving any-word rule.
    if [ "$mw1" -lt 2 ]; then a1="$(author_match_strict "$want2" "$text")"
    else a1="$(author_match "$want2" "$text")"; fi
    if [ "$mw2" -lt 2 ]; then a2="$(author_match_strict "$want1" "$text")"
    else a2="$(author_match "$want1" "$text")"; fi
    # Interp 1: want1 is the title, want2 the author
    s1="$(awk -v g="$(title_full_match "$want1" "$text")" \
              -v a="$a1" \
              -v mw="$mw1" \
          'BEGIN{
             if (g+0==0) { print "0.000"; exit }
             if (mw+0 < 2 && a+0 == 0) { print "0.000"; exit }
             printf "%.3f", 0.7 + 0.3*a
           }')"
    # Interp 2: want2 is the title, want1 the author
    s2="$(awk -v g="$(title_full_match "$want2" "$text")" \
              -v a="$a2" \
              -v mw="$mw2" \
          'BEGIN{
             if (g+0==0) { print "0.000"; exit }
             if (mw+0 < 2 && a+0 == 0) { print "0.000"; exit }
             printf "%.3f", 0.7 + 0.3*a
           }')"
    if ge "$s1" "$s2"; then echo "$s1"; else echo "$s2"; fi
}

# book_match_fields WANT1 WANT2 CAND_TITLE CAND_AUTHOR
# Like book_match_score, but the candidate's title and author are already
# separated (clean structured extraction), so each wanted field is compared to
# the CORRECT candidate field — title-to-title, author-to-author. This removes
# the contamination risk of scoring against a flattened blob: a word that
# appears only in the candidate's author can no longer satisfy a title gate, and
# vice versa. Both list-interpretations are scored (WANT1=title or WANT2=title).
# CAND_AUTHOR may be empty; the weak-title author requirement then fails closed.
# For SHORT/weak titles (the dangerous case: a 1-word title like "Eragon" is a
# subset of any longer title containing that word — "Murtagh: The World of
# Eragon"), require the candidate title to actually START with the wanted title,
# and not be dominated by extra meaningful words. This rejects same-author series
# mismatches that the plain subset gate + author match would wrongly accept.
# Returns 0 = ok, 1 = reject. Only meaningful for short titles; callers gate on mw.
short_title_ok() {
    local wnorm cnorm wmw cmw
    wnorm="$(norm "$1")"; cnorm="$(norm "$2")"
    wmw="$(meaningful_words "$1")"; cmw="$(meaningful_words "$2")"
    [ "$wnorm" = "$cnorm" ] && return 0                       # exact title: fine
    case "$cnorm " in "$wnorm "*) ;; *) return 1;; esac        # must lead with it
    [ "$cmw" -le $((wmw + 3)) ]                                # not a whole other title
}

book_match_fields() {
    local want1="$1" want2="$2" ctitle="$3" cauthor="$4"
    local s1 s2 mw1 mw2 g1 g2 a1 a2
    mw1="$(meaningful_words "$want1")"
    mw2="$(meaningful_words "$want2")"
    # is there a candidate author at all? (used by the contradiction gate below)
    local cauthor_present=0
    case "$(norm "$cauthor")" in "") cauthor_present=0;; *) cauthor_present=1;; esac
    # Interp 1: want1 is the title (vs candidate title),
    #           want2 is the author (vs candidate author)
    g1="$(title_full_match "$want1" "$ctitle")"
    if [ "$mw1" -lt 2 ]; then
        a1="$(author_match_strict "$want2" "$cauthor")"
        # weak title: also require a start-anchored, length-bounded title match,
        # so "Eragon" doesn't match "Murtagh: The World of Eragon".
        short_title_ok "$want1" "$ctitle" || g1="0.000"
    else
        a1="$(author_match "$want2" "$cauthor")"
        # STRONG title, but the candidate author is PRESENT and does not match at
        # all -> the author actively contradicts (e.g. wanted "Donna Tartt" vs
        # candidate "Procopius" for an identically-titled "The Secret History").
        # Reject: an exact title alone must NOT match a different author's book.
        # (An ABSENT candidate author can't contradict, so the title-only floor
        # still stands — preserves SE misspelled-author / empty-author cases.)
        if [ "$cauthor_present" -eq 1 ] && ! ge "$a1" "0.001"; then
            g1="0.000"
        fi
    fi
    # SUBTITLE FALLBACK (v7): the gate failed (incl. via the v6 contradiction
    # zero), but the WANTED title has a subtitle the candidate lacks (curated
    # lists carry full titles; shadow-lib entries often store only the main
    # title). Retry the gate on the MAIN title (pre-subtitle), and credit it ONLY
    # if the author also matches — so a contradicting author (which v6 just
    # zeroed) can NEVER be rescued here, and a bare prefix without author support
    # stays rejected. Strong main title keeps the forgiving author rule; a weak
    # main title still demands the strict author match. Only attempted when the
    # main title differs from the full title.
    if [ "$(printf '%s' "$g1" | cut -c1)" = "0" ]; then
        local mt1; mt1="$(main_title "$want1")"
        if [ "$(norm "$mt1")" != "$(norm "$want1")" ]; then
            local gm1 am1 mmw1
            gm1="$(title_full_match "$mt1" "$ctitle")"
            mmw1="$(meaningful_words "$mt1")"
            if [ "$mmw1" -lt 2 ]; then
                am1="$(author_match_strict "$want2" "$cauthor")"
                short_title_ok "$mt1" "$ctitle" || gm1="0.000"
            else am1="$(author_match "$want2" "$cauthor")"; fi
            if [ "$(printf '%s' "$gm1" | cut -c1)" != "0" ] && ge "$am1" "0.001"; then
                g1="$gm1"; a1="$am1"
            fi
        fi
    fi
    s1="$(awk -v g="$g1" -v a="$a1" -v mw="$mw1" \
          'BEGIN{
             if (g+0==0) { print "0.000"; exit }
             if (mw+0 < 2 && a+0 == 0) { print "0.000"; exit }
             printf "%.3f", 0.7 + 0.3*a
           }')"
    # Interp 2: want2 is the title, want1 is the author
    g2="$(title_full_match "$want2" "$ctitle")"
    if [ "$mw2" -lt 2 ]; then
        a2="$(author_match_strict "$want1" "$cauthor")"
        short_title_ok "$want2" "$ctitle" || g2="0.000"
    else
        a2="$(author_match "$want1" "$cauthor")"
        if [ "$cauthor_present" -eq 1 ] && ! ge "$a2" "0.001"; then
            g2="0.000"
        fi
    fi
    # SUBTITLE FALLBACK (v7, interp 2): mirror of interp 1 with want2 as title.
    if [ "$(printf '%s' "$g2" | cut -c1)" = "0" ]; then
        local mt2; mt2="$(main_title "$want2")"
        if [ "$(norm "$mt2")" != "$(norm "$want2")" ]; then
            local gm2 am2 mmw2
            gm2="$(title_full_match "$mt2" "$ctitle")"
            mmw2="$(meaningful_words "$mt2")"
            if [ "$mmw2" -lt 2 ]; then
                am2="$(author_match_strict "$want1" "$cauthor")"
                short_title_ok "$mt2" "$ctitle" || gm2="0.000"
            else am2="$(author_match "$want1" "$cauthor")"; fi
            if [ "$(printf '%s' "$gm2" | cut -c1)" != "0" ] && ge "$am2" "0.001"; then
                g2="$gm2"; a2="$am2"
            fi
        fi
    fi
    s2="$(awk -v g="$g2" -v a="$a2" -v mw="$mw2" \
          'BEGIN{
             if (g+0==0) { print "0.000"; exit }
             if (mw+0 < 2 && a+0 == 0) { print "0.000"; exit }
             printf "%.3f", 0.7 + 0.3*a
           }')"
    if ge "$s1" "$s2"; then echo "$s1"; else echo "$s2"; fi
}

# =============================================================================
# match-lib.sh version 7  (footer stamp — must match MATCH_LIB_VERSION at top;
# if these disagree the deployed copy on otis is a stale partial paste.)
# =============================================================================