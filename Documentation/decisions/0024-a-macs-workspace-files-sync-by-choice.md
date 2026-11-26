# 0024. A Mac's workspace files sync by choice

Status: Accepted for the Mac, 2026-11-25, held by `WorkspaceSyncSettingTests`,
`withWorkspaceSyncOffOnlyDocumentsAreGathered`,
`workspaceSyncDefaultsByWhetherThisMacHasSyncedBefore` and
`withWorkspaceSyncOffOnlyDocumentsAreWork`. Planned by Fable; the owner asked
for it.

## Context

Everything under a writing's workspace that is not one of its documents is a
`.workspaceFile`: its sources, its agent chats, its revision history, the
custom skills. Only a Mac uses them — the phone has never planned the kind —
and they are most of what a library holds: 347 MB of sources alone on the
owner's. A writing's documents (`.writingDocument`) and its review marks
(`.writingReview`) are another matter: the phone has them, and they always
sync.

## Decision

**Whether a Mac syncs its workspace files is a choice, kept on that Mac**
(`WorkspaceFilesSync`, `sync.workspaceFiles`): off for a new library, on for
one the Mac has completed a pass for already — decided once at launch and then
the reader's, in Settings › Sync as "Sync writing workspaces from this Mac".

Off, the Mac does what the phone has always done with the kind: it passes core
a `plannedKinds` that leaves `.workspaceFile` out, so nothing of it is
uploaded, fetched, tombstoned or reaped, and what is already on the server is
left exactly as it is. The gather offers only the documents, lists no folders
for the kind, reads no attachment times, queues no tool-output cleanup
(`0023`), and the local-work reading counts only documents, so an attached PDF
does not start a pass with nothing to publish. Offload and its setting are
unavailable, and a request still waiting is withdrawn and said. The setting is
read once per pass, so a change part way through does not split one.

Turning it off is refused while sources are only on the server, or a source
removal is still waiting to reach it — the offload lock — since they would be
left there with nothing here asking for them back. Turning it on starts a pass,
which downloads every source already on the server; Settings says so. A source
removed while off stays queued and is carried out when it is on again.

Rejected: a synced setting, which would let one Mac switch another's off — the
Mac's settings travel last-copy-wins — and deciding the default from the sync
records, when "has this Mac completed a pass" says the same thing with one
read.

## Consequences

A Mac with it off has no copy of its writings' sources, chats or history
anywhere but on itself. A second Mac with it on syncs them as before; the two
differ exactly as a Mac and the phone always have.

A recent deletion of the kind is still asked about by core's per-file probe
for a fortnight, whether or not it is planned — the phone pays the same. A
guard there would touch the merge model, and is left for a change of its own.

## Review

Two serious findings, both the setting read too early. A pass read it once at
its start, so turning it off during a pass still let that pass's offloads
delete a local copy; offloads now also check it as it stands — before the run
and before each file goes. And a Move or Join ran its pass without reading it
at all; it is now read where every pass starts, a Move's included.

And two lesser ones: turning it off withdraws a waiting offload request at
once, without waiting for a pass that may fail; and off, the export reads and
stages nothing of the kind, so an unreadable skill or chat cannot stop the
pass that carries the documents.

## Review of the fixes

Reviewed on its own, the fix commit had three lesser faults, now fixed: a Move
ran a pass queued while it ran only if offloads were waiting, so turning
workspace sync on during a Move did not bring the downloads; the withdrawal
started by turning it off could outlive a turn back on and cancel a request
made after it, so it now stops the moment offloads are allowed again; and it
reported a cancellation it could not save as done.

The controller is testable after all: `WorkspaceSyncSettingTests` builds one
on a private defaults suite and a temporary library, and holds the refusal to
turn it off while sources are only on the server, the withdrawal, its stop
when offloads are allowed again, and its report of a cancellation that failed.
Still without a test: the live check before an offload and a Move's reading
of the setting and its queued pass, which need a pass run against a server.

## Stopping

Three further reviews of the fixes found only lesser faults, all in the
previous fix and all in the Move or Join — the one-time move from the old
layout, which the owner's library has made. That is `0022`'s stopping rule
met, and its cutting rule applied: the follow-up after a Move goes back to
running only for waiting offloads. A pass asked for during a Move — turning
workspace sync on, say — waits for the next pass, or Sync Now. Chasing it from
the Move met a server not yet showing the moved library, and a refusal whose
own error it would replace, round after round. The withdrawal's reason is now
taken with each cancellation, as the settings stood when it acted.
