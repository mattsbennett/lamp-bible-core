# 0020. A source may be put back on the server alone

Status: Accepted for the Mac, 2026-11-25, held by
`offloadsAsourceTheServerHolds`,
`refusesToOffloadAsourceTheServerHasNotTaken` and
`theInstructionsNameAsourceThatIsOnlyOnTheServer`. Builds on `0018`, whose
withholding this is the only producer of. Asked for by the owner.

## Context

`0019` gave a source a way off the server, and `0018` stopped the server
pushing back a source this Mac no longer holds. Together they make deletion
work, but deletion is the only lever either of them offers: a reader who
wants the 355 MB of sources off *this* Mac, and still wants them, has
nothing to press.

The space is worth reclaiming. On the owner's library the sources are 355.0
MB against 8.9 MB of revision history, and the great majority of them are
PDFs that were read once. They are also, by this point, held in two places:
on the store, and here.

`0018` already describes a Mac that holds no copy of a source the server
has, and keeps its hands off it. Nothing, until now, could *put* a Mac into
that state deliberately.

## Decision

Offloading is a separate act from removal, with a separate control, and the
two are never collapsed into one menu.

- **Offload** deletes this Mac's copy and leaves the server's. It is
  reversible by **Download**, which fetches the copy back. A row in that
  state draws with `icloud.and.arrow.down` and says "On the server".
- **Remove** is `0019`'s deletion: it goes everywhere, and it is not
  reversible.

A source may only be offloaded once the server is known to hold it — the
record for the file carries a confirmed `installedRevision`. Without that
check, offloading a source the pass has not yet uploaded would be a
deletion wearing a reversible label.

The offload is **noted before the file is deleted**, not after. A crash
between the two then reads as "offloaded, and the file is already gone",
which is true and recoverable; the other order would read as a source this
Mac has never seen, which `0018` would then withhold for ever with no way
to ask for it back.

An agent working in the workspace may **Download** an offloaded source and
may not offload or remove one. It can want a source it cannot see; it has
no standing to decide the library should stop holding one. Its inventory
names an offloaded source, marks it "not downloaded", and tells it not to
treat the absence as a missing file.

## Consequences

Nothing offloads by itself yet. This record is the mechanism and the
safety rule; the policy that will actually reclaim the space — offloading a
workspace's sources after a period of inactivity — is the owner's setting,
and it will call `offloadSource` rather than inventing a second path.

`0018`'s withholding now has exactly one producer, the recorded offloads.
That is deliberate: withholding driven by "this Mac does not have the file"
was tried first and was wrong four times over, because a new Mac has none of
the files and would have withheld the whole library with no way to fetch it.
Withholding is a policy this Mac has stated, never an inference from an
empty folder.
