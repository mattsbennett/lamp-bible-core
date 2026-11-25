# 0016. A compacted revision is claimed as held, not fetched again

Status: **Superseded by 0017**, 2026-11-24. The defect and its measurements
stand, and the live confirmation below is the evidence for both records; what
0017 replaces is how the claim decides a member was superseded. This one
inferred it from absence, and three review rounds each found a different hole
in that inference. Left as written, per the README: a record is history.

## Context

`0015` asked what a writing's revision history costs and answered in bytes at
rest: 9.03 MB, about 2% of what a workspace weighs. That premise — the cost
is bytes, paid once — is not what the code does.

Read in order:

1. **Compaction is Mac-local and constant.** `record` compacts on every call
   ("Recursive, because recording compacts"), so during a typing run the open
   run's file is replaced on each autosave by a new file under a new
   `mergedID`, and the old one is deleted locally.
2. **Every revision file is a sync member.** `LampWorkspaceSync` copies
   `.lamp/revisions/*.json` out as `Revisions/*.json`.
3. **Nothing tombstones a revision.** The deletion ledger
   (`workspaceFiles(in:)`) covers top-level documents and `context/` only.
   Nothing compacts the server or the phone.
4. **So the server lists every revision ever uploaded.**
5. **And a listed member with no local copy is a download.**
   `LampSyncFilePlan.change`:
   `guard let local else { return listed == nil ? .none : .download }`
6. **Which lands back on disk and is deleted again.** `mergeTree` writes the
   downloaded `Revisions/` into `.lamp/revisions/`, and the next line is
   `DevotionalAgentRevisionStore.compact(in: workspace)`. The comment there
   anticipated an original returning "from another Mac"; the server is a
   holder too, and the one that never lets go.

Core already models this shape exactly — `LampSyncUnclaimedInstalls`, whose
Lean rules include `anUnclaimedMemberComesDownForEver` — and reports it
without correcting it, because core cannot know why a recorded file is
absent. The Mac has the mechanism for saying otherwise, `heldWithoutAFile`,
and it covered three module kinds.

On the owner's library: 168 recorded revision members against 125 on disk.
**43 orphans, about 2.9 MB downloaded, written and deleted on every pass.** A
lower bound, not an estimate: the records say what this Mac uploaded, and
since nothing tombstones a revision the server's listing can only be larger.
Passes run by themselves, so this is the term items 0 and 2a of
`../ScalabilityPlan.md` exist to stop, and an at-rest figure was hiding it.

## Decision

**A writing workspace's revision member with no file at its path is claimed
as held**, unless an untagged merge here still needs that id. The gather adds
every such member to `heldWithoutAFile`, after the workspaces have been
described.

Both qualifications came out of review, and both changed the decision rather
than the code around it:

- **Writing workspaces only.** A custom skill is published by copying its
  whole directory with *no* extension filter, so
  `Workspaces/Skills/<skill>/Revisions/index.json` is an ordinary file of a
  skill's own that matches the shape exactly. Claiming it would stop sync
  restoring it. Only `Workspaces/Writing` carries the invariant this claim
  reasons about, so only it is claimed.
- **Except what a demotion is waiting for.** `removingReplaced` drops an
  untagged merge in favour of the records that know which turn made the
  changes, and that needs **every** id the merge replaced to be held by
  something not itself up for demotion. An id nobody here holds stops the
  demotion — and if its file is also claimed, it never arrives, so the merge
  keeps a turn's changes under no turn's name for good. Those ids are left
  unclaimed and go on being fetched until one of them settles the demotion,
  after which the merge no longer names them.

  **Only an agent's merge.** A demotion needs a holder that knows a turn,
  nothing the person typed carries one, and `canMerge` refuses two revisions
  of different kinds — so a `.userEdit` merge covers user edits and nothing
  else, none of which can ever name a turn. Keeping those fetchable would
  download and discard a revision on every pass to settle a demotion that
  cannot happen, which is the loop this record exists to stop. Every untagged
  merge on the owner's library is a user edit (70 of 125 local revisions),
  so this is the difference between claiming 34 of the 43 and all of them.

- **A workspace with no history left claims nothing.** The claim says a
  missing revision was superseded by one that is here; where none is here —
  a folder restored without its `.lamp`, a directory deleted by hand —
  nothing superseded anything, the history is lost rather than compacted, and
  the server's copies are the only way back. Claiming them would be worse
  than fetching them.

Why the claim is true rather than convenient: a revision file is written once
and never edited, and the only thing that removes one is compaction, which
*"Every replacement is on disk before anything it replaces is removed"*. So
for this kind, "recorded, and absent" means "superseded by a file that is
here". The content is held; it simply is not a file at that path — the same
sentence `mergedIntoTheLibrary` already rests on.

The rule is deliberately **not** narrowed to paths the Mac can prove it
wrote. Core keeps a claim only where its own records name an install at that
path and drops every other, so a member another Mac wrote still comes down
the first time, is recorded, and becomes claimable only once this Mac has
compacted it away. The safety condition is enforced centrally; the Mac does
not restate it.

## What was rejected

- **Claiming by `replacedRevisionIDs`** — the first fix proposed, and it was
  measured before it was written: it claims **10 of 43**. The reason is
  structural. `coveredRevisionIDs` is `replacedRevisionIDs ?? [id]`, and
  `merge` unions the two sides' *covered* ids, so a merge of a merge names
  the originals and never the intermediate. Every intermediate merge uploaded
  during a run is therefore named by nothing that outlives it, and a run of
  *n* changes leaves *n−1* of them. It cannot be repaired after the fact
  either: `mergedID` is a truncated SHA-256 over the sorted id list, so an
  orphan's covered set cannot be recovered from its name, and the originals'
  times are not carried, so the run's prefixes cannot be reconstructed.

- **A local list of retired revision ids.** It duplicates state the sync
  records already keep, and it does not self-heal: a lost record costs one
  download and is then recorded and claimable again, where a lost retired
  list reinstates the loop silently and for ever.

- **Making `coveredRevisionIDs` include `id`**, so successors name their
  intermediates. It fixes nothing this does not, only helps merges made
  afterwards, changes every merged id, and would make a new-format merge
  un-demotable in `removingReplaced` — harmless only because such merges
  never cross turns and so never need demotion. Not worth the reasoning.

- **Server-side tombstones for revision files.** That is the format change
  the count cap was rejected for in `0015`, for a problem a client claim
  solves.

- **A guard on the member's filename stamp** — claim only where some local
  revision is at least as new as the member. All 43 would still qualify, and
  it narrows the one wrong case below at the price of parsing every member's
  filename on every pass.

## What follows

- **The one wrong case** is a workspace folder restored from a backup older
  than some of its revisions: recorded, absent, claimed as held, so those do
  not come back from the server. It is the wrong case
  `mergedIntoTheLibrary` already accepts, and the alternative is fetching
  them for ever.
- **The phone does nothing.** It never deletes a revision file, so it has no
  absence and no loop. It carries revisions without decoding them, so it
  could not make this claim in any case.
- **Not addressed: the at-rest copy on the server and the phone.** Both hold
  every revision ever uploaded, uncompacted and unbounded, and nothing
  deletes one. This record stops the traffic, not the accumulation. Bounding
  it needs a tombstone, which is `0015`'s rejected format change.
- **One case is accepted, not fixed: a tagged *merge* that was dropped by an
  untagged superset.** `removingReplaced` drops any revision whose covered
  set is a strict subset of another's, tags or not, so an untagged legacy
  merge covering `A+B+C` deletes a tagged merge covering `A+B`. That tagged
  merge's filename carries its own `mergedID`, not `A` or `B`, so nothing
  local names it and it is claimed as held.

  The ordinary recovery still works: `A`, `B` and `C` *are* named by the
  untagged merge, so the exception above keeps them fetchable, and a tagged
  single among them settles the demotion without the tagged merge. The case
  that cannot recover is narrower — where `A` and `B` were merged into the
  tagged merge before either was ever uploaded, so the server holds the merge
  and not its parts.

  Left as it is. What is lost there is per-turn granularity on legacy agent
  history, not a version of the text: the untagged merge still carries every
  version. Fixing it needs a member's *kind* to be visible before it is
  downloaded — in the manifest, or encoded in the name — which is the format
  change `0015` rejected, for a corner of legacy data.
- **The log says how many, not which.** A member's path carries names the
  reader chose — a context file is titled whatever the book is called — and
  the unified log is what a sysdiagnose collects and a person sends on. The
  count is public and the paths are private, and the folder is public only as
  far as the layout's own names go: a second component is kept for
  `Workspaces/Writing` and its siblings and dropped everywhere else, because
  a book's picture lives under its module id and a module id carries words
  from the title. Two review rounds were needed to get that line safe — the
  first version named the reader's document, the second named their books.
  The count is what the two-pass check needs.
- **Still to do:** two passes over the owner's store with no editing, reading
  the unified log for "Fetched again". Before the fix it should report 43
  under `Workspaces/Writing` on both passes; after it, 9.
- **`0015` is untouched.** Nothing here changes the revision format.
