# Review record prune plan

Planned by Fable on 2026-11-27, against core `7219c9a`. The owner said yes
to turning on the 90-day prune of retired review marks. The coordinator
checked the load-bearing claims against the code the same day.

## Why a caller is not enough

`LampWritingReview.pruning(before:)` and
`LampWritingReviewStore.retirementLifetime` (90 days) exist, but neither app
calls them. Both apps decide whether a review record has news by comparing
the held file's bytes with the downloaded copy's (Mac:
`LampSyncMacPassLibrary`'s reconcile). A merge is a union. So:

- **Pruning by age in `takeIn`** loops for ever against a device that does
  not prune. The other device unions the retirements back, this one strips
  them, and each uploads on every pass.
- **Pruning only on local writes** never sticks. The other device's
  `takeIn` hands the entries back, so every write costs one more upload and
  one more download than it does today.

## Design

Both halves go in core's `LampWritingReviewStore`, so neither app can
forget them.

- **Lead, in `update`.** When `change` returns a record that differs from
  the one read, save it pruned. A change that moves nothing saves as today.
  A prune rides a write that is going up anyway, and never causes one.
- **Follow, in `takeIn`.** After the merge, drop a retirement only when all
  three hold:
  - it is past the lifetime by this device's clock;
  - the incoming copy lacks it;
  - neither copy holds the mark.

  Dropping only what the incoming copy lacks can only move the file toward
  its bytes. The mark condition keeps an old unsent clear that meets a copy
  still showing the mark. The follow must not call `tidied()`.
- **Restorations follow at `restorationWindow`** (7 days). This closes a
  round trip that already happens today:
  - `restoringWording` drops restorations older than 7 days;
  - the other device's merge unions them back.

Where it settles:

| Case | Extra transfers | Settles |
| --- | --- | --- |
| Same version, one writes | none | both pruned, byte-equal |
| Mixed, the new one writes | one upload, one download | unpruned, then quiet |
| Anyone idle | none | no loop |

**When it starts to matter.** The record first landed on 2026-11-18. No
retirement is old enough to prune before about 2027-02-16.

**The cost, named.** A device away from sync for longer than 90 days can
bring back a mark another device retired.

**One narrow interaction to pin with a test.** `restoringWording` skips a
re-mark whose id is retired (`remarkID(restoring:)`). If a restore is
recorded again more than 90 days after its re-mark was cleared, the re-mark
returns.

## The model

- `mergeReview` and its laws stay as they are.
- New Lean definitions for lead and follow, with age passed in as
  `old : Nat → Bool`, as `pruneTombstone` takes `now`.
- `takeInReview` returns the followed merge.
- Theorems:
  - a follow differs from the merge only where it equals the incoming copy;
  - a retirement is kept while the incoming copy shows its mark;
  - a young retirement is never dropped;
  - following a led copy settles both ways;
  - `retirementLifetimeCost`, a counterexample in the style of
    `tombstoneLifetimeCost`.
- A `reviewFollow` conformance table, checked through `takeIn(now:)`.
- `coverage.json`:
  - qualify "a clear on one device is never undone" with the lifetime;
  - move the prune of retirements out of "not modelled";
  - fix the newest-20 restorations line, a cap that sits inside the
    merge.

## Order

1. **A two-store sync harness** in core's tests, on today's code. It counts
   uploads, and keeps today's `takeIn` as the reference for an older build.
   No behaviour change.
2. **The follow.** The pure function, `takeIn(now:)`, the Lean definitions,
   theorems and table, and both coverage entries, in one commit. It does
   nothing until something leads.
3. **The lead in `update`.**
4. **A decision record**, at the next free number (0041 at the time of writing). Rejected options:
   - pruning by age in `takeIn`;
   - pruning on writes only;
   - a call in each app;
   - a `prunedBefore` field, which an old build strips on rewrite;
   - compaction.

   Also fix the doc comments that say nothing prunes the record or that a
   retired id never returns.
5. **Both apps' suites.** Add to the Mac's
   `aDownloadedReviewIsMergedAndOnlyNewsGoesBackUp` that its 2023
   retirement survives.

Tests that must bite, from the harness:

- one write in the same version: one upload, then ten idle passes with
  none;
- mixed versions: two uploads, then none;
- a change that moves nothing: the bytes and the file date are unchanged;
- an old unsent clear: it is kept, and is sent;
- an orphan wording arriving: the bytes stay equal;
- a follower one hour behind: one extra upload, then none;
- a restore followed with no upload (this fails today).
