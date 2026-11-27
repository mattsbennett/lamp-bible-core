# 0041. Old review retirements are pruned by a write, and followed on taking in

Status: Accepted, 2026-11-27. `LampWritingReviewStore.update` and `takeIn`,
`LampWritingReview.merged(with:lettingGoOfRetiredBefore:restoredBefore:)`.
Held by `LampWritingReviewPruneSyncTests`, the `reviewFollow` table, and the
theorems from `followingOnlyMovesTowardTheIncomingCopy` on in
`Verification/SyncMerge.lean`. Planned in `../ReviewPrunePlan.md`.

## Context

A review record keeps every retired mark's id, so a copy that still holds
the mark cannot bring it back in a merge. `pruning(before:)` and a 90-day
`retirementLifetime` existed, but neither app called them, so the records
only grew. The owner asked for the prune to be turned on.

Both apps send a record when the held file's bytes differ from the copy last
agreed with the server, and a merge is a union. So where the prune runs
decides whether copies settle at all.

## Decision

- **The lead.** `update` prunes what is past its lifetime when the change
  it was given altered the record. A change that alters nothing writes
  nothing, as before.
- **The follow.** `takeIn` merges, then lets go of a retirement only when
  all three hold:
  - it is past its lifetime by this device's clock;
  - the incoming copy lacks it;
  - neither copy holds its mark.
- **Restorations.** Restorations past their week are let go the same way,
  where the incoming copy has none of their mark. A restore already drops
  those, and the other device handed them back.
- **No tidying.** Neither half tidies. A merge can leave a wording whose
  mark the other copy retired, and every copy holds it alike. Codex's review
  found that the first version's write dropped it, and the other device
  handed it back: an upload more for every write.
- **Judged by the bytes.** `update` prunes only when the record's encoded
  bytes would change, as `save` decides whether to write. A change that
  only reorders writes nothing, and prunes nothing.
- **Before the cap.** The follow lets go of this copy's entries before
  merging, not after. The merge keeps only the newest twenty restorations,
  and one about to go could otherwise push out one the incoming copy holds.
- **No retired mark kept.** In the model, what a follow keeps holds no mark
  that is retired, as a saved record holds none. So a retirement a write
  lets go of later cannot show again a mark the follow hid
  (`aMarkTakenAwayStaysAwayWhenItsRetirementGoes`).

Removing only what the incoming copy lacks can only move the file toward
the bytes it was sent. The model proves that, and that the follow shows
exactly what the merge shows. Devices of one build then settle on the
pruned bytes after one upload. Against a build that does not prune, the
entries come back once and then nothing moves. Following restorations also
removes the round trip that every restore cost.

The prune has nothing to do before about 2027-02-16. The record first
landed on 2026-11-18, so no retirement is 90 days old until then.

## Consequences

- **A device away for longer than 90 days** brings back a mark the others
  retired and have since let go (`retirementLifetimeCost`). This is the
  cost the lifetime was always documented to carry.
- **A restore recorded again more than 90 days after its re-mark was
  cleared** makes the re-mark again: `restoringWording` skips a re-mark only
  while its id's retirement is kept. That needs a device keeping a restore
  owed for that long. It is documented on `retirementLifetime`, not pinned
  by a test.
- **A clock behind the others by less than its margin** holds on to an
  entry the others just found old. That costs one upload, and then nothing.

## Rejected

- **Pruning by age in `takeIn`.** Against any copy that still holds the
  entries, it is sent and handed back on every pass, for ever.
- **Pruning only on writes.** Every other copy's union hands the entries
  back, so it never sticks, and each write costs one more upload and
  download than before.
- **A call in each app.** Both write through the store, and two copies of
  the rule would drift.
- **A field recording how far a copy was pruned.** A build that does not
  know it drops it on rewrite. It would also change `mergeReview`, and need
  the held digest plumbed into reconcile.
- **Compacting clearances.** See R6 of `../ReviewMarksPerformancePlan.md`.
