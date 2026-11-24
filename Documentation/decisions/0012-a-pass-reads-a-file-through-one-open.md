# 0012. A pass reads a file through one open of it

Status: Accepted for core, 2026-11-24, held by `LampSyncOpenFileTests` and the
six upload tests that pinned `0009`–`0011` and pass unchanged. Both apps get
it, because it is in the engine. Designed by Fable after the same class of
review finding came back in four consecutive rounds.

## Context

For one candidate, a pass used to resolve the same path several times and work
from the path each time: a stat for the identity, an open and a mapping for
the digest, a second stat so a digest was only remembered under an identity
the file still had, a stat of the source in the upload loop, a `copyItem`, a
stat of the copy.

Each pair of those is a window, and reviewers found three different ways
through it: a digest remembered under an identity belonging to a different
file than the one that was hashed; a copy holding bytes from outside the
library while a later stat saw the original inode again; and — the one that
mattered — a directory on the way to a candidate replaced by a symbolic link
*before* `describe` hashed it, which makes the gathered digest the outside
file's digest too, so `0011`'s byte comparison agrees and publishes it.

Each was answerable on its own and the answers were not converging. Three of
the four findings were literally "two resolutions".

There is also a failure mode none of the reviews raised. `0008` turned paths
that had been scratch copies into live library paths, and the digest was taken
through `Data(contentsOf:.alwaysMapped)`. A mapping of a file that is
truncated under it raises **SIGBUS**, which takes the process with it — and a
pane, an agent or a command-line tool writing a document is a supported
workflow. A read that runs out of file is a short read.

## Decision

`LampSyncOpenFile.with(url) { … }` opens a path once and answers everything
from that descriptor: the identity (`fstat`), whether it is an ordinary file
(`st_mode`), the digest (read, not mapped), and a copy of it.

- **Scoped and synchronous.** Both callers finish with the file before they
  await anything — `describe` is synchronous, and the upload's open, copy and
  hash all complete before the store's write is awaited — so nothing holds a
  descriptor across a suspension. It is a plain struct whose only maker is
  `with`, not `~Copyable`: the testing macros cannot see through a
  non-copyable type, and there is no caller that needs one.
- **A gather follows a symbolic link; an upload refuses one.** That asymmetry
  is `0010`'s rejection, and it is the thing to keep straight: a gather that
  refused a link would leave the path out of the plan's locals, which reads as
  "this client does not hold it", so the plan would schedule a download and
  the install would write the server's bytes *through* the link. A refusal is
  only safe at the upload, where it is a reported failure and nothing follows
  from it.
- **A copy is a clone where the filesystem has them.** `fclonefileat` of an
  open regular file cannot come out as anything but a regular file, which is
  what `copyItem` on a link failed to promise, and on APFS it moves no bytes.
  The fallback is a read-and-write loop from the same descriptor.
- **A digest already held is answered from a stat, without opening the
  file.** Nothing is read on a hit, so there is nothing for a second
  resolution to disagree with: an identity *is* an identification — device
  and inode name the file, the size and the two times say it is untouched — so
  a digest recorded against it is of that file's bytes however the path was
  walked to find it. This is also most of the cost: an open where a stat would
  do was 200 ms of a 540 ms pass across fourteen thousand candidates.

## Consequences

- Measured at 250 workspaces, on a quiet machine: digesting every candidate
  is **673–720 ms** and **330–346 ms** with the cache answering — the same as
  before, within noise. One path walk instead of three, and a read instead of
  a mapping, costs nothing.
- `LampFileIdentity.whatIs(at:)` and `isOrdinaryFile(at:)`, and the pass's own
  errno classifier, have no callers left and are gone. A `LampFileIdentity`
  can now be made from a `stat` a caller already holds.
- A truncation under a reader is a short read rather than a signal.
- The boundary prose for `LampSyncLocalFile.swift` and
  `LampSyncBundlePass.swift` has to say the reading is through one open file,
  since that is the sentence the model's "the digest is of the bytes at that
  path" leans on.

## What it must not break

The six tests that pin `0009`, `0010` and `0011` all pass **unchanged**, which
is the point of doing this as a refactor and not a redesign:
`aCandidateThatBecameASymlinkIsNotPublished`,
`aPathWhoseDirectoryBecameALinkIsNotPublished`,
`aFileDeletedBeforeTheUploadIsNotAFailure`,
`aFixedFileCompactionRemovedIsChangedAndNotAFailure`,
`aFixedFileRelinkedWithTheSameBytesIsStillPublished`,
`anUploadIsSentFromACopyOfTheFile`.

And `keepsTheFileItOpenedWhenThePathIsReplaced`: the path is removed and
rewritten while the file is open, and the digest and the copy are still of
what was opened.

**Two ways a pass could stop for ever**, both found by review of the first
version of this and both held by a test with a time limit:

- **A named pipe with nobody writing to it.** An ordinary `open` of one waits
  until somebody writes, which for a pass that expected a file is for ever.
  The flags carry `O_NONBLOCK` for that reason alone; on a regular file it
  changes nothing. Removing it does not fail
  `doesNotWaitOnAPipeNobodyIsWriting` — the test never finishes, which is the
  point.
- **A character device.** `/dev/zero` never reaches the end of itself, so a
  read loop over it runs until the disk fills. Nothing but an ordinary file
  is read, and that is asked of the descriptor *before* anything else, so
  what comes back names the thing that is wrong rather than whichever
  syscall refused first — a pipe cannot be seeked, so the seek was answering
  first and saying `ESPIPE`.

Neither was reachable before: the path-based check rejected both without
opening them, and Foundation's read refused a device. They are the price of
holding the file, and they are paid once each.

## What is still open

**A directory on the way to a candidate, replaced between two callers' opens
— the gather's and the upload's.** One open closes the windows *within* each;
it does not make the gather and the upload the same open, and nothing
reasonably can.

The mechanism that would close it is `openat(rootDescriptor, relativePath,
O_NOFOLLOW_ANY)`: a descriptor held on the library root, each candidate opened
relative to it, and every component refused if it is a link. `O_NOFOLLOW`
guards the **last** component only, which is why this record does not claim
more than it does. `O_NOFOLLOW_ANY` on an absolute path is no use either —
`/var` and `/tmp` are themselves symlinks, and the scratch directory lives
under `/var/folders`.

It is not built because **the refusal has nowhere safe to go**, which is the
same wall `0010` hit. A candidate refused at the gather leaves the plan's
locals, reads as "not held", and the install writes the server's bytes through
the very link that was refused — worse than publishing. `heldWithoutAFile`
only helps a path that already has a recorded revision; a path never uploaded
falls through it. Making a refusal safe needs a "held but not publishable"
state the plan carries, in core and in both apps. That is a larger change than
this race deserves, and it should be taken on for its own reasons rather than
for this one.

**What the race actually requires** is worth stating, because it bounds how
much any of this matters: a process running as the same user, writing inside
the user's own library, during a pass, replacing a directory with a symbolic
link. The Mac app is not sandboxed and agents writing in a workspace are a
supported workflow, so such a process is ordinary — but no ordinary one
replaces a directory with a link mid-pass, and a hostile one already has user
execution and the files. Publishing through the user's own sync server is the
long way round. The value in this decision is the correctness of the sentence
the model leans on, the SIGBUS, and that the findings stop coming; it is not
security.

## Rejected

- **A descriptor through `LampSyncRemoteStore`.** It cannot reach the network
  layer even in principle: the WebDAV path is `URLSession.upload(for:fromFile:)`,
  and the file is read by `nsurlsessiond`, another process. Four wrappers
  forward `write(fileAt:)` and would all change for nothing. Descriptors for
  the source, a path for the copy.
- **Claiming the scratch copy is private.** It is a randomly named file in
  the user's temporary directory. 0600 and 0700 keep out other users, of whom
  there are none in this threat; they do not keep out another process of this
  user. `0010` already retracts the claim that it does.
- **`O_NOFOLLOW_ANY` on the absolute path.** `/var` is a symlink, so it fails
  on every library and every scratch file. Only `openat` relative to a root
  descriptor works.
- **`~Copyable` with a `deinit` that closes.** The right shape for a
  descriptor that must outlive a scope, and neither caller has one. It also
  stops `#expect` seeing the value, which is a poor trade for nothing gained.
- **A fixed 256 KB read buffer.** The first version allocated and zeroed one
  per candidate, which at fourteen thousand candidates — most a few kilobytes
  — made digesting four times slower than mapping had been. The buffer is
  allocated uninitialised and never larger than the file. (That measurement
  was first taken at a load average of 13, which is nobody's measurement; the
  figures in this record were taken after waiting for the machine.)
- **One classification for the source and the copy.** A scratch copy that
  disappears before it is hashed reports `ENOENT` exactly as a missing source
  does, and reporting that as a file that changed in the library would be a
  lie about the library. The two opens are two steps with two answers.
- **A public `LampSyncOpenFile`.** `with(url) { $0 }` hands back a value
  whose descriptor is closed, and whose number the system may hand to another
  file — so it would then answer about that one. The two callers are in this
  module, so the type is internal and the hatch is not there to find.
