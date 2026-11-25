# 0021. A writing left alone gives its sources back

Status: Accepted for the Mac, 2026-11-25, held by
`WorkspaceSourceOffloadTests`, `WorkspaceSourceOffloadGatheringTests`,
`offloadsAbatchAgainstTheCurrentServerAndTheUploadedBytes`,
`asourceThatWillNotGoIsNotMarkedOffloaded` and
`thecheapDateQueryAgreesWithTheWritingsThemselves`. Completes `0020`, which
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

**After a finished pass, not at launch.** Offloading may only touch a file
the server is known to hold, and a confirmed revision is what a pass's bundle
update has just produced. A launch sweep would run on what the records said
when the app last quit. The launch pass means "after a pass" covers launch
anyway, and with sync off there is no pass and so no sweep — which is right,
because there is nowhere for the sources to go. Throttled to once an hour.

**The sweep is stricter than the button**, in two ways, because nobody is
watching it:

- it checks the **current** source. `mayOffload` accepts a confirmation from
  any server this Mac has ever synced with, so after a change of server it
  would delete the only copy of a file the new one never took.
- it checks the bytes on disk are the bytes that went up. A confirmed
  revision says an upload completed, not that nothing has happened since.
  Sources are read-only hard links and nothing writes one in place, so this
  should never fire; it costs one hash of a file about to be deleted anyway.

A writing with an editor open is never swept, whatever its dates say. The
agent pane lives inside that editor, so a chat or a Terminal turn mid-flight
is held back by the same check.

## Consequences

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
