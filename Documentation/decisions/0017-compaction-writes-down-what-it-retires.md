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
- **One entry a line: the published name, and the id.** The *name* is what a
  claim matches, because a manifest member has no other identity and the
  store calls a revision file anything ending `.json` — it writes
  `<millis>-<uuid>.json` and also accepts `<uuid>.json`, which sync's own
  tests publish. A first version derived the id by parsing the name, and so
  could never match the second shape: those members were fetched and deleted
  on every pass, the exact loop this record exists to stop, let back in
  through an inference about a convention the code does not enforce on read.
  Names are compared folded (NFC then lower case, the same expression the
  pass folds paths with), which is safe because `0013` makes the pass refuse
  two server members differing only in case.

  The *id* is kept beside it, against the planner's advice to carry the name
  alone. A retirement has to be reconsidered when a legacy untagged merge
  turns up later and `removingReplaced` wants an original back — and that
  merge names the ids it covers, while the original it wants has no file
  here. Only this line can map that id to the name it was published under,
  so name-alone makes the case unimplementable. Both are written from one
  `entry` in the same statement, so the objection to carrying two keys —
  two things to keep true — does not bite.
- **Appended, never rewritten.** This is on the autosave path,
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

**Everything compaction deletes is retired. There is no demotion
exception.** One was built and removed, and the reason is the useful part.

`compact` begins with `removingReplaced`, so a demotion that *can* fire here
already has: if every original of an untagged merge were present, the merge
would be gone and the originals kept. Originals are deleted under an untagged
merge only when one of them is already missing locally — and whether the
missing one ever arrives is a fact about the server, which no local predicate
can see. So the exception was not an approximation of `removingReplaced`; it
was an attempt to evaluate it on an input this Mac does not have, which is
why four versions of it were each wrong in a new way:

1. asking whether the deleted revision's own id was covered — a merge's
   covered set names originals, never another merge, so a deleted tagged
   merge never matched;
2. withholding anything a demotable merge subsumed — which caught untagged
   intermediates, and an untagged merge can never be a holder at all;
3. restricting that to revisions that could be holders — which still withheld
   a tagged `A+B` whose every change a surviving tagged `A+B+C` held;
4. withholding only the last holder of something wanted — correct about the
   folder, and still blind to the server.

And withholding was never patient waiting: a withheld revision is fetched,
written and deleted again on **every pass, for ever**, which is the loop this
list exists to stop. Twice over, a version of this exception reintroduced the
defect the record was written to fix.

**What that costs**, written plainly: where this Mac compacted an untagged
merge before every original of it had arrived, that merge may keep a turn's
changes under no turn's name — and, where the merge spans two changes, the
state between them becomes unreachable on this Mac while another Mac can
still restore to it. See "the second reachable case" below for the trace;
an earlier draft of this record claimed no version of the text was ever lost,
and that was wrong. `removingReplaced` still prefers the originals whenever
all of them are present. If anyone proposes bringing the exception back, the
bar is to name the input it needs and show it is on disk.

**And a retirement is not trusted on its own.** It says the replacement was
on disk when compaction ran, not that it still is. One further condition,
from review: **some history here still decodes.** If the history was lost
afterwards the replacement went with it, and the server's copy of the retired
original may be the only one left — and a filename was not enough to check
that, because the one remaining file can be corrupt.

So the claim costs one decode per workspace that has a member with no file,
and nothing at all for a workspace that has none, against the shape before
this, which decoded the library's whole history on every pass. `0016`'s
rejected evidence survives only as that condition, demoted to its proper job:
necessary, never sufficient.

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

## The list is advisory

**A failure to write or read the list costs one more download of what it would
have claimed, and never a compaction, never history.** That is the rule, not
an implementation detail, and every hardening of it has to keep it true. What
it already covers, each found by review:

- A retirement that cannot be written does not fail the compaction.
  `prepareLibraryForSync` compacts every workspace before importing anything,
  so a throw over a bookkeeping file stopped unrelated documents syncing.
- A list that exists and will not open is left alone rather than replaced. The
  atomic-write fallback would have discarded every earlier retirement and set
  those entries alternating between claimed and downloaded.
- One damaged byte loses its own line, not the file. Decoding the whole thing
  as UTF-8 first answered "nothing is retired", after which compaction
  appended good entries behind the damage and neither old nor new was seen
  again.
- An append starts on a line of its own, so an append interrupted mid-line
  cannot have the next good entry glued to its fragment.

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
- **Deriving the id from the published name** instead of recording the name.
  It is an inference about a convention the store does not enforce on read,
  and it broke on the convention's own second shape — a member published as
  `<uuid>.json` could never be matched, so it was fetched for ever. The test
  written with it asserted the wrong answer, which is how it went unnoticed.
- **Following the chain of retirements to a live replacement**, which is what
  positive evidence that *this* revision's replacement still exists would
  need: with intermediate merges the replacement may itself be retired, so it
  is a walk, not a lookup. Rejected for cost. What is there instead — some
  revision in the workspace still decodes — is knowingly an approximation of
  it, and the same *shape* of weak evidence that `holdsAnyRevision` was
  retired for in `0016`; the difference is that it is now a necessary
  condition beside the list rather than the whole of the claim. Recorded so
  the next reviewer who notices does not reopen it.

Five details the name brings with it, all from review:

- **Compared folded**, and only where exactly one missing member folds that
  way — counted over folded whole *paths*, across every member with no file.
  Counting basenames made two workspaces' `autosave.json` look like a
  collision, so neither was claimed and both were fetched for ever: the loop
  this record exists to stop, reintroduced by the guard against a different
  one. A folded match could otherwise claim two members on one retirement,
  and `0013`'s refusal of case-colliding members is checked among the
  *planned downloads* — which a claim has already removed them from, so the
  collision would go unreported and the other member dropped in silence.
- **Percent-encoded on the line.** The store reads any `.json` in the folder,
  so a published name can hold a space, or a newline, which is this file's own
  record separator. A trimmed name read ` run.json` back as `run.json` and
  would have claimed the wrong member.
- **Each record ends with a sentinel.** An append of
  `draft.json.backup.json` interrupted after `draft.json` would otherwise be
  a valid retirement for a different file that really exists — and the next
  append, which starts a line of its own, would leave the fragment looking
  complete for ever.
- **A wanted revision vetoes its name, not just its id.** Two retirements
  whose names differ only in case fold alike, so dropping the wanted entry
  and keeping the other left the same folded name in the answer, claiming
  the very revision the demotion was waiting for.
- **Retirement is withheld by subsumed coverage, not by id**, and only for a
  revision that could actually *be* a holder. `removingReplaced` takes its
  holders from revisions not themselves up for demotion, and an untagged
  merge always is — so withholding an untagged intermediate (`A+B` under
  `A+B+C`) could never help a demotion and only had it fetched on every
  pass. And a merge's covered set names originals, never another merge, so
  asking whether a deleted revision's own id was covered missed a deleted
  *tagged merge* entirely — which is exactly what `removingReplaced` could use, given one
  more original, to put a turn's name back.

## How the list is checked

Not by a test per guess — that is how one predicate was wrong four rounds
running, each round shipping a test that encoded the version it came with.
The claim a retirement makes is *this Mac holds that history in merged form*,
and that is exactly true when **a retired file coming back would change
nothing the store keeps**. `RetirementKeepsWhatItClaimsTests` states that
over generated runs of edits, and it bites: reversing the strict-subset rule
in `removingReplaced` fails it on hundreds of draws.

**The property holds given a precondition: no untagged record covers a change
that a tagged record also covers.** Under it, demotion can never fire,
`removingReplaced` is strict-subset removal with a deterministic tie-break,
and a returned file is still a subset of whatever replaced it.

An earlier version of this record said the precondition was what the current
build guarantees, since `canMerge` refuses to cross turns and to mix kinds,
so only an older build could break it. **That was wrong**, and the second
reachable case below is why.

The counterexample, which a reviewer found and which the first version of
this property missed because its generator drew fresh ids for every merge's
coverage: tagged single `A`, untagged single `B`, and two untagged legacy
merges `AB` and `AC` with `C` never present.

```
KEPT:    [AC, B]
DROPPED: [A, AB]
returning AB -> kept becomes [AC, AB]
```

Where an untagged merge covers tagged changes, the kept set depends on which
files are present, and so on arrival order; the retired list freezes one such
outcome, in either direction. For *this* shape — two overlapping untagged
legacy merges — accepted, because no local rule can do better: it needs a
file that is not here, which is the same reason the demotion exception was
removed. Outside the precondition the test asserts
only what the code promises itself, and compares the two reductions with each
other rather than with `compact`'s output: `compact` reduces and *then*
merges, so a merge it forms can subsume something it kept, and a further
reduction drops that. Benign, settled by the next compaction, and worth
writing down because it makes `compact`'s output a poor baseline for any
such assertion.

## The second reachable case, and what it really costs

`replace(_ latest:with turnID:)` writes a tagged record whose
`replacedRevisionIDs` is `latest.coveredRevisionIDs ∪ {latest.id}`. That is a
tagged record covering a change an untagged record also covers — the shape
the precondition rules out — and **this build writes it**, which is what the
earlier wording got wrong.

The path, traced: Mac X holds untagged `A` and `B`, merges them into untagged
`M`, and deletes and retires both. Mac Y holds the tagged replacements `RA`
and `RB`. On Y, `M` arrives and is demoted — `A` is held by `RA`, `B` by
`RB`, both tagged — so Y keeps `[RA, RB]`. On X, `RA` and `RB` arrive as
strict subsets of `M` and are dropped, and `M` cannot be demoted because `A`
is retired and therefore claimed, so it never comes back. X keeps `[M]`.

A merge keeps the earlier side's `before` and the later side's `after`, so
what each Mac can restore to is:

```
Y: before_A, after_A, after_B
X: before_A,          after_B
```

**`after_A` is a version of the document that Y can restore to and X cannot.**
An earlier version of this record said the cost here was never a version of
the text. That was wrong too. The cost is the turn's name on X, one
intermediate version unreachable on X, and two Macs whose histories do not
converge. Nothing is destroyed: `A` is on the server and on Y.

How narrow: it needs two Macs; two panes on the writing Mac, one opened
mid-run without the turn; a pass publishing the untagged record inside the
seconds-wide window before its tagged replacement, twice over for two
consecutive changes (one leak alone is settled by the equal-coverage
tie-break, which prefers the tagged record); and the receiving Mac compacting
both before the tagged ones arrive. There is one Mac today.

## What this makes possible, and is not done here

**Reactive un-retirement.** Unlike the overlapping-legacy-merge case, this one
is locally decidable, because the trigger is an *arrival*: a tagged record
about to be dropped under an untagged merge that would be demotable if its
retired originals were present — every replaced id either held by a
non-candidate or named in the retired list, and one holder tagged. Removing
those originals from the list brings them back next pass, the demotion fires,
and X converges to Y. If one is not on the server, nothing fetches and
nothing loops.

That is not the demotion exception returning. The exception guessed, at
retirement time, about a file whose existence it could not know; this acts at
arrival time on a file the list itself proves was published.

**Done**, 2026-11-25, held by
`putsBackWhatAdemotionWouldNeedWhenAtaggedRecordIsDropped`. Compaction
un-retires the ids an untagged merge covers whenever a record that knows its
turn is being dropped under that merge: the next pass fetches them, and
`removingReplaced` gets its chance to prefer the originals. The failure mode
is benign — if the server no longer has one, nothing is listed and nothing is
fetched, so there is no loop, at worst one download that settles it. Removal
is the one operation on this file that rewrites it rather than appending,
which is rare enough to leave the autosave path alone.

## The case still accepted

A tagged *merge* dropped by an untagged superset is not retired, so it is
fetched again — which is now the deliberate behaviour rather than an
oversight: `removingReplaced` drops any revision whose covered set is a strict
subset of another's, tags or not, and keeping that one fetchable is what lets
the demotion eventually happen. What stays unrecoverable is narrower: where
the originals were merged before either was ever uploaded, so the server holds
the merge and not its parts. What is lost there is per-turn granularity on
legacy agent history. A version of the text can become unreachable on one
Mac in the `replace` path below, which is recorded there with its remedy.
