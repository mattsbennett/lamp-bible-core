# 0055. The Move keeps the old library

Status: Accepted, 2026-11-28. Mac `LibrarySyncController.keepOldLibrary`,
held by `movingKeepsTheOldLibraryBesideTheBundle`,
`aMoveStopsIfTheOldLibraryCannotBeKept` and `aMoveRunAgainKeepsOneCopy`.
Recommended by Fable at the owner's request.

## Context

Codex's first review of the harness (0053) found a loss that predates the
harness.

The Mac has imported no archive since Mac `9423bba` (2026-10-20, "Sync only
through the bundle"). The revision a Move is conditioned on comes from the
read that judges the offer, not from an import. `LampSyncLibraryMigration`
carries only the settings and ledgers into the first bundle, and relies on
the Mac's next pass to publish the rest from its own library. On WebDAV the
first bundle is written at the archive's own path.

So anything that lived only in the archive was overwritten. That covers
installed modules, workspaces, decks and media from another Mac, or from a
library this Mac no longer holds. Notes, writings and highlights fare better:
the archive-era Mac also published them file by file, and the pass after the
Move adopts those files.

The Move's own text said "Nothing is deleted from the server by the move".
The owner's library had already moved.

## Decision

- **Keep the archive.** On WebDAV, before the migration, the Move writes the
  archive's bytes to `lamp-bible-before-move-<digest>.lampsync` at the root.
  - Nothing a pass lists looks there.
  - The write is conditioned on the path being absent, so a refusal means the
    archive is already kept, and a Move run again keeps one copy.
  - Any other failure stops the Move before anything is replaced.
  - A folder's old tree stays where it is, as before.
- **Say the truth.** The offer's text now reads: "The move publishes this
  Mac's library. The old library is kept on the server beside the new one,
  so nothing is deleted, but anything only it held — from another Mac, say —
  is not brought across." The comments on the controller and on core's
  migration say the same.

What stays: another Mac's work that this one never had is on the server
only in the kept archive, until that Mac updates and publishes it, or
someone recovers it by hand.

## Rejected

- **Import the archive first.** That rebuilds the archive-era merge that
  `9423bba` and core `dbb4555` deleted, including the writings' JSON
  normalisation and the compatibility manifest's supersession. It runs to
  several hundred lines across both repos, and no archive-era library is left
  to prove it on.
- **Leave it.** It knowingly overwrites what may be the only full copy.
- **Refuse when the archive holds what the Mac's library doesn't.** No
  comparison is sound without an importer:
  - by bytes, it refuses a legitimate mover who has edited anything since;
  - by path, it strands one who has deleted something, and misses edits
    inside shared files.
- **Refuse a Mac that holds none of the archive's modules.** A narrower check
  by module file name, which the export copied by name. Module IDs were
  renamed on 2026-11-16 (BSBs to BSB), so a legitimate Mac's names may no
  longer match an older archive's, and the check was dropped rather than
  refined.
