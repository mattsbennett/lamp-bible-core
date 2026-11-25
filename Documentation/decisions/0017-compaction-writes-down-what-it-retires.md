# 0017. Compaction writes down what it retires

Status: Accepted for the Mac, 2026-11-24, held by `RevisionMembersHeldTests`.
Supersedes `0016`, which reached the same goal by inferring from absence; four
review rounds found the same hole in that inference three times over, and the
planner withdrew the choice.

## Context

`0016` stopped a real defect, confirmed live on the owner's library: a
revision file compaction deletes is downloaded again on every pass, for ever.
Two passes of the pre-fix build reported **45 revision members fetched again,
every one on both passes**, with the revisions folder byte-identical
afterwards — fetched, written by the merge, deleted again by the compaction on
the next line, net zero, in perpetuity.

Its mechanism was: a member with a sync record and no local file is claimed as
held, because *compaction only ever removes a file it has replaced*. That
reading of absence is where the trouble was. Three review rounds, each on a
different symptom of it:

1. **Claiming by `replacedRevisionIDs` reached 10 of 43.** `coveredRevisionIDs`
   is `replacedRevisionIDs ?? [id]` and `merge` unions the two sides' *covered*
   sets, so a merge of a merge names the originals and never the intermediate.
   A run of *n* autosaves leaves *n−1* intermediates named by nothing that
   outlives them, and `mergedID` is a truncated SHA-256, so no name can be
   recovered afterwards.
2. **A demotion needs every id an untagged merge replaced.** Claiming one kept
   it away for good, so a turn's changes would stay under no turn's name.
   Patched by keeping those fetchable; then narrowed again, because a
   `.userEdit` merge can never be demoted at all (`canMerge` refuses mixed
   kinds, and nothing typed carries a turn) and was fetching for a demotion
   that could not happen.
3. **"Any local history exists" is not evidence.** The guard added for a
   workspace that lost its `.lamp/revisions` was satisfied by a single new
   edit saved into the emptied folder — after which every older member was
   claimed and the server's only copies skipped. And finding the ids at all
   meant decoding every workspace's history on every pass, both document
   snapshots per revision, while holding `WritingWorkspaceFiles` — the owner
   the editor's own writes queue behind.

Each patch moved the ambiguity somewhere else, which is the signature of a
wrong shape rather than a run of defects.

## Decision

**`compact` writes down the ids it removes, and the claim reads that list.**

- `.lamp/retired-revisions.json`, beside `draft-sync.json`. Only
  `.lamp/revisions/*.json` is published, and `SyncSupportTests` pins that, so
  this is local state by construction: no tombstone, nothing the phone sees,
  no synced format change, nothing in `SyncMerge.lean` or `coverage.json`.
  `0015` is untouched.
- **One id a line, appended, never rewritten.** This is on the autosave path,
  and a decode-sort-rewrite of the whole list under the store's lock was
  measured at 44 ms against 3 ms once fifteen thousand ids had accumulated —
  latency growing for ever with the file. A torn append leaves one
  unparseable line, which the reader skips, so that id is fetched once and
  retired again.
- Written between putting the replacements on disk and deleting what they
  replace. A crash after the write and before the delete leaves a retired id
  whose file is still there, which changes nothing — the claim is only
  consulted for a member with no local file. A crash the other way leaves a
  deleted revision unretired, which costs one download and then retires
  itself.
- The gather claims a missing member whose id is on its workspace's list. One
  small file per workspace, read only for workspaces that have a missing
  member, nothing decoded.

The sentence that decides it: **a sync record says *installed here once*; what
the claim needs is *removed here deliberately, with its replacement on disk*,
and only the code that did the removing can say that.** Every guard in `0016`
was an attempt to infer that fact from things that do not carry it.

The demotion exception moves to the writer, where everything is already
decoded: **nothing a surviving demotable merge covers is retired.** The first
version withheld only revisions that knew their own turn, and a reviewer
showed that was not enough — `removingReplaced` needs a holder for *every* id
the merge covers and only one of them has to know a turn, so retiring an
untagged original blocks the demotion for good while the tagged one is
fetched and discarded for ever. Only an agent's merge counts as demotable: a
`.userEdit` merge can never be demoted, so nothing is held back for it.

Everything else compaction deletes is retired, including a duplicate name of
a revision that stays — the published copy at the deleted name has no file
either, and nothing else would say why.

**And a retirement is not trusted on its own.** It says the replacement was
on disk when compaction ran, not that it still is, and it is not a standing
verdict. Two further conditions, both from review:

- **Some history here still decodes.** If the history was lost afterwards the
  replacement went with it, and the server's copy of the retired original may
  be the only one left. A filename was not enough to check this — the one
  remaining file can be corrupt — so a revision has to decode.
- **Nothing a surviving demotable merge covers.** A legacy untagged merge
  arriving later can displace the tagged replacement that justified a
  retirement, after which `removingReplaced` wants that original back. The
  live state overrides the older entry.

So the claim costs one decode per workspace that has a member with no file,
cached, and nothing at all for a workspace that has none — against the shape
before this, which decoded the library's whole history on every pass.
`0016`'s rejected evidence survives only in that first bullet, demoted to its
proper job: necessary, never sufficient.

Core still keeps a claim only where its own records name an install at the
path, so a member another Mac wrote comes down the first time regardless.

## What this closes, and what it costs

Both open findings of `0016` close. A workspace that loses `.lamp/revisions`
but keeps the list claims only what it really retired; one that loses all of
`.lamp` claims nothing and fetches once. The per-pass decode is gone.

**No seeding.** The existing 45 come down once more, are deleted and retired
by that pass's compaction, and are claimed from the next.

**The list grows without bound**, about 36 bytes a retirement — some 55 KB for
a workspace with 1,535 retirements. Not pruned: a gather must stay read-only,
and the only safe pruner is a compaction that can prove the server no longer
lists the path, which it cannot.

**Still not addressed**, as in `0016`: the server and the phone hold every
revision ever uploaded, uncompacted, and nothing deletes one. This stops the
traffic, not the accumulation; bounding that needs the tombstone `0015`
rejected.

## What was rejected

- **Records plus absence** — `0016`, above.
- **Accepting the loop instead.** The honest form of "do nothing" is not
  keeping the guards: it is removing the claim and having the unclaimed
  reporter exclude `Revisions/` so it is not blinded. Rejected because the
  reporter being blinded is the real cost — `LampSyncUnclaimedInstalls` exists
  because the phone refetched every reading plan for months, and 45 revision
  members in that warning every pass is noise over the next such fault. That
  is paid per pass whatever the bytes are. Indeed the first live run of the
  fixed build immediately surfaced two faults nobody knew about: five
  `WritingMedia` members fetched again every pass, and three `Translations`
  deletions never carried out here.
- **Putting the retired ids in `WorkspaceFileLedger`.** It publishes its
  deletions as tombstones, which would delete the server's copies — the synced
  format change the cap was refused for.
- **`coveredRevisionIDs` including `id`**, so successors name their
  intermediates: only helps merges made afterwards, changes every merged id,
  and would make a new-format merge un-demotable.
- **A guard on the member's filename stamp.** Narrows one rare case for a
  parse of every member name on every pass.

## The case still accepted

A tagged *merge* dropped by an untagged superset is not retired, so it is
fetched again — which is now the deliberate behaviour rather than an
oversight: `removingReplaced` drops any revision whose covered set is a strict
subset of another's, tags or not, and keeping that one fetchable is what lets
the demotion eventually happen. What stays unrecoverable is narrower: where
the originals were merged before either was ever uploaded, so the server holds
the merge and not its parts. What is lost there is per-turn granularity on
legacy agent history, never a version of the text.
