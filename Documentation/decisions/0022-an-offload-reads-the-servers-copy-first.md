# 0022. An offload reads the server's copy first

Status: Accepted for the Mac, 2026-11-25, held by
`anOffloadGoesOnlyWhereTheServersCopyIsTheseBytes`,
`anOffloadReadsOnlyAsTheLooksAccount`, `anOffloadRunReadsBackOnlyItsBudget`,
`theLockAdmitsOnlyItsServerAndAccount`, `anonymousIsNotAnEmptyUsername`,
`afolderHoldingAnOffloadedSourceWaitsForItsDownload`,
`acopyComingBackDifferentIsSaidAndNotMarked`,
`adownloadWhoseQuarantineWillNotTakeIsKeptAndSaid`,
`asourceComesBackWithItsQuarantine`, `arequestNeedsAfileToBeAbout`,
`attachingRefusesOverAnUnreadableLedger`, `aledgerBehindAdeniedFolderIsUnreadable`,
`acopyAnInterruptedImportLeftIsCheckedAtTheNextGather`,
`afileTheReaderPutsInPlaceIsNotSaidToHaveComeBack`,
`asourceHiddenByAfolderIsDrawnBesideIt`,
`aworkspaceFolderLampMayNotSearchIsUnknown`,
`amemberTheServerDoesNotListIsNotOffloaded`,
`membersWhoseNamesFoldTogetherAreNotOffloaded`,
`downloadAllLeavesOutAsourceAfolderHides`,
`afailedReadCostsNothingFromTheAllowance`,
`asharedObjectIsNotMarkedForOneSource`, `afolderLockFollowsItsFolder`,
`afolderLockAdmitsOnlyItsFolder`,
`anOffloadIsForgottenOnlyWhenTheServerRecordsItsDeletion` and
`asourceSomethingStandsInTheWayOfStaysPut`.
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

## First review of the rebuild

No finding was about the read-back. Two serious ones were about the ledger
that says what is offloaded, in code older than this record:

- *Attaching over an unreadable ledger.* The names offloaded sources still
  hold were read from a ledger that answers empty when it will not read, so a
  new file could take an offloaded source's name and go up over its only copy.
  Attaching now refuses when the ledger will not read.
- *A ledger behind a folder Lamp may not search read as none.* "Is there a
  ledger" was asked with `fileExists`, which answers no for a file it cannot
  reach; the lock then saw nothing offloaded. Only a read that fails with
  "no such file" now means no ledger. Anything else is unreadable, and the
  lock holds.

And five lesser ones: what left is now kept until a returning copy is checked,
not until the gather answers the act — and checked at the gather too, so a copy
an interrupted import wrote still gets its mark (a different file there is the
reader's, and is not reported as having come back); re-entering the locked
account's own credentials is allowed, so a lost password can be restored
without opening a switch; a source hidden by a folder at its own path is drawn
beside the folder, telling the reader to move it; the read-back allowance is
shared by the whole run and checked before each read, with one oversized file
allowed only as a run's first; and both kinds of return notice are said when
both happen.

## Second review of the rebuild

One serious finding was in the read-back's reach rather than in another
memory. **Matching bytes are not enough for Download.** A server can return a
strong tag on PUT and the right bytes on GET, yet list the file with no
revision; Download plans a fetch only for a member listed with one, so such a
source, offloaded on its bytes, would sit on "Coming back" for ever. An
offload now also needs the pass's listing to have shown the path with a
revision. A source uploaded during that pass is not yet in its listing, so a
requested offload gets one more pass, once per press, and says so in its pane
if that does not list it either.

The other serious one was the ledger lesson again, one folder up: the list of
workspaces was read with `fileExists`, so a folder Lamp may not search read as
no workspaces and the lock could lift. The list now treats only "no such
file" as empty, and throws otherwise.

And three lesser ones: two members whose paths differ only in case are not
offloaded, since the pass refuses to fetch such a pair back; the read-back was bounded to the local copy's size
and one byte by a ranged read (reverted in the third review); and the pane
draws a source hidden by a folder under its own row identity.

## Third review of the rebuild

The one serious finding was the second review's own fix. **A ranged read is
not the whole file.** A server answering a ranged request with a part that
matched the local bytes would have vouched for a file that is longer. The
read-back is the whole body again, streamed to disk — exactly what Download
does. The bandwidth bound goes with it: a server copy replaced by something
larger in the seconds between a pass and its offloads is read in full once.
That is accepted; the bound on what a run *plans* to read stands, and a read
is charged to it only when it completes, so one the server refuses every time
does not hold back the sources behind it. (The Mac's WebDAV client still
forwards the ranged read; that is simply correct.)

And: Download All leaves out a source a folder stands at, whose failure would
have stopped the whole workspace's import; a lock on a sync folder carries the
folder's device and inode and follows it when Finder renames or moves it —
`0021`'s open item — rather than refusing the folder holding the copies; the
sweep stops if the inactivity setting changes while a read is in flight; and a
returning source linked to a stored object other sources share is not marked
where they carry another mark or none, since the mark would be theirs too — it
is said instead.

## Fourth review of the rebuild

The serious finding was again the previous round's fix. **Following a renamed
folder also has to refuse a replaced one.** The lock learned the folder's
device and inode to follow a rename, but admitted any folder at the locked
path; a different folder put there could settle the offloads as gone. A folder
lock now admits a pass only at its own folder, path or no path. The owner chose
to fix this and every lesser finding, then review again.

The lesser ones: an offload is settled as gone only by a deletion the manifest
*records* — a manifest that merely does not mention it may be an older one
restored on the server, with the copy still there; turning folder sync back on
to the locked folder, renamed since, is allowed by its identity rather than
refused by its path; a source with anything in its way — a folder at its path,
or a file where one of its folders should be — is left out of Download All,
refuses its own Download, is withheld if already asked for, and is drawn as
blocked, since its failed import would stop the rest of the workspace's; the
check made after a long read-back asks whether the look is still the pass's,
at the same server and account, without expiring it under a read that has just
matched; and the phone's pull waits for the offloads after a pass and for any
pass queued behind them before reading the library.

Still open: a source the server holds but a restored manifest no longer names
keeps its row and the lock, which is the safe direction, but Download cannot
fetch it — the gather only asks about paths the manifest names. Getting it
back needs the manifest to name it again.
