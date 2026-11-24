# 0009. An upload digests the bytes it is about to send

Status: Accepted for core, 2026-11-24, held by
`aFileRewrittenBeforeTheUploadIsRecordedAsItWasSent` and
`aFileDeletedBeforeTheUploadIsNotAFailure`. Both apps get it, because it is
in the engine. Design reviewed by Fable, which corrected two facts this
record would otherwise have had wrong; the defect it fixes was found by a
Codex review of `0008`.

## Context

`0008` had a pass record the path of a **live** file for the kinds whose
bytes are fixed at a path, instead of copying it into a scratch directory.
That removed 1.9 s of per-pass file work. It also removed, silently, a
snapshot that the copy had been providing.

The upload loop reused the digest the gather had taken for any path whose URL
it had been handed:

```swift
let digest = url == filesByPath[path]?.url
    ? filesByPath[path]?.digest
    : (try? LampSyncContentRevision.digest(forFileAt: url))
```

With a scratch copy, the two were the same bytes by construction. With a live
URL they need not be, and the pass would **send one thing and record
another**. A later revert to the recorded bytes then reads as already synced
and is never published again.

Three things rewrite those files, and the first two are the pass's own:

1. `importPortableWorkspaces` begins with `prepareLibraryForSync`, which
   compacts every workspace's revision history
   (`lamp-bible-macos/.../SyncSupport.swift`).
2. It compacts **again**, per workspace, after union-merging the incoming
   revisions — deliberately, because the merge brings back originals this Mac
   had compacted away, and compacting recognises them against their
   replacements.
3. Opening a workspace compacts it on a background utility queue
   (`DevotionalAgentWorkspaceView`), outside `@WritingWorkspaceFiles` and
   outside any pass.

Compaction writes a merged revision and **deletes** the ones it replaces. So
a recorded revision URL can be rewritten or deleted between the plan and the
upload, and (3) means no amount of reordering inside the pass can prevent it.

## Decision

The upload loop digests the file it is about to send, every time, for every
path. A file that is gone by then is reported as `changedDuringPass`, not as
a failure; one still there but unreadable is still a failure.

Not gated on kind. Core cannot know which of an app's candidates name a live
file and which name a copy — that is the exporter's choice, per file, not per
kind — and the cost is one SHA-256 per *uploaded* file rather than per
candidate. A steady pass uploads a handful.

**This is what the model already says.** In `Verification/SyncMerge.lean`,
`act`'s upload arm is `send w who c.content c.seen cond` where `c` is
`(w.device who).copy` — the copy at act time — and `send` records
`encode who content` of the content it sent. The `planned` comparison gates
`download` and `deleteLocally` there, never `upload`. An absent copy falls
through the match and sends nothing, records nothing. So the Swift's reuse of
the gathered digest was the divergence, and this restores conformance rather
than straining it. The Lean is untouched.

The step's own comment had been promising this all along — "publishes the
file the transaction produced, never the one digested before it ran" — but
the code honoured it only for a path the merge had rewritten.

**The phone had already reached the same conclusion for the files it
edits, and paid for it by copying.** Its collections, review marks and
writing documents are each written into a per-pass scratch file before being
gathered, with the reason in its own comments: "Sent from a copy, read under
the file's lock: a clear landing while the pass runs can't leave the bytes
sent unlike the digest taken of them." So the precaution is not new; what is
new is that the engine takes it, once, rather than each app buying it with a
copy.

Its **media and book pictures are gathered as live URLs** under the app's
Documents directory, so for those this is the same change it is on the Mac —
an earlier version of this record said the phone copied everything it
published, which is not true. Nothing else changes for iOS: one hash per
uploaded file, over bytes it had already written. What makes the live case
quiet there is the app container, which no other process of the same user can
write into — not a precaution of sync's.

## Consequences

- A pass publishes what the library holds when it publishes it. The recorded
  `uploadedDigest` is a statement about bytes that were actually sent.
- `LampSyncConditionalWrite.write(fileAt:)` already hashes the file at send
  time for read-back confirmation, so the pass was recording one measurement
  while confirming against another. Now they are the same one.
- A first-ever pass that uploads fifteen thousand files pays about 720 ms of
  hashing once. Nothing else changes size.
- `0008`'s "a candidate is read once, to be hashed and uploaded" is no longer
  true, and is corrected there.
- The boundary prose for `LampSyncBundlePass.swift` in `Verification/coverage.json`
  said only that a local copy is installed over or deleted while its digest
  is the one gathered. It now also says what an upload does, which is the
  opposite way round.

## What it must not break

- A file edited between the plan and the install is still not installed over
  (`anEditMadeDuringThePassIsNotInstalledOver`) — that is the `unchanged`
  gate, which this does not touch.
- A merged path still publishes the merge's own output, never the pre-merge
  copy.
- `unchangedSincePlanned` and the in-step record still compare against the
  gathered digest. That is the model's `unchanged`, and it is correct.

## Rejected

- **Staging the revisions too** (back to copying them). Honest, and it gives
  back nearly all of `0008`'s 1.9 s: revisions are fifty of the fifty-four
  files in a workspace.
- **Holding the recorded files' lifetime open across the pass** — making
  compaction wait for a pass that is holding a file. It means a lock held
  across network I/O, and it still cannot stop the background compaction a
  workspace does when it is opened.
- **Moving `prepareLibraryForSync` to the front of the pass**, so compaction
  happens before the gather. This was the first answer and it is wrong twice
  over. It leaves the *second* compaction — the one after the revisions merge
  — exactly where the defect is, and it does nothing about the background
  compaction on workspace open. Those two facts settle it on their own.

  It is also not free. `prepareLibraryForSync` at 250 workspaces of fifty
  revisions each is **1 930 ms** with a backlog to merge, **520 ms** on a
  settled history that still holds every revision — the per-pass figure —
  and **104 ms** once a merge has reduced that history to one revision a
  workspace. `compact(in:)` decodes every revision file of every workspace
  before it can conclude that nothing merges, and the decoded-history cache
  holds four workspaces. Today it runs only on a pass that received
  something, which while one person writes is almost no passes.

  **The first version of this record said 495 ms and 403 ms, and those
  numbers measured nothing.** The fixture's revision JSON named the two sides
  `before` and `after` where `DevotionalAgentRevision` requires
  `beforeMarkdown` and `afterMarkdown`, so every revision failed to decode
  and the timing was of a folder of files being thrown away. Caught by a
  Codex review of the measurement, not of the code. The fixture now encodes
  through the type, and `measuresWhatPreparingTheLibraryCosts` keeps the
  figures on their own library, since compaction deletes the very files the
  gather is measured over. A second review of that benchmark found it also
  timing the one-time writing of skill selections, and counting those
  selections as revision files, and the backlog of a smaller size being
  compacted before a larger one measured it; the figures above are after all
  three.
- **Gating the fresh digest on the file kind.** See the Decision: the
  exporter chooses per file, and core cannot see that choice.
