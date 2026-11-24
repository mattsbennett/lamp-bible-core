# 0010. A pass publishes only an ordinary file

Status: Accepted for core, 2026-11-24, held by
`aCandidateThatBecameASymlinkIsNotPublished`. Both apps get it, because it is
in the engine. Found by Codex reviews on both sides of the sink; Fable settled
where the check belongs, and a third review moved it again.

## Context

Before `0008`, every file a Mac pass published had been copied into a scratch
directory, and the gather then walked that directory asking for regular
files — so a symbolic link in the library was skipped without anyone having
decided it should be.

`0008` made a candidate name the live file. Now a path that is a link is
followed: `LampFileIdentity` stats through it and `Data(contentsOf:)` reads
through it, so a link would be hashed, planned and published with the bytes
of whatever it points at — any file this app can read.

The exporter does check. `childFiles` and `copyTree` both exclude links, and
the one path reached without them, the enabled-skills selection, now has its
own guard. But a check at the gather is a check at a moment: the file is read
again, seconds later, at the upload.

And `copyItem` on a symbolic link copies **the link**, so `0009`'s snapshot
is not enough by itself: the copy would be a link too, and both the digest
and the PUT would follow it.

## Decision

**A pass publishes an ordinary file and nothing else**, checked in the upload
loop — at the source before copying, and again on the copy.

`LampFileIdentity.whatIs(at:)` answers with three cases rather than two,
without following a link: `ordinaryFile`, `somethingElse`, `nothing`. The
three are needed because the two that are not an ordinary file mean opposite
things. Nothing there is a file that has gone since the plan, which `0009`
reports as `changedDuringPass` and is no failure. Something else is a file
that will not be published, which is a failure, reported with its path.

The source is asked first so that a path which has become a *directory* is
refused rather than copied tree and all. The copy is asked second because
that is the file actually being hashed and sent, and `copyItem` may have
produced a link from a link.

**A hard link is ordinary and passes.** A workspace's context files are hard
links into a per-library store of content-addressed objects
(`WorkspaceContextFileStore`), so a published file whose link count is above
one is entirely normal here.

The check is deliberately **not** part of `LampFileIdentity` itself. An
identity is a cache token that can be written down; what is at a path is a
fact about a moment that cannot be. A `Codable` identity carrying the answer
would have to invent one when decoded, and either answer would be wrong.

## Consequences

- A module, deck or media file that is a symbolic link stops being
  published, and says so with its path. Nothing in either app creates one; a
  person who had symlinked a module into their library would see a failure
  rather than have the link's target uploaded.
- Two `stat(2)` calls per uploaded file, one of them on a file just written.
  Nothing measurable.
- `Verification/coverage.json`'s boundary for `LampSyncBundlePass.swift` has
  to say this, since it is a new condition on what a pass will send.

## What it must not break

- **A hard-linked file is still published.** Context files would stop
  syncing otherwise, and that is most of a workspace.
- **A file that has gone is still not a failure.** The first version of this
  asked only whether the source was an ordinary file, which a missing file is
  not either — and that turned `0009`'s `changedDuringPass` into a failure.
  Caught by `aFileDeletedBeforeTheUploadIsNotAFailure`.
- `LampDatabaseFileRevision`'s stored JSON is unchanged, and so is
  `LampFileIdentity`'s: the check is a static function, not a field.

## Rejected

- **Refusing a non-ordinary candidate in `describe`.** This was the first
  version and it is worse than nothing. A refused candidate leaves the path
  out of the plan's locals, which reads as "this client does not hold it" —
  so the plan schedules a *download* and the install rewrites the very file
  the refusal meant to leave alone. Making that safe needs the path carried
  into planning as held-without-a-file, in both apps; the upload check is
  sound on its own, so it waits for a reason to exist.
- **Guarding only the source, before the copy.** Checking a path and then
  copying it is the same time-of-check problem one step along.
- **Refusing a file whose link count is above one.** It would read as
  "refuse anything shared" and would stop every workspace context file
  syncing. The thing to refuse is a *symbolic* link.
- **Resolving the link and publishing its target's bytes.** That would make
  a pass publish files from outside the library by design, which is the
  exposure, not the fix.

## What is still open

Two gaps that this does not close, both found by review, both wanting the
same mechanism — a candidate that carries what the app knows about it, which
is the next decision:

- **A symbolic link among a recorded path's *ancestors*.** Half closed by
  `0011`, and the other half is not — the distinction matters, and an
  earlier version of this record claimed the whole thing was done.
  `copyItem` resolves the directories on the way to a file, so replacing a
  workspace's `context` directory with a link gives an ordinary copy holding
  bytes from outside the library.
  - Replaced **after** the gather: caught. A fixed candidate's copy must
    hash to what the gather hashed, and the outside file does not.
  - Replaced **before** `describe` hashes it: not caught. The gathered
    digest is then the outside file's digest too, so the two agree and the
    comparison is satisfied.

  Both halves want the same thing, which neither has: the path resolved
  **once**, and the bytes hashed and sent through that one open file rather
  than through three separate opens of a path. That is a change to how core
  reads a file at all, so it is its own decision rather than a fourth patch
  to this one.
- **Two published paths differing only in case, on the receiving Mac.** A
  case-sensitive library can publish `Guide.md` and `guide.md`; a receiver
  with case-insensitive scratch storage stages one over the other and the
  pass still records both as installed, acknowledging a file it discarded.
  The export side of this is fixed — each staged copy sits in a directory
  named by its published path's digest — but the install side is not.

Neither is a regression from before `0008`: the first needs a process
writing inside the library mid-pass, and staging has always been a stat
followed by a copy of a path; the second is how the install path has always
behaved. Writing them down here is what got half of the first one fixed one
decision later.

## A claim this record used to make, and should not have

The first version said the copy sits "inside this pass's own scratch
directory, so unlike a check of the source it cannot be raced — nothing else
can reach it". That is not true. `LampSyncScratchFile.url()` returns a
randomly named path in the user's temporary directory, which any process
running as the same user can reach; no filesystem permission separates them.

What the copy does buy is real but narrower: it takes the file out of the
library, where the app's own panes, agents and compaction are writing, and
where the window is seconds. What remains is a same-user process tampering
with this pass's scratch file between the check and the PUT — which is
exactly as true of the staging copy every pass made before `0008`, so
nothing here made it worse. Closing it would mean holding the file open and
sending from the descriptor, which the store's URL-based interface does not
do today.
