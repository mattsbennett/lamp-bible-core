# 0018. A missing source is not a deletion

Status: Accepted for the Mac, 2026-11-25, held by
`aSourceThatMerelyGoesMissingIsNotDeletedEverywhere` and the withheld cases in
`LampSyncBundlePassTests`. Planned by Fable off the back of
`../ScalabilityPlan.md`'s measurements; the owner's ask was "it isn't
sustainable to sync this much".

## Context

A writing publishes its sources under `Workspaces/<kind>/<id>/Context/`. On
the owner's library that is **355.0 MB — 97.5% of everything the library
publishes** (23 PDFs are 307 MB of it; revision history, by comparison, is
8.9 MB). The phone has never taken a byte of it: its `isPlanned` declines
`.workspaceFile` and always has.

Three things were true of a source, and together they made it impossible to
manage:

1. **`LampSyncLocalDeletion.target(of:)` answers `.unsupported`** for a
   workspace file, so a source is never tombstoned and never reaped. Removing
   it does not shrink the store, ever.
2. **A member with no local copy is downloaded on every pass.** So removing a
   source locally would have had it fetched, written, and discarded by
   `mergeTree(skipping:)` on every pass for ever — `0016`'s defect, latent
   only because the owner had not yet removed one.
3. **The ledger inferred a deletion from absence.** `noteChanges` diffed what
   it remembered against the disk and called anything missing deleted.

(3) is the one that matters, because it makes (1) unsafe to fix. A workspace
holds CLI agents that run in it; a source gone from disk may mean the reader
removed it, or that this Mac offloaded it to free space, or that something
tidied up. Inferring "delete it from every device" from any of those loses an
86 MB source nobody meant to touch — and it would do so *permanently* the
moment a source became a deletable kind.

## Decision

**Absence is withheld; only an act deletes.**

- **`Gathered.withheld`** (core): a client may decline a *path*, not only a
  kind. A withheld member leaves the plan before any action — not fetched,
  not deleted, not recorded, not a failure — and pruning still sees the whole
  listing. It is the treatment `plannedKinds` already gives a kind, which is
  what the phone has done to every workspace file from the start.
- **The Mac withholds a source it does not hold.** Still on the server,
  absent here, fetched when something asks. That is lazy fetch, and it is the
  same predicate that stops the refetch loop in (2).
- **`WorkspaceContextFileStore.deleteContextFile`** is the only thing that
  means *delete it everywhere*. It removes the file, prunes the object store,
  and records the deletion in the ledger. `noteChanges` no longer invents one
  for a context key.

**Withheld is a policy, not a claim**, and that distinction is the whole
lesson of `0016` and `0017`. Those records exist because a client asserted a
*fact* about why a file was absent — "superseded, held in merged form" — and
was wrong in a new way for four review rounds running. `withheld` asserts
nothing about why: it says only that this client is not taking part in the
path. Nothing downstream has to be right about the reason.

## What follows

- **A document keeps the old behaviour.** Its deletion still travels from
  absence, and its times are comparable across Macs. Only sources changed.
- **Removing a source in Finder no longer propagates.** It reads as
  "offloaded" — present on the server, absent here. The owner agreed to this
  explicitly; the app's own control is how you say "remove everywhere".
- **An agent cannot delete a source.** It has no delete tool, and its `rm`
  now means absence rather than deletion. Before this, an agent tidying a
  workspace deleted the reader's sources from the *other* Mac, and after
  context became deletable it would have deleted them from the server too.
- **Eviction is now expressible**, which it was not: offloading a file is
  making it absent, and absence used to mean deletion. Compression was the
  owner's first instinct and is the wrong lever — measured on their files,
  the six largest PDFs compress **1.07×**, because a PDF is already
  deflated. Eviction reclaims all of a file rather than 7% of it, and
  "unarchive" is the ordinary fetch, so there is no resume problem: a
  half-fetched workspace is lazy fetch's normal state.

## Still to do, each its own record

- **Make a source a deletable kind** so the store can shrink. Safe only after
  this record, and it moves `deleteTarget` and a Lean rule.
- **Offload after inactivity**, as a policy over `withheld`, refusing to
  offload anything the records do not confirm the server holds at that exact
  revision — otherwise freeing space loses a source.
- **Stop publishing build output.** `node_modules` and `deck-build` are 26 MB
  but **518 of 559 context members**, and `LampWritingImport.skippedFolders`
  already names the folders to skip. It has to be done *as* an exclusion: not
  gathering them would make this client look as though it did not hold them,
  which is how `0013` says a client asks for a download.
- **A UI** showing per-source status with Download, Offload and a separate,
  confirmed Remove — and the agent instructions must list offloaded sources,
  or an agent will believe they are gone.
