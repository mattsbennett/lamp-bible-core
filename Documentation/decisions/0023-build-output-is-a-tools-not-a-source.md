# 0023. Build output is a tool's, not a source

Status: Accepted, 2026-11-25, held by `whatIsInsideAtoolsFolderIsItsOutput`,
`theWritersOwnFilesBesideItAreNot` (core), and on the Mac by
`atoolsOutputIsNotGatheredButTheFilesBesideItAre`,
`toolOutputOnTheServerIsQueuedOnce`, `removingAfolderQueuesNoneOfItsToolOutput`,
`neitherTheLedgerNorTheSweepWalksIntoAtoolsFolder`,
`toolOutputIsCleanedUpWhateverItsMarkAndPostdatesTheWrite` and
`removingAtoolsFolderQueuesNothing`. Planned by Fable; the
owner asked for it after `0022`.

## Context

On the owner's library 842 files sync with the NAS. 489 of them — 58% — are
one `node_modules` tree, inside a writing's sources under
`Context/…/deck-build/`, where a slide deck is built. Every pass lists, plans
and accounts for each of them. They are 24.5 MB of 372 MB, so leaving them
out is not about space; it cuts the members a pass deals in by about 87%.

They are already on the server, and that is the trap. A member the server
lists with no local file is planned as a download (`LampSyncFilePlan.change`):
a gather that merely stopped looking at them would fetch all 489 back on every
pass — the fault `0018` was written about.

## Decision

**A folder named `node_modules`, `venv`, `.venv`, `__pycache__` or `.git`
anywhere under a writing's sources holds a tool's output, and nothing in it is
a source** (`LampWritingWorkspaceLayout.toolFolders` and `isToolOutput`, in
core so every client and the writing import share one list; the import's
`skippedFolders` is now that list). A name rule is a pure function of the path,
not an inference from absence.

On the Mac:

- No walker of a writing's sources descends into one: the export that gathers
  them, the file ledger, the offload sweep, and the removal that names what a
  folder held.
- **A copy already on the server is removed from it, queued as a reader's
  removal of it would be** (`LampSyncRemovedModules.queueToolOutput`), at the
  gather, for each member that is tool output and not queued yet. The existing
  tombstone, reap and forget then carry it out, once. The queue is written
  only when something is added: its date is what tells this Mac it has work
  to publish.
- The local tree is left alone. It is the writer's working copy, and a
  member tombstoned with no local file plans nothing here.

The `deck-build` folder's own files — `build.js`, `package.json`, the deck's
images — are the writer's, and keep syncing. The phone neither publishes nor
fetches a writing's sources, so it needs nothing.

Rejected: withholding them, which strips the tombstone and the reap with
everything else, so a withheld member can never leave the server; making the
layout refuse such paths, which would leave the 489 manifest entries with no
way to be reaped; and deleting whole folders on the server, which the
per-file layout has no shape for.

## Consequences

The first pass after the upgrade tombstones and reaps the 489 files, one
request each over the LAN. After it, a pass gathers only the writer's files;
each pass logs what it gathered, what the server counts and what it listed,
to measure it by.

**A Mac on an older build keeps uploading them.** Where its own ledger has
dated them, the tombstone wins and it deletes its local copies once. Where it
has not, it uploads them again as new, this Mac tombstones them again, and the
two go back and forth — 489 writes and 489 deletions a round — until the older
Mac is updated. Every Mac that syncs this library should be updated together.

The tombstones themselves age out after 180 days, like any other.

## Review

Core: one lesser finding — a name beginning with a combining mark joined the
slash before it into one `Character`, so the rule missed the folder; it now
splits on the slash scalar.

Mac, two serious findings:

- *Tool output offloaded under `0022` could lose its only copy.* The offload
  sweep could have let such a file go before this change; cleaning it up then
  reaps the server's copy, the only one. Tool output this Mac has offloaded
  or asked back is left out of the cleanup until it is here again, and the
  sweep no longer looks inside a tool's folder at all.
- *Two weeks of per-file questions.* Core asks the server about every recent
  deletion of a kind no listing reaches, one request each, for the fourteen
  days a failed reap is retried — about 489 requests a pass where the same
  files cost 81 folder listings before. **Accepted by the owner**: the cost
  ends by itself after a fortnight, and passes are lighter for good after it.
  Teaching core that a file missing from its folder's listing is confirmed
  gone would remove it, at the price of a change to the merge model; not
  worth it for a one-time migration on one Mac.

And: a cleanup is dated past the member's own write, so a clock behind the
uploader's cannot make it lose; it is queued on the actor the reader's own
removals use, so neither overwrites the other; and removing a folder no
longer walks into a tool's folder to list what it holds.

## Review of the fixes

Reviewed on its own, the fix commit had two lesser faults, now fixed. Tool
output downloaded after being offloaded kept its "asked back" mark for ever —
nothing gathers a tool's folder, so nothing answered it — and so was never
cleaned up; a file that is here again now has its mark cleared and is cleaned
up like the rest. And moving the cleanup onto the workspace actor to keep it
from overwriting a reader's source removal put it beside a module removal
that writes the same queue on the main actor: every write to the queue now
goes through one locked read-change-write (`LampSyncRemovedModules.update`),
whatever actor it runs on. The lock has no test of its own; a race is not
something a test here can provoke reliably.

## A cut instead of a third check

The second fix — clearing a returned file's mark so it is cleaned up — could
itself delete the wrong copy: a build recreating the file with other bytes
would read as the download having landed. Rather than check the bytes, the
exception is gone. **Nothing under a tool's folder is kept for an offload
mark**: none is gathered or offloaded any more, the owner's library had none
offloaded, and a `node_modules` file deleted from the server is reinstalled by
the tool. Reconciliation then forgets the mark with the tombstone, as for any
source deleted. The first review's "only copy" finding is answered by `0023`'s
own premise: tool output is reproducible.

Also: the withdrawal that stops when offloads are allowed again still reports
what it had already done; and the pass a Move runs afterwards runs only once
the library has moved, so a refused Move keeps its own error.

Its review found three lesser faults, fixed: tool output an older build had
offloaded was still withheld, which strips the tombstone its cleanup needs —
it is no longer withheld; a Move the server took but did not confirm skipped
the pass queued behind it — the follow-up is now skipped only for a Move
refused before anything was written; and a withdrawal said why it happened as
the settings stood when it finished, not as they stood when it acted.
