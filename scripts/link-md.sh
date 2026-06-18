#!/usr/bin/env bash
LINK_MD_VERSION="14"  # bump on every change; echoed at startup AND footer below.
# v14: FIX nnn multi-select reader. v13 read the -p selection file with
#      `mapfile -d ''` (NUL-delimited), but nnn's selection separator depends on
#      the build/config — robmorgan's writes NEWLINE-separated, so all three
#      picks arrived as ONE blob ending ".../2026.tsv" with embedded newlines,
#      failing the *.tsv glob ("selection is not a .tsv ... aborting"). Now we
#      normalise NUL -> newline and read one path per line, so both NUL- and
#      newline-separated nnn builds work.
# v13: MULTI-TSV INTO ONE REPORT + nnn multi-select + tmux title.
#      (1) MULTI-TSV: --tsv may now be passed MORE THAN ONCE, and in interactive
#          mode nnn may SELECT several .tsv files (space-mark in nnn, then Enter).
#          All selected/overridden TSVs are merged into ONE fast-path id index and
#          applied to a SINGLE markdown report. (Previously --tsv kept only the
#          last value and nnn used only the first pick.) TSV_OVERRIDE became an
#          array TSV_OVERRIDES; load_tsv is called for each. A later TSV wins on a
#          title-key collision (last load_tsv assignment stands), logged once.
#      (2) The markdown is still resolved from the FIRST selected TSV's stem (or
#          nnn-picked) — many lists feed one combined page. File-arg mode is
#          unchanged: each .md still auto-finds its own same-stem .tsv unless an
#          explicit --tsv set is given (which then applies to every .md given).
#      (3) tmux TITLE: when run inside tmux we set the window/pane title (and the
#          terminal title via OSC) to "link-md" at start and restore on exit, so a
#          tmux -CC (control-mode / iTerm integration) session shows a named tab.
#          No-op outside tmux or when not a TTY.
#      (4) COLOUR: interactive listing of the selected TSV(s) + markdown is now
#          colourised (cyan header, green paths), matching the rest of the output.
# v12: FIX log-into-capture bug introduced with v11's pick_md_for_tsv. log()
#      printed its terminal copy to STDOUT, so when pick_md_for_tsv() (which
#      calls log) was used in `local_md="$(pick_md_for_tsv ...)"`, the captured
#      value was the log spew PLUS the path — link-md then tried to open that
#      whole blob as a file ("SKIP: not a file: [..date..] no markdown ..."). Fix:
#      log() now writes its terminal line to STDERR, so command-substitution of
#      any helper only ever captures the helper's intentional stdout. Colour TTY
#      gate moved from fd1 to fd2 to match. (The shared $GUNIT_LOG write is
#      unchanged.) No behaviour change to non-capturing callers.
# v11: MD-PICKER FALLBACK. When the same-stem markdown for a selected/derived TSV
#      is MISSING in $LISTS_DIR, instead of aborting we now open nnn in $LISTS_DIR
#      so you can pick the right .md by hand (the TSV and the list file don't
#      always share a stem). Applies in BOTH places the pairing is done:
#        * interactive mode (nnn-selected TSV -> no same-stem .md): offer the
#          picker rather than the old hard "no markdown ... aborting".
#        * pick_md_for_tsv() helper: shared "derive .md, else nnn-pick from
#          $LISTS_DIR" logic. A non-.md pick / quit aborts cleanly; nnn is only
#          required to reach this fallback (a present same-stem .md still needs
#          nothing). Selecting a .md outside $LISTS_DIR is allowed (you navigate
#          freely), but it must end in .md and exist.
# v10: NUMBER-AGNOSTIC headings. Lists dropped the "NN." numbering, so headings
#      are now "#### [title](url)" / "#### title" with no leading number. Every
#      heading regex (already-linked detector, new-heading detector, relink
#      demote, heading_author block-break, title extraction) made the "NN. "
#      prefix OPTIONAL — numbered and unnumbered lists both work, and a number is
#      preserved on output if the source had one. Without this, v9 silently did
#      nothing on the unnumbered live files (matched no headings) and --relink
#      stripped covers while leaving headings unprocessed. Cover/link logs now key
#      on id rather than a (now-absent) heading number.
# v9: --relink mode. Strips ALL existing links and cover lines from the file
#     first (demotes "#### NN. [title](url)" back to "#### NN. title", removes
#     every cover image line), then runs the normal link+cover pass so everything
#     is rebuilt from scratch. Implies --force (covers re-exported). Use after the
#     library changes underneath a list — wrong/stale ids, a deleted book, a
#     replaced cover — to resync without hand-editing. Write gate is relink-aware:
#     under --relink the rebuilt file is compared to the original and written on
#     ANY difference (so a stripped-but-not-re-found link still persists), vs the
#     normal "only write if a link/cover was added".
# v8: FIX author detection. A book block can carry several "#####" lines (a mood/
#     tags line, the author, a metadata line) in any order — e.g.
#       ##### satirical · urgent · adventurous
#       ##### Percival Everett
#       ##### Fiction, 2024, 320 pages
#     heading_author() previously took the FIRST "#####" line as the author, so it
#     passed "satirical · urgent · adventurous" as the author. The library search
#     still found the title, but the author GATE in lib_find_id then rejected the
#     correct book (md "author" shared no word with the real author) — every book
#     failed identically as "NOT FOUND". heading_author now scans all "#####" lines
#     in the block and returns the first that is NEITHER a mood line ('·'-separated)
#     NOR a metadata line (4-digit year or the word 'pages'), falling back to the
#     first "#####" line if none qualify. (This was the real cause of the mass
#     NOT-FOUND run — not a library lock; the v4 tag-lib retry stays as insurance.)
# v7: INTERACTIVE MODE now uses nnn as a file picker instead of a typed search
#     string. Running ./link-md.sh with NO file args opens nnn in $TSV_DIR; you
#     navigate and SELECT a .tsv (Enter on it) — nnn writes the pick to a temp
#     file (nnn -p) and quits, and we read it back. The same-stem .md in
#     $LISTS_DIR is then paired, both paths shown, confirm to proceed. nnn is
#     REQUIRED: if it's not on PATH we hard-fail with an install hint. Selecting
#     a non-.tsv, or quitting without a pick, aborts cleanly. (typed-search
#     resolver from v6 retired.)
# v6: INTERACTIVE MODE. Running ./link-md.sh with NO file args now prompts for a
#     search string, finds a TSV in $TSV_DIR (default ../tsv-lists) whose filename
#     contains that string (case-insensitive), derives the matching markdown in
#     $LISTS_DIR (default /home/robmorgan/gunit/web/lists) by stem, presents both
#     paths, and asks to proceed before processing. Multiple TSV matches are
#     listed for a numeric pick; a missing .md aborts. New env: TSV_DIR, LISTS_DIR.
#     All other flags (--dry-run, --no-covers, etc.) still apply in this mode.
# v5: MERGED cover-md into link-md (covers ON by default). After a heading is
#     linked (or is already linked), its Calibre cover is exported to
#     <md-dir>/covers/<id>.jpg and a thumbnail line is inserted beneath the
#     heading:  [![](covers/<id>.jpg)](<book-url>). New flags: --no-covers,
#     --covers-only, --force (re-export covers even if present). The old
#     line-count guard is retired (we now legitimately ADD lines); the write is
#     gated on "something changed" instead, trailing-newline handling kept. The
#     parse loop now reads the whole file (mapfile) so it can look one line ahead
#     for an existing cover line (idempotency). cover-md.sh is retired.
# v4: TWO fixes from a real run. (1) FALSE POSITIVES: replaced tag-lib's
#     find_book_id fuzzy fallback (scored a flattened "title author" blob, so a
#     shared author rescued a wrong title — "Down Among the Sticks and Bones"
#     wrongly matched "Middlegame", same author) with a strict in-script
#     lib_find_id: scores title-vs-title and author-vs-author SEPARATELY
#     (book_match_fields) and gates on a real author match. (2) ABORT-WITHOUT-
#     WRITE: a source .md whose last line lacked a trailing newline gained one in
#     the rewrite, tripping the line-count guard. Now we match the source's
#     trailing-newline state before the guard, so it only fires on real line
#     add/drop. 'via' tag for library hits is now [lib] (was [fuzzy]).
# v3: colourised terminal output (green=linked, yellow=not-found, cyan=summary,
#     red=fatal/abort, bold=start/done). Colour goes to the TERMINAL ONLY — the
#     shared gunit log stays plain. Auto-disabled when stdout isn't a TTY or
#     NO_COLOR is set. Added version footer at end of file (deploy-staleness check).
# v2: norm() takes its string as $1 (arg), not stdin — call sites were piping
#     into it, which under set -u spammed "match-lib.sh: $1: unbound variable"
#     on every book (non-fatal but noisy). Also guard the TSV fast-path lookup
#     against an empty normalised title ("bad array subscript" under set -u).
# =============================================================================
#  link-md.sh — turn book headings in a markdown list into Calibre-Web links,
#               and add the book's cover thumbnail beneath each (covers ON by
#               default; --no-covers to skip).
#
#  For every book heading of the form
#       #### NN. <title>
#  (followed by an author line "##### <author> | tags..."), this finds the
#  matching book in the Calibre library and rewrites the heading as a markdown
#  link to its Calibre-Web page, then inserts a linked cover thumbnail under it:
#       #### NN. [<title>](https://books.rob.me.uk/book/<id>)
#       [![](covers/<id>.jpg)](https://books.rob.me.uk/book/<id>)
#       ##### <author> | tags...
#
#  HOW A BOOK IS RESOLVED TO A CALIBRE ID (in order):
#    1. TSV FAST PATH (optional): if a companion .tsv is given/found and a row
#       whose title matches carries a 6th-column calibre id, use it directly —
#       no library query. (fetch-books v47+ writes that id.)
#    2. LIBRARY LOOKUP: otherwise a STRICT in-script matcher (lib_find_id) scores
#       title-vs-title and author-vs-author SEPARATELY (book_match_fields from
#       match-lib.sh) and gates on a real author match — so a same-author wrong
#       title is rejected. Works for EVERY book actually in the library, whether
#       or not fetch-books ever recorded its id.
#
#  COVERS: once a heading has an id (newly linked OR already linked), the book's
#  cover is exported from Calibre to <md-dir>/covers/<id>.jpg (calibredb gives
#  the in-container cover path; we docker-cp the original jpg out, no re-encode)
#  and a thumbnail line is inserted beneath the heading. Books with no cover in
#  Calibre are reported and skipped. Existing images are reused unless --force.
#
#  IDEMPOTENT: a heading already in [title](url) form keeps its link; a heading
#  already followed by its covers/<id> line keeps it. Re-runs only add what's
#  missing. A book not found in the library is left as plain text and reported.
#
#  SAFE: never edits in place until the whole file is rewritten to a temp; writes
#  a .bak alongside. The file is only written if something actually changed.
#  --dry-run shows the diff and writes nothing. A hard library lock just yields
#  no match / no cover — those books wait for the next run.
#
#  USAGE:
#     ./link-md.sh booker.md
#     ./link-md.sh --dry-run booker.md
#     ./link-md.sh --no-covers booker.md          # links only, no thumbnails
#     ./link-md.sh --covers-only booker.md        # covers only (skip linking)
#     ./link-md.sh --force booker.md              # re-export covers even if present
#     ./link-md.sh --relink booker.md             # strip ALL links+covers, rebuild fresh
#     ./link-md.sh --tsv booker.tsv booker.md     # use this TSV for the fast path
#     ./link-md.sh --tsv a.tsv --tsv b.tsv combined.md   # merge several TSVs
#                                                  #   into one report's fast path
#     ./link-md.sh *.md                           # several files; each finds its
#                                                  #   own <name>.tsv automatically
#  Env:
#     BOOK_BASE_URL  (default https://books.rob.me.uk/book)  link prefix
#     CALIBRE_CONTAINER (default calibre)  docker container running calibredb
#     CALIBRE_LIBRARY   (default /books/Calibre)  library path inside container
#     CONFIDENCE        (default 0.6)  fuzzy library match must score >= this
#     COVER_DIR_NAME    (default covers)  sub-dir (next to the md) for images
#     COVER_EXT         (default jpg)  cover filename extension
#     GUNIT_LOG         (default ~/logs/gunit.log)  shared log; lines tagged [lm]
# =============================================================================
set -uo pipefail

BOOK_BASE_URL="${BOOK_BASE_URL:-https://books.rob.me.uk/book}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CONFIDENCE="${CONFIDENCE:-0.6}"
ID_SCHEME="${ID_SCHEME:-annas}"
COVER_DIR_NAME="${COVER_DIR_NAME:-covers}"
COVER_EXT="${COVER_EXT:-jpg}"
GUNIT_LOG="${GUNIT_LOG:-$HOME/logs/gunit.log}"
TSV_DIR="${TSV_DIR:-../tsv-lists}"
LISTS_DIR="${LISTS_DIR:-/home/robmorgan/gunit/web/lists}"

DRY_RUN=0
TSV_OVERRIDES=()   # --tsv may be given more than once; all merged into one index
COVERS=1          # covers on by default
DO_LINK=1         # linking on by default
FORCE=0           # re-export covers even if the image already exists
RELINK=0          # strip all links+covers first, then rebuild from scratch
FILES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --tsv) TSV_OVERRIDES+=("${2:-}"); shift ;;
        --no-covers) COVERS=0 ;;
        --covers-only) DO_LINK=0; COVERS=1 ;;
        --force) FORCE=1 ;;
        --relink) RELINK=1; FORCE=1 ;;   # reset everything, then re-link + re-pull covers
        -h|--help) sed -n '2,76p' "$0"; exit 0 ;;
        --) shift; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done; break ;;
        -*) echo "unknown arg: $1" >&2; exit 1 ;;
        *) FILES+=("$1") ;;
    esac
    shift
done
[ "${#FILES[@]}" -eq 0 ] && INTERACTIVE=1 || INTERACTIVE=0

# --- logging: terminal + shared gunit log, tagged [lm] -----------------------
mkdir -p "$(dirname "$GUNIT_LOG")" 2>/dev/null
# --- colour (terminal only) --------------------------------------------------
# Colour is applied to the TERMINAL line only, never to $GUNIT_LOG (escape codes
# in a shared logfile break greps and look like junk). Disabled automatically
# when stderr isn't a TTY (piped/redirected) or when NO_COLOR is set. (log writes
# its terminal copy to stderr, so the TTY test is on fd 2.)
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''
fi

# --- tmux / terminal window title --------------------------------------------
# Set a window title at start, restore (best-effort) on exit. Inside tmux we
# rename the window (works in tmux -CC control mode / iTerm integration, which
# surfaces it as a tab name) and, if the window was set to automatic-rename,
# turn that off for our run so tmux doesn't immediately overwrite our title.
# We also emit the standard OSC-0 terminal-title escape so a plain terminal tab
# is named too. All of this is a no-op when not on a TTY.
_TITLE_SET=0
_TMUX_RENAMED=0
set_window_title() {
    local t="$1"
    [ -t 2 ] || return 0
    # OSC 0: set icon name + window title (most terminals + tmux passthrough)
    printf '\033]0;%s\007' "$t" >&2
    if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux rename-window "$t" 2>/dev/null && _TMUX_RENAMED=1
        # stop tmux auto-renaming over us for the duration of this window
        tmux set-window-option automatic-rename off 2>/dev/null || true
    fi
    _TITLE_SET=1
}
restore_window_title() {
    [ "$_TITLE_SET" -eq 1 ] || return 0
    if [ "$_TMUX_RENAMED" -eq 1 ] && command -v tmux >/dev/null 2>&1; then
        # hand the window name back to tmux's automatic rename
        tmux set-window-option automatic-rename on 2>/dev/null || true
    fi
    # clear the OSC title
    printf '\033]0;%s\007' "" >&2
}
trap restore_window_title EXIT
set_window_title "link-md"

# log MESSAGE [COLOUR]
# COLOUR (optional) is an escape sequence applied to the terminal copy only.
log() {
    local msg="$1" colour="${2:-}"
    local stamp; stamp="[$(date '+%F %T')] [lm]"
    # terminal (stderr, so $(...) captures of helpers never swallow log lines):
    # timestamp dimmed, message in the requested colour
    printf '%s %s%s%s\n' "${C_DIM}${stamp}${C_RESET}" "$colour" "$msg" "${C_RESET:+$C_RESET}" >&2
    # logfile: plain, no colour
    echo "$stamp $msg" >> "$GUNIT_LOG" 2>/dev/null || true
}

# --- shared matcher + library helpers ----------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
# match-lib.sh: norm, ge, author_match(_strict), title_full_match,
#               meaningful_words, short_title_ok, book_match_fields/score
# tag-lib.sh:   cdb (reads as root → shares GUI lock), find_book_id f1 f2 md5
#               → echoes "<id>\t<via>" or nothing
if [ ! -f "$HERE/match-lib.sh" ] || [ ! -f "$HERE/tag-lib.sh" ]; then
    log "FATAL: match-lib.sh / tag-lib.sh must sit next to this script ($HERE)" "$C_RED"
    exit 1
fi
# export config find_book_id reads, then source the libs
export CALIBRE_CONTAINER CALIBRE_LIBRARY CONFIDENCE ID_SCHEME
. "$HERE/match-lib.sh"
. "$HERE/tag-lib.sh"

command -v python3 >/dev/null || { log "FATAL: python3 not installed" "$C_RED"; exit 1; }
if [ "$COVERS" -eq 1 ]; then
    command -v docker >/dev/null || { log "FATAL: docker not found (need it for covers; use --no-covers to skip)" "$C_RED"; exit 1; }
fi

# -----------------------------------------------------------------------------
# nnn_pick_md  ->  echoes a chosen .md path (in/under $LISTS_DIR), or nothing.
# Opens nnn at $LISTS_DIR so you can hand-pick the markdown when the stem-derived
# one is missing. The pick must end in .md and exist; a non-.md pick or a quit
# yields nothing (caller treats that as abort). nnn is required to reach here.
# -----------------------------------------------------------------------------
nnn_pick_md() {
    command -v nnn >/dev/null || {
        log "FATAL: nnn not installed (needed to pick a markdown). Install: sudo apt install nnn" "$C_RED"
        return 1
    }
    [ -d "$LISTS_DIR" ] || { log "FATAL: lists dir not found: $LISTS_DIR" "$C_RED"; return 1; }
    local pf; pf="$(mktemp)"
    log "no same-stem markdown — pick one from $LISTS_DIR (Enter to select, q to cancel)" "$C_YELLOW"
    nnn -p "$pf" "$LISTS_DIR" </dev/tty >/dev/tty 2>&1
    local pick; pick="$(tr '\0' '\n' < "$pf" 2>/dev/null | head -n1)"
    rm -f "$pf"
    [ -z "$pick" ] && return 1
    case "$pick" in *.md) : ;; *) log "selection is not a .md: $pick" "$C_YELLOW"; return 1 ;; esac
    [ -f "$pick" ] || { log "selected markdown does not exist: $pick" "$C_RED"; return 1; }
    printf '%s\n' "$pick"
}

# -----------------------------------------------------------------------------
# pick_md_for_tsv TSV  ->  echoes the markdown path to use for this TSV.
# Derives <same-stem>.md in $LISTS_DIR; if it exists, uses it. If not, falls back
# to nnn_pick_md so the user chooses the list file by hand. Echoes nothing (and
# returns 1) if no usable markdown was chosen.
# -----------------------------------------------------------------------------
pick_md_for_tsv() {
    local tsv="$1" stem md
    stem="$(basename "$tsv")"; stem="${stem%.tsv}"
    md="$LISTS_DIR/$stem.md"
    if [ -f "$md" ]; then printf '%s\n' "$md"; return 0; fi
    log "no markdown at $md — falling back to nnn picker" "$C_YELLOW"
    nnn_pick_md
}

# -----------------------------------------------------------------------------
# INTERACTIVE MODE (no file args): open nnn in $TSV_DIR as a file picker. You
# select a .tsv (Enter on it); nnn writes the pick to a temp file (nnn -p) and
# quits. We pair it with the same-stem markdown in $LISTS_DIR (or, if that's
# missing, an nnn-picked .md), show both, and confirm before processing. nnn is
# REQUIRED in this mode.
# -----------------------------------------------------------------------------
if [ "$INTERACTIVE" -eq 1 ]; then
    command -v nnn >/dev/null || {
        log "FATAL: nnn not installed. Install it on otis:  sudo apt install nnn" "$C_RED"
        exit 1
    }
    # resolve TSV_DIR relative to the script dir if it's a relative path
    case "$TSV_DIR" in /*) tsvdir="$TSV_DIR" ;; *) tsvdir="$HERE/$TSV_DIR" ;; esac
    [ -d "$tsvdir" ] || { log "FATAL: TSV dir not found: $tsvdir" "$C_RED"; exit 1; }

    pickfile="$(mktemp)"
    # -p <file>: write selection(s) here and quit; open nnn at the TSV dir.
    # Space-mark several .tsv files in nnn then Enter to select them all.
    # (A single Enter on one file works too.)
    nnn -p "$pickfile" "$tsvdir"

    # read ALL picks. nnn's selection separator varies by build/config: some
    # write NUL-separated, some newline-separated. Normalise NUL -> newline,
    # then read one path per line so both layouts work.
    _picks=()
    while IFS= read -r _p; do
        [ -n "$_p" ] && _picks+=("$_p")
    done < <(tr '\0' '\n' < "$pickfile" 2>/dev/null)
    rm -f "$pickfile"

    # validate every pick is an existing .tsv; collect into sel_tsvs
    sel_tsvs=()
    for p in "${_picks[@]}"; do
        [ -z "$p" ] && continue
        case "$p" in
            *.tsv) : ;;
            *) log "selection is not a .tsv (skipped): $p" "$C_YELLOW"; continue ;;
        esac
        [ -f "$p" ] || { log "selected file does not exist (skipped): $p" "$C_YELLOW"; continue; }
        sel_tsvs+=("$p")
    done
    [ "${#sel_tsvs[@]}" -eq 0 ] && { log "no usable .tsv selected — aborting" "$C_YELLOW"; exit 0; }

    # derive the markdown from the FIRST selected TSV's stem; if missing, nnn-pick.
    # All selected TSVs feed this one report.
    local_md="$(pick_md_for_tsv "${sel_tsvs[0]}")" \
        || { log "no markdown chosen — aborting" "$C_YELLOW"; exit 1; }

    printf '%s\n' "${C_CYAN}Found:${C_RESET}" >&2
    if [ "${#sel_tsvs[@]}" -eq 1 ]; then
        printf '  TSV:      %s%s%s\n' "$C_GREEN" "${sel_tsvs[0]}" "$C_RESET" >&2
    else
        printf '  TSVs (%d, merged into one report):\n' "${#sel_tsvs[@]}" >&2
        for t in "${sel_tsvs[@]}"; do
            printf '            %s%s%s\n' "$C_GREEN" "$t" "$C_RESET" >&2
        done
    fi
    printf '  Markdown: %s%s%s %s(exists)%s\n' "$C_GREEN" "$local_md" "$C_RESET" "$C_DIM" "$C_RESET" >&2

    printf 'Proceed? [y/N] ' >&2
    read -r yn
    case "$yn" in
        y|Y|yes|YES) : ;;
        *) log "aborted by user" "$C_YELLOW"; exit 0 ;;
    esac

    TSV_OVERRIDES=("${sel_tsvs[@]}")
    FILES=( "$local_md" )
fi

# -----------------------------------------------------------------------------
# lib_find_id TITLE AUTHOR  ->  echoes a calibre book id, or nothing.
#
# Strict library resolver for the md linker. Unlike tag-lib's find_book_id (which
# scores a FLATTENED "title author" blob and so let a shared author rescue a wrong
# title), this:
#   * searches calibre by TITLE only (the md gives us a clean title),
#   * pulls each candidate's title and author as SEPARATE fields,
#   * scores with book_match_fields (title-vs-title, author-vs-author), and
#   * requires the winning candidate's AUTHOR to actually match the md author
#     (when we have one) — so a same-author, different-title book is rejected.
# Returns the single best id at/above CONFIDENCE, else nothing. Reads via `cdb`
# (root, shares the GUI lock); a hard lock just yields no candidates -> no match.
# -----------------------------------------------------------------------------
lib_find_id() {
    local title="$1" author="$2"
    [ -z "$title" ] && return 1

    # candidate ids: exact-ish title search first, then a looser bare search.
    local ids hit
    hit="$(cdb search "title:\"$title\"" 2>/dev/null | tr ',' ' ')"
    [ -z "$hit" ] && hit="$(cdb search "title:\"$title\"" 2>/dev/null | tr ',' ' ')"
    ids="$(printf '%s\n' $hit | awk 'NF && /^[0-9]+$/ && !seen[$0]++')"
    [ -z "$ids" ] && return 1

    local id best_id="" best_score="0.000" ctitle cauthor s
    local best_ctitle="" best_cauthor=""
    for id in $ids; do
        # structured fields: title and author kept SEPARATE (no blob).
        local row
        row="$(cdb list -f title,authors -s "id:$id" --for-machine 2>/dev/null \
            | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); b = d[0] if d else {}
    a = b.get("authors",""); a = " & ".join(a) if isinstance(a,list) else a
    # tab-separate so the shell can split title from author cleanly
    sys.stdout.write((b.get("title","") or "") + "\t" + (a or ""))
except Exception: pass' 2>/dev/null)"
        ctitle="${row%%$'\t'*}"
        cauthor="${row#*$'\t'}"; [ "$cauthor" = "$row" ] && cauthor=""
        [ -z "$ctitle" ] && continue

        # title-vs-title, author-vs-author (no cross-contamination)
        s="$(book_match_fields "$title" "$author" "$ctitle" "$cauthor")"
        if ge "$s" "$best_score"; then best_score="$s"; best_id="$id"
            best_ctitle="$ctitle"; best_cauthor="$cauthor"; fi
    done

    [ -z "$best_id" ] && return 1
    ge "$best_score" "$CONFIDENCE" || return 1

    # AUTHOR GATE: if the md gave us an author, the winning candidate must share
    # at least one meaningful author word. This is the backstop against a strong
    # title-coincidence on the wrong edition/book. Skipped only when we have no
    # md author at all (then the title score alone decides).
    if [ -n "$author" ] && [ -n "${best_cauthor:-}" ]; then
        local am
        am="$(author_match "$author" "$best_cauthor")"
        [ "${am:-0}" = "0" ] && return 1
    fi
    printf '%s\n' "$best_id"
}

# -----------------------------------------------------------------------------
# ensure_cover ID DESTDIR  -> 0 if covers/<id>.<ext> exists (now), 1 otherwise.
# Reads the book's in-container cover path from calibredb, then docker-cp's the
# original jpg out to the host. Reuses an existing image unless --force. A book
# with no cover recorded in Calibre returns 1 (caller leaves heading coverless).
# -----------------------------------------------------------------------------
ensure_cover() {
    local id="$1" destdir="$2"
    local dest="$destdir/$id.$COVER_EXT"
    if [ "$FORCE" -eq 0 ] && [ -s "$dest" ]; then
        return 0
    fi
    local cpath
    cpath="$(cdb list -f cover -s "id:$id" --for-machine 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); b = d[0] if d else {}
    sys.stdout.write(b.get("cover","") or "")
except Exception: pass' 2>/dev/null)"
    [ -z "$cpath" ] && return 1
    mkdir -p "$destdir"
    if docker cp "$CALIBRE_CONTAINER:$cpath" "$dest" >/dev/null 2>&1 && [ -s "$dest" ]; then
        return 0
    fi
    rm -f "$dest" 2>/dev/null
    return 1
}

log "=== link-md v$LINK_MD_VERSION start (files=${#FILES[@]} dry-run=$DRY_RUN covers=$COVERS link=$DO_LINK force=$FORCE base=$BOOK_BASE_URL) ===" "$C_BOLD"

# -----------------------------------------------------------------------------
# TSV fast-path index. Builds an associative array: normalised-title -> id, for
# rows that carry a 6th-column calibre id. Title is column 1; norm() collapses
# case/punctuation so "The Gilded Razor: A Memoir" keys identically to the md.
# -----------------------------------------------------------------------------
declare -A TSV_ID
load_tsv() {
    local tsv="$1"
    [ -f "$tsv" ] || return 1
    local raw t bid key
    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw%$'\r'}"
        [ -z "$raw" ] && continue
        # Title|Author|status|md5|date|bookid  — we only need title (1) + id (6)
        t="$(printf '%s' "$raw" | cut -d'|' -f1)"
        bid="$(printf '%s' "$raw" | cut -d'|' -f6 | tr -d '[:space:]')"
        [ -z "$t" ] && continue
        case "$bid" in ''|*[!0-9]*) continue;; esac   # need a numeric id
        key="$(norm "$t")"
        [ -n "$key" ] && TSV_ID["$key"]="$bid"
    done < "$tsv"
    return 0
}

# -----------------------------------------------------------------------------
# Per-file processing. We rewrite line by line. State machine: when we see a
# heading "#### NN. <title>", we remember it; the FIRST following "##### ..."
# line gives the author (text before the first '|'). With title+author known we
# resolve an id and rewrite the stored heading line into the output.
#
# Because the author arrives on a LATER line than the title, we buffer the
# heading and flush it once the author is known (or when the next book heading /
# EOF arrives without an author line — then we resolve title-only).
# -----------------------------------------------------------------------------
process_file() {
    local md="$1"
    [ -f "$md" ] || { log "SKIP: not a file: $md" "$C_YELLOW"; return; }

    # pick the TSV(s): explicit --tsv override(s) (one or more), else the
    # <same-stem>.tsv next to the md. Multiple overrides all merge into TSV_ID;
    # a later TSV wins a title-key collision (last load_tsv assignment stands).
    declare -gA TSV_ID; TSV_ID=()
    local -a tsvs=()
    if [ "${#TSV_OVERRIDES[@]}" -gt 0 ]; then
        tsvs=("${TSV_OVERRIDES[@]}")
    else
        tsvs=("${md%.md}.tsv")
    fi
    if [ "$DO_LINK" -eq 1 ]; then
        local _t _loaded=0
        for _t in "${tsvs[@]}"; do
            if load_tsv "$_t"; then
                log "$md: loaded ids from $(basename "$_t") (fast path)"
                _loaded=1
            else
                log "$md: no/empty TSV ($_t) — those titles resolve via library"
            fi
        done
        if [ "$_loaded" -eq 1 ]; then
            log "$md: fast-path index now holds ${#TSV_ID[@]} id(s) from ${#tsvs[@]} TSV(s)" "$C_CYAN"
        else
            log "$md: no usable TSV — resolving all via library"
        fi
    fi

    local mddir destdir
    mddir="$(cd "$(dirname "$md")" && pwd)"
    destdir="$mddir/$COVER_DIR_NAME"

    local tmp; tmp="$(mktemp)"
    local n_link=0 n_have=0 n_miss=0 n_fast=0
    local n_cover=0 n_cover_have=0 n_cover_no=0

    # Whole file in memory so we can look one line ahead (for an existing cover
    # line) and forward-scan for a heading's author.
    mapfile -t LINES < "$md"
    local total="${#LINES[@]}" i=0

    # --relink: RESET the file to its unlinked state IN MEMORY before the normal
    # pass runs, so everything is rebuilt from scratch. Two transforms:
    #   * demote a linked heading "#### NN. [title](url)" back to "#### NN. title"
    #   * drop any cover line entirely (a markdown image-link: starts with "[![")
    # The subsequent link+cover pass then re-resolves every id fresh and (because
    # --relink implies --force) re-exports every cover. This fixes a file whose
    # links/covers have drifted (wrong id, deleted book, stale cover) without
    # hand-editing — at the cost of re-querying Calibre for every book.
    if [ "$RELINK" -eq 1 ]; then
        local -a RESET=(); local rl rstripped n_reset=0 n_dropcover=0
        for rl in "${LINES[@]}"; do
            # drop COVER lines only — a markdown image whose src points at the
            # covers dir: ![](covers/..) or [![](covers/..)](url), and the absolute
            # /covers/.. form. We must NOT strip other images (e.g. a /screenshots/
            # illustration line in a list), so we key on the covers path, not just
            # on "is an image".
            if [[ "$rl" =~ ^[[:space:]]*\[?!\[[^]]*\]\((/?${COVER_DIR_NAME}/|/covers/) ]]; then
                n_dropcover=$((n_dropcover+1)); continue
            fi
            # demote linked heading -> plain heading. The "NN. " number prefix is
            # OPTIONAL (lists may be numbered "#### 95. [t](u)" or unnumbered
            # "#### [t](u)"); we keep whatever prefix was there.
            if [[ "$rl" =~ ^(####\ ([0-9]+\.\ )?)\[(.*)\]\(https?://[^\)]*/book/[0-9]+\)[[:space:]]*$ ]]; then
                rstripped="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
                RESET+=("$rstripped"); n_reset=$((n_reset+1)); continue
            fi
            RESET+=("$rl")
        done
        LINES=("${RESET[@]}")
        total="${#LINES[@]}"
        log "$md: --relink reset ($n_reset link(s) stripped, $n_dropcover cover line(s) removed)" "$C_CYAN"
    fi

    # find the author line for a heading at index $1. A book block may carry
    # SEVERAL "##### ..." lines — e.g. a mood/tags line, the author, and a
    # metadata line, in any order:
    #     ##### satirical · urgent · adventurous     (mood: '·'-separated)
    #     ##### Percival Everett                      (author: a plain name)
    #     ##### Fiction, 2024, 320 pages              (metadata: year / 'pages')
    # We can't assume the author is first. Instead we scan every "#####" line in
    # the block (until the next "#### " heading) and return the FIRST that is
    # NOT obviously a mood or metadata line:
    #   * mood line   — contains the '·' middle-dot separator (U+00B7)
    #   * metadata    — contains a 4-digit year (19xx/20xx) OR the word 'pages'
    # The first survivor is taken as the author (text before any '|' kept, as
    # before). If nothing survives the filter, fall back to the first "#####"
    # line so a file whose author genuinely is first still works. A block with a
    # single "#####" line (author only) is returned directly.
    heading_author() {
        local j=$(( $1 + 1 ))
        local first_hash="" cleaned
        while [ "$j" -lt "$total" ]; do
            local l="${LINES[$j]}"
            [[ "$l" =~ ^####\ ([0-9]+\.\ )? ]] && break     # next book heading (number optional)
            if [[ "$l" =~ ^#####\ .+ ]]; then
                cleaned="$(printf '%s' "$l" | sed -E 's/^##### [[:space:]]*//; s/[[:space:]]*\|.*$//; s/[[:space:]]*$//')"
                # remember the very first ##### line as a fallback
                [ -z "$first_hash" ] && first_hash="$cleaned"
                # skip mood lines (middle-dot separated) and metadata lines
                case "$cleaned" in
                    *"·"*) j=$((j+1)); continue ;;            # mood/tags line
                esac
                if printf '%s' "$cleaned" | grep -qiE '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)|pages'; then
                    j=$((j+1)); continue                      # metadata line
                fi
                # first line that's neither mood nor metadata = the author
                printf '%s' "$cleaned"
                return
            fi
            j=$((j+1))
        done
        # nothing survived the filter — fall back to the first ##### line
        [ -n "$first_hash" ] && printf '%s' "$first_hash"
    }

    # emit the cover line for ID/URL beneath the heading just written, unless the
    # NEXT source line (index $1) is already that cover line. Updates counters.
    emit_cover() {
        local id="$1" url="$2" nextidx="$3"
        [ "$COVERS" -eq 1 ] || return
        local coverline="[![](${COVER_DIR_NAME}/${id}.${COVER_EXT})](${url})"
        local nxt=""; [ "$nextidx" -lt "$total" ] && nxt="${LINES[$nextidx]}"
        if [ "$nxt" = "$coverline" ]; then
            n_cover_have=$((n_cover_have+1)); return
        fi
        if ensure_cover "$id" "$destdir"; then
            printf '%s\n' "$coverline" >> "$tmp"
            log "  cover id=$id -> ${COVER_DIR_NAME}/${id}.${COVER_EXT}" "$C_GREEN"
            n_cover=$((n_cover+1))
        else
            log "  NO COVER in Calibre for id=$id" "$C_YELLOW"
            n_cover_no=$((n_cover_no+1))
        fi
    }

    while [ "$i" -lt "$total" ]; do
        local line="${LINES[$i]}"

        # already-linked heading: "#### [title](.../book/<id>)" with an OPTIONAL
        # "NN. " number prefix (numbered or unnumbered lists both match).
        if [[ "$line" =~ ^####\ ([0-9]+\.\ )?\[.*\]\((https?://[^\)]*/book/([0-9]+))\)[[:space:]]*$ ]]; then
            local url="${BASH_REMATCH[2]}" id="${BASH_REMATCH[3]}"
            printf '%s\n' "$line" >> "$tmp"
            n_have=$((n_have+1))
            emit_cover "$id" "$url" $((i+1))
            i=$((i+1)); continue
        fi

        # new book heading: "#### <title>" (NOT already a link), with an OPTIONAL
        # "NN. " number prefix. The already-linked branch above ran first, so this
        # only catches plain (unlinked) headings.
        if [[ "$line" =~ ^####\ ([0-9]+\.\ )?.+ ]]; then
            local numpfx title id="" via=""
            # numpfx = the "NN. " prefix if present (kept verbatim so a numbered
            # list stays numbered on output), else empty.
            numpfx="$(printf '%s' "$line" | sed -E 's/^#### ([0-9]+\. )?.*/\1/')"
            title="$(printf '%s' "$line" | sed -E 's/^#### ([0-9]+\. )?[[:space:]]*//')"

            if [ "$DO_LINK" -eq 1 ]; then
                local pnorm author
                pnorm="$(norm "$title")"
                author="$(heading_author "$i")"
                # 1) TSV fast path by normalised title
                if [ -n "$pnorm" ] && [ -n "${TSV_ID[$pnorm]:-}" ]; then
                    id="${TSV_ID[$pnorm]}"; via="tsv"; n_fast=$((n_fast+1))
                else
                    # 2) strict library lookup (title-vs-title, author-vs-author)
                    local found; found="$(lib_find_id "$title" "$author")"
                    [ -n "$found" ] && { id="$found"; via="lib"; }
                fi
            fi

            if [ -n "$id" ]; then
                local url="$BOOK_BASE_URL/$id"
                # keep the original "NN. " prefix if the source line had one;
                # otherwise emit an unnumbered linked heading.
                printf '#### %s[%s](%s)\n' "$numpfx" "$title" "$url" >> "$tmp"
                log "  linked [$via] $title -> $url" "$C_GREEN"
                n_link=$((n_link+1))
                emit_cover "$id" "$url" $((i+1))
            else
                printf '%s\n' "$line" >> "$tmp"
                if [ "$DO_LINK" -eq 1 ]; then
                    log "  NOT FOUND in library: $title (left as plain text)" "$C_YELLOW"
                    n_miss=$((n_miss+1))
                fi
            fi
            i=$((i+1)); continue
        fi

        # any other line: copy through unchanged
        printf '%s\n' "$line" >> "$tmp"
        i=$((i+1))
    done

    log "$md: linked=$n_link (fast=$n_fast) already-linked=$n_have not-found=$n_miss | covers added=$n_cover have=$n_cover_have no-cover=$n_cover_no" "$C_CYAN"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "$md: DRY-RUN — diff (no write):"
        command -v diff >/dev/null && diff -u "$md" "$tmp" | sed 's/^/    /' || true
        rm -f "$tmp"
        return
    fi

    # write only if something actually changed. Normally that's "a link or cover
    # was added". Under --relink we also reset/stripped lines, so a file can change
    # even when nothing re-links (e.g. a deleted book's link was demoted and not
    # re-found) — so there we compare the rebuilt file against the original and
    # write on any difference. (preserve trailing-newline state before comparing.)
    if [ -s "$md" ] && [ -n "$(tail -c1 "$md")" ]; then
        printf '%s' "$(cat "$tmp")" > "$tmp.nonl" && mv "$tmp.nonl" "$tmp"
    fi

    local changed=0
    if [ "$RELINK" -eq 1 ]; then
        cmp -s "$md" "$tmp" || changed=1
    else
        { [ "$n_link" -gt 0 ] || [ "$n_cover" -gt 0 ]; } && changed=1
    fi
    if [ "$changed" -eq 0 ]; then
        log "$md: nothing changed — leaving file untouched"
        rm -f "$tmp"
        return
    fi

    cp "$md" "$md.bak"
    mv "$tmp" "$md"
    log "$md: written (links=$n_link covers=$n_cover); backup at $md.bak" "$C_GREEN"
}

for f in "${FILES[@]}"; do
    process_file "$f"
done

log "=== link-md v$LINK_MD_VERSION done ===" "$C_BOLD"

# =============================================================================
#  link-md.sh version 14  (footer stamp — must match LINK_MD_VERSION at top;
#  if these disagree the deployed copy on otis is a stale partial paste.)
# =============================================================================