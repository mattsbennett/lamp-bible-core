# 0019. A reader's source is deleted everywhere

Status: Accepted for core and the Mac, 2026-11-25, held by
`areadersSourceIsDeletedEverywhere` in `Verification/SyncMerge.lean`, the
`deleteTarget` conformance table, and
`removingAsourceQueuesItForTheServer`. Follows `0018`, which it is unsafe
without. Planned by Fable; the owner asked for it by name.

## Context

A writing's sources are most of what a library publishes — **355.0 MB of
363.9 MB** on the owner's, against 8.9 MB of revision history — and until now
**nothing could remove one from the server**.
`LampSyncLocalDeletion.target(of:)` answered `.unsupported` for every
workspace file, so a source was never tombstoned and never reaped. A reader
who deleted an 86 MB PDF from a writing kept paying for it, on the store and
on every device that had fetched it, for ever. Its removal travelled only
inside the workspace tree: the other Mac dropped its copy, and the bytes
stayed on the server.

## Decision

**A source is a deletable kind.** `LocalKind.contextFile` and
`LocalDeletion.contextFile` in the model, `case contextFile(folder:
relativePath:)` in Swift, allowed by `deleteAllowed`, so a removal is
tombstoned, published and reaped like a deck or a document.

- **Only `Workspaces/Writing/<folder>/Context/…`.** Every other workspace
  file is still never deleted as a file — a conversation, a skill, the ledger
  — which is what `anyOtherWorkspaceFileIsNotDeletedAsAFile` still says. A
  custom skill is published by copying its whole tree, so a skill that keeps
  its own `Context` folder is *not* a reader's source; the parse requires the
  writing folder.
- **Per file, never per folder.** Removing a folder queues one deletion for
  each file under it. A folder is not a member, so a folder's path would
  tombstone nothing and leave every file inside it on the other devices.
- **Carried out through the object store.** The receiving side goes through
  `removeDeletedSource`, which prunes the content-addressed object once
  nothing links to it. A source removed without that leaves its bytes in the
  store, which is most of what this deletion exists to reclaim.
- **Tolerant of the file being absent.** The receiving Mac may have offloaded
  it or never fetched it. There is then nothing to remove, and what matters is
  that the offload note goes — otherwise the gather would withhold a member
  that no longer exists.

## Why this is safe only after `0018`

A workspace has CLI agents running inside it. While the ledger inferred a
deletion from absence, making a source deletable would have turned any
`rm` — an agent tidying up, a failed tool call, a Finder drag — into the
permanent removal of a reader's source from the server and every device.
`0018` made absence mean nothing and put the deletion on the act, which is
what this record stands on. The two must not be separated, and `0018` is
listed first for that reason.

## What this does not do

**It does not reduce what goes up.** A source still publishes in full from
the Mac that has it; this only makes removal effective. Lazy fetch (`0018`'s
`withheld`) is what keeps a second device from pulling 355 MB, and offloading
is what reclaims the space locally.

## Still to do

- **Offload after inactivity**, as a policy over `withheld`, refusing to
  offload anything the records do not confirm the server holds at that exact
  revision.
- **Stop publishing build output**: `node_modules` and `deck-build` are 26 MB
  but 518 of 559 source members, and must be excluded rather than merely not
  gathered (`0013`).
- **The UI**: per-source status with Download, Offload and a separate,
  confirmed Remove, and an agent fetch tool with no delete.
