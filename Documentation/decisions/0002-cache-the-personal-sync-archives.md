# 0002. The personal collections are compiled once per change, not once per pass

Status: Accepted, 2026-11-24, held by `LampPersonalArchiveCacheTests`. The key
is not the one this record first proposed — see **Decision**.

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

**Not keyed on `personalChangeStamp()`**, which this record first proposed and
which would not have worked. That stamp is the maximum over every kind of
personal item, and a pass runs *because* something personal changed — so one
writing's autosave would have moved the key for the notes archive and every
highlight set as well, and the cache would have missed on every pass it was
meant to spare. The ledger's primary key is `(kind, item_key)`, so a per-kind
stamp costs an index-prefix read: `personalItemStamp(.devotional)` for the
writings, `.note` for the notes. A writing session now leaves everything but the
writings alone.

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
- The cache keys on the same ledger `LocalWork` already trusts to decide whether
  a pass is worth running at all, read one kind at a time. If those stamps can
  be stale, sync is already wrong in a larger way; this does not add an
  assumption, it leans on an existing one.
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

## Rejected

- **Compiling only the rows that changed.** `VACUUM` and the format make the
  archive whole-file by nature; an incremental build would be a new format.
- **Skipping the verify-decompress.** It is cheap next to the compress and it is
  the check that a corrupted archive never leaves the device.
- **Moving the compile off the pass and onto the autosave.** Same work, charged
  to the keystroke path instead.
