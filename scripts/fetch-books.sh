#!/usr/bin/env bash
FETCH_BOOKS_VERSION="83"   # bump on every change; echoed at startup so you can
# v83: VERIFY-TIER CANDIDATES ("try up to N, let dc:title decide"). When a
#      contaminated listing leaves the WRONG book as the only candidate clearing
#      CONFIDENCE (Lock In: the imposter "Lock In 2 Head On" scores >0.6, the real
#      "Lock In: A Novel..." scores below it and was never tried), the loop had
#      nothing else to attempt and gave up. Now candidates scoring in
#      [VERIFY_FLOOR, CONFIDENCE) are accumulated as a TIER-1 "verify-only" set,
#      tried only after all confident (tier-0) candidates fail, and admitted ONLY
#      by the post-download dc:title check. So the real low-scored edition gets a
#      chance: download, dc:title matches -> accept; a wrong low-scored one is
#      discarded by dc:title. VERIFY_MAX_DLS (default 3) caps total quota spends
#      per book so a genuinely-absent title can't drain the day. A verify-only hit
#      no longer stops the mirror walk (another mirror may have it confidently).
#      Diagnostics from 82.x retained one more round to watch the new tier; strip
#      in a later cleanup with the guard-dedup refactor.
# v82.2: THIRD md5 SITE. There are THREE md5-trust points, not two: (1) the
#        pre-search already_in_library check, (2) the lazy-backfill link, and (3)
#        the POST-SEARCH md5 BACKSTOP — which fires after the Anna's search returns
#        the matched md5 and checks it against the library. (3) was unguarded and
#        was re-stamping the row downloaded|<bad-md5> every run, UNDOING the backfill
#        guard's reset (the Lock In <-> 1968 loop you saw across runs). Added the
#        same title-sanity guard to (3): a contaminated md5 is not treated as
#        "owned"; it falls through to download + dc:title verification.
# v82.1: DIAGNOSTIC + FIX. v82's md5/backfill guards silently no-opped because
#       they gated the title read through cdb_search_ok() — which validates SEARCH
#       output, not `list --for-machine` JSON — so it returned false, found_title
#       stayed empty, and the guard trusted the md5 (Head On slipped through again).
#       Removed that wrong gate (keep only the cdb_locked check) and added
#       [md5-guard]/[backfill-guard] diagnostic log lines so the decision is
#       visible. Remove the diagnostics once confirmed working.
# v82: EXTEND md5 TITLE-SANITY TO THE LAZY-BACKFILL LINK PATH. v81 added the
#      title-sanity guard to already_in_library (the pre-search check), but a
#      'downloaded' row with a contaminated md5 and no calibre id never reaches
#      that check — it goes through the LAZY-BACKFILL path, which resolved the
#      row's md5 to a calibre id and wrote 'linked: <title> -> id N' with NO title
#      check. So "Lock In" (carrying Head On's md5) still linked to Head On's id
#      1968. Now the backfill applies the same guard: if the md5 resolves to a book
#      whose title contains neither list field, it does NOT link — it logs
#      "NOT linking: ... contaminated md5" and blanks the row's status+md5 so the
#      NEXT run re-searches it fresh. Fail-safe: if the title read locks/fails, it
#      links as before. (Same logic as v81's already_in_library guard; duplicated
#      across the two sites for now — a future refactor could share a
#      title_matches_book_id helper.)
# v81: POST-DOWNLOAD TITLE VERIFICATION + cleaned Anna's search query + md5
#      (a) VERIFY THE FILE IS THE RIGHT BOOK. Anna's listing metadata can lie: a
#      record titled "Lock In 2 Head On" (the Head On sequel mis-tagged with book
#      1's name) passes the title gate for a "Lock In" search, so fetch-books
#      downloads Head On believing it's Lock In. The listing is unfixable upstream
#      (the contaminating words ARE in the candidate title), but the DOWNLOADED
#      FILE carries its own honest <dc:title> in the OPF — which says "Head On".
#      After the magic-byte ebook check and before moving the file into the watched
#      folder, we read the epub's dc:title and require the WANTED title's meaningful
#      words to be present (and, for weak/short titles, the file title to start
#      with the wanted title — same short_title_ok rule). On a mismatch the file is
#      discarded (rc=5) and the candidate loop tries the next hit, exactly like a
#      PDF reject. FAIL-OPEN: if the title can't be read (DRM, odd zip, non-epub
#      MOBI, no python3) we DO NOT reject — verification is a catch, never a new
#      gate that could strand good files. Only epub is checked (OPF is trivial to
#      read); other formats pass through unverified.
#      (b) CLEANED SEARCH QUERY. The Anna's search sent the RAW title, so titles
#      with '/' or heavy punctuation ("Romeo and/or Juliet: A Choosable-Path
#      Adventure") matched the index poorly and returned nothing (false nomatch).
#      The query is now normalised (slash/colon/dash -> space, collapse) before
#      url-encoding, so the search terms match Anna's indexed title. The RAW title
#      is still used for scoring/gating; only the QUERY string is cleaned.
#      (c) md5 MATCH TITLE-SANITY. already_in_library's md5-identifier match was
#      trusted blindly: if a CONTAMINATED md5 (Head On's file md5, which a "Lock
#      In" search keeps selecting) is stamped on a library book, the pre-search
#      check found that book by md5 and skipped the download — so "Lock In" kept
#      resolving to the library's "Head On" and never downloaded the real book.
#      Now, after an md5 hit, we read the FOUND book's title and require the wanted
#      title's meaningful words to be present; if neither list field matches the
#      found title, the md5 is treated as contaminated and we fall through to the
#      title/author check (which correctly won't find it) so the real download can
#      proceed. Fail-safe: if the title read locks/fails, we trust the md5 as
#      before. This is the stage that actually blocks the Lock In case — (a)'s
#      post-download dc:title check only runs once a download happens, but the
#      contaminated md5 was short-circuiting BEFORE any download.
# v80: STOP BURNING QUOTA ON FOREIGN/PDF CANDIDATES + LOG EVERY SPEND.
#      (a) PRE-DOWNLOAD LANGUAGE SKIP. search_one now carries each candidate's
#      language-rank (0=English/unknown/allowed, 1=affirmatively-foreign) through
#      to the download loop as a 4th field. The loop SKIPS a langrank=1 candidate
#      WITHOUT downloading it — so a book with many foreign editions (The Half
#      King: 5 editions, Vow of Thieves: 4, The Alchemyst: 3) no longer spends a
#      quota slot per foreign edition only to reject it post-download. Skip is on
#      an AFFIRMATIVE foreign label ONLY; blank/und/unknown/multi-with-en still
#      download and hit the OPF gate (v76's fail-open stance preserved). This is
#      the fix for the silent quota bleed where ~23 of 50 daily slots were spent
#      on candidates fetch-books downloaded then discarded.
#      (b) LOG EVERY QUOTA SPEND. fast_download_md5 now logs a 'spent slot' line
#      carrying the md5 for EVERY fast-download API fetch — including the ones
#      rejected afterwards for language/PDF/format. Previously only the KEPT
#      download logged a 'downloaded -> [md5:...]' line, so quota-status.sh could
#      date only ~27 of 50 spends and mislabelled the discarded-candidate spends
#      as 'shelfmark/manual'. Pairs with quota-status.sh v6, whose parser reads
#      the new 'spent' lines so all real spends are datable and the projection
#      horizon extends to the full cap. Token: 'quota-spend [md5:<hash>]'.
# v79: FORCE-RETRY ABSENCE CHECK FIX. v78's --force-retry decided "in library?"
#      by the annas:<md5> identifier ALONE. But many library books were never
#      stamped with that identifier (the md5 is only stamped at TAG time, and
#      fuzzy-matched/older imports often never were), so the md5 lookup returned
#      empty for books that ARE present — and force-retry then reset a perfectly
#      good 'tagged' row to pending. (Harmless per-run because the pre-search
#      library check immediately re-skipped them, but it churned statuses: a
#      tagged row came back as downloaded and got needlessly re-tagged.) Fix:
#      force-retry now calls already_in_library (the SAME check the pre-search
#      stage uses), which tries the md5 identifier AND falls back to a bidirectional
#      title/author match. A row is reset ONLY when that returns a CLEAN absent
#      (rc=1); rc=0 (present, by id or title/author) leaves the row untouched, and
#      rc=2 (calibre locked/unreadable) leaves it untouched too. So "confirmed
#      absent" now means genuinely absent, not merely un-stamped.
# v78: (a) NEW 'pdf-only' TERMINAL STATUS. When every candidate is rejected and
#      AT LEAST ONE rejection was specifically a PDF (vs. a network/other error),
#      the row is marked 'pdf-only' instead of 'failed'. This is the prize-list
#      case: a book that exists on Anna's only as a scanned PDF. fast_download_md5
#      now returns rc=4 on a PDF magic-byte reject (distinct from rc=1 generic
#      fail); the candidate loop records whether any attempt was a PDF reject and
#      picks the terminal status accordingly. 'pdf-only' is SKIPPED by normal runs
#      (no quota wasted re-proving it) but RE-ATTEMPTED under --retry (in case an
#      epub edition has since appeared). Rationale: pre-v49 fetch-books accepted
#      PDFs and wrote 'downloaded', stranding ~70 un-importable files in the
#      watcher's /done with TSV rows that tag-books retries forever; this status
#      makes the PDF-only outcome explicit and terminal-but-retryable.
#      (b) NEW --force-retry (alias --verify): re-checks EVERY row against the
#      live Calibre library by md5. A row claiming to be done (downloaded/queued/
#      downloading/completed/tagged) whose book is CONFIRMED ABSENT from Calibre is
#      reset to pending and re-attempted in the same pass — so deleting a book from
#      Calibre and running --force-retry re-downloads it. CRUCIAL SAFETY: a row is
#      reset ONLY on a confirmed absence. If the library check can't run (calibre
#      locked/busy/unreachable — cdb_search_retry returns a lock/error rather than
#      a clean empty), the row is left UNTOUCHED, so a transient lock never wipes a
#      good status or triggers a needless re-download. --force-retry also implies
#      --retry (it reconsiders failed/nomatch/pdf-only too). Without a confirmed
#      absence, a present book is left exactly as it was (incl. its calibre id).
# v77: GET ALL HITS, LOOK FIRST. The CAND_LIMIT=3 cut happened BEFORE any real
#      (OPF) language check, so a book whose top-3 equal-scored hits were all
#      foreign editions failed even when an English copy sat just past the cut
#      (The Alchemyst: ar/de/nl tried, English never reached). Split the single
#      "3" into two knobs: CAND_LIMIT (now 30) is just the EMIT ceiling — the
#      full ranked hit list is handed to the download loop — and MAX_ATTEMPTS
#      (new, default 12) bounds how many candidates the loop actually fetches +
#      OPF-checks before giving up. A language reject is treated as an expected
#      fall-through to the next candidate, not a hard stop. Combined with v76's
#      language-rank sort (English/unknown cards ordered first), the right
#      edition is normally attempt 1-2 and the budget only bites on books with
#      many foreign editions ahead of the English one. No quota cost change:
#      language-rejected downloads were already discarded pre-quota-count.
# v76: (a) AA CANDIDATE LANGUAGE PRIORITISATION. The Anna's result parser now
#      captures each card's language label (the "[en]"/"[fr]" ISO code in the
#      metadata line) as a 5th field, and the candidate sort orders by language-
#      rank (English/unknown before affirmatively-foreign) AHEAD of format-rank,
#      after score. Fixes books where 3 foreign editions filled CAND_LIMIT and
#      the English edition was never attempted — Vow of Thieves (fr/fr), The
#      Alchemyst (ar/de/nl), The Half King (it/it/de) all failed this way at
#      score 1.000. Language label is a SORT key only, NOT a gate; the OPF
#      language check post-download (v72/73) remains the real guard, and fail-
#      open is preserved (blank/unknown label ranks 0). welib parser emits the
#      same field arity with empty fmt+lang. (b) the offset-60 MOBI-header probe
#      (head64) now pipes through tr -dc '[:print:]' like first64 already did,
#      killing the "command substitution: ignored null byte" warning that fired
#      on every download (cosmetic; BOOKMOBI/MOBI/TPZ are printable so detection
#      is unchanged). (c) found but NOT changed here: fetch-books looks for
#      check-mirrors at /home/robmorgan/scripts/ — the scripts live in
#      ~/gunit/scripts/, so mirror state has gone unrefreshed ~11 days. Flagged
#      for a follow-up once you confirm the intended check-mirrors path.
# v75: (a) language gate treats und/mul/zxx/unknown as NON-declarations (fail-
#      open) - an English edition whose OPF declares dc:language=und is no longer
#      rejected; only an affirmative disallowed language (fr, nl...) is. Fixes
#      Brideshead/others matching 1.000 then discarded as 'und'. (b) start line
#      reworded: floor + mirrors always, retry/wait/dry-run shown as bare words
#      only when on, SE-first shown as "check standard Ebooks". (c) tmux window
#      name set per-list to "fetchbooks: <list>" on interactive tty runs only
#      (replaces the hardcoded rename-window that fired even under the timer).
# v74: dry-run now logs the MATCHED CANDIDATE's title/author text under each
#      "DRY: would download <md5>" line, not just the md5+score. A dry-run that
#      says "score 1.000" tells you the matcher was confident but not WHAT it was
#      confident about — and Anna's metadata can mislabel a file (e.g. a "Lock In"
#      search returning a candidate whose card says one title but whose file is
#      another). Surfacing the candidate text distinguishes a real matcher fault
#      from Anna's bad metadata. Pure diagnostic; no matching behaviour changed.
# v73: THE LANGUAGE GATE WAS A NO-OP SINCE v64. epub_lang_ok fed its python
#      extractor script via a heredoc on stdin (`docker exec ... python3 - "$tmp"
#      <<'PY'`) but WITHOUT `docker exec -i`, so stdin was never attached: python3
#      read an EMPTY program, printed nothing, and the gate saw no language and
#      fail-open ACCEPTED every book. This is why a Dutch "All Fours" (OPF declares
#      nl, en-US, nl-NL) was downloaded repeatedly while the log said "epub declares
#      no dc:language — accepting": the script never ran. (The magic-byte probes
#      next to it always worked because they pass the program as a `sh -c` argument,
#      not on stdin.) Fix: add `-i`. Now the extractor actually runs and v72's
#      all-languages reject logic finally takes effect. Verified the same in-
#      container extraction returns ['nl','en-US','nl-NL'] for the All Fours file.
# v72: epub language gate (v64) now inspects ALL dc:language tags, not just the
#      first. A Dutch edition of "All Fours" shipped a multilingual OPF declaring
#      <dc:language>nl</dc:language> AND <dc:language>en-US</dc:language>; the old
#      gate read only the first tag, and a sibling weakness (the allow-check
#      stopped at the first allowed code) meant a mixed OPF with any en tag could
#      pass. The gate now collects every declared language and REJECTS if ANY is
#      outside LANGS — pure-English OPFs still pass, foreign editions that mix in
#      an incidental en tag no longer slip through, regardless of tag order. The
#      reject log lists the offending language(s) and the full tag set. (Note:
#      this only gates NEW downloads; files fetched before v64 — e.g. the Dutch
#      All Fours already on disk — were never gated and must be re-fetched.)
# v71: two runtime/list ergonomics.
#      (1) --floor N: override QUOTA_FLOOR (the fast-download reserve) for one run
#      from the command line, instead of having to export QUOTA_FLOOR. Validated
#      as a non-negative integer; 0 disables the floor. Parsed in the arg loop so
#      it wins over the env default.
#      (2) "#skipstandard" in-file directive: a comment-style header line (like
#      "#tag:") that disables the Standard Ebooks search for THAT list, baked
#      into the data so it persists across runs without the --skipstandard flag.
#      Parsed per-file into a local file_se_first (seeded from the global SE_FIRST,
#      which --skipstandard / SE_FIRST=0 may have already forced off); the per-book
#      SE gate now consults file_se_first instead of SE_FIRST. Put the directive
#      at the TOP of the list (above the first book row) — like #tag, it only
#      affects rows parsed AFTER it. Aliases: #skip-standard. Run-level SE uses
#      (startup downloader check, keyless-Anna's fallback) stay global, unchanged.
# v70: two small fixes. (1) The "library check unavailable (calibre busy?)" defer
#      message now names the REAL cause via LIB_CHECK_REASON — "content server
#      unreachable (is the calibre GUI/server up?)", "library locked by another
#      calibre program", "content server auth rejected", or a generic read error
#      — instead of always guessing "calibre busy?". already_in_library classifies
#      the failed output before each return-2. (Most common in practice: the GUI/
#      content server being down, which the old message hid.) (2) The per-TSV
#      flock handle (v68) moves from "<list>.tsv.lock" beside the lists to
#      /tmp/gunit-fetch.<hash>.lock, so it no longer clutters the tsv-lists
#      folder and clears on reboot. Old stray *.tsv.lock files can be deleted.
# v69: --wait is now the DEFAULT for ALL runs (was opt-in). After a pass, the run
#      stays open and re-attempts quota_blocked books as quota recovers, until the
#      list is clear or WAIT_MAX_SECS of IDLE time (v63 reset-on-progress). New
#      --no-wait (alias --once) restores the old single-pass behaviour for the
#      timer or one-shot manual runs. Ctrl-C stops a waiting run cleanly (EXIT
#      trap tidies .part-* files). NOTE: pairs with calibre-lib v2, which makes a
#      content-server outage fall back to on-disk reads instead of freezing the
#      whole run — relevant because a long-lived --wait run is more exposed to a
#      mid-run server restart.
# v68: hardening from a code review. (1) Per-TSV flock guard rail in process_file:
#      if a manual --retry ever overlapped a timer run on the SAME list, the last
#      `mv $tmp $file` would clobber the other's status updates (lost rows, wasted
#      quota). Runs are normally serialized so this rarely fires, but the lock
#      makes a second run WAIT (non-blocking probe + log, then block) and process
#      the already-updated file. Held on fd 9 across the whole read->tmp->mv
#      section; the body stays in the PARENT shell (not a subshell) so the EXIT
#      trap and CLEANUP_PARTS/CLEANUP_FILES appends still work — a subshell body
#      would hide in-flight .part-* files from the parent's cleanup trap. (3)
#      Startup sweep of orphaned .part-* files older than a day in DEST: the EXIT
#      trap deletes in-flight parts on Ctrl-C/SIGTERM, but SIGKILL / container
#      restart / hard crash bypasses it and leaks dead files onto the media drive.
#      Two review suggestions were considered and DECLINED with reasons: batching
#      the 3 magic-byte docker-exec probes into 1 (saves <1s on an already multi-
#      second rate-paced successful download, at the cost of a brittle binary-safe
#      hex dance — not worth it); and re-quoting the numeric $ids word-split (the
#      existing unquoted split is intentional and awk re-validates ^[0-9]+$).
# v67: fix the v66 library check STILL missing owned books, now via a parse bug.
#      v66 correctly routed reads through the content server (no more lock race,
#      and the search stage returns the id fine), but the per-candidate metadata
#      read still failed to parse. cdb_ro folds stderr into stdout, and the
#      FantasticFiction plugin prints banners BOTH before the JSON
#      ("...SyntaxWarning...") AND AFTER it ("Integration status: True"). v65's
#      slice-from-"[" stripped the LEADING banner, but json.loads(raw[i:]) then
#      choked on the TRAILING banner with "Extra data: ... char 98", the except
#      swallowed it, the only candidate was dropped, and already_in_library
#      returned 1 ("not in library") — so "Yesteryear: A Novel" (id 1189) kept
#      going to Anna's despite the server read finding it. Fix: parse with
#      json.JSONDecoder().raw_decode(), which decodes only the first JSON value
#      and ignores anything after it, so trailing banner noise is harmless.
#      Verified against the exact polluted output. (Only this one cdb metadata
#      read parses --for-machine JSON; the other json.load sites read Anna's API
#      or the tag-queue file and are unaffected.)
# v66: calibre access EXTRACTED to shared calibre-lib.sh, and READS now go through
#      the calibre CONTENT SERVER instead of the on-disk library. Root cause of the
#      recurring "owned book re-downloaded" bug (e.g. "Yesteryear: A Novel", id
#      1189): the always-on GUI container holds the library lock in bursts, so
#      on-disk reads raced it; a lost race made already_in_library report "not in
#      library" and fetch-books re-fetched a book already owned. v65's lock-retry
#      narrowed the window but couldn't close it (the lock is frequent enough that
#      reads still lost). The content server shares the GUI process and does NOT
#      contend for the lock, so reads through it never see "Another calibre program
#      is running". cdb_ro now routes via --with-library $CALIBRE_SERVER_URL (creds
#      auto-loaded from ~/gunit/config/calibre-server.env), falling back to the
#      on-disk path if that URL is unset. WRITES are unchanged (cdb_rw, on-disk, as
#      2001:2002) to preserve file ownership. The cdb_* lock helpers moved to the
#      shared lib verbatim; already_in_library is otherwise untouched. No behaviour
#      change unless the server creds are configured — then the lock race is gone.
# v65: fix in-library books being re-downloaded due to a LOCK RACE in the library
#      check's metadata read. already_in_library's search stage correctly found
#      the book's calibre id (via cdb_search_retry, which retries on lock), but
#      the per-candidate metadata fetch that follows used a BARE `cdb_ro list`
#      with NO lock retry. cdb_ro folds stderr into stdout, so when the always-on
#      calibre GUI container held the library lock at that instant, the "Another
#      calibre program is running" banner (plus FantasticFiction plugin startup
#      noise) landed on stdout, was piped into json.load, threw, and the
#      `except: pass` SILENTLY dropped the candidate. With a single candidate that
#      emptied the id list and the function returned 1 ("not in library") — so a
#      book sitting in calibre (observed: "Yesteryear: A Novel", id 1189) went
#      back to Anna's and was re-downloaded, wasting quota. Fixes: (1) new
#      cdb_list_retry wrapper (mirrors cdb_search_retry) so the metadata read
#      survives a transient lock; (2) if still locked after retries, return 2
#      (defer) instead of dropping the candidate; (3) strip any pre-JSON banner
#      noise by slicing from the first '[' before json.loads. The matcher itself
#      was never at fault — book_match_fields scores "Yesteryear" vs "Yesteryear:
#      A Novel" at 1.000; the book never reached scoring.
# v64: post-download epub LANGUAGE gate. The magic-byte guard proves a file is a
#      real epub but not that it's English, so a valid Spanish ePubLibre edition
#      (e.g. Orbital) passed and reached the library, where calibre-web's language
#      filter then hid it. New epub_lang_ok() reads dc:language from the epub's
#      OPF (python3 zipfile, inside DL_CONTAINER) and rejects a download whose
#      declared language isn't in LANGS. Fail-open: empty LANGS, no python3, or an
#      epub with no declared language all ACCEPT (logged), so the gate only drops
#      books that AFFIRMATIVELY declare a disallowed language. LANGS code matching
#      accepts both 2- and 3-letter forms (en/eng, es/spa, ...).
                          # confirm the copy on otis matches the latest edit.
#                          (version stamp also at end of file.)
# v63: --wait now RESETS its 24h cap whenever a retry pass actually downloads a
#      book. Previously wait_started was fixed at loop entry, so the WAIT_MAX_SECS
#      (24h) deadline counted total elapsed time: a run that kept making progress
#      (downloading a batch each time quota recovered) would still be killed 24h
#      after it began, mid-stream. Now the cap measures IDLE time since the last
#      successful download — after each pass, if QUEUED_RUN>0 (that pass grabbed
#      at least one book; QUEUED_RUN increments only on dl_rc==0 and is zeroed
#      before each pass) wait_started is reset to now. So the loop only gives up
#      after a genuine 24h with NO downloads; an actively-progressing wait stays
#      open indefinitely until the quota_blocked list is empty. No new tunable —
#      WAIT_MAX_SECS keeps its meaning, just measured from last-success not start.
# v62: FORMAT-AWARE candidate ranking. The Anna's &ext=epub filter is metadata-
#      only and unreliable (same caveat as &lang): a search restricted to ebook
#      formats still returns PDF cards. The candidate parser was format-BLIND —
#      it scored title/author only, so for a book with many identical-scoring
#      copies (every "A Spool of Blue Thread" hit scores 1.000) the CAND_LIMIT=3
#      cut was decided by sort's arbitrary tie-break order, which happened to put
#      three PDFs first. All three downloads were then rejected by the v49 magic-
#      byte guard and the book was marked 'failed' — even though 15+ epubs for it
#      sat in the same result set, just past the cut. Fix: the Anna's parser now
#      captures each card's format and emits it as a 4th field (md5\ttitle\t
#      author\tfmt); the scorer carries it; and the final sort orders by
#      (score DESC, format-rank ASC) where format-rank follows the FORMATS
#      preference order (epub<azw3<mobi<fb2) with pdf/unknown ranked LAST. So a
#      tied epub is always tried before a tied PDF, and the magic-byte guard
#      becomes a true backstop instead of burning every attempt. Caller output
#      shape (md5\tscore\ttext) is unchanged — format only influences ordering.
#      welib parser (abandoned) still emits 3 fields; the scorer defaults a
#      missing fmt to unknown, so it can't crash if welib is ever re-enabled.
# v61: INTERACTIVE MODE (matches link-md v7). Running fetch-books with NO file
#      args (and no list-producing flag) no longer errors — it opens nnn as a
#      file picker in $TSV_DIR (default ../tsv-lists, i.e. /gunit/tsv-lists/),
#      you select a .tsv (Enter on it), nnn writes the pick to a temp file
#      (nnn -p) and quits, and that one .tsv becomes the list to process. nnn is
#      REQUIRED in this mode (hard-fail with an install hint if absent); a
#      non-.tsv pick or quitting without a selection aborts cleanly. All flags
#      (--dry-run, --retry, --wait, --skipstandard, --tag) still apply. New env:
#      TSV_DIR (the picker's start dir). Passing list args explicitly is
#      unchanged. The block runs after log() is defined so it logs/colours like
#      everything else.
# v60: fix "$1: unbound variable" spam in cdb_ids under set -u. cdb_ids is used
#      two ways: as `cdb_ids "$out"` AND as a pipe stage `... | cdb_ids | head -1`
#      (the id-backfill lookups, lines ~1931/1933). In the pipe form it gets NO
#      positional arg, so a bare $1 is unbound and set -u aborts that subshell,
#      printing the error once per backfill row and returning empty (so the id
#      never got linked). cdb_ids now reads stdin when called with no arg. Latent
#      since the helper was introduced; only triggers on rows with an md5 but no
#      id yet — exactly the SE-only / quota-paused run that exposed it.
# v59: fix off-by-one quota floor — it landed exactly ONE below the reserve every
#      run. quota_ok() is called BEFORE a download but compared the floor against
#      the post-PREVIOUS-download reading (QUOTA_LIVE) / pre-queue projection,
#      neither of which accounts for the download this very call is authorizing.
#      With QUOTA_FLOOR=4: at QUOTA_LIVE=5 the old test (5<=4) passed, so it
#      queued one more, consuming the 5th and landing at 4 — the floor itself,
#      not floor+1 in reserve. Both branches now subtract the pending download
#      (QUOTA_LIVE-1 / projected-1) and stop when THAT would breach the floor, so
#      the run leaves QUOTA_FLOOR slots actually intact.
# v58: fix quota_blocked rows staying quota_blocked when the book IS in the
#      library. The pre-search library check was called with an EMPTY md5
#      (already_in_library "$author" "$title" "") so it only matched by
#      title/author. A quota_blocked/failed row carries the Anna's md5 it matched
#      earlier; once that book imports, calibre stamps identifiers:annas:<md5> —
#      the authoritative match. But if the imported metadata differed from the
#      list (trimmed subtitle, "H_ Wilson" vs "H. Wilson", reordered author), the
#      title/author check missed it, the row went back to Anna's, hit quota
#      again, and stuck. Now the row's md5 is passed in, so already_in_library's
#      exact identifier path (step 1) matches it. The re-marked row also records
#      the calibre id in col 6, becoming a fully-linked terminal row. Pending
#      rows have no md5 so they still match by title/author exactly as before.
#      Stuck rows clear on the next normal run (no --retry needed; quota_blocked
#      already re-processes automatically).
# v57: two changes.
#      (1) USE THE fast_download API's path_index/domain_index. The API doc says
#      both are optional integers (0+) selecting the collection and the download
#      server; when omitted the server picks a default that, for files in
#      multiple collections / on multiple partner servers, can be INVALID —
#      returning "Invalid domain_index or path_index" (the failures seen in the
#      logs). We now try the default first (most files resolve), and ONLY on that
#      specific error iterate path_index 0..FD_MAX_PATH_INDEX x domain_index
#      0..FD_MAX_DOMAIN_INDEX (default 3x2) until a real download_url comes back,
#      stopping at the first success. Quota-safe: you're charged on download_url
#      FETCH, not on the resolution calls. Composes with v53's multi-candidate
#      fallback: indices are tried per-md5, then the next candidate md5.
#      (2) self-documenting TSV schema header. The list is parsed column-wise by
#      fetch-books AND tag-books; fetch-books now writes a "#schema:" comment
#      block to the top of any list lacking one (once), recording the column
#      contract + status vocabulary + the col-6 dual meaning. All parsers skip
#      '#' lines, so it's preserved on every rewrite and ignored by consumers.
# v56: persistent "SE already checked, empty" marker so a book that's not on
#      Standard Ebooks doesn't re-search SE every run. The repeat offender is
#      quota_blocked: it auto-retries daily (no --retry), and each retry re-ran
#      the SE search first — so an Anna's-only book hit SE pointlessly every day
#      while waiting for quota. Now: when SE is searched and comes back empty
#      (not-found OR placeholder/not-yet-public-domain), the row is written with
#      "se-empty" in COL 6. On re-runs, a non-terminal row (quota_blocked/nomatch)
#      carrying that marker skips the SE search and goes straight to Anna's, and
#      re-propagates the marker. COL 6 is dual-purpose by status and the two
#      never co-occur: terminal rows (downloaded/tagged/...) use col 6 for the
#      calibre id; non-terminal rows use it for se-empty. NOT set on 'failed' (SE
#      had the book, only the download broke — a --retry should try SE again).
#      Bypass: --skipstandard / SE_FIRST=0 still skip SE for the whole run.
# v55: add --skipstandard (alias --skip-standard). Skips the Standard Ebooks
#      search for the whole run and goes straight to Anna's — for lists you KNOW
#      aren't public-domain (modern prize lists), where the per-book SE search is
#      just dead latency. Equivalent to SE_FIRST=0 but as a CLI flag; applied
#      after arg parsing so it overrides any SE_FIRST env value regardless of
#      position. NOTE: this is the SAME skip whether or not SE was tried before —
#      the TSV has no "SE already tried" marker, so without this flag SE is
#      re-searched fresh every run for any not-yet-done book.
#      ALSO: silence the cosmetic "ignored null byte in input" bash warning. The
#      filename built from Anna's download_url ran through urllib unquote, which
#      can emit a literal NUL (from a %00 or malformed multibyte) that bash can't
#      hold in a variable — it dropped the NUL and warned. The download was never
#      affected (filename still valid). Now the unquote step strips control bytes
#      in python before printing, so bash never sees a NUL.
# v54: two Gemini-review fixes (both correct on the merits).
#      (1) Ctrl-C double-cleanup. on_signal() called cleanup() AND THEN exit 130
#      — but exit fires the EXIT trap, which runs cleanup() a SECOND time, paying
#      the docker exec startup penalty twice and making Ctrl-C feel laggy.
#      on_signal now just exits; the EXIT trap runs cleanup exactly once.
#      (2) force UTF-8 for python helpers. Under a systemd timer/cron with a
#      non-UTF-8 locale, python's stdout defaults to ASCII and print()ing an
#      accented author (e.g. "Pedro Páramo") raises UnicodeEncodeError, swallowed
#      by 2>/dev/null -> empty -> false nomatch, silently undoing the v41 accent
#      fix. Now exports PYTHONIOENCODING=utf-8 once at the top.
#      (Gemini's 3rd note — the --content-on-error wget fallback being dead code
#      on a 502 — is correct but harmless: the JSON parse rejects the 502 HTML
#      and the mirror loop advances. Left as-is; mirror rotation covers it.)
# v53: three bugs fixed.
#      (1) --wait: two bugs prevented retries from actually firing. (a) The
#      wait_quota_left function returned empty when quota-probe.sh was absent or
#      its probe failed — the wait loop logged "quota probe failed" every cycle
#      and never triggered a retry. Now falls back to a direct fast_api_call
#      with the invalid-md5 probe (no quota consumed). (b) When the retry pass
#      DID fire, QUOTA_LIVE still held the stale "0" from when quota ran out
#      earlier, so quota_ok() immediately halted every retry book. The retry
#      section now clears QUOTA_LIVE, seeds QUOTA_START from the fresh probe
#      reading, and resets QUEUED_RUN.
#      (2)+(3) Multi-candidate fallback. When the best-matched Anna's md5 fails
#      to download — either "Invalid domain_index or path_index" (file not in
#      fast-download pool) or a magic-byte rejection (Anna's served a PDF/LIT
#      despite epub existing) — the script now tries up to CAND_LIMIT (default 3)
#      candidates for the same book before marking it failed. search_one now
#      returns all confident candidates (score >= CONFIDENCE) from the first
#      live mirror, sorted by score desc; process_file loops through them on
#      any rc=1 failure. Success or quota exhaustion (rc=2) stops the loop.
# v52: --wait default cap raised from 8h to 24h (WAIT_MAX_SECS 86400). Override
#      per-run with WAIT_MAX_SECS=... as before.
# v51: ban junk/dead formats at download. FORMATS scrub now strips zip/lit/rtf/
#      prc (not just pdf), and the post-download guard rejects them by magic bytes:
#      a PK file must carry the "application/epub+zip" signature (real epub) or
#      it's discarded as a bare zip; rtf/lit/pdf/html are rejected outright. Only
#      genuine epub + MOBI-family containers are accepted.
# v50: log the FULL md5 as an explicit [md5:<hash>] field on the download line.
#      The filename embeds only a TRUNCATED md5 (byte-budget trim), so quota-
#      status could not date downloads by md5 from the log. The explicit field
#      restores roll-off timing.
# v49: guarantee Anna's never delivers a PDF. (1) strip pdf from FORMATS even if
#      set explicitly, so the search never requests it. (2) post-download magic-
#      byte guard: inspect the real bytes and DISCARD a %PDF (or HTML/XML gate
#      page) even if Anna's mislabelled it epub — only zip-based (epub/azw3/fb2)
#      and MOBI-family containers are accepted. Closes the gap where the Anna's
#      download only checked non-empty, not content type.
# v48: SE books get linked too — the id backfill now matches se: rows by their
#      standard_ebooks identifier (stamped by tag-lib v3), not just Anna's md5.
# v47: store the Calibre book id as a 6th TSV column so links like
#      books.rob.me.uk/book/<id> can be built. fetch can't know the id at download
#      time (assigned only on import), so finished rows with an md5 but no id are
#      backfilled lazily on a later run via identifiers:<scheme>:<md5> (the same
#      lookup tag-lib uses). One cheap query per not-yet-linked book, once. SE
#      rows (no Anna's md5) are skipped by this lookup.
# v46: log to the shared $GUNIT_LOG (~/logs/gunit.log) used by all gunit scripts,
#      each line tagged [f]; terminal output (with colour) unchanged.
# v45: add --wait. After a pass, if any books are quota_blocked (Anna's quota
#      spent), keep the process open: poll quota every WAIT_INTERVAL (default 30m)
#      and once downloads_left >= QUOTA_FLOOR + WAIT_MARGIN (default floor+10) run
#      a retry pass over ONLY the quota_blocked rows. Repeat until none remain or
#      WAIT_MAX_SECS (default ~8h) elapses. Live re-probe uses the shared
#      quota-probe.sh helper with its valid md5. SE-only runs don't wait (nothing
#      to recover). Tunables: WAIT_INTERVAL, WAIT_MARGIN, WAIT_MAX_SECS.
# v44: seed the quota floor from the shared quota-probe.sh helper (the same one
#      quota-status.sh uses). It queries the JSON API with a VALID md5, returning
#      an EXACT, shelfmark-inclusive downloads_left WITHOUT spending a slot — more
#      reliable than the invalid-md5 preflight (which may not return account info
#      at all). Sourced like match-lib.sh; fetch-books passes its own container +
#      first mirror to the helper and restores its own PROBE_MD5 afterward. Falls
#      back to the invalid-md5 response, then to live-on-first-download, if the
#      helper is absent or the probe fails.
# v43: quota exhaustion no longer halts the run — Standard Ebooks (free, off-quota)
#      keeps working for the rest of the list. When Anna's daily quota is spent
#      (floor reached, or API refuses mid-run), ANNAS_QUOTA_OUT is set: every
#      remaining book still tries SE first, and only books SE lacks are marked
#      'quota_blocked' (a distinct status, NOT nomatch/failed) for a later run.
#      quota_blocked auto-retries on the next run (no --retry needed) since the
#      quota resets daily. New per-file counter + summary field. (Replaces v42's
#      whole-run halt.)
# v42: fix the fast-download quota FLOOR + clean stop at exhaustion. (1) The floor
#      never engaged at run start because QUOTA_START was empty until the first
#      successful download — so a run beginning with few/zero slots attempted (and
#      failed) downloads instead of stopping. preflight now seeds QUOTA_START from
#      the bad-md5 probe's account_fast_download_info.downloads_left (no quota
#      spent), so the floor (default now 4, was 5) holds from book 1. (2) When a
#      download is refused for quota exhaustion ("no downloads left" / downloads_
#      left=0), fast_download_md5 returns 2 and the run STOPS (remaining books left
#      pending) instead of logging "download failed" for every book and hammering
#      the API.
# v41: JSON-decode the FlareSolverr envelope. Non-ASCII titles/authors were
#      arriving as undecoded JSON unicode escapes ("Pedro Páramo" -> the literal
#      "Pedro P\u00e1ramo") because the parsers did html.unescape but never
#      json-decode. norm() then mangled them, so EVERY accented/non-Latin
#      title silently scored 0.000 (the real Pedro Páramo card) while an
#      unaccented "Pedro Paramo" entry matched. Now decode .solution.response
#      from FlareSolverr's JSON to real HTML once, before stripping comments and
#      parsing — so accent-folding in norm() works. Falls back to raw if a mirror
#      returns HTML directly. (Completes the v38 lazy-load fix.)
# v40: retry transient calibre locks instead of deferring. The library check ran
#      up to 4 calibredb searches per book; if the GUI briefly held the library
#      lock during ANY one of them, that search returned the "Another calibre
#      program is running" message and already_in_library returned 2 (defer the
#      whole book) — even though the same query succeeds moments later (confirmed:
#      title:"Kindred" succeeded while title:"Octavia E. Butler" was locked in the
#      same instant). cdb_search_retry now re-runs a locked search a few times
#      with a short wait (CDB_LOCK_RETRIES=4, CDB_LOCK_WAIT=2s); a lock that
#      truly persists is still treated as unavailable.
# v39: Gemini review fixes. (1) escape embedded double-quotes in the calibre
#      title: search so a title like The "Great" Gatsby doesn't break the query.
#      (2) refresh_file now parses the md5->state map ONCE into a bash assoc array
#      (was forking awk per TSV row) and splits rows with IFS read (was cut x5).
#      (3) use ${#resp} instead of echo -n|wc -c for the mirror size floor (no
#      subshell). (4) chown Anna's downloads to WATCHER_OWNER (=2001:2002) inside
#      the container after the move, so files land owned for the watcher even if
#      qbittorrent's PUID/PGID aren't 2001:2002; logs a hint if chown fails.
# v38: parse Anna's LAZY-LOADED results. Anna's now ships each search-result card
#      inside an HTML comment that client JS un-comments; FlareSolverr returns the
#      pre-JS HTML, so the cards stayed commented and the parser saw 0 results —
#      the only live /md5/ links were the "recent downloads" ticker (decoys). A
#      present book (e.g. Pedro Páramo) looked missing. search_one now strips the
#      <!-- --> markers before parsing, exposing the real cards (0 -> 50 for that
#      query). The field-separated matcher still rejects ticker/decoy entries.
#      This likely improves match rates across the board, not just one book.
# v37: dead-mirror visibility + safe handling. A mirror that returns nothing via
#      FlareSolverr (unreachable now, even if check-mirrors marked it WORKING
#      earlier) was skipped silently, turning "no mirror answered" into an
#      indistinguishable "nomatch" — so findable books (e.g. Pedro Páramo) looked
#      missing. Now: each unreachable/too-small mirror is logged; if NO mirror
#      answers, search_one returns UNREACHABLE and the loop leaves the row PENDING
#      (retry next run) instead of burning it as nomatch.
# v36: handle Standard Ebooks PLACEHOLDER pages (books with a catalogue entry but
#      not yet public domain, so NO download files — e.g. Life and Fate, Invisible
#      Cities). Previously these matched on SE search then failed the download and
#      were marked 'failed', blocking the Anna's fallback for a book SE will never
#      have. se_download now returns 3 for a placeholder (zero /downloads/ links),
#      and the loop falls through to Anna's instead of marking failed. A real page
#      missing only the requested format still returns 1 (failed, no fallback).
# v35: fix two false-positive matches. (1) The library check (already_in_library)
#      scored candidates with book_match_score on a flattened "title author" blob,
#      so the wanted AUTHOR's words could satisfy the TITLE gate — "The
#      Dispossessed / Le Guin" matched the library's "The Lathe of Heaven / Le
#      Guin". Now uses book_match_fields with title/author kept separate. (2) The
#      SE exact-title floor rescued a wrong book when the title was identical but
#      the author contradicted ("The Secret History" Tartt vs Procopius); the
#      floor now applies only when the candidate author is absent or shares a word
#      (misspellings still pass). Requires match-lib v6 (author-contradiction gate
#      in book_match_fields).
# v34: (1) coloured terminal output — log() now colourizes by message type for
#      the terminal only; the logfile stays plain (no escape codes). Auto-off
#      when stderr isn't a TTY (systemd timer) or NO_COLOR is set. (2) Gemini
#      review fixes: parse loops use `IFS=$'\t' read` / `IFS='|' read` instead
#      of forking cut per field; cleanup batches one docker exec for all parts
#      (Ctrl-C no longer hangs); cdb_ids strips spaces before splitting so
#      "12, 34" doesn't drop ids; --dry-run is now strictly read-only (rows kept
#      verbatim, source file not rewritten/touched).
# v33: fix false "library check unavailable" that deferred every book. The lock
#      detector grepped for "Traceback" anywhere in calibredb output, but
#      calibre's background page-count worker logs tracebacks for unrelated
#      corrupt books (e.g. a non-zip EPUB in the library) onto the same stream
#      as the search result. Those coexist with a valid "No books matching"/id
#      result, so the grep turned clean no-matches into deferrals. Now: only the
#      specific lock message "Another calibre program is running" means locked;
#      a result is valid if it has ids OR says no books matched, regardless of
#      worker traceback noise (cdb_locked / cdb_search_ok / cdb_ids helpers).
# v32: SE downloads now WORK. Root cause of the corrupt epub: the bare SE
#      download URL returns an HTML "Your Download Has Started!" interstitial,
#      not the epub — the binary needs ?source=download appended. Also, SE gates
#      direct downloads by IP: through gluetun (Romania) you get the gate page;
#      over otis's own connection you get the file. So ALL SE traffic (search +
#      download) now runs on the HOST via curl/wget, off the VPN. The
#      interstitial carries a honeypot that bans your IP 24h if followed — we
#      never parse it, only request URL+?source=download directly. PK magic-byte
#      check (v31) retained. Files chowned to 2001:2002 for the watcher.
# v31: se_download now validates the downloaded file is a real ZIP/epub (first
#      two bytes "PK") before moving it into DEST. v30 checked only non-empty,
#      so an HTML 404/redirect/rate-limit page got shipped as a ".epub" the
#      reader couldn't open. A non-PK file is now rejected and logged with the
#      URL + first bytes so the cause is visible.
# v30: fix SE result parser to match SE's real RDFa/schema.org markup (title +
#      author now parse correctly; v29 parsed author as blank). Add a title-only
#      SE retry: if "title author" finds nothing, retry with the title alone, so
#      a misspelled/mis-formatted list author (e.g. "George Elliot" vs SE's
#      "George Eliot") still matches. SE-only exact-title acceptance: an EXACT
#      normalized title match (equality, not subset) clears the bar on its own,
#      since match-lib's short-title guard otherwise demands author corroboration
#      a misspelled author can't give. The shared matcher and Anna's path keep
#      the stricter rule. Disable the retry with SE_TITLE_ONLY_RETRY=0.
# v29: per book, try STANDARD EBOOKS (free, public-domain, no key/quota/VPN)
#      BEFORE Anna's Archive. SE is authoritative: a confident SE match that
#      then fails to download is marked 'failed' (no Anna's fallback), so we
#      never spend Anna's quota on a book SE already had. Grabs the Compatible
#      epub. Source recorded as se:<author-slug>/<title-slug> in the md5 column.
#      Disable with SE_FIRST=0.
# =============================================================================
#  fetch-books.sh — feed a list of author | title, search Anna's Archive via
#  FlareSolverr, confidence-match the top hit, queue it in Stacks. Resumable:
#  rewrites each line's status in place (pending -> done|nomatch|failed) so a
#  re-run only retries what hasn't succeeded.
#
#  LIST FORMAT (PIPE-separated '|', one book per line; blank lines & # comments ok):
#     Wolf Hall  |  Hilary Mantel
#     Wolf Hall  |  Hilary Mantel  |  downloaded  |  <md5>  |  <date>   # cols 3-5 added by the script
#  (Fields are Title|Author. The matcher is bidirectional, so Author|Title also
#   works, but the script's own writes use Title|Author.)
#
#  Status values the script writes back:
#     done     queued to Stacks successfully (md5 recorded in 4th column)
#     nomatch  no search result cleared the confidence threshold
#     failed   matched, but the queue POST failed (retry next run)
#     (blank/pending/anything else) -> treated as not-yet-done, will be attempted
#
#  USAGE:
#     ./fetch-books.sh booker.tsv
#     ./fetch-books.sh --dry-run booker.tsv          # search+match, don't queue
#     ./fetch-books.sh --retry booker.tsv            # also re-attempt failed+nomatch+pdf-only
#     ./fetch-books.sh --force-retry booker.tsv      # re-verify EVERY row against
#                                                    #   Calibre; re-download any
#                                                    #   "done" book that's no longer
#                                                    #   in the library (e.g. after
#                                                    #   you deleted PDFs from Calibre)
#     ./fetch-books.sh --wait booker.tsv             # if quota runs out, keep the
#                                                    #   window open and retry the
#                                                    #   quota_blocked books every
#                                                    #   30m once slots free up
#     ./fetch-books.sh --skipstandard booker.tsv     # skip the Standard Ebooks
#                                                    #   search (straight to Anna's);
#                                                    #   use for non-public-domain
#                                                    #   lists where SE never hits
#                                                    #   (same as SE_FIRST=0)
#     ./fetch-books.sh --tag prizewinner booker.tsv  # record tag for later calibre step
#     ./fetch-books.sh --floor 5 booker.tsv          # keep 5 quota slots in reserve
#                                                    #   (overrides QUOTA_FLOOR env;
#                                                    #   --floor 0 disables the floor)
#     ./fetch-books.sh --refresh booker.tsv          # update statuses from Stacks
#     CONFIDENCE=0.55 ./fetch-books.sh summer.tsv     # lower the match threshold
#     MAX_PER_HOUR=20 ./fetch-books.sh booker.tsv      # be extra gentle (slower)
#     ./fetch-books.sh *.tsv                          # several lists in one run
#
#  TAGS: a "#tag:" header line (or --tag) sets calibre tags for the whole
#  list; separate multiple with commas (multi-word tags like "Booker Prize" work) ("#tag: prizewinner, booker").
#
#  DIRECTIVES: a "#skipstandard" header line (above the first book row) disables
#  the Standard Ebooks search for that list — the in-file equivalent of the
#  --skipstandard flag, for lists you KNOW aren't public-domain. Like #tag it
#  only affects rows below it, so keep it at the top.
#
#  FILTERS: results are restricted to ebook formats (FORMATS, never pdf) and to
#  English (LANGS=en). Override: FORMATS="epub" or LANGS="en fr" or LANGS="" (any).
#
#  RATE LIMIT: searches are paced to at most MAX_PER_HOUR (default 30) and never
#  faster than DELAY seconds apart, plus 0..JITTER random seconds so the cadence
#  isn't a perfect metronome. Set MAX_PER_HOUR=0 to disable the cap. Downloads
#  are Stacks' job and are self-limited by the slow-mirror servers, so only the
#  search rate is controlled here.
#
#  MIRROR HEALTH: before searching, if the check-mirrors state file is older
#  than STALE_SECS (default 3600s/1h) and check-mirrors.sh is found at
#  $CHECK_MIRRORS, it is run to refresh the WORKING-mirror list. Set the path:
#     CHECK_MIRRORS=~/scripts/check-mirrors.sh ./fetch-books.sh booker.tsv
#  Only mirrors marked WORKING are searched (full built-in list if no state).
#
#  STATUS COLUMN (4th field after author|title): the line lifecycle is
#     queued       -> sent to Stacks' download queue
#     downloading  -> Stacks is fetching it now      (after --refresh)
#     completed    -> Stacks finished the download    (after --refresh)
#     error        -> Stacks failed all mirrors       (after --refresh)
#     tagged       -> calibre tag applied             (set by tag-books.sh)
#     nomatch      -> search found nothing >= CONFIDENCE
#     pdf-only     -> only a PDF edition exists on Anna's (no ebook); terminal on
#                     normal runs, re-attempted under --retry
#  A 5th 'date' column records when the status last changed.
#  Run with --refresh (any time after queuing) to pull live state from Stacks'
#  /api/status and update the status+date columns. Uses the admin key.
#
#  FAST DOWNLOAD (Anna's membership): if you set fast_download.enabled:true and
#  a key in Stacks' config.yaml, fetch-books verifies via /api/status that the
#  key works and ABORTS if it doesn't (so books aren't silently sent down the
#  flaky free path). No key = free mirror path, used automatically.
#
#  QUOTA: a paid key has a daily download cap. fetch-books reads downloads_left
#  and STOPS queuing before driving it to/below QUOTA_FLOOR (default 5), so one
#  list run can't exhaust your daily allowance. Un-queued books stay 'pending'
#  for a later run. It projects from the starting figure (since Stacks consumes
#  quota as it downloads, lagging our queuing) and re-polls live every
#  QUOTA_RECHECK books (default 10) as a backstop. Set QUOTA_FLOOR=0 to disable.
#
#  RETRY: a normal run attempts only blank/pending lines (done/failed/nomatch/
#  pdf-only are left untouched). --retry additionally re-searches nomatch lines,
#  re-queues failed ones, and re-attempts pdf-only (in case an epub appeared).
#  done lines are never re-attempted on a normal/--retry run.
#
#  FORCE-RETRY: --force-retry (alias --verify) re-checks EVERY row against the
#  live Calibre library by md5 and re-downloads any "done" row (downloaded/queued/
#  downloading/completed/tagged) whose book is CONFIRMED ABSENT — so after deleting
#  books from Calibre, --force-retry re-fetches exactly those. A row is reset ONLY
#  on a clean confirmed-absence; if the library check can't run (calibre locked/
#  busy), the row is left untouched. Implies --retry.
#
#  QUOTA EFFICIENCY (v80): foreign-language candidates whose Anna's card
#  affirmatively declares a language outside LANGS are SKIPPED before download
#  (no quota spent), instead of being downloaded then rejected by the OPF gate.
#  Every actual fast-download spend is logged as a 'quota-spend [md5:...]' line so
#  quota-status.sh can account for all of them.
# =============================================================================

set -uo pipefail

# Force UTF-8 for every python3 helper in this script. The parsers print matched
# titles/authors (e.g. "Pedro Páramo") back to bash via command substitution. If
# this runs under a systemd timer / cron / stripped shell with no UTF-8 locale,
# python's stdout defaults to ASCII and print() of an accented string raises
# UnicodeEncodeError — which 2>/dev/null swallows, returning EMPTY to bash and
# producing a false nomatch. This would silently undo the v41 accent-decode fix
# whenever the locale isn't UTF-8. Exporting it here guarantees correct output
# regardless of the ambient LANG/LC_*.
export PYTHONIOENCODING=utf-8

# ---- cleanup on exit/interrupt ---------------------------------------------
# Track temp files (mktemp scratch + in-flight .part downloads) so a Ctrl-C or
# crash doesn't orphan them. CLEANUP_FILES are host paths; CLEANUP_PARTS are
# (container:path) pairs for downloads living inside DL_CONTAINER's mount.
CLEANUP_FILES=()
CLEANUP_PARTS=()
cleanup() {
    [ "${#CLEANUP_FILES[@]}" -gt 0 ] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null
    # one docker exec for ALL parts, not one per file: docker exec has ~0.2-0.5s
    # startup, so a per-part loop made Ctrl-C hang for seconds when many parts
    # were in flight. rm -f takes the whole array at once.
    if [ "${#CLEANUP_PARTS[@]}" -gt 0 ]; then
        docker exec "${DL_CONTAINER:-qbittorrent}" rm -f "${CLEANUP_PARTS[@]}" 2>/dev/null || true
    fi
}
# On a signal (Ctrl-C / kill), EXIT and let the EXIT trap clean up. Without the
# explicit exit, a bash INT trap runs the handler then RESUMES the interrupted
# command, so the loop carried on after Ctrl-C — which is why it felt
# uninterruptible. We do NOT call cleanup here: `exit 130` fires the EXIT trap
# below, which runs cleanup exactly once. Calling it here too would run cleanup
# twice — and the second run pays the docker exec startup penalty again,
# making Ctrl-C feel laggy right when you want it to die. 130 = killed by SIGINT.
on_signal() { echo; log "interrupted — cleaning up and stopping."; exit 130; }
trap cleanup EXIT
trap on_signal HUP INT TERM

# ---- config (override via env) ---------------------------------------------
STACKS_URL="${STACKS_URL:-http://localhost:7788}"
CONFIG_YAML="${CONFIG_YAML:-/home/robmorgan/gunit/stacks_config/config.yaml}"
FLARESOLVERR="${FLARESOLVERR:-http://localhost:8191/v1}"
CONTAINER="${CONTAINER:-gluetun}"
# Container used for the actual file download + move: it must be BOTH on the VPN
# (gluetun netns) AND have the media volume mounted. gluetun itself has the VPN
# but NOT the disk, so writes vanish. qbittorrent shares gluetun's netns and has
# /Nutmeg mounted, so it can both reach the partner server and write the file.
DL_CONTAINER="${DL_CONTAINER:-qbittorrent}"
# Owner the watcher expects on imported files (host uid:gid = robmorgan:media).
# Both download paths chown to this: SE (host-side) and Anna's (inside the
# container, via docker exec running as root). Set empty to skip chowning.
WATCHER_OWNER="${WATCHER_OWNER:-${SE_CHOWN:-2001:2002}}"
# Direct Anna's fast-download (bypasses Stacks). Reads the key from Stacks'
# config.yaml so you keep it in one place. AA_DOMAIN is the mirror used for the
# fast_download.json API call; DEST is the watched folder the watcher imports.
AA_KEY="${AA_KEY:-$(awk '/^fast_download:/{f=1} f&&/key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)}"
# Mirrors to try for the fast_download API, in order — falls through on 502 /
# unreachable so one flaky mirror doesn't abort the run. Override with a single
# or space-separated AA_DOMAINS.
AA_DOMAINS="${AA_DOMAINS:-${AA_DOMAIN:-annas-archive.se annas-archive.pk annas-archive.gd annas-archive.gl}}"
DEST="${DEST:-/Nutmeg/Media/Books/incoming/gunit_user_folders/shops@rob.me.uk}"
# An INVALID md5 used only to probe key/quota at preflight WITHOUT consuming a
# download (a valid md5 would burn one of your daily quota each run). Anna's
# returns the quota info in its error response for a bad md5.
PROBE_MD5="${PROBE_MD5:-00000000000000000000000000000000}"
MAXTIMEOUT="${MAXTIMEOUT:-60000}"
MIN_GOOD_BYTES="${MIN_GOOD_BYTES:-100000}"
MIRROR_STATE="${MIRROR_STATE:-$HOME/.cache/check-mirrors.state}"
CHECK_MIRRORS="${CHECK_MIRRORS:-$HOME/scripts/check-mirrors.sh}"  # set to your path
STALE_SECS="${STALE_SECS:-3600}"     # refresh mirror check if state older than this
CONFIDENCE="${CONFIDENCE:-0.6}"      # 0..1; top hit must score >= this to queue
DELAY="${DELAY:-3}"                  # min seconds between books (floor)
MAX_PER_HOUR="${MAX_PER_HOUR:-0}"    # 0 = no hourly cap; fast-download is quota-limited (50/day) so the search rate isn't the bottleneck. Set e.g. 60 to throttle if Anna's challenges the search.
QUOTA_FLOOR="${QUOTA_FLOOR:-3}"      # stop queuing when fast-download quota would drop to/below this (keep this many in reserve)
QUOTA_RECHECK="${QUOTA_RECHECK:-10}" # re-poll live downloads_left every N queued books
JITTER="${JITTER:-8}"                # +0..JITTER random secs added per wait (anti-metronome)
FORMATS="${FORMATS:-epub azw3 mobi fb2}"  # acceptable ebook formats, in preference order; never pdf
CAND_LIMIT="${CAND_LIMIT:-30}"           # max Anna's candidates EMITTED per book (the
                                         # sorted hit list handed to the download loop).
                                         # Was 3, which cut the list before any real
                                         # language check ran — a book whose first 3
                                         # equal-scored hits were all foreign editions
                                         # (The Alchemyst: ar/de/nl) failed even though
                                         # an English copy sat at hit #4+. Now we emit
                                         # the whole ranked list; MAX_ATTEMPTS bounds how
                                         # many are actually downloaded-and-checked.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-12}"       # max candidates the download loop will actually
                                         # fetch+OPF-check per book before giving up. The
                                         # language-rank sort puts English/unknown cards
                                         # first, so a real English edition is normally
                                         # attempt 1-2; this larger budget only bites on
                                         # books with many foreign editions ahead of the
                                         # English one. Bounds runaway retries on a
                                         # genuinely-broken record. A language reject is
                                         # an expected fall-through, not a hard failure.
# v83: SUB-CONFIDENCE VERIFY CANDIDATES. A contaminated listing can make the WRONG
# book the only candidate that clears CONFIDENCE (e.g. "Lock In 2 Head On" scores
# > 0.6 for a "Lock In" search while the REAL "Lock In: A Novel ..." — penalised
# for its subtitle — scores below 0.6 and never enters the hit list). The download
# loop then has only the imposter to try, rejects it by dc:title, and gives up.
# Fix: also accumulate candidates scoring in [VERIFY_FLOOR, CONFIDENCE) — the
# "verify-only" tier. These are NEVER trusted on score alone; they are tried ONLY
# after every confident candidate has failed, and ONLY the post-download dc:title
# check can admit them. So a low-scored-but-correct edition (the real Lock In) gets
# a chance: it downloads, its honest dc:title matches, and it's accepted; a
# low-scored-AND-wrong candidate downloads, fails dc:title, and is discarded.
# VERIFY_MAX_DLS bounds how many downloads the whole walk may spend (your "try 3"),
# so a genuinely-absent book can't burn quota chasing verify-tier candidates.
VERIFY_FLOOR="${VERIFY_FLOOR:-0.40}"     # min score to enter the verify-only tier
                                         # (below CONFIDENCE). Must still pass the
                                         # necessary title-word condition inside
                                         # book_match_fields (which returns 0 if a
                                         # wanted word is missing), so this isn't
                                         # "try anything" — it's "try plausible
                                         # title matches and let dc:title decide".
VERIFY_MAX_DLS="${VERIFY_MAX_DLS:-3}"    # max ACTUAL downloads (quota spends) the
                                         # candidate walk may make per book before
                                         # giving up. Caps the cost of verifying
                                         # contaminated/ambiguous listings.
# Hard guarantee: strip 'pdf' from FORMATS even if someone sets it explicitly, so
# the Anna's search never requests PDFs. (The post-download magic-byte guard is
# the real backstop, but this keeps banned formats out of the candidate list too.)
# Banned: pdf (handled separately for the library, never auto-downloaded), plus
# zip / lit / rtf / prc — junk or dead formats we never want imported.
BANNED_FORMATS="${BANNED_FORMATS:-pdf zip lit rtf prc}"
for _b in $BANNED_FORMATS; do
    FORMATS="$(printf '%s' "$FORMATS" | tr ' ' '\n' | grep -ivx "$_b" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
done
[ -z "$FORMATS" ] && FORMATS="epub azw3 mobi fb2"
LANGS="${LANGS:-en}"                 # language codes to allow (space-separated); empty = any
# Pre-fetch library check: before spending a download, see if the book is ALREADY
# in calibre (by annas:<md5> identifier, else strict title/author match) and skip
# if so, marking the row as in-library rather than burning a quota slot. Set
# LIB_CHECK=0 to disable (falls back to TSV-status dedup only).
LIB_CHECK="${LIB_CHECK:-1}"
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-/books/Calibre}"
CALIBRE_USER="${CALIBRE_USER:-2001:2002}"   # run calibredb as abc, not root
ID_SCHEME="${ID_SCHEME:-annas}"             # identifier scheme tag-books stamps md5 under
SE_ID_SCHEME="${SE_ID_SCHEME:-standard_ebooks}"  # scheme SE slugs are stored under (matches tag-lib)

# ---- Standard Ebooks (free public-domain source, tried before Anna's) -------
# SE is a static public site: no Cloudflare challenge, no membership key, no
# quota, no VPN required. We still route the HTML fetch through CONTAINER and
# the file download through DL_CONTAINER (which owns the disk mount), reusing
# the existing two-container split. SE_FIRST=0 disables and goes straight to
# Anna's. SE_FORMAT picks the download flavour; "compatible" is the plain epub
# (KOReader on Kindle reads it directly). SE match is AUTHORITATIVE: a confident
# match that fails to download is marked 'failed', NOT retried via Anna's.
SE_FIRST="${SE_FIRST:-1}"
SE_BASE="${SE_BASE:-https://standardebooks.org}"
SE_FORMAT="${SE_FORMAT:-compatible}"   # compatible | advanced | azw3 | kepub
# SE traffic runs on the HOST over the direct connection, not through gluetun:
# SE gates direct downloads by IP and the VPN (Romania) exit gets an HTML gate
# page instead of the epub, while otis's own connection gets the binary. Detect
# a host downloader once at startup. curl preferred (cleaner failure codes).
SE_DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then SE_DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then SE_DOWNLOADER="wget"; fi

# se_host_get URL -> echo body fetched on the host (direct connection). Used for
# SE SEARCH (download has its own streaming-to-file path in se_download). Empty
# echo on failure. Honours SE_DOWNLOADER.
se_host_get() {
    local url="$1"
    case "$SE_DOWNLOADER" in
        curl) curl -fsSL --connect-timeout 20 --max-time 60 "$url" 2>/dev/null ;;
        wget) wget -qO- --timeout=60 "$url" 2>/dev/null ;;
        *)    return 1 ;;
    esac
}
# Tag queue: on each successful download, append {md5,tags,title,author,queued_at}
# here so tag-queue.sh can tag the book once it's imported into calibre. Empty
# tags (no #tag: header, no --tag) means nothing to enqueue. TAG_QUEUE='' disables.
TAG_QUEUE="${TAG_QUEUE:-/home/robmorgan/gunit/config/tag-queue.json}"
LOG="${LOG:-${GUNIT_LOG:-$HOME/logs/gunit.log}}"   # shared log for all gunit scripts
GUNIT_TAG="f"                                       # short source tag in the merged log
# Interactive-mode (no file args) nnn picker start dir. Relative paths resolve
# against the script's own dir, so the default points at /gunit/tsv-lists/.
TSV_DIR="${TSV_DIR:-../tsv-lists}"

ALL_MIRRORS="${MIRRORS:-\
https://annas-archive.gd \
https://annas-archive.gl \
https://annas-archive.pk \
https://annas-archive.li \
https://annas-archive.se}"

DRY_RUN=0
RETRY=0
FORCE_RETRY=0   # --force-retry/--verify: re-check every row against Calibre by
                # md5; reset to pending (and re-attempt) any "done" row whose book
                # is CONFIRMED absent. Implies RETRY. Never resets on an unknown
                # (calibre lock/error) — only on a clean confirmed-absence.
REFRESH=0
TAG=""
WAIT=1   # v69: --wait is now the DEFAULT (poll for quota recovery and re-attempt
         # quota_blocked books until the list is clear or WAIT_MAX_SECS idle).
         # Use --no-wait for a single one-shot pass (the old default). Ctrl-C
         # cleanly stops a waiting run (the EXIT trap tidies .part-* files).
SKIP_STANDARD=0   # --skipstandard sets this; applied after arg parsing to force SE_FIRST=0
# --wait tunables: after a pass, if any books remain quota_blocked, keep the
# process open and re-attempt them once quota recovers. Poll every WAIT_INTERVAL
# seconds; only run a retry pass once downloads_left >= QUOTA_FLOOR + WAIT_MARGIN;
# give up after WAIT_MAX_SECS total.
WAIT_INTERVAL="${WAIT_INTERVAL:-1800}"   # 30 min between quota polls
WAIT_MARGIN="${WAIT_MARGIN:-10}"         # need floor+this many slots free to resume
WAIT_MAX_SECS="${WAIT_MAX_SECS:-86400}"  # 24h cap on the whole wait loop

# ---- args ------------------------------------------------------------------
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --retry)   RETRY=1; shift ;;
        --force-retry|--verify)
            # Re-verify every row against the live Calibre library by md5 and
            # re-download anything CONFIRMED missing. Implies --retry (also
            # reconsiders failed/nomatch/pdf-only). See the row dispatch below for
            # the confirmed-absence-only safety rule.
            FORCE_RETRY=1; RETRY=1; shift ;;
        --refresh) REFRESH=1; shift ;;
        --wait)    WAIT=1; shift ;;   # now the default; kept for explicitness/compat
        --no-wait|--once) WAIT=0; shift ;;   # single one-shot pass (old default)
        --skipstandard|--skip-standard)
            # skip the Standard Ebooks search entirely (go straight to Anna's) for
            # this run. Useful when you KNOW the list is non-public-domain (modern
            # prize lists etc.) and the per-book SE search is just dead latency.
            # Overrides any SE_FIRST env value. Set here AFTER args so it wins.
            SKIP_STANDARD=1; shift ;;
        --floor)
            # runtime override of QUOTA_FLOOR (the reserve of fast-download slots
            # we refuse to spend below). Overrides the QUOTA_FLOOR env/default for
            # this run only. Must be a non-negative integer; 0 disables the floor.
            [ "$#" -ge 2 ] || { echo "error: --floor requires an integer value" >&2; exit 1; }
            case "$2" in
                ''|*[!0-9]*) echo "error: --floor must be a non-negative integer, got '$2'" >&2; exit 1 ;;
            esac
            QUOTA_FLOOR="$2"
            shift 2 ;;
        --tag)
            # guard: shift 2 with no value left fails to advance -> infinite loop.
            [ "$#" -ge 2 ] || { echo "error: --tag requires a value" >&2; exit 1; }
            TAG="$(printf '%s' "$2" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"
            shift 2 ;;
        --help|-h) sed -n '2,48p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 1 ;;
        *)         FILES+=("$1"); shift ;;
    esac
done
# No file args: enter interactive mode (nnn picker) rather than erroring. The
# picker itself runs lower down, AFTER log() is defined, so it can log/colour.
if [ "${#FILES[@]}" -eq 0 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

# --skipstandard overrides the SE_FIRST env var: turn off the Standard Ebooks
# search for this whole run. Applied here (after parsing) so the flag wins no
# matter where it appeared on the command line.
[ "$SKIP_STANDARD" -eq 1 ] && SE_FIRST=0

mkdir -p "$(dirname "$LOG")" 2>/dev/null

# ---- coloured logging ------------------------------------------------------
# log() writes a plain line to the logfile AND a (possibly coloured) line to the
# terminal. Colour goes ONLY to the terminal copy — never into the logfile,
# where escape codes would corrupt it. Colour is auto-disabled when stderr is
# not a TTY (e.g. the systemd timer redirects to the log) or when NO_COLOR is
# set (https://no-color.org). The colour is chosen from the message content so
# every existing call site stays unchanged.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_BOLD=''
fi

# pick a colour for a message by matching distinctive substrings. Order matters:
# the first match wins, so errors/warnings are tested before softer states.
_log_colour() {
    case "$1" in
        FATAL*|*FATAL*)                                   printf '%s' "$C_BOLD$C_RED" ;;
        WARNING*|*WARNING*|*"not an epub"*|*"download failed"*|*"move failed"*) printf '%s' "$C_YEL" ;;
        "=== fetch-books"*|"=== refresh"*)                printf '%s' "$C_BOLD$C_CYN" ;;
        "→ "*|*"→ "*)                                     printf '%s' "$C_BOLD$C_BLU" ;;  # a book being processed
        *"SE downloaded"*|*"downloaded ->"*|*"downloaded  ("*) printf '%s' "$C_GRN" ;;     # success
        *"already in library"*|*"already-done"*)          printf '%s' "$C_DIM$C_GRN" ;;
        *nomatch*|*"not on Standard Ebooks"*)             printf '%s' "$C_DIM" ;;
        *"marking pdf-only"*|*"only PDF edition"*)        printf '%s' "$C_YEL" ;;
        *"force-retry:"*)                                 printf '%s' "$C_CYN" ;;
        *"skipping foreign-language candidate"*|*"foreign-language candidate(s) skipped"*) printf '%s' "$C_DIM" ;;
        *"quota-spend"*)                                  printf '%s' "$C_DIM" ;;
        *"library check unavailable"*|*"deferring"*|*"QUOTA STOP"*|*"quota_blocked"*|*"Anna's paused"*|*"quota exhausted"*|*"floor reached"*) printf '%s' "$C_YEL" ;;
        *"fast-download: ACTIVE"*|*"host downloader"*)    printf '%s' "$C_CYN" ;;
        *"(pacing"*)                                      printf '%s' "$C_DIM" ;;
        *FILE\ *queued:*)                                 printf '%s' "$C_BOLD" ;;        # per-file summary
        *)                                                printf '' ;;
    esac
}

log() {
    local msg="$*" ts; ts="$(date '+%F %T')"
    # plain to the shared logfile, tagged with the source script
    printf '%s  [%s] %s\n' "$ts" "$GUNIT_TAG" "$msg" >> "$LOG"
    # coloured (or plain, if disabled) to terminal — no tag needed there
    local col; col="$(_log_colour "$msg")"
    if [ -n "$col" ]; then
        printf '%s  %s%s%s\n' "$ts" "$col" "$msg" "$C_RESET" >&2
    else
        printf '%s  %s\n' "$ts" "$msg" >&2
    fi
}

# ---- interactive mode: nnn TSV picker --------------------------------------
# When called with no file args, open nnn in $TSV_DIR as a file picker. Select a
# .tsv (Enter on it); nnn writes the pick to a temp file (nnn -p) and quits, and
# we process that one list. Mirrors link-md v7's picker. nnn is REQUIRED here.
# A non-.tsv pick, or quitting with no selection, aborts cleanly.
if [ "${INTERACTIVE:-0}" -eq 1 ]; then
    HERE="$(cd "$(dirname "$0")" && pwd)"
    command -v nnn >/dev/null || {
        log "FATAL: no list args and nnn not installed for the picker. Install it on otis:  sudo apt install nnn   (or pass a LIST.tsv explicitly)"
        exit 1
    }
    # resolve TSV_DIR relative to the script dir if it's a relative path
    case "$TSV_DIR" in /*) tsvdir="$TSV_DIR" ;; *) tsvdir="$HERE/$TSV_DIR" ;; esac
    [ -d "$tsvdir" ] || { log "FATAL: TSV dir not found: $tsvdir"; exit 1; }

    pickfile="$(mktemp)"
    # -p <file>: write selection here and quit; open nnn at the TSV dir.
    nnn -p "$pickfile" "$tsvdir"
    # nnn -p writes NUL-separated paths; take the first.
    picked_tsv="$(tr '\0' '\n' < "$pickfile" 2>/dev/null | head -n1)"
    rm -f "$pickfile"

    [ -z "$picked_tsv" ] && { log "no file selected — aborting"; exit 0; }
    case "$picked_tsv" in
        *.tsv) : ;;
        *) log "selection is not a .tsv: $picked_tsv — aborting"; exit 1 ;;
    esac
    [ -f "$picked_tsv" ] || { log "selected file does not exist: $picked_tsv"; exit 1; }

    log "interactive: selected $picked_tsv"
    FILES=( "$picked_tsv" )
fi

# ---- api keys --------------------------------------------------------------
# config.yaml has two under "api:":  key (admin) and downloader_key.
# queue/add accepts the downloader key; /api/status needs the admin key.
ADMIN_KEY="$(awk '/^api:/{f=1} f&&/ key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
DOWNLOADER_KEY="$(awk '/^api:/{f=1} f&&/downloader_key:/{print $2; exit}' "$CONFIG_YAML" 2>/dev/null)"
# the queue uses the downloader key if present, else admin
API_KEY="$DOWNLOADER_KEY"
{ [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; } && API_KEY="$ADMIN_KEY"
if [ -z "${API_KEY:-}" ] || [ "$API_KEY" = "null" ]; then
    log "FATAL: could not read an api key from $CONFIG_YAML"; exit 1
fi

# ---- fetch Stacks status (admin key) ---------------------------------------
fetch_status() {  # echoes the raw JSON from /api/status
    curl -s "${STACKS_URL}/api/status?api_key=${ADMIN_KEY}"
}

# fast_api_call <md5> [path_index] [domain_index] -> echoes the JSON response
# from the first mirror that returns parseable JSON (not a 502/HTML/empty). Sets
# FAST_DOMAIN_USED to the mirror that worked. Returns 1 if all mirrors fail.
#
# path_index / domain_index are the API's OPTIONAL params (integers, 0+). When
# omitted the server picks a default mapping; for a file present in multiple
# collections or served from multiple partner servers, the default can resolve
# to an invalid combination — the API then returns "Invalid domain_index or
# path_index". Passing them explicitly lets the caller iterate combinations
# (see fast_download_md5) instead of being stuck with one bad default.
FAST_DOMAIN_USED=""
fast_api_call() {
    local md5="$1" path_index="${2:-}" domain_index="${3:-}" d url resp idx=""
    [ -n "$path_index" ]   && idx="${idx}&path_index=${path_index}"
    [ -n "$domain_index" ] && idx="${idx}&domain_index=${domain_index}"
    for d in $AA_DOMAINS; do
        url="https://${d}/dyn/api/fast_download.json?md5=${md5}&key=${AA_KEY}${idx}"
        # URL passed as a native arg to wget (no sh -c string), so a key with
        # shell metacharacters can't break out. --content-on-error first; if that
        # wget build lacks the flag (empty result), retry plain.
        resp="$(docker exec "$CONTAINER" wget -qO- --content-on-error --timeout=30 "$url" 2>/dev/null)"
        [ -z "$resp" ] && resp="$(docker exec "$CONTAINER" wget -qO- --timeout=30 "$url" 2>/dev/null)"
        # accept only if it parses as JSON
        if printf '%s' "$resp" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
            FAST_DOMAIN_USED="$d"
            printf '%s' "$resp"
            return 0
        fi
        # else try next mirror (502, HTML, empty, etc.)
    done
    return 1
}

# ---- fast-download preflight (direct Anna's API, no Stacks) -----------------
# Confirms the membership key works by calling the live fast_download API. We
# need a key (read from config or AA_KEY) — without one we can't download, so
# this aborts. With one, it reads the real downloads_left to seed the quota
# guard. The probe uses a known md5 with the key; a 200 + quota info = good.
preflight_fast_download() {
    if [ -z "${AA_KEY:-}" ] || [ "$AA_KEY" = "null" ]; then
        log "FATAL: no Anna's fast-download key found (fast_download.key in $CONFIG_YAML,"
        log "       or set AA_KEY=...). Direct download needs a membership key. Aborting."
        return 1
    fi
    # probe the key WITHOUT consuming a download, using an invalid md5, trying
    # mirrors in turn (one mirror's 502 shouldn't abort). Valid JSON with
    # error:"Record not found" proves API reachable AND key accepted (a bad key
    # gives a key/auth error). Bad-md5 probe carries no quota; that's read live.
    local resp err
    resp="$(fast_api_call "$PROBE_MD5")"
    if [ $? -ne 0 ] || [ -z "$resp" ]; then
        log "FATAL: fast-download API unreachable on all mirrors ($AA_DOMAINS)."
        log "       Mirrors may be down (502) or the VPN is blocked. Try again shortly."
        return 1
    fi
    err="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("__BADJSON__")' 2>/dev/null)"
    if [ "$err" = "__BADJSON__" ]; then
        log "FATAL: fast-download API returned unparseable response on $FAST_DOMAIN_USED."
        return 1
    fi
    case "$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')" in
        *key*|*secret*|*member*|*auth*|*account*|*invalid*)
            log "FATAL: fast-download key rejected by Anna's: \"$err\". Check the key/membership."
            return 1 ;;
    esac
    FAST_ACTIVE=1
    # Seed the quota floor NOW with an EXACT live read. The key-validity check
    # above used an invalid md5 (which may NOT return account info); the precise,
    # shelfmark-inclusive quota comes from quota-probe.sh, the shared helper that
    # quota-status.sh also uses. It queries the JSON API with a VALID md5 — which
    # returns account_fast_download_info WITHOUT spending a slot (you're only
    # charged when you fetch the download_url). Sourced like match-lib.sh.
    # Fallbacks: if the helper is missing or the probe fails, try to read quota
    # from the invalid-md5 response we already have; if that's empty too, learn
    # it live from the first download (QUOTA_START stays "").
    QUOTA_START=""
    local _qp="$(dirname "$0")/quota-probe.sh"
    if [ -f "$_qp" ]; then
        # source the shared helper for its quota_probe function. It reads its own
        # env vars via ${VAR:-default}; set them to fetch-books' values FIRST so
        # both agree on container/mirror (the helper won't override a set value).
        # Save + restore fetch-books' own PROBE_MD5 (the helper needs a VALID md5
        # and sets one; our invalid-md5 key-check already ran above, and nothing
        # else should inherit the changed value).
        local _saved_probe_md5="$PROBE_MD5"
        GLUETUN_CONTAINER="$CONTAINER"
        AA_DOMAIN="${AA_DOMAINS%% *}"   # first of fetch-books' mirror list
        unset PROBE_MD5                  # let the helper apply its own valid md5
        # shellcheck disable=SC1090
        . "$_qp"
        # remember the helper's VALID probe md5 so later live re-probes (e.g. the
        # --wait loop) can use it; fetch-books' own PROBE_MD5 is the invalid
        # key-check md5 and would make quota_probe fail.
        QP_PROBE_MD5="${PROBE_MD5:-}"
        if command -v quota_probe >/dev/null 2>&1 && quota_probe 2>/dev/null; then
            QUOTA_START="$QP_LEFT"
            [ -n "${QP_DONE:-}" ] && [ -n "${QP_CAP:-}" ] \
                && log "fast-download: live quota ${QP_LEFT} left (${QP_DONE}/${QP_CAP} used today, incl. shelfmark)"
        fi
        PROBE_MD5="$_saved_probe_md5"
    fi
    if [ -z "$QUOTA_START" ]; then
        QUOTA_START="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
    fi
    if [ -n "$QUOTA_START" ]; then
        log "fast-download: ACTIVE (key accepted; ${QUOTA_START} downloads left, floor ${QUOTA_FLOOR})"
        if [ "$QUOTA_START" -le "$QUOTA_FLOOR" ]; then
            # already at/under the floor: start in SE-only mode. SE (free) still
            # runs for every book; Anna's-only books get marked quota_blocked.
            ANNAS_QUOTA_OUT=1
            log "fast-download: only ${QUOTA_START} left (<= floor ${QUOTA_FLOOR}) — Anna's paused; Standard Ebooks still active."
        fi
    else
        log "fast-download: ACTIVE (key accepted; quota read live during run)"
    fi
    return 0
}

# ---- fast-download quota guard ---------------------------------------------
# Globals: FAST_ACTIVE (1 if fast-download on), QUOTA_START (downloads_left at
# preflight), QUEUED_RUN (count queued this run). The guard stops queuing before
# we'd drive the daily quota to/below QUOTA_FLOOR. Because Stacks consumes quota
# only as it downloads (lagging our queuing), we project from QUOTA_START minus
# what we've queued, AND re-poll the live figure every QUOTA_RECHECK books as a
# backstop. Returns 0 = ok to queue, 1 = stop (quota floor reached).
FAST_ACTIVE=0
QUOTA_START=""
QUEUED_RUN=0
ANNAS_QUOTA_OUT=0   # set once Anna's daily quota is spent; SE (free) still runs,
                    # but Anna's search/download is skipped and books only SE
                    # lacks are marked 'quota_blocked' for a later run.

quota_ok() {
    # only relevant when fast-download is the active path
    [ "$FAST_ACTIVE" -eq 1 ] || return 0
    # the most recent download reports the true remaining quota in QUOTA_LIVE;
    # prefer it over the projection when we have it.
    if [ -n "$QUOTA_LIVE" ]; then
        # QUOTA_LIVE is the reading AFTER the previous download; this call is
        # about to authorize ONE MORE, which lands us at QUOTA_LIVE-1. Stop when
        # that next download would breach the floor, not when we've already hit
        # it — otherwise we queue one book past the intended floor (the v58
        # symptom: lands at QUOTA_FLOOR exactly, one below the reserve).
        if [ "$(( QUOTA_LIVE - 1 ))" -lt "$QUOTA_FLOOR" ]; then
            log "  QUOTA STOP: ${QUOTA_LIVE} fast downloads left; one more would breach floor ${QUOTA_FLOOR}."
            log "  Remaining books left un-queued — run again after your daily reset."
            return 1
        fi
        return 0
    fi
    # before the first download we only have the projection from preflight
    if [ -n "$QUOTA_START" ]; then
        # QUEUED_RUN counts books already queued this run; this call wants ONE
        # more, so the post-queue remaining is (projected - 1). Same off-by-one
        # fix as the live branch: stop when the NEXT download breaches the floor.
        local projected=$(( ${QUOTA_START:-0} - ${QUEUED_RUN:-0} ))
        if [ "$(( projected - 1 ))" -lt "$QUOTA_FLOOR" ]; then
            log "  QUOTA STOP: projected ${projected} left; one more would breach floor ${QUOTA_FLOOR} (started ${QUOTA_START})."
            return 1
        fi
    fi
    return 0
}

# ---- refresh mode: update statuses from Stacks, don't fetch ----------------
# Builds an md5 -> state map from /api/status, rewrites each queued line's
# status + date. States use Stacks' own vocabulary: queued / downloading /
# completed / error.
refresh_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    local st; st="$(fetch_status)"
    if [ -z "$st" ] || ! printf '%s' "$st" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        log "FATAL: could not read /api/status (admin key wrong, or Stacks down)"; return 1
    fi

    # md5 -> state map as "md5 state" lines, parsed ONCE into a bash associative
    # array. The old code forked awk per TSV row to look up the map, which on a
    # 500-book list meant 500 awk processes; an in-memory assoc array makes each
    # lookup instant.
    local map
    map="$(printf '%s' "$st" | python3 -c '
import sys, json
s = json.load(sys.stdin)
state = {}
for item in s.get("queue", []):
    if item.get("md5"): state[item["md5"]] = "queued"
for item in s.get("current_downloads", []):
    if item.get("md5"): state[item["md5"]] = "downloading"
for item in s.get("recent_history", []):
    md5 = item.get("md5")
    if not md5: continue
    if item.get("error"): state[md5] = "error"
    elif item.get("completed_at"): state[md5] = "completed"
    else: state[md5] = "queued"
for md5, stt in state.items():
    print(md5, stt)
')"
    declare -A STATEMAP=()
    local _k _v
    while read -r _k _v; do
        [ -n "$_k" ] && STATEMAP["$_k"]="$_v"
    done <<< "$map"

    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp"); local n_upd=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac
        local a t s m d raw_nocr
        # split on '|' with one read instead of five cut forks (matches the
        # process_file parser). strip CR first; trim/strip per field after.
        raw_nocr="${raw%$'\r'}"
        IFS='|' read -r a t s m d <<< "$raw_nocr"
        s="$(printf '%s' "${s:-}" | tr -d '[:space:]')"
        m="$(printf '%s' "${m:-}" | tr -d '[:space:]')"
        # don't touch tagged lines or lines without an md5
        if [ "$s" = "tagged" ] || [ -z "$m" ]; then printf '%s\n' "$raw" >> "$tmp"; continue; fi
        local newstate="${STATEMAP[$m]:-}"
        if [ -n "$newstate" ] && [ "$newstate" != "$s" ]; then
            printf '%s|%s|%s|%s|%s\n' "$a" "$t" "$newstate" "$m" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            log "  $a — $t: $s -> $newstate"
            n_upd=$((n_upd+1))
        else
            printf '%s\n' "$raw" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
    log "FILE $file — $n_upd status update(s)"
}

if [ "$REFRESH" -eq 1 ]; then
    log "=== fetch-books v$FETCH_BOOKS_VERSION --refresh (querying Stacks status) ==="
    for f in "${FILES[@]}"; do refresh_file "$f"; done
    log "=== refresh done ==="
    exit 0
fi

# ---- refresh mirror health if state is stale -------------------------------
refresh_mirrors_if_stale() {
    local age=999999
    if [ -f "$MIRROR_STATE" ]; then
        age=$(( $(date +%s) - $(date -r "$MIRROR_STATE" +%s) ))
    fi
    if [ "$age" -lt "$STALE_SECS" ]; then
        log "mirror state is fresh (${age}s old, threshold ${STALE_SECS}s) — skipping check"
        return
    fi
    if [ ! -x "$CHECK_MIRRORS" ] && [ ! -f "$CHECK_MIRRORS" ]; then
        log "mirror state stale (${age}s) but check-mirrors not found at $CHECK_MIRRORS — using existing state"
        return
    fi
    log "mirror state stale (${age}s old) — running $CHECK_MIRRORS to refresh"
    # run it; its output goes to the log, its state file is what we consume
    NO_COLOR=1 STATE_FILE="$MIRROR_STATE" bash "$CHECK_MIRRORS" >>"$LOG" 2>&1 \
        && log "mirror check complete" \
        || log "mirror check exited non-zero — proceeding with whatever state exists"
}
refresh_mirrors_if_stale

# ---- which mirrors to use --------------------------------------------------
mirrors=()
if [ -n "${MIRRORS:-}" ]; then
    # explicit MIRRORS= on the command line wins over the state file
    read -ra mirrors <<< "$MIRRORS"
    log "using explicit MIRRORS override: ${mirrors[*]}"
elif [ -f "$MIRROR_STATE" ]; then
    while IFS='|' read -r host verdict; do
        [ "$verdict" = "WORKING" ] && mirrors+=("https://$host")
    done < "$MIRROR_STATE"
fi
if [ "${#mirrors[@]}" -eq 0 ]; then
    log "no WORKING mirrors in $MIRROR_STATE — using full built-in list"
    read -ra mirrors <<< "$ALL_MIRRORS"
fi

# ---- helpers ---------------------------------------------------------------
# Shared confidence matcher lives in match-lib.sh (norm, ge, author_match,
# meaningful_words, title_full_match, book_match_score) so fetch-books and
# tag-books agree on what a match is. Sourced here; fetch-specific helpers
# (score, pace, search_one) stay below.
. "$(dirname "$0")/match-lib.sh"

# token-overlap score of needle vs haystack, 0..1 (fraction of needle tokens
# present in haystack). fetch-only; not part of the shared gate.
score() {
    local needle haystack; needle="$(norm "$1")"; haystack=" $(norm "$2") "
    local hit=0 tot=0 w
    for w in $needle; do
        tot=$((tot+1))
        case "$haystack" in *" $w "*) hit=$((hit+1));; esac
    done
    [ "$tot" -eq 0 ] && { echo 0; return; }
    awk -v h="$hit" -v t="$tot" 'BEGIN{printf "%.3f", h/t}'
}

# format rank for candidate tie-breaking: lower = preferred. Among candidates
# with the SAME match score (very common — many identical copies of a popular
# book all score 1.000), we want a real ebook tried before a PDF, because the
# Anna's &ext= filter is metadata-only and leaks PDFs into an epub-only search,
# and the post-download magic-byte guard discards them. Rank follows the FORMATS
# preference order (epub<azw3<mobi<fb2 by default); any format NOT in FORMATS —
# pdf, unknown ("?"), or junk — sorts LAST, so it's only attempted once every
# real ebook candidate has been exhausted. Echoes an integer.
fmt_rank() {
    local want="$1" i=0 f
    for f in $FORMATS; do
        if [ "$f" = "$want" ]; then printf '%s' "$i"; return; fi
        i=$((i+1))
    done
    # not a preferred ebook format (pdf / ? / anything else): rank after them all
    printf '%s' "$(( i + 99 ))"
}

# language rank for candidate tie-breaking: lower = preferred. Mirrors the OPF
# language gate's allow logic but applied to the Anna's CARD label (an ISO code
# like "en"/"fr"/"de" scraped from the result card metadata line), purely to
# ORDER which candidates are attempted — it is NOT a gate. Fail-OPEN, matching
# epub_lang_ok: a blank/unknown label, or empty LANGS, ranks 0 (try it, the OPF
# gate decides for real). A label that prefix-matches any LANGS entry ranks 0.
# A label that affirmatively names a language NOT in LANGS ranks 1, so it sorts
# after the English/unknown candidates and only gets attempted if they run out.
# Echoes 0 or 1.
lang_rank() {
    local lab="$1" l
    [ -z "$lab" ] && { printf '0'; return; }           # unknown -> try it
    [ -z "$LANGS" ] && { printf '0'; return; }          # no restriction -> all 0
    for l in $LANGS; do
        # prefix match: card "en" matches LANGS "en" or "en-US"; LANGS "en"
        # matches a card "eng". Compare on the shorter 2-char stem either way.
        case "$l" in "$lab"*) printf '0'; return ;; esac
        case "$lab" in "$l"*) printf '0'; return ;; esac
    done
    printf '1'                                          # affirmatively disallowed
}


# pace between searches: honour both the DELAY floor and the MAX_PER_HOUR cap,
# plus a small random jitter so the cadence isn't a perfect (bot-like) metronome.
pace() {
    local base="$DELAY"
    if [ "$MAX_PER_HOUR" -gt 0 ]; then
        local by_rate=$(( 3600 / MAX_PER_HOUR ))
        [ "$by_rate" -gt "$base" ] && base="$by_rate"
    fi
    local jit=0
    [ "$JITTER" -gt 0 ] && jit=$(( RANDOM % (JITTER + 1) ))
    local wait=$(( base + jit ))
    log "    (pacing ${wait}s)"
    sleep "$wait"
}

# search one query across mirrors; echo "md5 | result_text" for the best hit
# that clears CONFIDENCE, else echo nothing.
search_one() {
    local author="$1" title="$2"
    local want_t want_a; want_t="$(norm "$title")"; want_a="$(norm "$author")"
    local q resp best_md5="" best_score=0 best_text=""
    local all_hits=""    # "score\tmd5\ttext" lines — all confident candidates from best mirror

    # URL-encode the query properly. The old "sed 's/ /+/g'" only handled
    # spaces, so titles with a colon, apostrophe, ampersand, question mark, or
    # any non-ASCII char (curly apostrophe U+2019 etc.) produced a malformed
    # query and Anna's returned nothing -> false nomatch. quote_plus encodes
    # everything safely (space->+, : -> %3A, ' -> %27, & -> %26, ...).
    # v81: FIRST strip index-hostile punctuation (notably '/', as in "Romeo
    # and/or Juliet") to spaces, BEFORE encoding. quote_plus would otherwise send
    # a literal '/' (%2F) that Anna's search handles poorly -> false nomatch. We
    # clean only the QUERY here; matching still uses the raw title via norm().
    local _qclean
    _qclean="$(printf '%s' "${title} ${author}" | sed 's#[/\\|<>]# #g; s/  */ /g')"
    q="$(printf '%s' "$_qclean" | python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.stdin.read().strip()))' 2>/dev/null)"
    [ -z "$q" ] && q="$(echo "$_qclean" | sed 's/ /+/g')"   # fallback

    # format filter: Anna's accepts repeated &ext=<fmt>; restrict to ebook
    # formats so PDFs (and other junk) never enter the candidate list.
    local extfilter="" f
    for f in $FORMATS; do extfilter="${extfilter}&ext=${f}"; done

    # language filter: Anna's accepts repeated &lang=<code>; restrict to English
    # (or whatever LANGS lists). Empty LANGS = no language restriction.
    local langfilter="" l
    for l in $LANGS; do langfilter="${langfilter}&lang=${l}"; done

    local base
    local mirrors_answered=0
    for base in "${mirrors[@]}"; do
        local url payload
        url="${base%/}/search?q=${q}${extfilter}${langfilter}"
        payload="{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":$MAXTIMEOUT}"
        resp="$(docker exec "$CONTAINER" sh -c \
            "wget -qO- --timeout=$(( MAXTIMEOUT/1000 + 15 )) \
             --post-data='$payload' --header='Content-Type: application/json' \
             '$FLARESOLVERR' 2>/dev/null")"
        # A dead mirror returns nothing (FlareSolverr can't reach it). Don't skip
        # silently — that turned "no mirror answered" into an indistinguishable
        # "nomatch". Log it so a search miss caused by dead mirrors is visible.
        if [ -z "$resp" ]; then
            log "      mirror unreachable: ${base#https://} (no data via FlareSolverr)"
            continue
        fi
        if [ "${#resp}" -lt "$MIN_GOOD_BYTES" ]; then
            log "      mirror returned too little (<${MIN_GOOD_BYTES}B): ${base#https://}"
            continue
        fi
        mirrors_answered=$((mirrors_answered+1))

        # FlareSolverr returns the page wrapped in a JSON envelope
        # ({"solution":{"response":"<html...>"}}) where non-ASCII chars are JSON
        # unicode escapes (á -> \u00e1). The parsers below do html.unescape but
        # NOT json-decode, so a title like "Pedro Páramo" arrived as the LITERAL
        # 12 chars "Pedro P\u00e1ramo" and norm() mangled it -> score 0.000, while
        # an unaccented "Pedro Paramo" entry matched. EVERY non-ASCII title/author
        # was silently failing. Decode the JSON envelope to real HTML ONCE here, so
        # \u00e1 becomes á and norm()'s accent-folding works. Falls back to the raw
        # string if it isn't JSON (e.g. a mirror that returns HTML directly).
        resp="$(printf '%s' "$resp" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    sol = d.get("solution") or {}
    print(sol.get("response", "") or raw)
except Exception:
    print(raw)
' 2>/dev/null)"
        [ -z "$resp" ] && { log "      mirror returned empty after JSON decode: ${base#https://}"; continue; }

        # Anna's LAZY-LOADS search results: each result card is shipped inside an
        # HTML comment (<!-- ... -->) that client-side JS un-comments and renders.
        # FlareSolverr returns the raw HTML BEFORE that JS runs, so the cards stay
        # commented and the parser found 0 results — while the only LIVE /md5/
        # links on the page were the "recent downloads" ticker (decoy books). A
        # book could thus be present yet invisible (e.g. Pedro Páramo: 0 parsed,
        # but 50 real cards once un-commented). Strip the comment MARKERS only
        # (not content) so the real cards become parseable. Harmless when a mirror
        # doesn't comment-wrap (no markers to strip). The field-separated matcher
        # still rejects ticker/decoy entries (e.g. an author literally named
        # "Pedro Paramo" on unrelated books).
        resp="${resp//<!--/}"
        resp="${resp//-->/}"

        # Extract candidates as "md5<TAB>title author" lines. welib and Anna's
        # structure their result cards differently, so use the right extractor.
        local candidates
        case "$base" in
            *welib*)
                # welib puts clean metadata in attributes: data-title / data-author,
                # near each /md5/<hash>. Parse structurally with python.
                candidates="$(printf '%s' "$resp" | python3 -c '
import sys, re, html
s = sys.stdin.read()
# find each md5 and the nearest data-title/data-author after it
out, seen = [], set()
for m in re.finditer(r"/md5/([a-f0-9]{32})", s):
    md5 = m.group(1)
    if md5 in seen: continue
    window = s[m.end(): m.end()+1200]
    t = re.search(r"data-title=\"([^\"]*)\"", window)
    a = re.search(r"data-author=\"([^\"]*)\"", window)
    if not t:
        # fall back to the <h2> heading text after the link
        h = re.search(r"<h2[^>]*>([^<]+)", window)
        t = h
    title = html.unescape(t.group(1)).strip() if t else ""
    author = html.unescape(a.group(1)).strip() if a else ""
    if title:
        seen.add(md5)
        out.append(f"{md5}\t{title}\t{author}\t\t")
for line in out[:12]:
    print(line)
' 2>/dev/null)"
                ;;
            *)
                # Anna's result cards. CRITICAL: the page opens with a
                # "recent downloads" ticker (js-recent-downloads-scroll) full of
                # /md5/ links to UNRELATED books, ~150KB before the real results.
                # Parsing from byte 0 scored the ticker — that mis-matched
                # "The Pretender" to "The Fear of Falling" etc. So we first cut
                # to the results region (anchored on the "aarecord" marker the
                # result cards use) and parse only from there.
                #
                # Each real card carries clean fields:
                #   data-content="<title>"  data-content="<author>"   (in the
                #   fallback-cover block), and a path hint
                #   "<collection>/<author>/<Title>_<id>.<ext>".
                # We emit "md5<TAB>title<TAB>author" so the scorer compares
                # title-to-title and author-to-author — no blob contamination.
                candidates="$(printf '%s' "$resp" | python3 -c '
import sys, re, html
s = sys.stdin.read()
# 1. drop everything before the results region. If the anchor is absent
#    (markup changed), produce NO candidates rather than parse the ticker —
#    a clean nomatch is the safe failure direction.
anchor = s.find("aarecord")
if anchor < 0:
    sys.exit(0)
s = s[anchor:]

seen, out = set(), []
for m in re.finditer(r"/md5/([a-f0-9]{32})", s):
    md5 = m.group(1)
    if md5 in seen: continue
    # window for THIS card: up to the next result md5
    card = s[m.end(): m.end()+2500].split("/md5/")[0]

    title = author = ""
    # primary: the two data-content attributes (title first, author second)
    dc = re.findall(r"data-content=\"([^\"]*)\"", card)
    if len(dc) >= 1: title  = html.unescape(dc[0]).strip()
    if len(dc) >= 2: author = html.unescape(dc[1]).strip()

    # fallback: the path hint  <collection>/<author>/<Title>_<id>.<ext>
    if not title or not author:
        ph = re.search(r"[a-z0-9-]+/[^/<>\"]+/[^/<>\"]+_\d+\.[a-z0-9]+", card)
        if ph:
            parts = ph.group(0).split("/")
            if len(parts) >= 3:
                if not author: author = parts[-2].strip()
                if not title:
                    t = re.sub(r"_\d+\.[a-z0-9]+$", "", parts[-1])
                    title = t.replace("_", " ").strip()

    # format of THIS card. Anna shows it in the metadata line, e.g.
    # "English [en], epub, 1.2MB". The &ext= URL filter is metadata-only and
    # unreliable (PDFs leak through a restricted-to-epub search), so we capture
    # the real per-card format and let the caller rank ebook formats above pdf.
    # First real format token wins; default "?" when none is visible.
    fm = re.search(r"\b(epub|azw3|mobi|fb2|pdf|cbz|cbr|djvu|lit|rtf|prc)\b", card, re.I)
    fmt = fm.group(1).lower() if fm else "?"

    # language label of THIS card, from the same metadata line. Anna shows it as
    # a bracketed ISO code, e.g. "English [en]". This is METADATA only — it is
    # NOT a trustworthy gate (the OPF language check post-download is the real
    # guard), but it IS a usable SORT key: among equally-scored copies of a book,
    # an "[en]" card should be tried before an "[fr]"/"[de]" one, so foreign
    # editions do not fill the CAND_LIMIT slots and starve the English edition
    # (the Vow of Thieves / Alchemyst / Half King failure: 3 foreign candidates
    # tried, English never reached). Capture the bracketed code; "" if none.
    lm = re.search(r"\[([a-z]{2,3})\]", card)
    lang = lm.group(1).lower() if lm else ""

    if title:
        seen.add(md5)
        # tab-separated fields; author may be empty (scorer handles it). fmt is
        # the 4th field and lang the 5th, both used only for tie-break ordering.
        out.append(f"{md5}\t{title}\t{author}\t{fmt}\t{lang}")

for line in out[:30]:
    print(line)
' 2>/dev/null)"
                ;;
        esac

        # NOTE: no bare-hash fallback here. If the HTML parse yields no
        # candidates, we have no title/author metadata to score against —
        # scoring a bare hash always fails (0.000) and queuing an unscored hash
        # is exactly the wrong-book risk. So an empty parse => clean nomatch.

        local line md5 cand_t cand_a cand_fmt cand_lang s
        # split tab fields with bash read (Anna's parser emits
        # md5\ttitle\tauthor\tfmt\tlang; welib emits the same arity with empty
        # fmt+lang -> ranked as unknown/neutral). No per-candidate cut forks.
        # Validate md5 shape inline.
        while IFS=$'\t' read -r md5 cand_t cand_a cand_fmt cand_lang; do
            case "$md5" in
                *[!a-f0-9]*|"") continue ;;     # not a clean hex string
            esac
            [ "${#md5}" -eq 32 ] || continue
            # Score field-to-field, both interpretations of the LIST entry
            # (Author|Title or Title|Author). want_t/want_a are this list line's
            # two fields. book_match_fields compares each candidate field to the
            # right wanted field — no blob, so a stray word elsewhere on the page
            # can't leak in. Title gate is strict; weak title needs author (with
            # the order-or-reversal rule from match-lib).
            s="$(book_match_fields "$want_t" "$want_a" "$cand_t" "$cand_a")"
            if ge "$s" "$best_score"; then
                best_score="$s"; best_md5="$md5"
                best_text="$(printf '%s — %s' "$cand_t" "$cand_a" | cut -c1-80)"
            fi
            # accumulate ALL confident candidates for multi-attempt fallback.
            # v83: ALSO accumulate sub-confidence candidates down to VERIFY_FLOOR
            # into a SEPARATE verify tier (tier 1), so a contaminated listing that
            # leaves the wrong book as the only >=CONFIDENCE hit doesn't starve the
            # real (lower-scored) edition. book_match_fields already returns 0 if a
            # wanted title word is missing, so a verify-tier candidate still had to
            # match the wanted title words — it's "plausible but not confident",
            # admitted only by the post-download dc:title check. Tier 0 = confident
            # (tried first), tier 1 = verify-only (tried after). Tier is the primary
            # sort key so all confident candidates are exhausted before any verify
            # one is downloaded.
            local _tier=""
            if ge "$s" "$CONFIDENCE"; then _tier=0
            elif ge "$s" "$VERIFY_FLOOR"; then _tier=1
            fi
            if [ -n "$_tier" ]; then
                local _ct fmtrank langrank
                _ct="$(printf '%s — %s' "$cand_t" "$cand_a" | cut -c1-80)"
                fmtrank="$(fmt_rank "$cand_fmt")"
                langrank="$(lang_rank "$cand_lang")"
                if [ -z "$all_hits" ]; then
                    all_hits="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$_tier" "$s" "$langrank" "$fmtrank" "$md5" "$_ct")"
                else
                    all_hits="${all_hits}
$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$_tier" "$s" "$langrank" "$fmtrank" "$md5" "$_ct")"
                fi
            fi
        done <<< "$candidates"

        # found at least one CONFIDENT candidate on this mirror — stop searching.
        # v83: a verify-only (tier 1) hit does NOT stop the mirror walk — another
        # mirror might have the real book as a confident hit, which we'd prefer.
        case "$all_hits" in
            0$'\t'*|*$'\n'0$'\t'*) break;;   # some line begins with tier 0
        esac
    done

    if [ -n "$all_hits" ]; then
        # all_hits lines: tier<TAB>score<TAB>langrank<TAB>fmtrank<TAB>md5<TAB>text
        # v83: sort by TIER asc (k1) first — every confident (tier 0) candidate is
        # emitted before any verify-only (tier 1) one, so the download loop tries
        # all confident candidates before spending quota on verify-tier guesses.
        # Then score DESC (k2), language-rank ASC (k3), format-rank ASC (k4) as
        # before. Emit md5<TAB>score<TAB>text<TAB>langrank for the download loop.
        printf '%s\n' "$all_hits" \
            | sort -t$'\t' -k1,1n -k2,2rn -k3,3n -k4,4n \
            | head -n "${CAND_LIMIT:-30}" \
            | awk -F'\t' 'BEGIN{OFS="\t"}{print $5,$2,$6,$3}'   # md5 score text langrank
    elif [ "$mirrors_answered" -eq 0 ]; then
        # no mirror responded at all — this is NOT a clean "book not found", it's
        # an infrastructure miss. Signal it so the caller can leave the row
        # pending (retry later) instead of burning it as nomatch.
        printf 'UNREACHABLE\n'
    fi
}

# ---- Standard Ebooks search ------------------------------------------------
# Search SE for the book; if a card clears CONFIDENCE, echo
#   "<author-slug>/<title-slug>\t<score>\t<cand_title> — <cand_author>"
# else echo nothing.
#
# SE result markup is RDFa/schema.org. Each book is an <li> whose about=
# attribute holds the canonical /ebooks/<author>/<title>[/<translator>] path;
# the title is the first <span property="schema:name"> and the author is the
# first schema:name span inside the <p class="author"> block (so a "Translated
# by" name that follows is ignored). We parse per-card structurally and score
# with the SAME shared matcher Anna's uses, so the gate is identical.
#
# Two passes: first "title author" (precise), then — if that found nothing —
# "title" alone. The title-only retry rescues books whose list author is
# misspelled or formatted differently from SE's (e.g. "George Elliot" vs SE's
# "George Eliot"); it's SAFE because book_match_fields still gates every
# candidate, so a bare-title query can widen what SE returns but cannot queue a
# wrong book. SE_TITLE_ONLY_RETRY=0 disables the second pass.
SE_TITLE_ONLY_RETRY="${SE_TITLE_ONLY_RETRY:-1}"

# parse SE search HTML on stdin -> "slug<TAB>title<TAB>author" candidate lines
se_parse_candidates() {
    python3 -c '
import sys, re, html
s = sys.stdin.read()
out, seen = [], set()
for cm in re.finditer(r"<li\b[^>]*\babout=\"(/ebooks/[^\"]+)\"", s):
    slug = cm.group(1)[len("/ebooks/"):].strip("/")
    if not slug or slug in seen:
        continue
    rest = s[cm.end():]
    nxt = re.search(r"<li\b[^>]*\babout=\"/ebooks/|</ol>", rest)
    card = rest[:nxt.start()] if nxt else rest
    tm = re.search(r"property=\"schema:name\"[^>]*>\s*([^<]+?)\s*<", card)
    title = html.unescape(tm.group(1)).strip() if tm else ""
    author = ""
    pm = re.search(r"<p class=\"author\"[^>]*>(.*?)</p>", card, re.S)
    if pm:
        am = re.search(r"property=\"schema:name\"[^>]*>\s*([^<]+?)\s*<", pm.group(1))
        if am:
            author = html.unescape(am.group(1)).strip()
    if title:
        seen.add(slug)
        out.append((slug, title, author))
for slug, title, author in out[:48]:
    print(f"{slug}\t{title}\t{author}")
' 2>/dev/null
}

# fetch + parse + score one SE query string. Echoes the best
# "slug\tscore\ttext" that clears CONFIDENCE for the wanted title/author, else
# nothing. want_t/want_a are the list's two fields (bidirectional matcher).
se_query_and_score() {
    local query="$1" want_t="$2" want_a="$3"
    local q url resp candidates
    # v81: strip index-hostile punctuation ('/', backslash, pipe, angle brackets)
    # to spaces before encoding, same as the Anna's query — a literal '/' in
    # "Romeo and/or Juliet" otherwise yields a false no-result here too.
    q="$(printf '%s' "$query" | sed 's#[/\\|<>]# #g; s/  */ /g' | python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.stdin.read().strip()))' 2>/dev/null)"
    [ -z "$q" ] && return 0
    url="${SE_BASE%/}/ebooks?query=${q}&sort=relevance&view=grid&per-page=48"
    # fetch on the host (direct), consistent with se_download — keeps SE entirely
    # off the VPN so a gated exit can't break search either.
    resp="$(se_host_get "$url")"
    [ -z "$resp" ] && return 0
    candidates="$(printf '%s' "$resp" | se_parse_candidates)"
    [ -z "$candidates" ] && return 0

    local best_slug="" best_score=0 best_text="" slug cand_t cand_a sc
    local want_t_norm want_a_norm
    want_t_norm="$(norm "$want_t")"; want_a_norm="$(norm "$want_a")"
    while IFS=$'\t' read -r slug cand_t cand_a; do
        [ -z "$slug" ] && continue
        sc="$(book_match_fields "$want_t" "$want_a" "$cand_t" "$cand_a")"
        # SE-ONLY exact-title acceptance: the shared matcher requires author
        # corroboration for SHORT titles (the "Eragon" subset guard), so a
        # 1-word title like "Middlemarch" scores 0 when the list author is
        # misspelled ("George Elliot" vs SE's "George Eliot"). For SE's small,
        # curated public-domain catalogue an EXACT normalized title match
        # (equality, not subset) is a safe standalone signal — it cannot match a
        # longer different title. The list field order is ambiguous, so accept if
        # the candidate title exactly equals EITHER wanted field. Grant the 0.7
        # title-only floor. SE-only; match-lib and Anna's keep the stricter rule.
        #
        # BUT the floor must NOT override a CONTRADICTING author: an exact title
        # by a DIFFERENT author is a different book (e.g. "The Secret History" by
        # Donna Tartt vs Procopius's "The Secret History"). Only apply the floor
        # when the candidate author is absent, or shares at least one word with a
        # wanted field (which covers misspellings — "Elliot"/"Eliot" share
        # "George"). A present-but-zero-overlap author blocks the floor.
        local cand_t_norm; cand_t_norm="$(norm "$cand_t")"
        if { [ -n "$want_t_norm" ] && [ "$cand_t_norm" = "$want_t_norm" ]; } \
           || { [ -n "$want_a_norm" ] && [ "$cand_t_norm" = "$want_a_norm" ]; }; then
            local author_ok=0
            if [ -z "$(norm "$cand_a")" ]; then
                author_ok=1   # absent author can't contradict
            elif ge "$(author_match "$want_t" "$cand_a")" "0.001" \
              || ge "$(author_match "$want_a" "$cand_a")" "0.001"; then
                author_ok=1   # shares a word (covers misspellings)
            fi
            [ "$author_ok" -eq 1 ] && { ge "$sc" "0.700" || sc="0.700"; }
        fi
        if ge "$sc" "$best_score"; then
            best_score="$sc"; best_slug="$slug"
            best_text="$(printf '%s — %s' "$cand_t" "$cand_a" | cut -c1-80)"
        fi
    done <<< "$candidates"

    if [ -n "$best_slug" ] && ge "$best_score" "$CONFIDENCE"; then
        printf '%s\t%s\t%s\n' "$best_slug" "$best_score" "$best_text"
    fi
}

se_search_one() {
    local f1="$1" f2="$2" hit
    # pass 1: both fields together (precise)
    hit="$(se_query_and_score "${f1} ${f2}" "$f1" "$f2")"
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
    # pass 2: single-field retries. The list field order is ambiguous (the
    # matcher is bidirectional for exactly this reason), so we don't know which
    # field is the title. Query EACH field alone; the one that is the real title
    # will find + accept the book (exact-title path), the other returns nothing.
    # This rescues a misspelled/mis-formatted author: searching the title alone
    # avoids the bad author token that made SE's search return zero results.
    if [ "$SE_TITLE_ONLY_RETRY" = "1" ]; then
        local fld
        for fld in "$f1" "$f2"; do
            [ -z "$fld" ] && continue
            hit="$(se_query_and_score "$fld" "$f1" "$f2")"
            if [ -n "$hit" ]; then
                log "    SE: matched on single-field retry (list author may differ from SE's)"
                printf '%s\n' "$hit"; return 0
            fi
        done
    fi
    return 0
}

# ---- Standard Ebooks download ----------------------------------------------
# Given a slug path (author/title[/translator]), build the epub download URL and
# fetch it into DEST. CRITICAL DETAILS learned the hard way:
#
#  * The bare download URL returns the "Your Download Has Started!" HTML
#    interstitial (Content-Type application/xhtml+xml), NOT the epub. A real
#    browser gets the binary by appending ?source=download — that query param is
#    the bypass and returns Content-Type application/epub+zip. We append it.
#  * That interstitial page carries a honeypot link that BANS YOUR IP FOR 24
#    HOURS if a crawler follows it. We never parse or follow links on it — we
#    only request the known URL + ?source=download directly.
#  * SE gates direct downloads by IP. Through the gluetun VPN (Romania exit) the
#    request returns the interstitial; over otis's OWN direct connection it
#    returns the epub. So SE downloads run ON THE HOST (curl/wget here), NOT
#    through DL_CONTAINER/gluetun. SE is a legal public-domain source, so there's
#    no reason to route it via the VPN anyway.
#  * The host (otis) runs this as uid 2001 / gid 2002 (= the owner the watcher
#    expects), so files land correctly owned; we still chown/chmod defensively.
#
# Same placement discipline as Anna's: temp .part, validate, atomic move. PK
# magic-byte check rejects any non-epub (e.g. an interstitial that slipped
# through). Returns 0 ok, 1 fail.
SE_CHOWN="${SE_CHOWN:-$WATCHER_OWNER}"   # owner to set on SE files (= WATCHER_OWNER); empty = skip

# Map SE_FORMAT to the link LABEL SE uses on the book page, so we scrape the
# correct download href rather than guessing the filename (which differs for
# translated works, where the epub filename includes the translator slug).
se_format_label() {
    case "$1" in
        compatible) echo "Compatible epub" ;;
        advanced)   echo "Advanced epub" ;;
        azw3)       echo "azw3" ;;
        kepub)      echo "kepub" ;;
        *)          echo "" ;;
    esac
}

se_download() {
    local slug="$1"
    local page page_url href url tmp fname label
    label="$(se_format_label "$SE_FORMAT")"
    [ -z "$label" ] && { log "    SE: unknown SE_FORMAT '$SE_FORMAT'"; return 1; }

    # Fetch the book PAGE (host/direct) and extract the real download href for
    # the requested format by its visible label. This is authoritative — no
    # filename guessing, so translated works (3-segment slugs whose epub file
    # includes the translator) resolve correctly. We do NOT follow links on the
    # download interstitial (the honeypot); we read the book page's own list.
    page_url="${SE_BASE%/}/ebooks/${slug}"
    page="$(se_host_get "$page_url")"
    if [ -z "$page" ]; then
        log "    SE: could not fetch book page $page_url"; return 1
    fi
    href="$(printf '%s' "$page" | SE_LABEL="$label" python3 -c '
import sys, re, html, os
s = sys.stdin.read(); want = os.environ["SE_LABEL"].lower()
best = ""
for m in re.finditer(r"<a\b[^>]*href=\"([^\"]*/downloads/[^\"]+)\"[^>]*>(.*?)</a>", s, re.S):
    href = m.group(1)
    text = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip().lower()
    if text == want:
        best = href; break
print(best)
' 2>/dev/null)"
    if [ -z "$href" ]; then
        # Distinguish a PLACEHOLDER page (book not yet public domain — SE has a
        # catalogue entry but NO download links at all) from a real page missing
        # just this one format. A placeholder has zero /downloads/ links and an
        # "ebook-placeholder" article; in that case the book genuinely isn't
        # available on SE, so the caller should fall through to Anna's rather
        # than mark it failed. Return 3 = "not available on SE (placeholder)".
        if ! printf '%s' "$page" | grep -q '/downloads/'; then
            log "    SE: '$slug' is a placeholder (not yet public domain) — no files on SE"
            return 3
        fi
        log "    SE: no '$label' download link on $page_url (this format unavailable)"
        return 1
    fi
    # absolute URL + the ?source=download bypass (bare URL returns the HTML
    # "Your Download Has Started!" interstitial, not the epub).
    case "$href" in
        http*) url="$href" ;;
        /*)    url="${SE_BASE%/}${href}" ;;
        *)     url="${SE_BASE%/}/${href}" ;;
    esac
    case "$url" in *\?*) url="${url}&source=download" ;; *) url="${url}?source=download" ;; esac

    # filename in DEST: SE's own basename, minus any query string
    fname="$(printf '%s' "$url" | sed 's/?.*//; s/&.*//; s#.*/##')"
    [ -z "$fname" ] && fname="$(printf '%s' "$slug" | tr '/' '_').epub"

    tmp="${DEST}/.part-se-$(printf '%s' "$slug" | tr '/' '-')"
    # host-side cleanup (this file lives on the host now, not in a container)
    CLEANUP_FILES+=("$tmp")

    # download on the HOST over the direct connection (NOT via gluetun). Prefer
    # curl, fall back to wget; both are checked at startup (se_host_downloader).
    local dl_rc=0
    if [ "$SE_DOWNLOADER" = "curl" ]; then
        curl -fsSL --connect-timeout 30 --max-time 180 -o "$tmp" "$url" 2>/dev/null || dl_rc=$?
    else
        wget -q --timeout=180 -O "$tmp" "$url" 2>/dev/null || dl_rc=$?
    fi
    if [ "$dl_rc" -ne 0 ]; then
        log "    SE download failed ($SE_DOWNLOADER rc=$dl_rc): $url"
        rm -f "$tmp" 2>/dev/null; return 1
    fi
    if [ ! -s "$tmp" ]; then
        log "    SE download produced empty file"; rm -f "$tmp" 2>/dev/null; return 1
    fi
    # CONTENT CHECK: epub/azw3/kepub are ZIP containers — first two bytes "PK".
    # An interstitial/error HTML page starts with '<'. Reject anything non-PK so
    # a gate page never gets shipped as a ".epub" the reader can't open.
    local magic; magic="$(head -c2 "$tmp" 2>/dev/null)"
    if [ "$magic" != "PK" ]; then
        log "    SE download is NOT an epub (magic='$magic', not 'PK') — got the"
        log "    interstitial/gate page instead of the binary. URL: $url"
        log "    first bytes: $(head -c80 "$tmp" 2>/dev/null | tr -d '\0' | cut -c1-80)"
        rm -f "$tmp" 2>/dev/null; return 1
    fi

    if ! mv "$tmp" "${DEST}/${fname}" 2>/dev/null || [ ! -s "${DEST}/${fname}" ]; then
        log "    SE move failed or dest missing/empty: ${fname}"
        rm -f "$tmp" "${DEST}/${fname}" 2>/dev/null; return 1
    fi
    # ownership/perms so the watcher imports cleanly. We already run as 2001:2002
    # so this is usually a no-op; it's defensive for root-timer runs. Failure is
    # non-fatal (the file is in place; the timer's chown dance can fix perms).
    [ -n "$SE_CHOWN" ] && chown "$SE_CHOWN" "${DEST}/${fname}" 2>/dev/null || true
    chmod 664 "${DEST}/${fname}" 2>/dev/null || true
    log "    SE downloaded -> ${fname}  (standardebooks.org, host/direct, no quota used)"
    return 0
}

# --- pre-fetch library check ------------------------------------------------
# Is this book ALREADY in calibre? Checks (1) the exact annas:<md5> identifier
# (only present if tag-books stamped it), then (2) a strict title/author match
# against the library's stored metadata using the SAME matcher as everything
# else (book_match_score from match-lib). Echoes the calibre id if found (so the
# caller can log it), nothing if not. LIB_CHECK=0 disables.
# Read calibredb as the container's DEFAULT user (root) — the user the always-on
# GUI app runs as — so these reads SHARE its lock context and succeed even while
# the GUI holds the library lock. Running as a different user (2001:2002) is
# refused with "Another calibre program is running", which previously came back
# empty (stderr was hidden) and made already_in_library wrongly report "not in
# library" -> fetch-books then spent a download on a book already owned. We keep
# stderr now so callers can detect a real failure vs a genuine no-match.
# calibredb access (cdb_ro reads via the lock-free content server, cdb_rw writes
# on-disk as 2001:2002) and the lock helpers (cdb_locked / cdb_ids /
# cdb_search_ok / cdb_search_retry / cdb_list_retry) now live in the shared
# calibre-lib.sh, so every gunit script agrees on calibre access. Sourcing it also
# auto-loads the content-server creds from ~/gunit/config/calibre-server.env. If
# CALIBRE_SERVER_URL is unset (creds file absent), cdb_ro transparently falls back
# to the on-disk --library-path, so this degrades safely. See that file's header
# for the full rationale (the GUI lock race that sent owned books back to Anna's).
. "$(dirname "$0")/calibre-lib.sh"

# returns 0 and echoes a calibre id if the book is already present; 1 if not.
# returns 2 if the library check could not run (calibredb error) — caller should
# treat 2 as "unknown", and (to avoid wasting quota on a possible duplicate)
# skip the download rather than assume it's absent.
already_in_library() {
    local f1="$1" f2="$2" md5="$3"
    [ "$LIB_CHECK" = "1" ] || return 1

    # classify WHY a read failed, into LIB_CHECK_REASON, so the caller can log a
    # message that names the real cause instead of guessing "calibre busy?". Set
    # right before each `return 2`.
    _lib_reason() {
        local out="$1"
        if printf '%s' "$out" | grep -qiE 'Connection reset by peer|Connection refused|\[Errno (104|111)\]|URLError|urlopen error|Max retries|HTTP Error (50[234])'; then
            LIB_CHECK_REASON="content server unreachable (is the calibre GUI/server up?)"
        elif printf '%s' "$out" | grep -qi 'Another calibre program'; then
            LIB_CHECK_REASON="library locked by another calibre program"
        elif printf '%s' "$out" | grep -qiE 'HTTP Error 401|Unauthorized|Forbidden'; then
            LIB_CHECK_REASON="content server auth rejected (check creds)"
        else
            LIB_CHECK_REASON="calibre read error"
        fi
    }

    # 1. exact by md5 identifier
    if [ -n "$md5" ]; then
        local ex idn
        ex="$(cdb_search_retry "identifiers:${ID_SCHEME}:${md5}")"
        cdb_locked "$ex" && { _lib_reason "$ex"; return 2; }   # still locked after retries
        # if the result is neither a clean match nor a clean no-match, the read
        # genuinely failed (not just worker noise) — treat as unknown.
        if ! cdb_search_ok "$ex"; then _lib_reason "$ex"; return 2; fi
        idn="$(cdb_ids "$ex" | head -1)"
        if [ -n "$idn" ]; then
            # v81: TITLE SANITY on the md5 match. An md5 identifier match is normally
            # authoritative — BUT a contaminated Anna's listing can stamp the WRONG
            # md5 onto a book (e.g. Head On's file carries an md5 that a "Lock In"
            # search keeps selecting; that md5 is on the library's Head On record).
            # Trusting md5 alone then makes "Lock In" resolve to Head On and skip the
            # real download forever. So we sanity-check: does the FOUND book's title
            # actually contain the wanted title's meaningful words? If not, this md5
            # match is suspect — DON'T accept it; fall through to the title/author
            # path (which will correctly NOT find Lock In and let the download
            # proceed). f1/f2 are the list's two fields (title/author either order);
            # we accept the match if EITHER field's words are satisfied by the found
            # title, so the real-author-as-f2 case can't cause a false reject.
            local found_title tg1 tg2 _rawft
            _rawft="$(cdb_list_retry -f title -s "id:$idn" --for-machine 2>/dev/null)"
            # DIAGNOSTIC (v82.1): log what we read + the gate decisions, so a
            # contaminated-md5 case that still slips through tells us WHY.
            log "    [md5-guard] id $idn raw-read len=$(printf '%s' "$_rawft" | wc -c); locked=$(cdb_locked "$_rawft" && echo yes || echo no); search_ok=$(cdb_search_ok "$_rawft" && echo yes || echo no)"
            # if this read is locked/failed, don't risk a false "contaminated"
            # verdict — just trust the md5 match (the original behaviour).
            if ! cdb_locked "$_rawft"; then
                found_title="$(printf '%s' "$_rawft" | python3 -c '
import sys,json
raw=sys.stdin.read(); i=raw.find("[")
if i<0: sys.exit(0)
try:
    d,_=json.JSONDecoder().raw_decode(raw[i:]); b=d[0] if d else {}
    print(b.get("title","") or "")
except Exception: pass' 2>/dev/null)"
            fi
            log "    [md5-guard] found_title='${found_title}'  f1='$f1' f2='$f2'"
            if [ -n "$found_title" ]; then
                tg1="$(title_full_match "$f1" "$found_title")"
                tg2="$(title_full_match "$f2" "$found_title")"
                log "    [md5-guard] tg1($f1)=$tg1 tg2($f2)=$tg2"
                if [ "$tg1" != "1.000" ] && [ "$tg2" != "1.000" ]; then
                    log "    md5 ${md5} is on calibre id $idn ('$found_title') but neither '$f1' nor '$f2' matches that title — treating md5 as contaminated, not trusting it"
                    idn=""   # fall through to the title/author check below
                fi
            fi
            [ -n "$idn" ] && { echo "$idn"; return 0; }
        fi
    fi

    # 2. strict title/author match against library metadata. Loose-search calibre
    # by each field to gather candidates, then score with the shared matcher so a
    # near-miss title can't false-positive (same gate fetch-books uses on Anna's).
    local ids="" field
    for field in "$f1" "$f2"; do
        local h safe_field
        # escape double quotes for calibre's search grammar: an embedded " in the
        # title (e.g. The "Great" Gatsby) would otherwise close the title:"..."
        # phrase early and break the query. (cdb_ro uses docker exec with "$@",
        # not sh -c, so there's no second shell to worry about — only calibre's
        # own query parser, which the backslash-escaped quote satisfies.)
        safe_field="${field//\"/\\\"}"
        h="$(cdb_search_retry "title:\"$safe_field\"")"
        cdb_locked "$h" && { _lib_reason "$h"; return 2; }
        if ! cdb_search_ok "$h"; then _lib_reason "$h"; return 2; fi
        h="$(cdb_ids "$h" | tr '\n' ' ')"
        if [ -z "$h" ]; then
            h="$(cdb_search_retry "$field")"
            cdb_locked "$h" && { _lib_reason "$h"; return 2; }
            if ! cdb_search_ok "$h"; then _lib_reason "$h"; return 2; fi
            h="$(cdb_ids "$h" | tr '\n' ' ')"
        fi
        ids="${ids} ${h}"
    done
    # de-dupe + keep only numeric ids. $ids is intentionally unquoted here: it's a
    # space-separated list of numeric tokens we WANT word-split into lines, and awk
    # re-validates each with ^[0-9]+$ so nothing unexpected survives.
    ids="$(printf '%s\n' $ids | awk 'NF && /^[0-9]+$/ && !seen[$0]++' | tr '\n' ' ')"
    [ -z "$ids" ] && return 1

    local id cand cand_t cand_a s raw_meta
    for id in $ids; do
        # emit candidate title and authors as separate TAB fields so we can score
        # with book_match_fields (title-to-title, author-to-author). The old code
        # flattened "title authors" into one blob and used book_match_score, which
        # let the wanted AUTHOR's words satisfy the title gate against the blob —
        # e.g. wanted "The Dispossessed / Ursula K. Le Guin" matched the library's
        # "The Lathe of Heaven / Ursula K. Le Guin" at 1.0 because "Le Guin"
        # matched as a title. Separated fields + book_match_fields fix that.
        #
        # Use cdb_list_retry (NOT bare cdb_ro): this read must survive a transient
        # GUI lock the same way the search stage does. If it's STILL locked after
        # retries, return 2 (defer) — never silently drop the candidate, which is
        # what previously sent in-library books back to Anna's.
        raw_meta="$(cdb_list_retry -f title,authors -s "id:$id" --for-machine)"
        cdb_locked "$raw_meta" && { _lib_reason "$raw_meta"; return 2; }
        # Strip everything before the leading JSON bracket: cdb_ro folds stderr
        # into stdout, so plugin banners / warnings can precede the array and
        # break json.load. Slice from the first '[' so the parser sees clean JSON.
        cand="$(printf '%s' "$raw_meta" | python3 -c '
import sys,json
raw=sys.stdin.read()
i=raw.find("[")
if i<0: sys.exit(0)
# Parse ONLY the first JSON value starting at "[" and IGNORE anything after it.
# cdb_ro folds stderr into stdout, and the FantasticFiction plugin prints banner
# lines BOTH before the JSON ("...SyntaxWarning...") AND after it ("Integration
# status: True"). Slicing from "[" handles the leading noise, but json.loads on
# raw[i:] then chokes on the TRAILING banner with "Extra data". raw_decode stops
# at the end of the first valid value, so trailing noise is harmless.
try:
    d,_ = json.JSONDecoder().raw_decode(raw[i:]); b = d[0] if d else {}
    a=b.get("authors",""); a=" ".join(a) if isinstance(a,list) else a
    print((b.get("title","") or "")+"\t"+(a or ""))
except Exception: pass' 2>/dev/null)"
        [ -z "$cand" ] && continue
        IFS=$'\t' read -r cand_t cand_a <<< "$cand"
        [ -z "$cand_t" ] && continue
        s="$(book_match_fields "$f1" "$f2" "$cand_t" "$cand_a")"
        if ge "$s" "$CONFIDENCE"; then echo "$id"; return 0; fi
    done
    return 1
}

# Direct Anna's fast-download. Calls fast_download.json with the key, gets the
# download_url, fetches the file to a temp name in DEST, then moves it into
# place on completion (so the watcher never sees a partial). Updates the global
# QUOTA_LIVE from the API's downloads_left. Returns 0 ok, 1 fail, 2 quota out.
#
# The API's path_index/domain_index are optional; when omitted the server picks
# a default that can be invalid for files in multiple collections / on multiple
# servers, giving "Invalid domain_index or path_index". So we first try with no
# indices (the common case, default mapping works), and ONLY if we get that
# specific error do we iterate explicit combinations (path 0..N x domain 0..M)
# until one resolves. Other errors (record not found, quota) don't trigger the
# grid — they won't be fixed by a different index. Tunables: FD_MAX_PATH_INDEX,
# FD_MAX_DOMAIN_INDEX (default 3 and 2 → up to 12 combos, but it stops at the
# first that works, which is usually 0/0 or 0/1).
QUOTA_LIVE=""
FD_MAX_PATH_INDEX="${FD_MAX_PATH_INDEX:-3}"
FD_MAX_DOMAIN_INDEX="${FD_MAX_DOMAIN_INDEX:-2}"

# epub_lang_ok TMP_PATH  ->  0 = language allowed (or LANGS empty, or couldn't
# check), 1 = at least one declared language is outside LANGS (reject).
#
# WHY: Anna's &lang= search filter is metadata-only and unreliable, and the
# magic-byte content guard only proves the file is a real epub — NOT that it's
# English. A valid Spanish epub (e.g. an ePubLibre edition) passes the byte guard
# and reaches the library, where calibre-web's language filter then hides it.
# So we read the epub's own dc:language from its OPF BEFORE the file enters the
# watched folder, and reject a download whose declared language isn't in LANGS.
#
# MULTILINGUAL OPFs: a foreign edition can declare SEVERAL languages, e.g. a
# Dutch "All Fours" whose OPF lists <dc:language>nl</dc:language> AND
# <dc:language>en-US</dc:language>. Checking only the FIRST tag is unreliable
# (OPF ordering isn't guaranteed) and checking "any allowed code present" lets
# the incidental en-US rescue a Dutch book. So we collect ALL dc:language tags
# and reject if ANY is outside LANGS — a pure-English OPF passes, a mixed one
# with a disallowed language does not, regardless of tag order.
#
# HOW: the epub is a zip and the OPF is usually DEFLATE-compressed, so a raw byte
# grep of $tmp is unreliable. We extract dc:language with python3's stdlib
# zipfile (no external `unzip` needed) INSIDE $DL_CONTAINER, where the file lives.
#
# FAIL-OPEN by design: if LANGS is empty, or python3 isn't in the container, or
# the epub declares no language at all, we ACCEPT and log why — better to let a
# book through (tag-books/calibre-web can still sort language later) than to
# silently drop books because the check couldn't run. Only an epub that
# AFFIRMATIVELY declares a non-allowed language is rejected.
epub_lang_ok() {
    local tmp="$1"
    [ -z "$LANGS" ] && return 0          # no restriction configured

    # python3 present in the download container? If not, can't inspect — fail open.
    if ! docker exec "$DL_CONTAINER" sh -c 'command -v python3 >/dev/null 2>&1'; then
        log "    note: python3 not in $DL_CONTAINER — skipping epub language check (fail-open)"
        return 0
    fi

    # Extract ALL dc:language subtags (lowercased, region stripped), newline-
    # separated: "en-US" -> "en", "nl" -> "nl". Empty output if none found.
    # zipfile reads the OPF named in META-INF/container.xml (fallback: first
    # *.opf). We collect EVERY <dc:language> tag, not just the first, because a
    # foreign edition can carry a multilingual OPF (e.g. "nl, en-US, nl-NL") that
    # includes an allowed code incidentally — taking only the first tag would
    # accept or reject by OPF ordering, which is unreliable. See the allow-logic
    # below: the book is rejected if ANY declared language is outside LANGS.
    local langs_raw
    langs_raw="$(docker exec -i "$DL_CONTAINER" python3 - "$tmp" 2>/dev/null <<'PY'
import sys, zipfile, re
path = sys.argv[1]
def all_langs():
    try:
        z = zipfile.ZipFile(path)
    except Exception:
        return []
    names = z.namelist()
    opf = ""
    # find the OPF via container.xml, else the first .opf in the zip
    if "META-INF/container.xml" in names:
        try:
            c = z.read("META-INF/container.xml").decode("utf-8", "ignore")
            m = re.search(r'full-path="([^"]+\.opf)"', c)
            if m: opf = m.group(1)
        except Exception:
            pass
    if not opf:
        for n in names:
            if n.lower().endswith(".opf"): opf = n; break
    if not opf:
        return []
    try:
        x = z.read(opf).decode("utf-8", "ignore")
    except Exception:
        return []
    # every <dc:language>..</dc:language> (namespaces vary: dc:language|language)
    out = []
    for m in re.finditer(r'<(?:[\w]+:)?language[^>]*>\s*([^<\s]+)', x):
        v = m.group(1).strip().lower().split("-")[0]   # en-us -> en
        if v and v not in out:
            out.append(v)
    return out
print("\n".join(all_langs()))
PY
)"

    # Collapse to a unique, lowercased, whitespace-free list of subtags.
    local langs=""
    langs="$(printf '%s\n' "$langs_raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:blank:]' | sed '/^$/d' | sort -u)"

    if [ -z "$langs" ]; then
        log "    note: epub declares no dc:language — accepting (fail-open)"
        return 0
    fi

    # Build the allow-set from LANGS, accepting BOTH the 2-letter (ISO 639-1) and
    # 3-letter (ISO 639-2) forms for the common languages, since epubs use either.
    local want allow=""
    for want in $LANGS; do
        want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
        case "$want" in
            en|eng) allow="$allow en eng" ;;
            es|spa) allow="$allow es spa" ;;
            fr|fre|fra) allow="$allow fr fre fra" ;;
            de|ger|deu) allow="$allow de ger deu" ;;
            it|ita) allow="$allow it ita" ;;
            pt|por) allow="$allow pt por" ;;
            nl|dut|nld) allow="$allow nl dut nld" ;;
            ru|rus) allow="$allow ru rus" ;;
            *)      allow="$allow $want" ;;
        esac
    done

    # REJECT if ANY declared language is outside the allow-set. A pure-English
    # OPF (one or more tags, all en/eng) passes. A multilingual OPF that mixes in
    # a disallowed language (the "nl, en-US, nl-NL" foreign-edition case) is
    # rejected regardless of tag order — the presence of an allowed code no
    # longer rescues a book that ALSO declares a disallowed one.
    # Non-answers: ISO codes that DECLARE nothing - und (undetermined), mul
    # (multiple), zxx (no linguistic content), plus a literal "unknown". These
    # are not foreign-language declarations, so per this gate's fail-open intent
    # they must NOT trigger a reject. A book tagged only with these is accepted;
    # the pipeline defaults blank/unknown language to eng after import anyway. A
    # genuinely-foreign epub still declares its real code (fr, nl...) and is caught.
    local l code hit bad="" meaningful=""
    for l in $langs; do
        case "$l" in
            und|mul|zxx|unknown|"") continue ;;   # non-declaration -> ignore
        esac
        meaningful="$meaningful $l"
        hit=0
        for code in $allow; do
            [ "$l" = "$code" ] && { hit=1; break; }
        done
        [ "$hit" -eq 0 ] && bad="$bad $l"
    done

    # Only undetermined/non-answer tags present (no real language declared):
    # fail-open, same as the no-dc:language case above.
    if [ -z "$meaningful" ]; then
        log "    note: epub declares only undetermined language(s) ($(printf '%s' "$langs" | tr '\n' ' ' | sed 's/ *$//')) - accepting (fail-open)"
        return 0
    fi

    if [ -z "$bad" ]; then
        return 0
    fi
    local langs_csv; langs_csv="$(printf '%s' "$langs" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    log "    REJECTED: epub declares disallowed language(s) '$(printf '%s' "$bad" | sed 's/^ //')' (all tags: $langs_csv; allowed LANGS='$LANGS') — discarding"
    return 1
}

# v81: read the epub's own <dc:title> from its OPF, inside the download container
# (python3 + zipfile only — no calibre needed). Echoes the title, or nothing if it
# can't be read. Fail-open: any error -> empty -> caller does NOT reject.
epub_internal_title() {
    local container="$1" path="$2"
    docker exec "$container" python3 -c '
import sys, zipfile, re
try:
    z = zipfile.ZipFile(sys.argv[1])
    opf = None
    try:
        c = z.read("META-INF/container.xml").decode("utf-8","replace")
        m = re.search(r"full-path=\"([^\"]+\.opf)\"", c)
        if m: opf = m.group(1)
    except Exception:
        pass
    if not opf:
        for n in z.namelist():
            if n.lower().endswith(".opf"): opf = n; break
    if not opf: sys.exit(0)
    x = z.read(opf).decode("utf-8","replace")
    m = re.search(r"<dc:title[^>]*>(.*?)</dc:title>", x, re.S|re.I)
    if m:
        t = re.sub(r"<[^>]+>","",m.group(1)).strip()
        if t: print(t)
except Exception:
    sys.exit(0)
' "$path" 2>/dev/null
}

# v81: verify a downloaded epub really IS the wanted book, using its honest
# internal title (not Anna's listing). Returns 0 = ok/accept (match, or title
# unreadable -> fail open), 1 = mismatch (reject: a different book). $want_title
# is the LIST title (note the fetch-books field inversion: caller passes the
# actual wanted TITLE here regardless of column order). Only meaningful for epub;
# callers skip it for other formats.
verify_epub_is_book() {
    local container="$1" path="$2" want_title="$3"
    [ -z "$want_title" ] && return 0          # nothing to check against -> accept
    local ftitle; ftitle="$(epub_internal_title "$container" "$path")"
    [ -z "$ftitle" ] && return 0              # unreadable -> FAIL OPEN (accept)
    # necessary condition: every meaningful wanted word present in the file title
    local g; g="$(title_full_match "$want_title" "$ftitle")"
    if [ "$g" != "1.000" ]; then
        log "    TITLE MISMATCH: wanted '$want_title' but file is '$ftitle' — discarding (Anna's metadata was wrong)"
        return 1
    fi
    # weak/short wanted title: also require the file title to START with it, so a
    # one-word wanted title isn't satisfied by a different book that merely
    # contains the word (e.g. wanted "Eragon" vs file "Murtagh: The World of
    # Eragon"). Same rule as the upstream short_title_ok gate.
    local mw; mw="$(meaningful_words "$want_title")"
    if [ "$mw" -lt 2 ]; then
        if ! short_title_ok "$want_title" "$ftitle"; then
            log "    TITLE MISMATCH (weak title): wanted '$want_title' but file is '$ftitle' — discarding"
            return 1
        fi
    fi
    return 0
}

fast_download_md5() {
    local md5="$1" want_title="${2:-}" want_author="${3:-}" resp url err fname tmp
    local pi di tried_grid=0

    # First attempt: no explicit indices (server default). Most files resolve here.
    resp="$(fast_api_call "$md5")"
    if [ $? -ne 0 ] || [ -z "$resp" ]; then
        log "    fast-download API unreachable on all mirrors"; return 1
    fi
    url="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("download_url") or "")
except Exception: print("")' 2>/dev/null)"
    err="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("")' 2>/dev/null)"
    QUOTA_LIVE="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"

    # If the ONLY problem is the index default being invalid, iterate explicit
    # path_index x domain_index until a combination returns a real download_url.
    # The first combo that works wins; we stop immediately (no wasted calls).
    # Quota-safe: you're only charged when the download_url is FETCHED (the same
    # reason the preflight can probe a valid md5 for free), so these resolution
    # calls — which return no url — cost no quota.
    if { [ -z "$url" ] || [ "$url" = "null" ]; } \
       && printf '%s' "$err" | grep -qi 'domain_index\|path_index'; then
        log "    default index invalid for $md5 — iterating path/domain indices"
        for pi in $(seq 0 "$FD_MAX_PATH_INDEX"); do
            for di in $(seq 0 "$FD_MAX_DOMAIN_INDEX"); do
                tried_grid=1
                resp="$(fast_api_call "$md5" "$pi" "$di")"
                [ $? -ne 0 ] && continue
                [ -z "$resp" ] && continue
                url="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("download_url") or "")
except Exception: print("")' 2>/dev/null)"
                err="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error") or "")
except Exception: print("")' 2>/dev/null)"
                QUOTA_LIVE="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
                if [ -n "$url" ] && [ "$url" != "null" ]; then
                    log "    resolved with path_index=$pi domain_index=$di"
                    break 2
                fi
                # if the API now reports quota exhaustion, stop the grid (a
                # different index won't bring quota back).
                if [ "${QUOTA_LIVE:-}" = "0" ]; then break 2; fi
            done
        done
    fi

    if [ -z "$url" ] || [ "$url" = "null" ]; then
        # Distinguish QUOTA EXHAUSTION from other refusals. When the daily fast-
        # download allowance is spent, Anna's refuses with a "no downloads left"
        # style error AND (usually) downloads_left:0. Continuing to hit the API
        # for every remaining book is pointless and rude — signal the caller to
        # STOP the run (return 2) rather than mark just this one failed (return 1).
        local errlc; errlc="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')"
        case "$errlc" in
            *"no downloads left"*|*"download limit"*|*"quota"*|*"exhausted"*|*"too many"*)
                log "    fast-download refused: ${err} (daily quota exhausted)"
                QUOTA_LIVE=0
                return 2 ;;
        esac
        # also treat a live downloads_left of 0 as exhaustion even if the error
        # text is generic.
        if [ "${QUOTA_LIVE:-}" = "0" ]; then
            log "    fast-download refused: ${err:-no url} (downloads_left=0 — quota exhausted)"
            return 2
        fi
        local _gridnote=""; [ "$tried_grid" -eq 1 ] && _gridnote=" (after index grid)"
        log "    fast-download refused: ${err:-no download_url returned}${_gridnote}"; return 1
    fi

    # urllib.parse.unquote can produce a literal NUL byte if the URL contains a
    # percent-encoded %00 (or a malformed multibyte sequence decodes to one).
    # bash command substitution can't hold a NUL, so it drops it and prints the
    # cosmetic warning "ignored null byte in input". Strip NULs (and other control
    # chars) inside python so bash never sees one — harmless either way, but quiet.
    fname="$(printf '%s' "$url" | sed 's/?.*//; s#.*/##' \
        | python3 -c 'import sys,urllib.parse,re
s=urllib.parse.unquote(sys.stdin.read().strip())
print(re.sub(r"[\x00-\x1f]", "", s))' 2>/dev/null)"
    [ -z "$fname" ] && fname="${md5}.epub"
    # Truncate to fit the 255-BYTE filesystem limit WITHOUT losing the extension.
    # The old "cut -c1-180" chopped the tail — which is where .epub lives — so
    # long names lost their extension and the watcher (extension-gated) ignored
    # them. Split stem/ext, shorten the stem on a byte budget, reattach the ext.
    # Also guarantee an md5 in the stem so files stay identifiable + unique.
    fname="$(printf '%s' "$fname" | tr -d '/' | python3 -c '
import sys, os
name = sys.stdin.read().strip()
md5 = sys.argv[1]
stem, ext = os.path.splitext(name)
if not ext or len(ext) > 6:        # no real extension found
    stem, ext = name, ".epub"      # default; magic-byte check happens elsewhere
# ensure the md5 is present in the stem so the file is identifiable & unique
if md5 not in stem:
    stem = (stem[:60].rstrip() + " -- " + md5) if stem else md5
# byte-budget: keep total <= 200 bytes (margin under 255 for path safety)
budget = 200 - len(ext.encode("utf-8"))
enc = stem.encode("utf-8")[:budget]
# avoid cutting a multibyte char in half
stem = enc.decode("utf-8", "ignore").rstrip()
print(stem + ext)
' "$md5" 2>/dev/null)"
    [ -z "$fname" ] && fname="${md5}.epub"

    tmp="${DEST}/.part-${md5}"
    CLEANUP_PARTS+=("$tmp")
    if ! docker exec "$DL_CONTAINER" wget -q --timeout=120 -O "$tmp" "$url" 2>/dev/null; then
        log "    download failed (url fetch)"; docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1
    fi
    if ! docker exec "$DL_CONTAINER" sh -c '[ -s "$1" ]' _ "$tmp" 2>/dev/null; then
        log "    download produced empty file"; docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1
    fi
    # v80: a slot has now been spent — the fast-download URL was fetched and a
    # file is in hand. Log it REGARDLESS of whether the guard below accepts or
    # rejects it, so quota-status.sh can date every real spend (not just kept
    # downloads). The kept-download line further down still logs separately; this
    # is the per-spend accounting line. Token: 'quota-spend [md5:<hash>]'.
    log "    quota-spend [md5:${md5}]${QUOTA_LIVE:+  (quota left: $QUOTA_LIVE)}"
    # CONTENT-TYPE GUARD: reject by actual bytes, not by what Anna's claimed.
    # The &ext= filter is metadata-only and unreliable, so verify real magic bytes.
    # We accept ONLY genuine ebook containers and ban everything else — PDF, HTML
    # gate pages, bare ZIPs, .lit, .rtf, .prc — so junk never reaches the watcher.
    #
    # Detecting a real EPUB vs a bare ZIP: both start with "PK" (0x504b). A
    # conformant epub stores an uncompressed "mimetype" entry FIRST, so the literal
    # bytes "mimetypeapplication/epub+zip" appear at the very start of the file
    # (around offset 30). A junk zip won't have that. We read the first 64 bytes
    # and look for "application/epub+zip" — present = epub (accept), absent in a PK
    # file = bare/other zip (reject). azw3 is also a zip-ish container but Anna's
    # serves those rarely; if you need azw3, it'll be caught here as "not epub" —
    # acceptable, since FORMATS is epub-first and azw3 from Anna's is uncommon.
    # Three small docker exec probes. (These were considered for batching into a
    # single exec to save the ~0.2-0.5s exec startup ×3, but the saving is well
    # under a second and runs only on a SUCCESSFUL download — which is already
    # multi-second rate-paced — so the latency is invisible, and a batched binary-
    # safe version needs a hex-encode/decode dance that's harder to verify than
    # it's worth. Kept simple and obviously-correct on purpose.)
    local magic head64 first64
    magic="$(docker exec "$DL_CONTAINER" sh -c 'head -c 4 "$1" | od -An -tx1 | tr -d " \n"' _ "$tmp" 2>/dev/null)"
    head64="$(docker exec "$DL_CONTAINER" sh -c 'dd if="$1" bs=1 skip=60 count=8 2>/dev/null | tr -dc "[:print:]"' _ "$tmp" 2>/dev/null)"
    first64="$(docker exec "$DL_CONTAINER" sh -c 'head -c 64 "$1" 2>/dev/null | tr -dc "[:print:]"' _ "$tmp" 2>/dev/null)"
    case "$magic" in
        25504446*)   # %PDF
            log "    REJECTED: download is a PDF — discarding, not importing"
            docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 4 ;;  # rc=4: PDF (v78: drives 'pdf-only' status)
        3c3f786d*|3c68746d*|3c21444f*)  # "<?xm" / "<htm" / "<!DO" — XML/HTML page
            log "    REJECTED: download is XML/HTML (interstitial/gate page?) — discarding"
            docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1 ;;
        7b5c7274*)   # "{\rt" — RTF
            log "    REJECTED: download is RTF (not an ebook) — discarding"
            docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1 ;;
        49544f4c*)   # "ITOL" — Microsoft .lit (ITOLITLS)
            log "    REJECTED: download is a .lit (dead format) — discarding"
            docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1 ;;
        504b0304*|504b0506*|504b0708*)   # PK.. zip-family: accept ONLY a real epub
            case "$first64" in
                *application/epub+zip*)
                    # genuine epub — now also verify it's an allowed language.
                    # (The magic bytes prove "epub", not "English".) A Spanish
                    # ePubLibre edition is a valid epub but must not slip through.
                    if ! epub_lang_ok "$tmp"; then
                        docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1
                    fi ;;
                *)
                    log "    REJECTED: PK/zip but not an epub (bare zip or other) — discarding"
                    docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1 ;;
            esac ;;
        *)
            # MOBI/AZW family (PDB header at offset 60). Accept BOOKMOBI/Topaz; but
            # BAN .prc (also MOBI-family) per preference. .prc and .mobi share the
            # BOOKMOBI type, so we can't always tell them apart by header alone —
            # so if the original Anna's filename/ext was .prc, that was handled by
            # the FORMATS filter upstream; here we accept BOOKMOBI/MOBI/TPZ as the
            # Kindle-native mobi family. (prc files that reach here as BOOKMOBI are
            # functionally mobi and Kindle-readable; the library-level format flag
            # is where you'd choose to convert them.)
            case "$head64" in
                BOOKMOBI*|MOBI*|TPZ*|*BOOKMOBI*)
                    : ;;  # MOBI-family ebook — accept
                *)
                    log "    REJECTED: not a recognised ebook container (magic=${magic:0:8}, hdr60='${head64}') — discarding"
                    docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null; return 1 ;;
            esac ;;
    esac

    # v81: TITLE VERIFICATION (epub only). The magic check above proved it's an
    # ebook; now prove it's the RIGHT ebook, using the epub's own dc:title rather
    # than Anna's (possibly poisoned) listing. On mismatch, discard and return 5 so
    # the candidate loop moves to the next hit (like a PDF reject). Fail-open if the
    # title can't be read. Skip for non-epub (MOBI/azw3): OPF read is epub-specific
    # and these are rarer; they pass through unverified rather than risk a false
    # reject. $tmp is still the pre-move temp path inside DL_CONTAINER.
    case "${fname##*.}" in
        epub|EPUB)
            if ! verify_epub_is_book "$DL_CONTAINER" "$tmp" "$want_title"; then
                docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null
                return 5
            fi ;;
    esac

    # verify the move actually succeeded AND the destination exists non-empty
    # before reporting success — a silent mv failure must not log "downloaded".
    # Pass paths as ARGS to sh -c (not interpolated) so a filename with an
    # apostrophe (e.g. "The Handmaid's Tale.epub") can't break the shell string.
    if ! docker exec "$DL_CONTAINER" mv "$tmp" "${DEST}/${fname}" 2>/dev/null \
       || ! docker exec "$DL_CONTAINER" sh -c '[ -s "$1" ]' _ "${DEST}/${fname}" 2>/dev/null; then
        log "    move failed or dest missing/empty: ${fname}"
        docker exec "$DL_CONTAINER" rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # ownership/perms for the watcher. The mv ran AS the qbittorrent container's
    # internal user, so unless its compose PUID/PGID are 2001:2002 the file may
    # land owned by root or another uid and the watcher (which expects 2001:2002)
    # could choke. docker exec defaults to root, so it can chown to the numeric
    # owner regardless of the container's PUID. Non-fatal: the file is in place
    # either way. (SE_CHOWN reused as the canonical "watcher owner".)
    if [ -n "${WATCHER_OWNER:-}" ]; then
        docker exec "$DL_CONTAINER" chown "$WATCHER_OWNER" "${DEST}/${fname}" 2>/dev/null \
            || log "    note: could not chown ${fname} to $WATCHER_OWNER (check qbittorrent PUID/PGID)"
    fi
    docker exec "$DL_CONTAINER" chmod 664 "${DEST}/${fname}" 2>/dev/null || true
    log "    downloaded -> ${fname}  [md5:${md5}]${QUOTA_LIVE:+  (quota left: $QUOTA_LIVE)}"
    return 0
}

# Append a book to the tag queue so tag-queue.sh tags it once imported. Args:
# md5 tags title author. No-op if TAG_QUEUE is empty or tags is empty. Locked so
# concurrent fetch-books runs don't corrupt the JSON. Best-effort (a queue
# failure must not fail the download, which already succeeded).
enqueue_for_tagging() {
    local md5="$1" tags="$2" title="$3" author="$4"
    [ -z "$TAG_QUEUE" ] && return 0
    [ -z "$tags" ] && return 0
    local qlock="${TAG_QUEUE}.lock"
    (
        flock -w 10 8 || { log "    WARN: could not lock tag queue; not enqueued"; exit 1; }
        local err
        err="$(python3 -c '
import sys, json, os, time
qf, md5, tags, title, author = sys.argv[1:6]
try:
    arr = json.load(open(qf)) if os.path.exists(qf) and os.path.getsize(qf) else []
except Exception:
    arr = []
# de-dupe: if this md5 is already queued, leave it (avoid pile-up on re-runs)
if not any(e.get("md5") == md5 for e in arr if md5):
    arr.append({"md5": md5, "tags": tags, "title": title,
                "author": author, "queued_at": int(time.time())})
    json.dump(arr, open(qf, "w"))
' "$TAG_QUEUE" "$md5" "$tags" "$title" "$author" 2>&1)"
        if [ -n "$err" ]; then
            log "    WARN: enqueue failed (download still OK): ${err##*: }"
        else
            # keep the queue group-writable so the root timer can rewrite it and
            # we can still write it next time (shared-file ownership dance).
            chmod 664 "$TAG_QUEUE" 2>/dev/null || true
            log "    enqueued for tagging: [$tags]"
        fi
    ) 8>"$qlock"
}


process_file() {
    local file="$1"
    [ -f "$file" ] || { log "skip (not found): $file"; return; }
    # Per-TSV advisory lock (guard rail). Runs are normally serialized (one
    # fetch-books at a time), so this almost never contends — but if a manual
    # --retry ever overlapped a timer run on the SAME list, both would read the
    # file, write their own $tmp, and the last `mv "$tmp" "$file"` would clobber
    # the other's status updates (lost downloaded/quota_blocked rows, wasted
    # quota). flock makes the second run WAIT for the first, then process the
    # already-updated file. Lock is a sibling .lock (never the data file itself —
    # mv replaces its inode). We hold the lock on fd 9 for the WHOLE function and
    # release it explicitly at the end, rather than wrapping the body in a
    # subshell: the body appends to CLEANUP_PARTS/CLEANUP_FILES, and the EXIT trap
    # that cleans orphaned .part-* files on Ctrl-C lives in THIS shell — a subshell
    # body would hide those appends from the parent trap and reintroduce orphans.
    # Lock handle in /tmp (not beside the .tsv) so it doesn't clutter the lists
    # folder, and is cleared on reboot. The file stays empty and is never deleted
    # — that's normal flock behaviour (the lock is on the fd, not the contents);
    # deleting it would race a concurrent locker. Keyed by the TSV's full path so
    # each list gets its own lock.
    local _lock="/tmp/gunit-fetch.$(printf '%s' "$file" | md5sum | cut -d' ' -f1).lock"
    exec 9>"$_lock"
    # Non-blocking probe first: if it's held, say so (a --wait run can hold for
    # hours, so a silent block would look like a hang), THEN block until free.
    if ! flock -n 9; then
        log "another fetch-books holds $file — waiting for it to finish"
        if ! flock -x 9; then
            log "could not lock $file — skipping to avoid a racy write"
            exec 9>&-
            return
        fi
    fi
    _process_file_body "$file"
    local _rc=$?
    flock -u 9; exec 9>&-   # release + close the lock fd
    return "$_rc"
}

_process_file_body() {
    local file="$1"
    local tmp; tmp="$(mktemp)"; CLEANUP_FILES+=("$tmp")
    local n_done=0 n_skip=0 n_nomatch=0 n_fail=0 n_bad=0 n_qblock=0 n_pdfonly=0
    local file_tag="$TAG"   # --tag wins; else picked up from a #tag: header below
    # Per-file Standard Ebooks toggle. Starts from the global SE_FIRST (which the
    # --skipstandard flag / SE_FIRST env may already have forced to 0), and a
    # "#skipstandard" directive line in THIS list forces it to 0 for this file
    # only — a permanent, in-the-data equivalent of the --skipstandard flag, for
    # lists you KNOW aren't public-domain. There is no in-file way to turn SE back
    # ON once the flag/env disabled it globally (the flag is the broader switch).
    local file_se_first="$SE_FIRST"

    # Self-documenting schema header. The TSV is consumed by several scripts
    # (fetch-books, tag-books, sync-tag-to-shelf) that each parse it by column;
    # this comment block records the contract so the format is discoverable from
    # the data file itself. Written ONCE if absent (detected by the #schema: tag)
    # and preserved verbatim thereafter, since every parser skips '#' lines.
    # Skipped in dry-run (read-only) and only when the file lacks the marker.
    if [ "$DRY_RUN" -eq 0 ] && ! grep -q '^#schema:' "$file" 2>/dev/null; then
        {
            printf '#schema: gunit book list v1 — columns are PIPE-separated (|)\n'
            printf '#  1 title    2 author    3 status    4 md5/source    5 date    6 calibre_id|se-empty\n'
            printf '#  status: (blank)=pending  downloaded  nomatch  failed  pdf-only  quota_blocked  tagged  queued/downloading/completed (legacy)\n'
            printf '#  col4: Anna'\''s md5, or se:<author>/<title> for Standard Ebooks rows\n'
            printf '#  col6: calibre book id on DONE rows; the literal "se-empty" on quota_blocked/nomatch/pdf-only rows means SE was already searched and had nothing (skip re-search)\n'
            printf '#  lines beginning with # are comments; "#tag: NAME[, NAME...]" sets the calibre tags for this whole list\n'
        } >> "$tmp"
        log "  wrote schema header to $file (first run on this list)"
    fi

    while IFS= read -r raw || [ -n "$raw" ]; do
        # read a "#tag: ..." header directive (only if --tag didn't set one)
        case "$raw" in
            \#tag:*|\#tag\ *)
                if [ -z "$TAG" ]; then
                    file_tag="$(printf '%s' "$raw" | sed 's/^#tag:[[:space:]]*//; s/^#tag[[:space:]]*//')"
                    # normalise to a canonical comma list: trim space around
                    # commas and at the ends, drop blanks. Spaces WITHIN a tag
                    # are kept, so multi-word tags like "Booker Prize" survive.
                    file_tag="$(printf '%s' "$file_tag" \
                        | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/,\{2,\}/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^,//; s/,$//')"
                    log "  list tag from header: '$file_tag'"
                fi
                printf '%s\n' "$raw" >> "$tmp"; continue ;;
            \#skipstandard|\#skip-standard|\#skipstandard\ *|\#skip-standard\ *)
                # in-file directive: skip Standard Ebooks for this whole list,
                # going straight to Anna's. Equivalent to the --skipstandard flag
                # but baked into the data, so it persists across runs without a
                # per-invocation flag. Logged once; preserved verbatim on rewrite.
                if [ "$file_se_first" = "1" ]; then
                    file_se_first=0
                    log "  Standard Ebooks: disabled for this list (#skipstandard directive)"
                fi
                printf '%s\n' "$raw" >> "$tmp"; continue ;;
        esac
        case "$raw" in ''|\#*) printf '%s\n' "$raw" >> "$tmp"; continue;; esac

        local author title status md5 date bookid rest
        # columns: title | author | status | md5 | date | calibre_id
        # (field1 is the TITLE despite the var name `author` — historical; do not
        # "fix"). `rest` catches any 7th+ columns so nothing is lost on rewrite.
        #
        # COL 6 is dual-purpose by status (the two never co-occur on one row):
        #   - terminal rows (downloaded/queued/.../tagged): the calibre book id.
        #   - non-terminal rows (quota_blocked/nomatch): the SE-checked marker
        #     "se-empty", meaning Standard Ebooks was already searched for this
        #     book and had nothing. On re-runs we skip the (pointless) SE search
        #     for these, going straight to Anna's. A quota_blocked book that's not
        #     on SE would otherwise re-search SE every single day until its Anna's
        #     quota frees up.
        local raw_nocr; raw_nocr="${raw%$'\r'}"
        IFS='|' read -r author title status md5 date bookid rest <<< "$raw_nocr"
        # field count for the malformed guard: count '|' separators + 1
        local seps="${raw_nocr//[!|]/}"; local nfields=$(( ${#seps} + 1 ))
        # trim surrounding whitespace on the two fields we match on
        author="$(printf '%s' "${author:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        title="$(printf '%s' "${title:-}"   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        status="$(printf '%s' "${status:-}" | tr -d '[:space:]')"
        md5="$(printf '%s' "${md5:-}"       | tr -d '[:space:]')"
        bookid="$(printf '%s' "${bookid:-}" | tr -d '[:space:]')"
        # SE-checked marker: col 6 == "se-empty" on a non-terminal row means SE was
        # already searched and empty, so skip the SE search this run. (On terminal
        # rows col 6 is the calibre id and this stays 0.)
        local se_already_empty=0
        [ "$bookid" = "se-empty" ] && se_already_empty=1

        # malformed guard: a data line needs at least author|title. Fewer than 2
        # pipe-fields, or an empty author/title, means the line is malformed.
        if [ "$nfields" -lt 2 ] || [ -z "$author" ] || [ -z "$title" ]; then
            log "  MALFORMED (expected 'author | title', got $nfields field(s)) — kept verbatim: $(printf '%s' "$raw" | cat -v)"
            printf '%s\n' "$raw" >> "$tmp"; n_bad=$((n_bad+1)); continue
        fi

        # In a WAIT retry pass we ONLY re-attempt rows left quota_blocked by an
        # earlier pass; everything else passes through verbatim. (A normal pass
        # has WAIT_PASS=0 and handles all statuses as usual below.)
        if [ "${WAIT_PASS:-0}" -eq 1 ] && [ "$status" != "quota_blocked" ]; then
            printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
        fi

        # already in-flight or finished -> keep as-is, don't re-fetch.
        # downloaded = fetched this pipeline (or marked present by the library
        # check); queued/downloading/completed/tagged = old Stacks states. All
        # mean "done, don't touch" — and crucially skip BEFORE the calibre library
        # check, so a finished row costs nothing on re-runs.
        #
        # EXCEPTION: backfill the calibre book id (6th column) for a finished row
        # that has an md5 but no id yet, so links like books.rob.me.uk/book/<id>
        # can be built. The id only exists AFTER import (fetch can't know it at
        # download time), so we fill it lazily on a later run via the same
        # identifiers:<scheme>:<md5> lookup tag-lib uses. One cheap query per
        # not-yet-linked book, once; after that the id is present and it skips.
        # se: rows now carry a standard_ebooks identifier (stamped at tag time),
        # so they're matched the same way as Anna's md5 rows.
        case "$status" in
            downloaded|queued|downloading|completed|tagged)
                # --force-retry: verify this "done" row is ACTUALLY in Calibre.
                # If the book is confirmed absent, reset the row to pending and fall
                # through to normal processing so it re-downloads. If present, or if
                # the check can't run, leave it alone.
                #
                # v79: use already_in_library (NOT a bare md5-identifier lookup).
                # The md5 is only stamped at tag time, so many in-library books
                # lack the annas:<md5> identifier — an md5-only check called them
                # absent and needlessly reset good 'tagged' rows. already_in_library
                # checks the md5 identifier AND falls back to a bidirectional
                # title/author match, returning: 0 present, 1 clean-absent, 2
                # uncheckable (calibre locked/unreadable). We reset ONLY on rc=1.
                # NOTE param order: already_in_library wants (title, author, md5);
                # field1 ($author) is the TITLE, field2 ($title) is the AUTHOR.
                if [ "$FORCE_RETRY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
                    if [ "$LIB_CHECK" != "1" ]; then
                        # Can't verify library presence with the check disabled, so
                        # we must not reset (resetting blind would re-download owned
                        # books). Leave the row untouched and note why, once.
                        log "  force-retry: LIB_CHECK is off — cannot verify '$author'; leaving $status row untouched (set LIB_CHECK=1 to enable force-retry)"
                        printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
                    fi
                    local _fr_id _fr_rc
                    _fr_id="$(already_in_library "$author" "$title" "$md5")"; _fr_rc=$?
                    if [ "$_fr_rc" -eq 1 ]; then
                        log "  force-retry: '$author' not in Calibre (was $status) — resetting to pending and re-attempting"
                        status=""           # reset; drop the stale id, keep md5 as a search hint
                        bookid=""
                        # do NOT 'continue' — fall through to normal processing below
                    elif [ "$_fr_rc" -eq 2 ]; then
                        log "  force-retry: library check unavailable (${LIB_CHECK_REASON:-calibre unreadable}) for '$author' — leaving $status row untouched"
                        printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
                    else
                        # rc=0: present (by md5 or title/author). Fall through to the
                        # normal done-row handling below, which backfills the id if
                        # missing (preferring the id already_in_library just found)
                        # and then skips. Seed bookid so the backfill can short-cut.
                        [ -z "$bookid" ] && [ -n "$_fr_id" ] && bookid="$_fr_id"
                    fi
                fi
                ;;
        esac
        case "$status" in
            downloaded|queued|downloading|completed|tagged)
                if [ -z "$bookid" ] && [ "$DRY_RUN" -eq 0 ]; then
                    local looked="" _scheme _value
                    case "$md5" in
                        "") ;;                                  # nothing to look up by
                        se:*)                                   # Standard Ebooks slug
                            _value="${md5#se:}"; _value="${_value//\//_}"
                            looked="$(cdb_search_retry "identifiers:${SE_ID_SCHEME}:${_value}" | cdb_ids | head -1)" ;;
                        *)                                      # Anna's md5
                            looked="$(cdb_search_retry "identifiers:${ID_SCHEME}:${md5}" | cdb_ids | head -1)" ;;
                    esac
                    if [ -n "$looked" ]; then
                        # v81: title-sanity on the backfill md5 link (same reason as
                        # already_in_library's md5 guard). A contaminated md5 (a
                        # different book's file md5 sitting on this row) would link
                        # the row to the WRONG calibre book ("Lock In" -> Head On's
                        # id 1968). Verify the found book's title contains the wanted
                        # title's words before linking; if not, DON'T link — blank
                        # the row's md5 and status so it's re-searched fresh next run
                        # (the only way to recover the right book). Fail-safe: if the
                        # title read locks/fails, link as before.
                        local _bf_raw _bf_title _bf_ok=1
                        _bf_raw="$(cdb_list_retry -f title -s "id:$looked" --for-machine 2>/dev/null)"
                        log "    [backfill-guard] id $looked raw-len=$(printf '%s' "$_bf_raw" | wc -c) locked=$(cdb_locked "$_bf_raw" && echo yes || echo no)"
                        if ! cdb_locked "$_bf_raw"; then
                            _bf_title="$(printf '%s' "$_bf_raw" | python3 -c '
import sys,json
raw=sys.stdin.read(); i=raw.find("[")
if i<0: sys.exit(0)
try:
    d,_=json.JSONDecoder().raw_decode(raw[i:]); b=d[0] if d else {}
    print(b.get("title","") or "")
except Exception: pass' 2>/dev/null)"
                            if [ -n "$_bf_title" ] \
                               && [ "$(title_full_match "$author" "$_bf_title")" != "1.000" ] \
                               && [ "$(title_full_match "$title" "$_bf_title")" != "1.000" ]; then
                                _bf_ok=0
                            fi
                            log "    [backfill-guard] found_title='${_bf_title}' row-title='$author' row-author='$title' -> $([ "$_bf_ok" -eq 0 ] && echo CONTAMINATED || echo ok)"
                        fi
                        if [ "$_bf_ok" -eq 0 ]; then
                            log "  NOT linking: md5 $md5 -> id $looked ('$_bf_title') but row is '$author' — contaminated md5, resetting row to re-search"
                            printf '%s|%s|||%s\n' "$author" "$title" "${date:-}" >> "$tmp"
                            n_skip=$((n_skip+1)); continue
                        fi
                        bookid="$looked"
                        log "  linked: $author -> id $bookid"
                        printf '%s|%s|%s|%s|%s|%s\n' \
                            "$author" "$title" "$status" "$md5" "${date:-}" "$bookid" >> "$tmp"
                        n_skip=$((n_skip+1)); continue
                    fi
                fi
                printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue ;;
        esac
        # error/nomatch/pdf-only -> only re-attempt under --retry; otherwise keep
        # verbatim. pdf-only (v78) is terminal on normal runs (the book is PDF-only
        # on Anna's; re-proving it just wastes quota) but --retry re-attempts it in
        # case an epub edition has since appeared.
        # NOTE: 'quota_blocked' is deliberately NOT in this list — it means "would
        # have fetched from Anna's but the daily quota was spent", so it should be
        # re-attempted automatically on the next run (after the quota resets), no
        # --retry needed. It simply falls through and is processed normally.
        if [ "$status" = "error" ] || [ "$status" = "failed" ] || [ "$status" = "nomatch" ] || [ "$status" = "pdf-only" ]; then
            if [ "$RETRY" -eq 0 ]; then
                printf '%s\n' "$raw" >> "$tmp"; n_skip=$((n_skip+1)); continue
            fi
            log "  retrying previously-$status line"
        fi
        log "→ $author — $title"

        # PRE-SEARCH LIBRARY CHECK: if the book is already in calibre, skip it
        # entirely — no Anna's search, no download, no quota.
        #
        # We pass the row's existing md5 (col 4) when it has one. A quota_blocked
        # or failed row carries the Anna's md5 it matched earlier; if that book
        # later imported, calibre stamped it identifiers:annas:<md5>, which is the
        # AUTHORITATIVE match. Previously this call passed an empty md5 and relied
        # on title/author only — so a book whose imported metadata differs from the
        # list (trimmed subtitle, "H_ Wilson" vs "H. Wilson", reordered author)
        # would NOT match, the row would go back to Anna's, hit quota again, and
        # stay quota_blocked forever even though it was sitting in the library.
        # Passing the md5 fixes those stuck rows. For a pending row md5 is empty,
        # so this is a title/author match exactly as before (catches library books
        # Anna's search would miss on punctuation/author-format grounds).
        if [ "$LIB_CHECK" = "1" ]; then
            local prelib prerc
            prelib="$(already_in_library "$author" "$title" "$md5")"; prerc=$?
            if [ "$prerc" -eq 0 ] && [ -n "$prelib" ]; then
                log "    already in library (calibre id $prelib) — skipping (no search, no download)"
                # preserve the md5 AND record the calibre id in col 6, so the row
                # becomes a fully-linked terminal row (downloaded|md5|date|id) and
                # later link-md/tag passes don't have to re-look-it-up.
                printf '%s|%s|downloaded|%s|%s|%s\n' "$author" "$title" "$md5" "$(date '+%Y-%m-%dT%H:%M')" "$prelib" >> "$tmp"
                n_skip=$((n_skip+1))
                continue
            elif [ "$prerc" -eq 2 ]; then
                # library check could not run (calibre busy / locked). Don't risk
                # spending a download on a book we might already own — defer this
                # row (leave its current status untouched) and move on.
                log "    library check unavailable: ${LIB_CHECK_REASON:-calibre unreadable} — deferring, not downloading"
                printf '%s\n' "$raw" >> "$tmp"
                n_skip=$((n_skip+1))
                continue
            fi
        fi

        # STANDARD EBOOKS FIRST: many list books are public-domain classics SE
        # has produced. Try SE before Anna's — it's free, keyless, quota-free.
        # A confident SE match is AUTHORITATIVE: if its download then fails we
        # mark the row 'failed' and do NOT fall through to Anna's (so a public
        # book never spends Anna's quota). DRY_RUN reports the SE hit and skips.
        #
        # se_already_empty (col-6 marker from a prior run) skips the SE search:
        # this book was searched on SE before and had nothing, so re-searching is
        # dead latency. We propagate the marker forward on the row we write below.
        local se_empty=0   # set to 1 this run if SE is searched and comes back empty
        [ "$se_already_empty" -eq 1 ] && se_empty=1
        if [ "$file_se_first" = "1" ] && [ "$se_already_empty" -eq 0 ]; then
            local se_hit se_slug se_score
            se_hit="$(se_search_one "$author" "$title")"
            if [ -n "$se_hit" ]; then
                se_slug="$(printf '%s' "$se_hit" | cut -f1)"
                se_score="$(printf '%s' "$se_hit" | cut -f2)"
                if [ "$DRY_RUN" -eq 1 ]; then
                    log "    DRY: would download from Standard Ebooks: $se_slug (score $se_score)"
                    printf '%s\n' "$raw" >> "$tmp"   # read-only: keep row verbatim
                    pace; continue
                fi
                local se_rc
                se_download "$se_slug"; se_rc=$?
                if [ "$se_rc" -eq 0 ]; then
                    printf '%s|%s|downloaded|se:%s|%s\n' "$author" "$title" "$se_slug" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                    n_done=$((n_done+1))
                    # tag-queue keys on the md5/source token; se:<slug> is unique+stable.
                    enqueue_for_tagging "se:$se_slug" "$file_tag" "$author" "$title"
                    pace; continue
                elif [ "$se_rc" -eq 3 ]; then
                    # placeholder: SE lists it but has no files yet (not public
                    # domain). SE will never have this one, so DON'T mark failed —
                    # fall through to Anna's, which may have it. No `continue`.
                    # Record SE as empty so future runs skip the SE search.
                    se_empty=1
                    log "    SE has no file for this book — falling through to Anna's Archive"
                else
                    log "    SE matched ($se_slug) but download failed — marking failed (no Anna's fallback)"
                    printf '%s|%s|failed|se:%s|%s\n' "$author" "$title" "$se_slug" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                    n_fail=$((n_fail+1))
                    pace; continue
                fi
            else
                # SE searched, nothing found — mark empty so future runs skip SE.
                se_empty=1
                log "    not on Standard Ebooks — trying Anna's Archive"
            fi
        fi

        # SE-empty marker for col 6 on the non-terminal rows we may write below
        # (quota_blocked / nomatch). Empty string when SE wasn't found empty, so
        # the writes that append "${se_mark}" stay 5-field in that case.
        local se_mark=""
        [ "$se_empty" -eq 1 ] && se_mark="|se-empty"

        # Anna's unavailable (keyless SE-only run) and SE didn't have it: leave
        # the row pending for a later run rather than burning it as nomatch.
        if [ "${ANNAS_AVAILABLE:-1}" -eq 0 ]; then
            log "    Anna's unavailable — leaving pending for a later run"
            printf '%s\n' "$raw" >> "$tmp"
            n_skip=$((n_skip+1)); continue
        fi

        # Anna's daily quota already spent earlier this run: SE was still tried
        # above (free), but this book isn't on SE. Don't hit the Anna's API again
        # — mark it 'quota_blocked' so it's visibly distinct from nomatch/failed
        # and a later run (after the daily reset) picks it up. Keep going so the
        # rest of the list still gets its free SE downloads.
        if [ "$ANNAS_QUOTA_OUT" -eq 1 ]; then
            log "    Anna's quota spent — not on SE, marking quota_blocked for a later run"
            printf '%s|%s|quota_blocked|%s|%s%s\n' "$author" "$title" "${md5:-}" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
            n_qblock=$((n_qblock+1)); pace; continue
        fi

        local hit
        hit="$(search_one "$author" "$title")"

        if [ "$hit" = "UNREACHABLE" ]; then
            # no Anna's mirror answered (FlareSolverr couldn't reach any). This is
            # infrastructure, not a real miss — leave the row pending so a later
            # run (with healthier mirrors) retries it, rather than burning it as
            # nomatch which a normal run would never revisit.
            log "    no Anna's mirror reachable — leaving pending for a later run"
            printf '%s\n' "$raw" >> "$tmp"
            n_skip=$((n_skip+1)); pace; continue
        fi
        if [ -z "$hit" ]; then
            log "    nomatch (no hit >= $CONFIDENCE)"
            printf '%s|%s|nomatch||%s%s\n' "$author" "$title" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
            n_nomatch=$((n_nomatch+1))
            pace; continue
        fi

        # Use the first (best-scored) candidate for pre-download decisions
        # (library check, quota guard, dry-run). Further candidates are only
        # tried if the first download fails for a non-quota reason.
        local first_md5 first_score first_text
        first_md5="$(printf '%s' "$hit" | head -1 | cut -f1)"
        first_score="$(printf '%s' "$hit" | head -1 | cut -f2)"
        first_text="$(printf '%s' "$hit" | head -1 | cut -f3)"

        # POST-SEARCH md5 BACKSTOP: now that we have the matched md5, check the
        # exact annas:<md5> identifier (the pre-search check was title/author only,
        # since md5 wasn't known yet). Catches a book stamped with this md5 even if
        # its stored title/author differ from the list. LIB_CHECK gates it.
        if [ "$LIB_CHECK" = "1" ] && [ -n "$first_md5" ]; then
            local idhit
            idhit="$(cdb_search_retry "identifiers:${ID_SCHEME}:${first_md5}")"
            # only the lock message (or a result that's neither a match nor a
            # clean no-match) means "unavailable" — incidental worker tracebacks
            # do NOT, see cdb_locked/cdb_search_ok.
            if cdb_locked "$idhit" || ! cdb_search_ok "$idhit"; then
                log "    library check unavailable: ${LIB_CHECK_REASON:-calibre unreadable} — deferring, not downloading"
                printf '%s\n' "$raw" >> "$tmp"
                n_skip=$((n_skip+1)); pace; continue
            fi
            local idn
            idn="$(cdb_ids "$idhit" | head -1)"
            if [ -n "$idn" ]; then
                # v82.1: TITLE SANITY (same as the other two md5 sites). The matched
                # Anna's md5 may be contaminated (a different book's file md5 — e.g.
                # Head On's, which a "Lock In" search keeps selecting). If it resolves
                # to a library book whose title contains neither list field, DON'T
                # treat it as "already owned" — fall through and download, letting the
                # post-download dc:title check decide. Without this, the backstop
                # re-stamps the row downloaded|<bad-md5> every run, undoing the
                # backfill guard's reset (the Lock In -> 1968 loop).
                local _bs_raw _bs_title _bs_contam=0
                _bs_raw="$(cdb_list_retry -f title -s "id:$idn" --for-machine 2>/dev/null)"
                if ! cdb_locked "$_bs_raw"; then
                    _bs_title="$(printf '%s' "$_bs_raw" | python3 -c '
import sys,json
raw=sys.stdin.read(); i=raw.find("[")
if i<0: sys.exit(0)
try:
    d,_=json.JSONDecoder().raw_decode(raw[i:]); b=d[0] if d else {}
    print(b.get("title","") or "")
except Exception: pass' 2>/dev/null)"
                    if [ -n "$_bs_title" ] \
                       && [ "$(title_full_match "$author" "$_bs_title")" != "1.000" ] \
                       && [ "$(title_full_match "$title" "$_bs_title")" != "1.000" ]; then
                        _bs_contam=1
                    fi
                fi
                log "    [backstop-guard] md5 $first_md5 -> id $idn found_title='${_bs_title}' row='$author' -> $([ "$_bs_contam" -eq 1 ] && echo CONTAMINATED || echo ok)"
                if [ "$_bs_contam" -eq 1 ]; then
                    log "    md5 backstop: id $idn ('$_bs_title') does not match '$author' — contaminated md5, NOT treating as owned; will download and verify by dc:title"
                else
                    log "    already in library by md5 identifier (calibre id $idn) — not spending a download"
                    printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$first_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                    n_skip=$((n_skip+1))
                    pace; continue
                fi
            fi
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "    DRY: would download $first_md5 (score $first_score)"
            [ -n "$first_text" ] && log "         matched candidate: $first_text"
            printf '%s\n' "$raw" >> "$tmp"   # read-only: keep row verbatim
            pace; continue
        fi

        # quota guard: if fast-download is on and we'd breach the floor, stop
        # using Anna's — but DON'T halt the run. SE (free) keeps working for the
        # rest of the list; this matched book (Anna's-only) is marked
        # 'quota_blocked' for a later run, and ANNAS_QUOTA_OUT skips the Anna's
        # path for subsequent books (they still try SE first).
        if ! quota_ok; then
            log "    fast-download floor reached — Anna's paused; SE still active for remaining books"
            printf '%s|%s|quota_blocked|%s|%s%s\n' "$author" "$title" "$first_md5" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
            ANNAS_QUOTA_OUT=1
            n_qblock=$((n_qblock+1)); pace; continue
        fi

        # Try each candidate in order (already sorted: score desc, then
        # English/unknown-language before foreign, then epub before pdf). A
        # non-quota failure — PDF/LIT rejection, "Invalid domain_index or
        # path_index", or an OPF LANGUAGE reject — moves to the next candidate,
        # so a foreign edition at the top of the list does not block an English
        # one further down (The Alchemyst: ar/de/nl rejected, English copy
        # reached on the next attempt). We walk up to MAX_ATTEMPTS candidates;
        # the language sort means the right one is usually attempt 1-2, and the
        # budget only bounds runaway retries on a broken record. Quota
        # exhaustion (rc=2) or success (rc=0) stop the loop immediately.
        local dl_rc=1 best_md5="$first_md5" best_score="$first_score"
        local _try_md5 _try_score _try_text _try_lr _n_cand=0 _n_dls=0
        local _saw_pdf=0      # v78: any candidate rejected as a PDF (rc=4)
        local _saw_mismatch=0 # v81: any candidate rejected as wrong-book by dc:title (rc=5)
        local _skipped_lang=0 # v80: count of foreign candidates skipped pre-download
        # search_one now emits md5<TAB>score<TAB>text<TAB>langrank (langrank: 0 =
        # English/unknown/allowed, 1 = affirmatively foreign). v80: skip a
        # langrank=1 candidate WITHOUT downloading — it would only be rejected by
        # the OPF gate AFTER spending a quota slot. dl_rc is NOT changed by a skip,
        # so a list of all-foreign candidates ends with dl_rc=1 and the book is
        # marked failed/quota_blocked as before, just without the wasted spends.
        while IFS=$'\t' read -r _try_md5 _try_score _try_text _try_lr; do
            [ -z "$_try_md5" ] && continue
            if [ "$_n_cand" -ge "$MAX_ATTEMPTS" ]; then
                log "    attempt budget reached (MAX_ATTEMPTS=$MAX_ATTEMPTS) — stopping candidate walk"
                break
            fi
            # v80 pre-download language skip. Only on an AFFIRMATIVE foreign label
            # (langrank=1); blank/unknown/und rank 0 and still download + OPF-check,
            # preserving fail-open. Costs no quota.
            if [ "${_try_lr:-0}" = "1" ]; then
                _skipped_lang=$((_skipped_lang+1))
                log "    skipping foreign-language candidate $_try_md5 (langrank=1, not in LANGS='$LANGS') — no download, no quota spent"
                continue
            fi
            _n_cand=$((_n_cand+1))
            # v83: cap ACTUAL downloads (quota spends) at VERIFY_MAX_DLS. Each
            # fast_download_md5 that isn't a pre-download skip spends a slot; once
            # we've spent that many verifying candidates without a dc:title match,
            # stop — a contaminated/absent book shouldn't burn the day's quota.
            if [ "$_n_dls" -ge "$VERIFY_MAX_DLS" ]; then
                log "    download cap reached (VERIFY_MAX_DLS=$VERIFY_MAX_DLS spends) — stopping candidate walk"
                break
            fi
            [ "$_n_cand" -gt 1 ] && log "    candidate $_n_cand: trying $_try_md5 (score $_try_score)"
            best_md5="$_try_md5"; best_score="$_try_score"
            _n_dls=$((_n_dls+1))
            fast_download_md5 "$_try_md5" "$author" "$title"; dl_rc=$?   # $author=wanted title (field inversion), $title=wanted author
            [ "$dl_rc" -eq 0 ] && break   # success — done
            [ "$dl_rc" -eq 2 ] && break   # quota exhausted — will be quota_blocked below
            [ "$dl_rc" -eq 4 ] && _saw_pdf=1   # PDF reject — note it, then try next
            [ "$dl_rc" -eq 5 ] && _saw_mismatch=1   # v81: title mismatch (wrong book) — note, try next
            # dl_rc=1/4/5: this candidate failed (download/PDF/wrong-book); try next.
            # NOTE rc=5 still SPENT a quota slot (the file downloaded, then its own
            # dc:title revealed it was the wrong book) — that's logged as a spend.
        done <<< "$hit"
        [ "$_skipped_lang" -gt 0 ] && log "    ($_skipped_lang foreign-language candidate(s) skipped without spending quota)"

        if [ "$dl_rc" -eq 0 ]; then
            printf '%s|%s|downloaded|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
            n_done=$((n_done+1))
            QUEUED_RUN=$((QUEUED_RUN+1))
            # enqueue for tagging once it imports (no-op if no tags to apply).
            # NOTE: despite their names, $author holds list field 1 (the TITLE)
            # and $title holds field 2 (the AUTHOR) — the rows are Title|Author.
            # So passing ($author,$title) into the (title,author) params is CORRECT:
            # title<-field1, author<-field2. Do NOT "fix" this by swapping them.
            enqueue_for_tagging "$best_md5" "$file_tag" "$author" "$title"
            # if the API gave us the live remaining quota, trust it over the projection
            [ -n "$QUOTA_LIVE" ] && QUOTA_START=$(( QUOTA_LIVE + QUEUED_RUN ))
        elif [ "$dl_rc" -eq 2 ]; then
            # quota exhausted mid-run (the API refused even though the floor hadn't
            # tripped — e.g. quota dropped faster than projected). Don't halt the
            # run: SE is free and still works for remaining books. Mark THIS book
            # (matched on Anna's at score $best_score, but no quota to fetch) as
            # quota_blocked, set ANNAS_QUOTA_OUT so we skip the Anna's API for the
            # rest of the list, and continue.
            log "    daily fast-download quota exhausted — Anna's paused; SE still active for remaining books"
            printf '%s|%s|quota_blocked|%s|%s%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
            ANNAS_QUOTA_OUT=1
            n_qblock=$((n_qblock+1))
            pace; continue
        else
            local _tried; [ "$_n_cand" -gt 1 ] && _tried=" ($_n_cand candidates tried)" || _tried=""
            if [ "$_saw_pdf" -eq 1 ]; then
                # at least one candidate was a real PDF and no ebook candidate
                # succeeded: the book is PDF-only on Anna's. Terminal but retryable
                # (--retry re-attempts in case an epub edition appears later).
                log "    only PDF edition(s) available for $best_md5 (score $best_score)${_tried} — marking pdf-only"
                printf '%s|%s|pdf-only|%s|%s%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
                n_pdfonly=$((n_pdfonly+1))
            elif [ "$_saw_mismatch" -eq 1 ]; then
                # v81: every candidate that downloaded turned out (by its own
                # dc:title) to be a DIFFERENT book — Anna's listings for this title
                # are contaminated (e.g. a sequel mis-titled with this book's name).
                # Mark nomatch, not failed: the wanted book genuinely wasn't among
                # the candidates. --retry re-searches in case a clean listing appears.
                log "    all candidates were the wrong book (dc:title mismatch)${_tried} — marking nomatch"
                printf '%s|%s|nomatch|%s|%s%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" "$se_mark" >> "$tmp"
                n_nomatch=$((n_nomatch+1))
            else
                log "    download failed for $best_md5 (score $best_score)${_tried}"
                printf '%s|%s|failed|%s|%s\n' "$author" "$title" "$best_md5" "$(date '+%Y-%m-%dT%H:%M')" >> "$tmp"
                n_fail=$((n_fail+1))
            fi
        fi
        pace
    done < "$file"

    # dry-run is strictly read-only on disk: the tmp may contain status changes
    # the pre-search library check would make, but we DISCARD tmp and never
    # replace the file, so mtime/inode/content are untouched. (The "already in
    # library" lines are still logged, which is useful preview output.)
    if [ "$DRY_RUN" -eq 1 ]; then
        rm -f "$tmp" 2>/dev/null
    else
        mv "$tmp" "$file"
    fi
    log "FILE $file — queued:$n_done already-done:$n_skip nomatch:$n_nomatch failed:$n_fail pdf-only:$n_pdfonly quota-blocked:$n_qblock malformed:$n_bad"
}

# count quota_blocked rows remaining across all the lists (3rd pipe field).
count_quota_blocked() {
    local f n=0 c
    for f in "${FILES[@]}"; do
        [ -f "$f" ] || continue
        c="$(awk -F'|' '($3 ~ /^[[:space:]]*quota_blocked[[:space:]]*$/){n++} END{print n+0}' "$f")"
        n=$(( n + c ))
    done
    printf '%s' "$n"
}

# re-probe quota live (via the shared helper sourced at preflight). Echoes the
# integer downloads_left, or empty on failure. Uses the helper's VALID probe md5
# (QP_PROBE_MD5), not fetch-books' invalid key-check PROBE_MD5.
# Falls back to a direct fast_api_call with the invalid-md5 probe if the helper
# is unavailable or fails — no quota consumed either way.
wait_quota_left() {
    # Primary: shared helper with a valid md5 (most accurate reading)
    if command -v quota_probe >/dev/null 2>&1; then
        if PROBE_MD5="${QP_PROBE_MD5:-$PROBE_MD5}" quota_probe 2>/dev/null; then
            [ -n "${QP_LEFT:-}" ] && { printf '%s' "$QP_LEFT"; return; }
        fi
    fi
    # Fallback: call the fast-download API directly with the invalid-md5 probe.
    # Anna's returns downloads_left in the error response for a bad md5 (the same
    # source the v42 preflight fallback uses). No quota consumed.
    local _fb_resp _fb_left
    _fb_resp="$(fast_api_call "$PROBE_MD5" 2>/dev/null)"
    _fb_left="$(printf '%s' "$_fb_resp" | python3 -c 'import sys,json
try:
    v=json.load(sys.stdin).get("account_fast_download_info",{}).get("downloads_left")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
    printf '%s' "${_fb_left:-}"
}

# Start-line parts: floor + mirrors always; retry/wait/dry-run as bare words only
# when on; SE-first shown as "check standard Ebooks". Keeps the line readable -
# absent words mean "off" rather than printing "retry: 0".
_sl="floor: $QUOTA_FLOOR, mirrors: ${#mirrors[@]}"
[ "${RETRY:-0}" -eq 1 ]   && _sl="$_sl, retry"
[ "${WAIT:-0}" -eq 1 ]    && _sl="$_sl, wait"
[ "${DRY_RUN:-0}" -eq 1 ] && _sl="$_sl, dry-run"
_sl="$_sl, confidence: $CONFIDENCE"
[ "${SE_FIRST:-0}" = "1" ] && _sl="$_sl, check standard Ebooks"
log "=== fetch-books v$FETCH_BOOKS_VERSION start ($_sl) ==="

# Sweep orphaned partial downloads. The EXIT trap deletes in-flight .part-* files
# on Ctrl-C / SIGTERM, but a SIGKILL, container restart, or hard crash bypasses
# the trap and leaves them on the media drive forever. Runs are serialized (one
# fetch-books at a time), so any .part-* present at startup is necessarily from a
# dead earlier run — but we still only purge files older than a day as a belt-and-
# braces guard, so we can't race a sibling process even if that assumption ever
# changes. Inside DL_CONTAINER, since DEST lives in its mount.
_swept="$(docker exec "$DL_CONTAINER" sh -c '
    find "$1" -maxdepth 1 -name ".part-*" -type f -mtime +0 -print -delete 2>/dev/null | wc -l
' _ "$DEST" 2>/dev/null)"
[ -n "$_swept" ] && [ "$_swept" -gt 0 ] 2>/dev/null && \
    log "swept $_swept orphaned .part-* file(s) from a previous interrupted run"

# SE needs a host downloader (curl/wget). If neither exists, disable SE rather
# than fail every book on a futile SE attempt — Anna's still handles the list.
if [ "$SE_FIRST" = "1" ] && [ -z "$SE_DOWNLOADER" ]; then
    log "WARNING: SE_FIRST=1 but no curl/wget on the host — disabling Standard Ebooks."
    log "         Install one (e.g. apt-get install -y curl) to enable SE downloads."
    SE_FIRST=0
fi
[ "$SE_FIRST" = "1" ] && log "Standard Ebooks: host downloader = $SE_DOWNLOADER (direct connection, off-VPN)"
ANNAS_AVAILABLE=1
if [ "$DRY_RUN" -eq 0 ]; then
    if ! preflight_fast_download; then
        if [ "$SE_FIRST" = "1" ]; then
            # SE is on, so a keyless run is still useful for public-domain books.
            # Disable Anna's rather than abort: SE books download, non-SE books
            # get a clear 'nomatch (Anna's unavailable)' instead of a hard exit.
            ANNAS_AVAILABLE=0
            log "WARNING: Anna's fast-download unavailable — continuing with Standard Ebooks ONLY."
            log "         Books not on SE will be left for a later run (no Anna's quota/key)."
        else
            exit 1
        fi
    fi
fi
WAIT_PASS=0
for f in "${FILES[@]}"; do
    # Name the tmux window after the list being fetched, so multiple panes are
    # distinguishable. Only when inside tmux - never under the systemd timer /
    # cron (where $TMUX is unset). Uses tmux rename-window directly (the form the
    # old hardcoded line used, known to work here), guarded so a non-tmux run is
    # a clean no-op.
    if [ -n "${TMUX:-}" ]; then
        tmux rename-window "fetchbooks: $(basename "$f")" 2>/dev/null || true
    fi
    process_file "$f"
done

# ---- --wait: keep trying quota_blocked books as quota recovers --------------
# After the initial pass, if any books are quota_blocked (Anna's quota was spent)
# and --wait is set, hold the process open: poll quota every WAIT_INTERVAL, and
# once downloads_left >= QUOTA_FLOOR + WAIT_MARGIN, run a retry pass over ONLY the
# quota_blocked rows. Repeat until none remain or WAIT_MAX_SECS elapses. SE-only
# blocks (ANNAS_AVAILABLE=0) or a missing quota probe can't recover, so we don't
# wait in those cases.
if [ "$WAIT" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ "${ANNAS_AVAILABLE:-1}" -eq 1 ]; then
    remaining="$(count_quota_blocked)"
    if [ "$remaining" -gt 0 ]; then
        need=$(( QUOTA_FLOOR + WAIT_MARGIN ))
        wait_started=$(date +%s)
        log "=== --wait: $remaining book(s) quota_blocked; will retry every $((WAIT_INTERVAL/60))m once >= $need slots free (cap $((WAIT_MAX_SECS/3600))h) ==="
        while :; do
            now=$(date +%s); elapsed=$(( now - wait_started ))
            if [ "$elapsed" -ge "$WAIT_MAX_SECS" ]; then
                log "=== --wait: giving up after $((elapsed/60))m; $remaining book(s) still quota_blocked ==="
                break
            fi
            log "--wait: sleeping $((WAIT_INTERVAL/60))m (elapsed $((elapsed/60))m/$((WAIT_MAX_SECS/60))m, $remaining quota_blocked)"
            sleep "$WAIT_INTERVAL"
            left="$(wait_quota_left)"
            if [ -z "$left" ]; then
                log "--wait: quota probe failed this cycle — will retry next cycle"
                continue
            fi
            if [ "$left" -lt "$need" ]; then
                log "--wait: $left slots free (< $need needed) — waiting"
                continue
            fi
            log "=== --wait: $left slots free (>= $need) — retrying quota_blocked books ==="
            # Fresh retry pass. Reset stale quota state so quota_ok() doesn't
            # immediately halt the pass: QUOTA_LIVE may still hold the "0" from
            # when quota ran out (quota_ok checks it first and halts if <= floor).
            # Seed QUOTA_START from the freshly-probed value and reset the
            # per-run queue counter for correct projection during this pass.
            ANNAS_QUOTA_OUT=0
            QUOTA_LIVE=""          # clear stale reading; quota_ok reprojects from QUOTA_START
            QUOTA_START="$left"    # seed from fresh probe
            QUEUED_RUN=0           # fresh count for this retry pass
            WAIT_PASS=1
            for f in "${FILES[@]}"; do process_file "$f"; done
            WAIT_PASS=0
            # If THIS pass downloaded anything (QUEUED_RUN was zeroed just above,
            # and increments only on a real download), restart the 24h cap: the
            # deadline should measure IDLE time since the last success, not total
            # elapsed time. A wait that keeps making progress stays open; only a
            # genuinely idle 24h stretch gives up.
            if [ "${QUEUED_RUN:-0}" -gt 0 ]; then
                wait_started=$(date +%s)
                log "--wait: downloaded $QUEUED_RUN this pass — 24h idle cap reset"
            fi
            remaining="$(count_quota_blocked)"
            if [ "$remaining" -eq 0 ]; then
                log "=== --wait: all quota_blocked books resolved ==="
                break
            fi
        done
    fi
fi
log "=== fetch-books done ==="
# =============================================================================
# version: FETCH_BOOKS_VERSION 83
# =============================================================================