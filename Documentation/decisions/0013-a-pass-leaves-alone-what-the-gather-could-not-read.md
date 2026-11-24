# 0013. A pass leaves alone what the gather could not read

Status: Accepted for core, the Mac and the phone, 2026-11-24, held by
`aFileTheGatherCouldNotReadIsNotDownloadedOver`. Found by Fable while being
asked whether a "held but not publishable" state was worth building, and
confirmed by probe before anything was changed.

## Context

A gather that cannot read a file leaves it out of `Gathered.local`. Nothing
else said anything about it: the Mac added it to the pass's `gaps` and
reported it, and the phone simply skipped it.

But "not in the locals" is exactly how a client says *it does not hold this
path*. So the plan did what it should for a member nobody holds — it
downloaded the server's copy, and `install` wrote it over the file.

A probe, before any of this was changed, against a file made unreadable with
the server holding the path:

```
PROBE installed=["Workspaces/Presentations/easter.lampdeck"] \
      outcome.installed=["Workspaces/Presentations/easter.lampdeck"] failures=[]
```

Installed. Nothing reported. **This needed no hostile process and no race.**
A module whose permissions are wrong, a module symlinked to a disk that is
not mounted, a file a backup tool has locked: an ordinary thing done to one's
own library, and the file is replaced by whatever the server had, silently.

That is the "own reason" `0010` and `0012` were waiting for. Both of them
stopped at the same wall — a refusal to publish has nowhere to go — and both
reasoned about a mid-pass race that needs a process writing inside the
library. The live case is simpler and worse, and it is about the person's own
files rather than about security.

## Decision

`Gathered.refused` maps a path to the reason to tell the person. A refused
path is **excluded from the plan exactly as an unplanned kind is**: neither
fetched, published, deleted nor recorded, with pruning still seeing the whole
listing, so a tombstone waiting for its file is kept whoever plans what.

Not a third state the plan carries. The pass already had the right meaning in
`plannedKinds`, and this generalises that predicate from per-kind to
per-path — `isPlanned(path)`, used everywhere `plannedKinds` was, including
`LampSyncUnclaimedInstalls.deletionsNotCarriedOut`, so a refused path with a
record is not also reported as a deletion this pass failed to carry out.
`LampSyncFilePlan` is untouched and the path never reaches `changeAction`, so
`Verification/SyncMerge.lean` is untouched too.

Each refused path is one `outcome.failures` line, naming the path and the
reason, in path order: one line per pass rather than a new kind of report for
the person to learn. **One channel, not two** — the Mac had been adding the
same files to `gaps` as well, which put each one in the status line twice and
let two unreadable files crowd out whatever else had gone wrong.

Three details of the exclusion, each a review finding on the first version:

- **Matched folded, not only exactly.** A library on a case-insensitive
  volume has one file for `easter.lampdeck` and `Easter.lampdeck`, so
  refusing the spelling the gather saw left the pass free to download the
  other — and the install removes the destination before it copies, so the
  file that was refused was replaced anyway. Folding may refuse a genuinely
  different file on a case-sensitive volume; that is the conservative way
  round, since nothing is lost on the server and a pair of paths differing
  only in case is a thing to tell the person about rather than to act on.
- **Before the listing, not only after it.** The listing asks the server for
  a revision it was not given, which on a folder store is a read of the body
  — and a read that fails takes the pass with it, before it could report why
  the path was refused. `listingAndFolders` takes the refused set and skips
  that one request, while still listing and finding the file so pruning sees
  the whole listing.
- **Not conflated with a deletion this pass failed to carry out.**
  `deletionsNotCarriedOut` takes the refused set too.

Both apps feed it. The Mac already had the reasons in hand — the `unreadable`
it was reporting — and now says them to the pass as well. The phone had no
such list: it skipped a file it could not digest with a bare `continue`, so
its media and book pictures, which it gathers as **live** URLs rather than as
copies, had the same hazard; those two sites now record a refusal.

## Consequences

- A file this client cannot read is left alone and reported, and the next
  pass takes it once it can be read. Nothing is lost on the server, and the
  record is untouched, so no state has to be unwound.
- A person sees one failure line per unreadable file per pass, which is what
  they saw before for the Mac's `gaps` — the difference is that the file
  survives.
- `Verification/coverage.json`'s boundary for `LampSyncBundlePass.swift` has
  to say it, since it is a new condition on what a pass fetches and records.

## What it must not break

- A readable file is planned exactly as before: the predicate only ever
  *removes* paths, and only ones the gather named.
- A tombstone whose file is refused is still kept, because pruning sees the
  whole listing — the same reason an unplanned kind does not drop one.
- A refused path is not counted as a deletion not carried out.

## What this makes possible, and is not done here

`0012` keeps a deliberate asymmetry: the gather **follows** a symbolic link
and only the upload refuses one, because a gather that refused would have
left the path out of the locals and the install would have written the
server's bytes through the link. That reason is now gone — a refusal has
somewhere to go. So `LampSyncOpenFile.with(followingLinks:)` could be `false`
at the gather, and `ELOOP` could land in `refused` with its own reason, which
would close the symlinked-module case completely for the part a person can
reach.

Left for its own change, with its own record, because it reverses a sentence
`0012` states plainly and that record should be superseded rather than
quietly contradicted.

## Rejected

- **A third state in the plan.** `plannedKinds` already meant "not acted on
  this pass", with the pruning behaviour this needs. A second mechanism
  beside it would be two things to keep in step.
- **Reporting without excluding**, which is what the Mac did: the person was
  told and the file was overwritten anyway.
- **Putting a refused path in `heldWithoutAFile`.** That says "held, taken at
  that revision, unchanged since", which is a claim about content this client
  cannot make about a file it could not read — and it only works for a path
  that already has a recorded revision, where the hazard is worst for one
  that does not.
- **Building `openat`/`O_NOFOLLOW_ANY` on the back of this.** The ancestor
  race `0012` describes is still race-only, still needs a process writing in
  the library mid-pass, and this mechanism does not make it worth building.
- **A test that takes a file's permissions away.** Mode 000 does not stop
  root opening it, and a suite run as root would then describe a readable
  candidate and never reach the pass. The fixture is a directory where the
  file should be, which no privilege makes readable.
