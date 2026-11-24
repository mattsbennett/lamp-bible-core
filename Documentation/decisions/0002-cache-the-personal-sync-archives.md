# 0002. The personal collections are compiled once per change, not once per pass

Status: Accepted, 2026-11-24, held by `LampPersonalArchiveCacheTests`. The key
took two goes to get right and neither is the one this record first proposed —
see **Decision**, which carries both wrong answers, since each was plausible.

## Context

Notes, writings and each highlight set travel as a compiled `.lamp` archive.
Building one means a temp SQLite database, every row inserted, `ANALYZE`,
`VACUUM`, a zlib compress and a decompress to verify
(`LampCore/LampPersonalFile.swift`, `LampPersonalWritingFile.swift`). The Mac
builds all of them at the start of every pass
(`LampSyncMacPassLibrary.editableCollections`), and iOS does the same in
`LibrarySyncPass.exportedBytes`.

An autosave moves `personalChangeStamp`, the six-second local-work probe sees the
change and starts a pass, so during a writing session the whole corpus is
recompiled every six to ten seconds — on the `LampLibrary` actor, which means
the reader's next chapter waits behind it. The work is SQLite and zlib, so it is
already C: a Release build does not help.

Measured in Release on a quiet M-series Mac, with writings of about 10 KB:
compiling the writings archive takes 435 ms at 250 writings, 1 749 ms at 1 000
and 3 599 ms at 4 000 — roughly 0.9 ms a writing, and about thirty times what
reading the whole list costs (19 / 54 / 125 ms). Hashing the result is immaterial
beside it.

The archive's bytes are deterministic and pinned by digest tests, so a cached
archive is indistinguishable from a fresh one to everything downstream.

## Decision

Cache the compiled bytes and rebuild only when that collection changed.

The key is a **revision each personal table keeps itself**, by trigger:
`personal_revisions`, one row per kind, bumped on every insert, update and
delete of `personal_devotionals` and `personal_notes`
(`personalRevisionsSchema`). Per kind, not per library, because a pass runs
*because* something personal changed: keyed on one number for the library, the
cache would miss on every pass it was meant to spare, and one writing's
autosave would still recompile the notes.

Two keys were tried first and both were wrong.

**`personalChangeStamp()`**, which this record originally proposed, is the
maximum over *every* kind, so a writing's autosave moved the key for the notes
and every highlight set too. Useless rather than unsound.

**A per-kind maximum of the sync ledger** replaced it, and that one was unsound
— caught by a review the day it landed, before it had reached a build anyone
runs. The ledger is not a record of change: `present_since` means "this device
saved this item", and a copy carried in by sync deliberately does not stamp it,
so that an arriving copy cannot outrank a deletion recorded in between. Five
writers change rows without stamping: the two sync-import paths, conflict
resolution, the ledger-driven deletions, and the notes merge. Since a pass
installs the other device's rows *after* gathering and *before* re-exporting
the merged file, the Mac would have republished its own pre-merge bytes over
the copy just merged in — deterministically, in the ordinary two-device case —
and a resolved writing conflict would never have been published at all. The
ledger's values are also clock readings from whichever device wrote them, so a
device whose clock ran fast would have held the maximum still for as long as it
was ahead.

A trigger-kept revision answers all of it: no writer has to remember, nothing
is a clock, `INSERT OR REPLACE` and `ON CONFLICT DO UPDATE` both land on a
counted statement, and because the count lives in the file, a write from
`lamp-mcp` — another process on the same library — is seen, which an in-memory
counter would miss.

**Together with** a fingerprint of the writing media — every file under
`Media/Devotionals`, by path and modification time. Media presence is an input,
not incidental: the archive is refused outright when a picture a writing names
is missing from this device, and a picture can arrive or go with no row moving,
since a media file and the row naming it travel as separate sync files. Without
it, a picture deleted outside Lamp would be followed by a pass publishing bytes
built while it was there. The archive embeds no picture's bytes, so a file
rewritten at its path changes nothing and does not need to invalidate anything —
but it does, harmlessly, because the fingerprint includes the date.

The stamp is read **before** the rows. A write landing between the two then
leaves the cache keyed on a stamp older than its bytes, which costs one needless
compile on the next pass; keyed on a stamp taken *after* the rows, the same
write would be cached as though it were already in the file, and would never be
published at all.

The compile runs off the actor — rows fetched on it, compiled outside — using
`FileManager.default` rather than the library's own, since Foundation will not
let a `FileManager` cross an isolation boundary and no caller has ever supplied
one.

## Consequences

- A pass during a writing session stops recompiling writings that did not
  change, and the actor stops being held for the duration.
- The cache depends on nothing but the database's own count of changes to the
  rows it compiles. It does not lean on the ledger, which answers a different
  question, nor on any clock.
- A `UserData.sqlite` replaced underneath the library — a restore, a copy put
  there from outside — drops the cached archives, since what was read from the
  file before it answers for nothing in the new one.
- The pinned-digest tests must keep passing untouched, and a new test should
  assert that a cached build is byte-identical to a fresh one and that an edit
  changes both the stamp and the bytes.
- No change to `Verification/SyncMerge.lean`: no decision moves, only when the
  same bytes are produced.
- Highlights are still compiled per set on every pass. They are built on the
  Mac's side of the pass (`exportHighlights`), not by `personalArchive`, and the
  ledger has no per-set stamp — `highlight`, `highlightSet` and `highlightTheme`
  are keyed by item, not by set — so the most a cache could key on there is
  highlights-wide. Left for its own change.
- `personalArchiveCompiles` counts compiles, so a test can prove one did *not*
  happen. A cache with no such counter is a cache nothing can hold to its claim.
  Three of the tests are about the key rather than the cache: a writing carried
  in by sync, a resolved conflict, and notes carried in by sync must each be in
  the next archive. All three pass now and would have failed on the key this
  record first landed with.
- The writing media fingerprint includes hidden names. A picture stored from a
  source called `.photo.png` is kept as `.photo-xxxxxxxx.png`, which the
  archive requires like any other, so skipping hidden files would have served
  bytes for a collection that is in fact refused.

## Rejected

- **Compiling only the rows that changed.** `VACUUM` and the format make the
  archive whole-file by nature; an incremental build would be a new format.
- **Skipping the verify-decompress.** It is cheap next to the compress and it is
  the check that a corrupted archive never leaves the device.
- **Moving the compile off the pass and onto the autosave.** Same work, charged
  to the keystroke path instead.
