# 0054. Joining claims the phone's library

Status: Accepted, 2026-11-28. Mac `LibrarySyncController.move`, held by
`joiningClaimsThePhonesLibraryThenSyncs` and
`joiningRefusesALibraryAMacKeptSince`.

## Context

On a server where only the phone has synced, the Mac offers **Join** instead
of **Move**. Pressing it had never worked. The Mac ran
`LampSyncLibraryMigration.migrate` for both offers, and that refuses any
library the Mac did not keep. The reader saw "This library was not kept by
the Mac, so the Mac does not move it." and nothing else could be done.

The harness in 0053 found this while planning; its first Join test
reproduced it.

Core already has the routine for the phone's case,
`LampSyncSettingsStore.migratePhoneLibrary`, and iOS calls it before running
a pass. It claims the bundle path:
- the first bundle carries the phone's settings and shared preferences;
- it is written only over the archive as read;
- a library the Mac kept is refused, and nothing is written.

The phone's modules are already one file each, so the pass after the claim
adopts them.

## Decision

`move` branches on the offer:
- **Move** reads the archive again, names any entry it cannot place, and
  runs the Mac's migration, as before;
- **Join** calls `migratePhoneLibrary`.

Both then run the same pass and the same follow-up.

## Rejected

- **Removing the Join offer**, so a phone-only library always went through
  Move. Move refuses a phone's library by design, so the reader would be
  offered a button that always fails.
- **Join conditioned on the revision this Mac imported, as Move is.** That
  condition exists because Move rewrites the library from the archive, and
  anything another device added since would be lost. Join carries the
  archive's own contents into the bundle and writes only over the archive
  it read, so the revision it read is the right condition.
