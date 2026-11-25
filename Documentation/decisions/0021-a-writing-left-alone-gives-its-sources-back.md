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

## What a second review changed, and what it left

Every finding of the first review was real, and so was every P1 of the
second. Three of those were paths where "reversible" was not:

- **Remove on an offloaded row could delete a tree.** The listing is shallow
  and drawn from the ledger as well as the disk, so a row can name a path a
  *folder* has since taken; the removal unlinks recursively. It now takes
  only a regular file inside the context directory, as the sibling that
  carries out another device's deletion already did.
- **The batch deleted whatever was at the path, not the file it checked.**
  Every candidate is hashed before any is deleted, so a batch leaves a window
  in which Finder, a restore, or an agent running in that very workspace can
  put other bytes at an already-checked path. The file's identity is taken
  with the digest and compared again immediately before the unlink — the full
  identity, not the inode, because a write in place keeps the inode.
- **The manual button had no look at the server**, which this record had
  justified on the grounds that a reader is standing there watching. That is
  not a substitute for knowing: the record it trusted is the same record that
  outlives a source somebody deleted from the sync folder by hand. The button
  now takes the last pass's listing, and refuses, saying so, when there has
  not been one.

Also from that round: removing a folder takes its *offloaded* descendants
too, or they stay on the server for ever with nothing left here to name them;
a source asked back is left alone for a week, since a download advances no
inactivity clock and the sweep would otherwise undo it on the next pass; and
Remove on an offloaded row asks first, because that click destroys the only
copy there is. Remove on a row whose file is here does not ask, which is the
behaviour it has always had.

**And then closed.** Those four were written here as follow-ups and done the
same day, which is the right order round: they are small, and each was a way
the feature lied to the reader.

- **A download that failed left no row.** Clearing the note is what lets a
  pass fetch a source, and that also took it off the list — so an unreachable
  server left nothing to see and nothing to press. The *ask* outlives the
  attempt now: a source asked back and not yet here reads "Coming back" and
  carries Try Again. It stops being awaited when the file arrives, and when
  it is let go of again.
- **Another Mac's removal of a source neither is holding** reached nothing.
  There is no local file for the plan to delete, so the note survived and the
  row went on saying "On the server". The pass's manifest is now reconciled
  against the notes — on membership, never on a folder listing, since a
  listing that failed is not a deletion.
- **The agent's inventory** was rewritten when a download was asked for
  rather than when it landed, so an agent started in the pane in between was
  told about a source that was not there. It is rewritten when the pane
  notices the sources have actually changed.
- **The editor hold** was taken once before the batch. Hashing a workspace's
  sources takes long enough for a reader to open the writing in the middle of
  it, so it is asked again before each file goes.

## A third review, and a fix that did nothing

The folder removal above — "removing a folder takes its *offloaded*
descendants too" — **did not work when it was written**, and shipped with no
test. It asked the ledger for members under an empty prefix; that function
answers in published paths and checks them against the published shape, so
handed anything less than the whole workspace prefix it filtered everything
out and returned nothing. The record said the behaviour existed. It did not.
It does now, and a test fails if it stops.

That is the argument for the loop rather than against it: the fix read
correctly, the record described it correctly, and only a reviewer reading the
function it called noticed that the two did not meet.

Four more of the same kind, all introduced by the two rounds of fixes before
this one:

- Recording the *ask* so a failed download keeps its row meant that carrying
  out another device's deletion recorded one too, leaving a row saying
  "Coming back" for something that was never coming. A deletion forgets the
  note; only a reader asking records a request.
- Remove on a row that was waiting for a download did nothing: it has no
  local file either, so it needs the same path an offloaded row takes.
- The digest and the identity were read separately, so a file replaced
  between them bound one file's verified bytes to another file's identity —
  and the check before the unlink would then wave it through. They are taken
  either side of the read now.
- Comparing the *whole* identity treated a hard-linked sibling as replaced:
  sources are links into the object store, and unlinking either moves the
  shared inode's change time. Two copies of one file would never both go.
  Everything but the change time was compared — reversed in round five,
  below, because it cost `0007`'s guard.

And the pane's Offload now refuses on an observation older than a quarter of
an hour, rather than acting on a listing from whenever this Mac last synced.

## The collapse

Four review rounds found about forty defects, nearly all of one shape: two
representations that had to agree, and did not. Fixing them one at a time
kept producing the next — most of each round's P1s came from the round
before. So the design was taken back to the planner, which named two
faults and one window, and the feature was rebuilt around them. Everything
above this section is the history that led here; this is what the code does.

**One act per path; presence observed.** The ledger records what the reader
*did* to a source — let it go to the server, or asked for it back — as one
value per path, `offloaded` or `wanted`, or none. Whether the file is here is
never stored: it is read from the disk every time, and only a regular file
counts — a folder that has taken the path does not. Everything else is a
function of the two:

| act | file here | withheld | row |
|---|---|---|---|
| none | yes | no | the file |
| none | no | no | none: the pass fetches it, as `0018` says |
| `offloaded` | no | **yes** | "On the server", Download |
| `offloaded` | yes | no | the file — an unlink that never happened, or a reattachment |
| `wanted` | no | no | "Coming back", Try Again |
| `wanted` | yes | no | the file |

It replaced a set of offloaded paths and a dictionary of fetch times whose
value meant "asked at" before arrival and "landed at" after. A path cannot be
both offloaded and wanted now, because it holds one value; forgetting and
asking are different values rather than two helpers that shared a line.
The withholding, the pane's rows and the agent's inventory all read one
derivation, so they cannot disagree with each other.

**Grace is by arrival.** A source is left alone for a week after it *arrives
here*, however it came — fetched, attached, or copied in by another Mac. That
is a local field of its own, `arrivedAt`, stamped both when the gather first
sees a context file and when a pass records what it has just installed: a pass
installs sources after the gather's note, so the gather alone never sees a
download arrive. It is kept apart from `presentSince`, which is portable and
settles deletions across devices — an arrival here is this Mac's fact, and
moving the shared value on every download would move when other Macs judge a
deletion to have happened.
Measuring from the ask arrived already expired for a download slower than the
grace. And it closed a gap no review found: none of the writing's activity
clocks moves when a source is attached, so a PDF attached to a six-month-old
writing in preparation for working on it was uploaded, listed, and offloaded
by the sweep two passes later.

**One observation, from one place.** What a finished pass saw — which store,
which members the manifest counted, what the listing of the context folders
said — is one value, written by the gather and labelled with the source *its
store was built from*. It used to live in three places, and a review found
them disagreeing about which server they described. It answers only for that
server and only for a quarter of an hour, and it becomes the current
observation only when the pass finishes. There is no longer a way to offload
without one.

**The unlink takes a verified source, and nothing else.** A source is read
through one open of the file, which gives its identity and the digest of the
same bytes (`decisions/0012`, through core's `LampVerifiedFileRead`); the
identity is taken either side of the read and must agree. The unlink takes
only that value, asks the path — without following a link, and refusing
anything but a regular file — whether it still holds those bytes, and calls
`unlink(2)`, which will not remove a folder. The comparison is the **whole**
identity, change time included: the change time is the only thing that
notices a file rewritten at the same size with its date put back, which
`0007` requires be noticed. A first version of the rebuild ignored it, because
unlinking one of two hard links to a source moves the other's — and a review
pointed out that this traded away `0007`'s guard to save a pass. So a
workspace holding the same file twice offloads one copy now and the other on
the next sweep, read afresh.

**What is accepted rather than closed.** Between that last question and the
unlink there is no I/O and a few microseconds; macOS cannot unlink by
descriptor, so it cannot be closed, and only another process of the same user
in the workspace could use it. That is the bound `0010` already accepts. Three
review rounds went into narrowing it; this is where it stops.

The hold on an open writing is asked once per file, **before** anything is
noted for it, and nothing suspends from noting the offload to unlinking the
file — so a pass gathering the workspace can never see between them.

A Download asked for while a pass is running is answered when that pass
finishes, rather than left for a poll only the reader window runs.

One finding from the earlier rounds turned out to describe nothing: comparing
names in NFC so a decomposed name is not drawn twice. Swift compares strings
by canonical equivalence, so the two spellings were already one row. The
normalisation stays, because the path goes on to name a file and a ledger key,
where the bytes do matter — but the row was never wrong.

## Round five, on the rebuilt design

Nothing in it landed in the act-and-presence core, the verified unlink, or
the row table's logic, which is what the rebuild was for. Two findings were
the old shape in a path that had not been moved onto the shared derivation —
a folder that has taken an offloaded file's own path hid it from the
confirmation while the removal still counted it, and the arrival stamp that a
pass's import never reached. The rest were where this feature meets the rest
of sync:

- **The comparison ignored the change time**, so a file rewritten at the same
  size with its date put back passed as unchanged — `0007`'s guard, given up to
  let a hard-linked twin go a pass sooner. Reversed, as above.
- **A pending upload vouched for bytes nothing had confirmed.** `recordUpload`
  moves the uploaded digest and the pending revision together and leaves the
  installed revision until the bundle update confirms, so after a failed update
  the digest named new bytes and the revision old ones. The digest and the
  revision have to be a confirmed pair now; a pending record vouches for
  nothing.
- **A sync refused because one was running looked like a sync that failed**,
  and threw away the observation the running pass had just written. It is now
  turned into a request for a pass afterwards, before anything is touched.
- **Membership comes from the closing manifest**, so an update that retried
  against another device's deletion does not leave that source drawn as on the
  server. The listing stays the gather's: revisions are what was seen.
- **Switching servers does not forget what the old one holds.** Reconciliation
  only forgets a source the server it is talking to ever recorded.
- **Each unlink also asks whether the same server is still configured**, so a
  sweep does not go on deleting after sync is turned off or moved.
- **Removing a source that has just landed goes through the verified unlink**,
  so it cannot remove a folder put at the path while it was being hashed.

Three of those live in the controller and are held by reading rather than by a
test: the refused-sync guard, the closing manifest, and the per-unlink check of
the server. The others each have a test that fails when the fix is reverted.

## Round six

Ten findings across both repositories. Fixed:

- **Identity is trusted only where `0007` trusts it.** The verified read now
  says whether the volume it read from keeps an identity that notices a
  change — taken from the open descriptor, so it is the volume the bytes came
  from. Off APFS nothing is offloaded: on exFAT, or a share that mirrors the
  write time into the change time, a file rewritten at the same size with its
  date put back keeps a matching identity, and the last check before the
  unlink is of identity alone.
- **The closing manifest must still count a source** before the listing may
  vouch for it: another device can remove and reap it after the gather looked.
- **The unlink re-checks that the file still resolves inside the context
  directory.** `O_NOFOLLOW` and `AT_SYMLINK_NOFOLLOW` guard only the last
  component (`0012` says so), so a folder on the way moved out and replaced by
  a link would have led the unlink to the same file in its new place.
- **A confirmed Remove spares a different file** attached under the same name
  while the confirmation was open. A file here is the source being removed
  only if its bytes are the ones this Mac uploaded.
- **The button and the sweep both ask, just before each unlink, whether the
  look they began with is still the current one** — same server, no newer pass.
- A link at an offloaded path no longer hides the row that offers it back; the
  first pass after an upgrade stamps arrival, so nothing is offloaded for the
  first week; and a socket is reported as not a file rather than unreadable.

Held by reading rather than a test: the refusal off APFS (the test machine's
volume is APFS, so the guard never fires there; core tests the trust decision
itself), and the per-unlink recheck of the observation.

**Not fixed, and why.**

- *An offload is not tied to the server that holds it.* Offload to one server,
  switch to another, and the source is stranded on the first: the new server
  never had it, Download cannot reach it, and Remove would queue a path-only
  deletion against the new server. Not a defect to patch but a question of
  what switching should do with sources that live only on the old server —
  so it went to the owner. Decided below.
- *A download already in flight can undo a Remove.* If a pass has planned the
  download when the reader removes a source that is on its way, the file can
  land after the deletion and be accepted as newer. Closing it means checking
  the queued removal where the import commits a download, which is core's
  sync path rather than this feature's.

## Switching servers while sources are offloaded

**The owner's decision, 2026-11-25: refuse until they are downloaded.** Of the
three offered — refuse, download them and then switch, or keep them listed
against the old server — this is the one that cannot strand anything, and if
a server is being left for good, downloading first is what has to happen
anyway.

The lock is the server the offloads went to, **written down when the first
offload begins** — before anything is deleted — and released only when
nothing is only on the server and no removal of a source is still queued for
it, since a removal sent after a switch would reach the wrong server. While it
holds, sync may always be turned **off**, which changes no server, and may be
turned back on to that server; it may be pointed nowhere else, and the sync
details may not be forgotten. The WebDAV account is locked with the address:
another account at the same address can be another set of files.

A first version inferred the lock instead: sync could go to any server this
Mac had a confirmed record of holding every source. A review pointed out that
this was round one's mistake again in new code — a record is a memory of a
past upload, and an old server holding one may since have lost or replaced the
file, so switching back to it would have left Download fetching the wrong
version or nothing while the only current copy sat on the server just left.
It also left a window: the list the lock was read from lagged the first unlink
of a batch, and a server could be changed in it.

The Sync settings say so above the controls, with **Download All**, and
disable the address, account, folder chooser and Forget while it holds; a lock
held only by a queued removal says that instead. The controller refuses at
each setter as well, with the reason. Download All asks for every offloaded
source and starts a pass whatever the automatic-sync setting says, since it is
a press; the lock lifts once they have arrived and nothing is queued.

Reconciliation follows the same server: only the manifest of the server the
offloads went to may settle them, and within it a source missing from the
manifest is forgotten whether or not its record survives — another device's
deletion reaps the record, and requiring one kept the row for ever.

An attachment never takes the name of a source that is not here: the disk
shows it free, and a new file given it would have been published over the
server's copy.

Held by tests: the rule (`syncCannotLeaveTheServerTheOffloadsWentTo`), the
reconciliation (`onlyTheHoldingServersManifestSettlesAnOffload`), the way out
(`downloadAllAsksForEverySourceAndTheLockHoldsUntilTheyArrive`) and the names
(`anAttachmentDoesNotTakeAnOffloadedSourcesName`). The controller's refusals,
and the lock going on before the first unlink, are held by reading.

One server for the whole library, not one per source: while the lock holds,
every outstanding offload went to the same server, so recording it once is
enough and the act stays one value per path.
