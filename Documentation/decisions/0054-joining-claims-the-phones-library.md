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

## Review

Three Codex rounds were run over the harness and this change.

- **Round one.** It said a Move or Join pressed after sync was repointed
  acts on the new destination. I bound the offer to its source and account.
- **Round two.** Every finding was in that binding:
  - an account read after an await;
  - a follow-up registered before the guard;
  - the offer judged only once.

  The binding protected nothing. A stale Move is refused by its revision
  check, and a stale Join claims only what a fresh offer at the new
  destination would claim. A library the Mac kept refuses Join. So, by
  0022's rule, the binding was cut and round one's finding is not a defect.

  What round two found that was real: an offer refused at the server stayed
  on offer, and Sync Now never judged it again. Now the offer is judged
  again whenever the bundle path's revision is not the one judged, and
  always where nothing is there. Both providers are judged by core's
  `earlierLibrary(in:)`. The Move admits itself as every pass does.
- **Round three.** No P0 or P1. Left, as rare and losing nothing:
  - **A server whose HEAD omits the ETag its GET sends.** The archive is
    judged as a loose tree, and the Move is refused as "import again".
    Earlier code failed the same way. Nothing is lost; the Move can't run.
  - **An archive that changes between the HEAD and the classifying read.**
    The offer is recorded under the older revision. The Move is refused and
    the next sync judges it again, as the refusal says to do.
  - **Two servers whose archives share an ETag.** After a repoint the old
    offer stays. Synology's tags make that unlikely.
  - **Join skips the old reader's manifest checks.** A phone's archive with
    a bad legacy manifest can be claimed. Its settings are carried across
    either way.
  - **Join can leave copied files behind if it loses the race.** Core copies
    format-3 writing files before its conditional write, so a Join that loses
    to another Mac can leave them. They are written only where absent. This
    is core's routine, shared with iOS.
  - **A phone's folder can leave its old settings database behind.** Its
    legacy `UserData` database is not carried into the first bundle. This is
    core's claim, shared with iOS.
