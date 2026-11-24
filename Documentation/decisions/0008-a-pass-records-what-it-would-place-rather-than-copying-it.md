# 0008. A pass records what it would place, rather than copying it into scratch

Status: Accepted for the Mac, 2026-11-24, held by
`WorkspaceExportRecordTests` and the 56 exporter-pinning tests it sits
beside. Design reviewed by Fable; the implementation reviewed by Codex,
which found three defects in it — see the Decision and Consequences, and
`0009`, which this decision turned out to depend on. The phone has no
workspace export at all, so nothing here is asked of it.

## Context

A Mac sync pass asks `LampSyncLocalFiles.workspaceFiles` what this app holds.
That ran the real workspace exporter into a scratch directory and then walked
the directory to list the candidates — so every pass copied every document,
every context file, every revision and every transcript of every workspace,
to hash them and send a handful.

The exporter was doing two jobs and only one of them was wanted. The wanted
one is that **the exporter decides the published paths**: it is the single
place that knows a workspace's `Documents/`, `Context/`, `Revisions/`,
`Conversations/` layout, and a pass that did its own path arithmetic would be
a second copy of that layout to keep in step. The unwanted one is the bytes.

Measured at two hundred and fifty workspaces — five documents and fifty
revisions each, fourteen thousand files — the gather was **2.9 s**, which
with `0002` caching the per-pass compile away and `0007` keying digests on
file identity made it the largest thing a local pass does. A pass runs every
six to ten seconds while someone writes.

The cost is **per file, not per byte**: `copyItem` on APFS clones, so the
bytes are never moved. Hard-linking instead was tried and measured *slower*
(4.8 s against 2.9 s) — the extra `link(2)` buys nothing a clone did not
already give, and the cost that remains is five or so syscalls a file,
fifteen thousand times. The fix therefore has to be **fewer file operations,
not cheaper ones**.

## Decision

`exportPortableWorkspaces` takes an optional `WorkspaceExportRecord`. Given
one, each place it would have copied a file it instead records the published
path and the URL of the **live** file, and copies nothing. `workspaceFiles`
passes a record and reads the candidates off it.

The exporter keeps deciding the paths, and keeps its side effects: each
workspace's file ledger is still saved and its document deletions still
recorded. That is why the export still runs on every pass rather than being
replaced by path arithmetic in the caller.

**What a writer can rewrite at its path while the pass runs is still
copied**, and the copy is what goes into the record. The rule, and it is
the whole of the decision's soundness:

> A recorded path is read twice — hashed at the gather, sent at the upload —
> so recording the live file is sound only where the file cannot be rewritten
> at that path in between.

`LampSyncBundlePass` reuses the gathered digest for a path whose URL it was
handed (`LampSyncBundlePass.swift:516-518`), so a file that changes under a
pass is sent as new bytes recorded under the old digest — and a later revert
to those bytes then reads as already synced. A document's digest is also the
`agreedDigest` a later pass judges "edited here since" against.

So **snapshotted**: a document (a pane, an agent or a command-line tool
writes it), a custom skill (`WorkspaceSkillStore.saveSkill`) and the
enabled-skills selection (`writeSelection`, on every tick of a checkbox).
Five or six files a workspace against fifty-odd revisions, so the copy costs
almost nothing. Transcripts and the portable ledger are written into scratch
and recorded from there in any case: those bytes exist nowhere else, because
a transcript is re-encoded on the way out.

And **recorded**: revisions, written once under a timestamped name, and
context files, content-addressed and read-only.

That is as far as "written once" goes, and not as far as it first appeared.
A revision's *bytes* are never edited, but compaction deletes a revision and
replaces it with a merged one — and a pass does that to itself, between its
gather and its upload. `0009` is what makes recording sound in the face of
it, by having the upload digest what it sends; this condition is about which
files are worth copying, not about what the pass may assume of them.

The first version of this recorded the skills and the selection too. Caught
by a Codex review, which also found that the selection was the one path
reached by a bare `fileExists` rather than through `childFiles` or
`copyTree`: both of those exclude symlinks, and a recorded symlink would have
a pass stat it, hash it and publish the bytes at the far end — any file this
app can read. Copying one had left a link in the staging directory that the
enumeration skipped, because it asked for regular files. Now guarded, and
held by `aSymlinkedSelectionIsNotPublished`, which publishes an outside
file's bytes if the guard is removed.

## Consequences

- The gather falls from **2.9 s to 1.10 s** at two hundred and fifty
  workspaces, and from **14 000 staged files to 1 250**. Both counts are of
  regular files, and `MacScaleMeasurementTests` now runs the old copying
  export beside the new one in the same run so the two are counted alike:
  copying is still 2.4 s, for the copy on its own, before anything is
  enumerated. The first version of this record compared a file count against
  a subpath count that also included directories.
- A deleted `.backup` export is unaffected: `writingFolder == .backup` still
  copies everything, because a backup *is* the bytes.
- The decks a `.perFile` pass never looks at are no longer exported at all.
  `LampSyncLocalFiles.workspaceFiles` already skipped whatever that staged,
  so exporting them copied every deck and every deck image into a scratch
  directory, every pass, to be ignored.
- A candidate's URL may now be a live file under the library rather than a
  copy, so anything downstream that assumed a stable scratch copy is wrong.
  **One thing did**, and this record said it did not: the upload loop reused
  the digest taken at the gather, so a file rewritten in between was sent as
  new bytes recorded under the old digest. Found by a Codex review, fixed in
  `0009`, where the measurements that ruled out the alternatives are also
  recorded. A candidate is now read twice — hashed at the gather, hashed
  again as it is sent.
- `0007`'s second condition says workspace files keep hashing because they
  "are exported fresh into scratch every pass and so have new inodes anyway".
  That reason is now gone for the recorded kinds, so
  `keepsDigestAgainstIdentity` could be extended to them. **Open, and worth
  more than this record first claimed.** Digesting all 14 000 candidates at
  250 workspaces is 706–765 ms, and **177 ms** when a cache answers every
  one: about **530 ms of a 1.8 s pass**, not the 150 ms recorded here at
  first. That figure came from running `describe` twice over the same
  candidates and timing the second run — but `describe` consults the cache
  only for kinds where this is true, and `.workspaceFile` is not one, so it
  measured a warm page-cache re-read and not a cache hit at all. Caught by a
  Codex review of the measurement. `MacScaleMeasurementTests` now offers the
  same files under a kind the cache does answer for.

  Of that 530 ms, about **470 ms** is actually reachable: the measurement
  offers every candidate under a cacheable kind, including the ~1 250 staged
  ones, and a staged file is written into a scratch directory named
  `lamp-sync-<UUID>` per pass, so it has a new path and a new inode every
  time and could never be answered from a cache. The recorded files —
  revisions and context — are some 12 750 of the 14 000.

  **Done in `0011`**, by moving the per-file answer off the kind and onto
  the candidate: `.workspaceFile` covers both the recorded files, which are
  fixed at their path, and the staged ones, which get a fresh scratch path
  every pass, and only the exporter knows which is which. Measured honestly
  — which took three attempts, each smaller than the last — digesting falls
  from about 720 ms to about 335 ms.

## What it must not break

- **What is published is the same.** `recordingPublishesWhatCopyingPublishes`
  runs the export both ways over the same workspace and compares the
  published path to the bytes behind it, which is all a pass ever uses.
- What can change under a pass is staged and what cannot is pointed at:
  `whatCanChangeUnderAPassIsStagedAndTheRestPointedAt` asserts where each
  recorded URL sits, for all five kinds. Both halves bite — removing the
  snapshots fails it three times.
- A symlink is never published: `aSymlinkedSelectionIsNotPublished`.
- The ledger and the deletion records are still written. The existing
  exporter tests cover that and were not relaxed.

## Rejected

- **Hard links instead of copies.** Measured slower; see Context.
- **Path arithmetic in the caller**, skipping the exporter. It duplicates the
  layout, and silently loses the ledger and deletion side effects.
- **A linear scan to replace a path placed twice.** `removeAll` on the
  record's array cost *more than the copying it replaced* — 7.1 s against
  2.9 s, fifteen thousand files of string comparisons. The record keeps an
  index of where each path sits. Caught by re-measuring rather than by
  review, which is the argument for measuring after a change and not only
  before one.
