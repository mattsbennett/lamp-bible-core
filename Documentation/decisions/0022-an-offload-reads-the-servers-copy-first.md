# 0022. An offload reads the server's copy first

Status: Accepted for the Mac, 2026-11-25, held by
`anOffloadGoesOnlyWhereTheServersCopyIsTheseBytes`,
`anOffloadReadsOnlyAsTheLooksAccount`, `anOffloadRunReadsBackOnlyItsBudget`,
`theLockAdmitsOnlyItsServerAndAccount`, `anonymousIsNotAnEmptyUsername`,
`afolderHoldingAnOffloadedSourceWaitsForItsDownload`,
`acopyComingBackDifferentIsSaidAndNotMarked`,
`adownloadWhoseQuarantineWillNotTakeIsKeptAndSaid`,
`asourceComesBackWithItsQuarantine` and `arequestNeedsAfileToBeAbout`.
Replaces the safety rule of `0021` and its review rounds five to fourteen.
Planned by Fable after the fourteenth round; the owner chose the rebuild, the
Remove cut and keeping the quarantine mark.

## Context

`0021` let a source's local copy go where three memories agreed: this Mac's
record of uploading it (a digest and a revision), the pass's listing of the
server's folder (a revision now), and the local file's digest. Each review
round then found one more way for them to agree while the server did not hold
the bytes Download would give back: a listing labelled with the wrong server
or account, a pending record, a weak tag, a server numbering versions from
one under a second account, an account switched twice, anonymous against
signed-in, another device replacing the file mid-pass, and — the fourteenth —
an upload whose response carried no strong tag, which core's revision-only
confirmation pairs with whatever strong tag the server shows next. Two of
round thirteen's three serious findings were in round twelve's fix.

The shape was the same every time. The proof was a conjunction of memories
taken at different times by different code under different labels, and every
seam between two of them was a finding. Adding a term adds a seam.

## Decision

**The proof is a read.** Just before a source goes, the server's copy is
read back through a store made exactly as the pass's was — same address, same
credentials, same folder access, from one function every caller uses — hashed,
and compared with the local file's digest from the same open that gives the
identity the unlink checks. Only equal bytes go. Records and the manifest
remain, as a short list of what is worth reading back: a manifest member that
this Mac uploaded or downloaded with these bytes. Nothing remembered stands in
for the read.

It costs one read per source, once: the library's sources are 347.7 MB, ever,
over a LAN. A run reads back at most 1 GB; the rest wait for the next pass.

It closes everything above at the moment of deletion, because none of it is
consulted. It cannot say the server keeps the bytes afterwards — that is the
lock's job — and the seconds between the read and the unlink are accepted, as
the microseconds between the identity check and the unlink already were:
replacing the file in that window takes another writer, and Lamp never writes
over a source in place.

**The lock names the account.** It holds the server and who it was reached as
(`SyncAccount.identity`: empty only with no username and no password, so
anonymous is never an empty username). A pass reaching that server any other
way is refused before it reads a manifest, which from another library would
settle the offloads as gone and release the lock. A stored password that
cannot be read is an error, never no password: going anonymous instead is how
round fourteen reached another library. A lock written before the account was
kept takes the account of the next pass at its server.

**Remove needs the file here.** Remove on a row with no copy on this Mac — or
on a folder holding one — was the one way this feature deleted a sole copy, on
the server, and it had cost seven findings. It is disabled with a line saying
to download first; the store refuses such a folder whatever the row said.
`removeOffloadedSource`, its confirmation dialog and the folder identity that
bound the dialog are gone.

**The quarantine mark is bound to the bytes that left.** The digest of each
source is kept with its offload. When a copy comes back, the same bytes get
the mark; different bytes are said ("came back changed") and get none — the
mark was about the file that left. A mark that will not take is said, and the
file stays: round fourteen's fallback, which removed the copy, could remove a
file the reader had put at the path.

Also: an offload request is bound to the file's device and inode, or refused
when there is no file to bind; the sweep and requested offloads wait while an
agent turn on that writing is in hand, phone-started ones included; a refusal
is shown only in the pane of the writing it concerns.

## Consequences

Deleted with the old proof: the listing's revisions in `ServerObservation`,
its closing against the written manifest, the weak-tag check, the per-address
account history and its marks, the follow-up passes that waited for a
confirmed revision and their "waiting" message, and `Skipped.notSeenOnTheServer`.
About nine tests went with them, and seven with Remove on an offloaded row.

Core's revision-only confirmation, which can record a digest against another
copy's tag when a PUT returns no strong ETag, is no longer a way to lose data
here. It is still wrong for sync, and stays open for whoever owns the bundle
pass.

Not done, and why: rejecting a copy that comes back different. Another
device's edit is a legitimate later version; refusing it would undo sync's
last-writer rule for this one kind of file. It is said instead.

Not covered by a test, because it lives in the app's controller: refusing a
pass whose account does not match the lock, and the keychain read error. Each
is a few lines over `OffloadLock.admits` and `SyncAccount.identity`, which are
tested.
