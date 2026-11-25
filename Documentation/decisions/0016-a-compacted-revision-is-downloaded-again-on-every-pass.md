# 0016. A compacted revision is downloaded again on every pass

Status: Proposed — the mechanism is confirmed in the code and the orphans are
counted on the owner's real library, but no live pass has been run to watch it
happen, and the fix is not written. Found by Fable while being asked whether
`0015`'s three sub-options were settled.

## Context

`0015` asked what revision history costs and answered in bytes at rest: 9.03
MB, 2% of what a workspace weighs. That premise — the cost is bytes, paid
once — is not what the code does.

Reading the pass straight, in order:

1. **Compaction is Mac-local and runs constantly.** `record` compacts on
   every call (`AgentRevisionSupport.swift`, "Recursive, because recording
   compacts"), so during a typing run the open run's file is replaced on each
   autosave by a new file under a new `mergedID`, and the old one is deleted
   locally.

2. **Every revision file is a sync member.** `SyncSupport.swift` copies
   `.lamp/revisions/*.json` out as `Revisions/*.json`.

3. **Nothing tombstones a revision.** The deletion ledger
   (`workspaceFiles(in:)`) covers top-level documents and `context/` only —
   its own doc comment says so. Nothing compacts the server or the phone.

4. **So the server keeps every revision ever uploaded**, including the ones
   compaction has since replaced locally.

5. **And a member with a server listing and no local copy is a download.**
   `LampSyncFilePlan.change`:

   ```swift
   guard let local else { return listed == nil ? .none : .download }
   ```

6. **Which lands back on disk and is deleted again.** `mergeTree` writes the
   downloaded `Revisions/` into `.lamp/revisions/`, and the next line is
   `DevotionalAgentRevisionStore.compact(in: workspace)`. The comment above
   it anticipates an original returning "from another Mac"; it does not
   consider that the server is itself a holder that never compacts.

The Mac has a mechanism for exactly this shape and it does not cover
revisions. `LampSyncMacPassLibrary.mergedIntoTheLibrary`'s doc comment
describes an unclaimed member as *"downloaded on every pass, for ever"*, and
the set it guards is `.module(.notes), .module(.devotionals),
.module(.highlights)`.

## The evidence

On the owner's live library, comparing `.lamp-sync-file-records.json` (what
this Mac has synced with the store) against what is on disk:

```
workspace                                    recorded  on disk  orphaned
9ADB692A-…-52058bb863352190                       103      101         2
2E56C9D2-…-915b127efb06e020                        61       22        39
C8B91824-…-7e9996109ff5f60b                         3        1         2
73B5596C-…-50fd75e3872bfc66                         1        1         0
                                                  168      125        43
```

43 revision members this Mac uploaded and has since compacted away. At the
mean size of the revisions still on disk in each workspace, that is **about
2.9 MB re-downloaded, written and deleted on every pass**.

Two honest limits on that number. The records are this Mac's record of what
it synced, not a listing of the server — proving the server still holds them
needs the store, and the stored credentials are not mine to reach for. But no
tombstone covers revisions, so the server's listing is a *superset* of what
was uploaded: 43 is a lower bound, not an estimate. And no pass has been run
under observation to watch the same paths arrive in `outcome.installed`
twice, which is what would turn this from "what the code says" into "what it
does".

Nothing covers this. `SyncSupportTests` checks that a revision is archived,
not that a compacted one stays gone.

## Why it matters more than `0015` did

Passes run by themselves, not on a button. So revision history's real cost is
not 9 MB sitting on a disk — it is a few MB of upload-bandwidth-shaped
traffic, a folder rewrite and a compaction, on every automatic pass, for ever,
and it grows with every hour of writing ever done rather than with what is
kept. That is the term `0`'s and `2a`'s "no redundant reads" goal exists to
stop, and it was hiding behind an at-rest figure.

It also strengthens `0015`: a count cap is not merely unconvergent against
another Mac, it is unconvergent against the server.

## The direction, not yet the decision

The fix belongs in the pass, not in the format — none of `0015`'s three
sub-options would touch it. The shape that fits is the one the Mac already
has: a gather that claims, through `heldWithoutAFile`, the revisions covered
by a local `replacedRevisionIDs`. That claim is *true* rather than merely
convenient, which is the bar — a revision file is immutable, and a local
merge that names it is this client stating it holds that history in the file
that replaced it.

Before writing it: check the claim against the `coverage.json` boundary for
this source, since `heldWithoutAFile` is a client claim the model reasons
about, and decide whether the phone needs the same (it carries revisions
without decoding them, so it cannot read `replacedRevisionIDs` to make the
claim).
