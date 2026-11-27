# Review marks performance plan

Planned by Fable on 2026-11-26, against core `5b91518`, Mac `d860e96` and
iOS `876e01f`. The coordinator checked the load-bearing claims against the
code the same day. Line numbers will drift; the names are what last.

The owner asked for faster drawing, clearing and restoring of review marks,
and reported that something occasionally blocks the main thread while
typing in the Mac's writing editor.

## Where the time goes

The test case is a real writing of 57,002 UTF-16 units. Its marks file is
1.1 MB: 447 marks with 914 pieces, 963 clearances with 4,136 pieces, 1,094
retired marks, and 442 kept wordings. In a Release build on a loaded
machine, one `drawing(in:forPlacing:)` takes about 1,000 ms:

- `anchored(in:)`: 809 ms
- `located`: 147 ms
- the rest: about 50 ms

Findings:

- **`anchored(in:)` is about 3,957 full-text scans.** Each stale piece
  calls `find`, then `unique`, then `only`. `only` scans the whole text to
  prove the context stands once.
  - 3,955 of those pieces are clearance pieces. All 963 clearances belong
    to one mark, `B605EF88`, a passage of 453 pieces; this was checked.
  - The cost is stale pieces times text length.
  - It repeats on every draw by design: a carry that moves nothing writes
    nothing, so stale anchors never refresh.
- **`located`'s 147 ms is the subtraction loop:** 453 × 4,136 calls to
  `subtracting`, each allocating. None of the cleared ranges touches the
  mark's drawn ranges, because `clearing` has already rewritten the mark's
  own pieces.
- **`drawing()` already shares one `located` between `restorable` and
  `changes`.** The four ~145 ms figures first reported were the same
  `located` call, timed through four public wrappers.
- **A ✓ pays the same work twice:** `clearing` runs `carryingToText` and
  then `located` before the draw starts.
- **A save's carry holds the file lock while it searches,** so a ✓ pressed
  meanwhile waits on it.
- **The 90-day prune of retired marks has no caller in either app.** This
  was checked. `pruning(before:)` and `retirementLifetime` are used only by
  tests.

## Order

Every item is measured with the R0 harness: Release, the same record,
before and after.

**R0. Harness and goldens.**

- `LampReviewMeasurementTests`: skipped unless `LAMP_REVIEW=1`; output
  lines start with `REVIEW`; the median of five runs, and instructions from
  `proc_pid_rusage`.
- Six scenarios:
  - S1: the old probe's stages;
  - S2: a draw after one word typed, at 25% of the text and inside the big
    mark;
  - S3: a draw with 24 held texts;
  - S4: a ✓ inside the big mark and on a small mark;
  - S5: a save's carry;
  - S6: restoring, by range and by marks.
- `LampWritingReviewGoldenTests`, always on: hashes of a canonical dump of
  each `Drawing` and of each resulting record's `encoded()` bytes, with
  fixed dates. Synthetic fixtures are built through the real API.
  - The hashes are frozen from the code before any change.
  - The private record is compared against a hash file kept outside the
    repo.
- The old `only` and the old subtraction loop are kept in the test target,
  as references for differential tests.

**R1. `only` asks an index of the text instead of scanning it.**

- A per-text search object holds the `NSString`, its UTF-16 units, and a
  lazily built map from each 4-unit run to its positions.
- Candidates come from the map in order, and each is confirmed with today's
  `range(of:options: [.literal, .anchored])`, so Core Foundation still
  decides every match. Needles shorter than 4 units keep today's loop.
- `drawing` shares one object between `anchored` and `located`; `carried`
  keeps one per source.
- `exact` gets a unit-equality fast path.
- Target: `anchored` from 809 ms to 10 ms or less.

**R2. `located` skips clearances that touch nothing.**

- Run today's subtraction step only where a range touches the cleared
  range; otherwise apply the remainder once, on the first step.
- Don't trim beforehand: a zero-length clearance at an untrimmed piece's
  whitespace edge removes that piece today, and trimming first would keep
  it.
- Target: `located` 10 ms or less; `drawing` 80 ms or less.

**R3. Measure again**, and make an item of any stage still over 100 ms off
the main thread or 16 ms on it.

**R4. The Mac's ✓ path.** Signposts first, then fixes only where they
point. Candidates:

- superseded draws are never cancelled;
- `restoring(_:in:)` runs a carry and an unanchored `located` on the main
  actor, in `DevotionalEditorView`;
- a ✓ waits on the lock behind a save's carry.

**R5. The page.** Time `setReviewMarks` and the review plugin's `apply` on
each keystroke.

**R6. A decision record against compaction for now,** and the 90-day prune
put to the owner.

- Clearances are bounded by the words in their mark, and go when it is
  retired.
- A rule for dropping them would need "every device has merged", and would
  touch `aClearanceIsNeverLost` and `Verification/coverage.json`.

Not recommended for now:

- caching anchors by text digest, which R1 makes unnecessary;
- persisting anchors, which would resend the record on every edit;
- an incremental redraw in core, since the page already does that for
  typing;
- a pure-Swift matcher, which may differ from Core Foundation at composed
  characters.

Each of R1, R2 and R6 gets a decision record, with its rejections.

iOS calls the same core functions:

- `Lamp Bible/View/WritingReviewSession.swift`: the draw, the clear, the
  restores, and the save's carry. Its typing-settle path calls
  `passageCount` on the unanchored record, so it pays for the scans too.
- `WritingFilesSheet.swift`.

## Typing lag

Suspects from reading the code, none verified:

1. `monitorWorkspaceDocuments` in `DevotionalEditorView`. It runs on the
   main actor every 700 ms, lists the workspace, and reads every companion
   file.
2. The page's own main thread:
   - `getMarkdownContent()` 300 ms after a pause;
   - `reportCaret` forcing layout on every key;
   - `setReviewMarks` re-parsing the 65 KB marked copy.
3. The app's work on each content report: `portableMarkdown` and
   `updateNSView`.
4. CPU time taken off the main thread by stacked draws and carries.

The investigation, in order:

- **T1. Instrument.** Release, and inert unless `LAMP_TYPING_PROBE=1`.
  - The app's main thread: a run-loop observer logging wall time and thread
    CPU time.
  - Signposts on the main actor and off it.
  - In the page: per-key timings, brackets around the review work, and a
    frame heartbeat.
- **T2. Drive it.** Send keys through `window.sendEvent`, in bursts that
  cross the 300 ms report, the 300 ms settle, the 700 ms and 1 s polls and
  the 1.5 s autosave. Run it with marks on and off, and with the agent pane
  open and shut. Use `xctrace` CPU counters.
- **T3. Read it.**
  - CPU close to wall time on the main thread means computation there.
  - CPU well below wall time means waiting on input or a lock.
  - A late `keydown`-to-applied time means the page's own work.
  - A heartbeat gap means the page was busy.
  - Late frames while a draw is open mean the work off the main thread.
- **T4.** Fix only what T3 names.
