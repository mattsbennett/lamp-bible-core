# 0021. A writing left alone gives its sources back

Status: Accepted for the Mac, 2026-11-25, held by
`WorkspaceSourceOffloadTests`, `WorkspaceSourceOffloadGatheringTests`,
`offloadsAbatchAgainstTheCurrentServerAndTheUploadedBytes`,
`asourceThatWillNotGoIsNotMarkedOffloaded`,
`asourceTheServerNoLongerListsIsNotOffloaded`,
`asourceTheServerHoldsAtAnotherRevisionIsNotOffloaded`,
`asourceConfirmedDuringThatPassWaitsForTheNext`,
`asourceAttachedWhereOneWasOffloadedIsNoLongerWithheld` and
`thecheapDateQueryAgreesWithTheWritingsThemselves`. Its safety rule was
rewritten the same day, after review; the first version is kept below. Completes `0020`, which
built the mechanism and said plainly that nothing used it. Planned by Fable;
the owner asked for the setting by name.

## Context

`0020` gave a reader a way to put one source back on the server by hand.
That reclaims space a file at a time, from a pane they have to open. The
sources are 347.7 MB of the 372.2 MB this library holds on disk, spread over
15 workspaces, and most of them belong to writings nobody has touched in
months.

So the lever has to pull itself.

## Decision

**The setting.** "Put sources back on the server" — never, one month, three
months, six months, one year — kept on this Mac alone and defaulting to
**never**. It is not in the synced settings: it governs this machine's disk,
and a desktop with room to spare should not inherit a laptop's policy. Never
is the default because sources leaving the machine is something a reader opts
into, and because the setting means nothing with no server to leave them on.

**The clock is not the workspace's files.** The obvious measure — the newest
modification date anywhere in the workspace — is wrong, and wrong in a way
that hides: offloading writes the ledger *into* the workspace, and so does
every sync pass, every opening of the agent pane and every arriving install.
A clock any of those move is one an offload resets by firing, so the sweep
would run once and never again. Excluding those writers one by one is the
same answer with a list that rots.

Three clocks instead, newest wins:

- the writing's own saved date, which travels in the personal file and so
  reads the same on every device;
- the newest message in the workspace's transcripts — research that never
  touched the draft is still work on this writing, and a message is dated by
  the reader's act rather than by a file;
- the newest of the writer's own documents at the top of the workspace, since
  an `outline.md` edit moves no saved date. This is the one file date, read
  through `stat`. A document arriving from sync reads as activity, which can
  only delay an offload.

None of the three moves when the sweep fires. Where none of them says
anything the workspace is kept: the answer to not knowing is to keep.

**After a finished pass, not at launch.** A launch sweep would run on what
the records said when the app last quit; the launch pass means "after a pass"
covers launch anyway, and with sync off there is no pass and so no sweep —
which is right, because there is nowhere for the sources to go. Throttled to
once an hour.

**A record is a memory. The listing is the observation.**

This was wrong when first written, and the first version is kept here because
it is the kind of wrong that reads as careful. It said: offloading may only
touch a file the server is known to hold, and *a confirmed revision is what a
pass's bundle update has just produced*. True, and empty. A record's
`installedRevision` is the last observation of that file, made once when it
was uploaded, and **no pass ever refreshes it**. A source deleted from the
sync folder by hand keeps its confirmation for ever: a workspace file is an
unlisted kind, so core never probes it; `LampSyncFilePlan.change` answers
`.none` for an unchanged local copy with no listing; and the absence report
covers listed kinds only. The pass finishes, having confirmed nothing, and a
sweep trusting the record deletes the last copy in existence.

The observation already exists and was being thrown away. The Mac's own
gather lists each workspace's `Context/` folder once per pass
(`revisionsOfUnlistedMembers`) to give those members a revision at all. The
controller now keeps that result, and a source may be offloaded only where
the listing showed it **at the revision recorded for it**. Zero extra
requests.

Three other shapes were considered and rejected:

- **A HEAD or PROPFIND per candidate** before deleting. It is a second notion
  of truth, taken by a store built outside the pass, duplicating the
  provider switch and the folder provider's security scope. The folder
  listing is the same request the engine trusts to install over local files,
  taken under the engine's retries, minutes old at most.
- **Moving the sweep inside the pass**, which would give it a store. It would
  also make core's modelled engine the thing that deletes unlisted-kind files
  unattended. The pass stays a pass; the sweep stays housekeeping after it.
- **Widening core's absence report to unlisted kinds.** The Mac draws that
  report as an error mark per file; 559 marks for sources is not what it is
  for, and the Mac already holds the listing it would be built from.

Properties worth knowing. The listing is taken at the gather, *before* the
uploads, so a source first confirmed during that same pass is not in it and
waits one more — conservative, and correct. A folder that would not list is
indistinguishable from one that showed nothing; both read as not seen, so
nothing is offloaded, which is the safe direction. And on a server whose
`PROPFIND` carries no `getetag` the sweep would be inert; on the owner's
Synology all 559 source records carry an ETag-shaped revision, so it is not.

**The sweep is stricter than the button**, in two ways, because nobody is
watching it:

- it checks the **current** source. `mayOffload` accepts a confirmation from
  any server this Mac has ever synced with, so after a change of server it
  would delete the only copy of a file the new one never took.
- it checks the bytes on disk are the bytes that went up. A confirmed
  revision says an upload completed, not that nothing has happened since.

The second of those is **not** a sweep-only rule, though it was written as
one. The reasoning for sparing the button — the app never replaces a source
in place, since `addContextItem` picks a free name rather than overwriting —
answers the wrong question. A workspace is a folder CLI agents run in: an
agent can remove and rewrite a file, Finder can drag-replace one, a restore
can put old bytes at a path. Both paths now go through one function, so the
button cannot drift from the sweep again. What the button does not get is the
listing: a press has no pass behind it, and there is a reader standing there
to see what happens.

A writing with an editor open is never swept, whatever its dates say. The
agent pane lives inside that editor, so a chat or a Terminal turn mid-flight
is held back by the same check.

## Consequences

A source is withheld only while there is **no file here** — the note says
what this Mac let go of, and a file back at that path says it has one again,
by a fetch that landed or by the reader attaching something new under the
same name. Withholding on the note alone left a reattached source withheld
for ever and never uploaded, the pane showing it as local while the pass
refused to carry it. This is strictly narrower than the note alone, so it
cannot bring `0018`'s regression back.

A source that will not delete has its note cleared again. A note saying
"offloaded" on a file still on disk is a lie in the one direction that shows:
the pass would withhold a member this Mac holds, and the pane would offer
Download for a file that is right there.

A workspace whose writing has been deleted is skipped. The folder outlives
the writing — deleting a writing leaves it, with its ledger — and the sweep
is driven by the library's writings, so it never sees the orphan. Cleaning
those up is housekeeping of a different kind and is not folded in here.

`0018`'s withholding still has exactly one producer, the recorded offloads.
This adds a second *caller* of the act, not a second way to infer it.

What this does not do is reduce how *many* members a pass handles. On this
library 489 of 842 records are one `node_modules` tree: build output, already
uploaded, reproducible by `npm install`. Excluding it is the other lever and
a separate decision, because files already on the server cannot simply stop
being gathered — a listed member with no local file plans as a download, and
that is the fault `0018` exists to name.
