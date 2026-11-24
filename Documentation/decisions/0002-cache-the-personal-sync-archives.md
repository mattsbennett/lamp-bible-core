# 0002. The personal collections are compiled once per change, not once per pass

Status: Proposed. Waiting on the Phase 0 measurement in `../ScalabilityPlan.md`
and on the owner's view of the cache key below.

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

The archive's bytes are deterministic and pinned by digest tests, so a cached
archive is indistinguishable from a fresh one to everything downstream.

## Decision

Cache the compiled bytes and rebuild only when the collection changed.

The key is `personalChangeStamp()` **together with** the listing of the media
folder that `normalizingMediaIn` reads. Media presence is an input, not
incidental: the archive is refused outright when a picture a writing names is
missing from this device, so a picture arriving or leaving has to invalidate the
cache even though no row changed.

Build the archive off the actor: fetch the rows on it, compile outside it.

## Consequences

- A pass during a writing session stops recompiling writings that did not
  change, and the actor stops being held for the duration.
- The cache key is the same signal `LocalWork` already trusts to decide whether
  a pass is worth running at all. If the stamp can be stale, sync is already
  wrong in a larger way; this does not add a new assumption, it leans on an
  existing one. **That is the part for the owner to agree to.**
- The pinned-digest tests must keep passing untouched, and a new test should
  assert that a cached build is byte-identical to a fresh one and that an edit
  changes both the stamp and the bytes.
- No change to `Verification/SyncMerge.lean`: no decision moves, only when the
  same bytes are produced.
- Highlights compile per set, so a library with many sets gains the most.

## Rejected

- **Compiling only the rows that changed.** `VACUUM` and the format make the
  archive whole-file by nature; an incremental build would be a new format.
- **Skipping the verify-decompress.** It is cheap next to the compress and it is
  the check that a corrupted archive never leaves the device.
- **Moving the compile off the pass and onto the autosave.** Same work, charged
  to the keystroke path instead.
