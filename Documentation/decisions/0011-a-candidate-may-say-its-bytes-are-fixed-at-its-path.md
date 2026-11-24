# 0011. A candidate may say nothing rewrites it where it sits

Status: Accepted for core and the Mac, 2026-11-24, held by
`LampSyncDigestCacheTests` and
`aPathWhoseDirectoryBecameALinkIsNotPublished`. Designed by Fable after a
Codex review found the measurement that had closed this question was
measuring the wrong thing. The phone gathers without `describe` and writes a
copy of everything it publishes, so it never makes the claim and nothing
changes for it.

## Context

`0007` lets a pass keep a digest against a file's identity under three
conditions: the filesystem maintains one, the process has not ended, and
**the kind is one whose bytes are worth it**
(`LampSyncFileKind.keepsDigestAgainstIdentity`). Workspace files were
excluded, for a reason that was true then: they were copied into a fresh
scratch directory on every pass, so a cached entry could never be hit.

`0008` stopped copying most of them. `0008` also recorded that extending the
cache to them would be worth about 150 ms and was not worth a kind — and
that figure was wrong. The benchmark ran `describe` twice over those
candidates and timed the second run, but `describe` consults the cache only
for kinds where this is true, so what it measured was a warm page-cache
re-read. Caught by a Codex review of the measurement, not of the code.

Measured through the real path, at 250 workspaces of five documents and
fifty revisions: digesting all 14 000 candidates is **714–788 ms**, and
**328–341 ms** on the pass after, both timed on a repeat gather so each has
had the same warm-up, against a gather of 1.1 s. Some **400 ms**,
a fifth of what a local pass spends, every six to ten seconds while somebody
writes — and it grows with document size while the stat cost does not.

That figure took three goes to measure honestly, and every correction made it
smaller. The first timed `describe` twice over kinds it skips the cache for,
so it measured a warm page-cache re-read: 150 ms. Correcting that by
relabelling every candidate under a cacheable kind gave 555 ms, but it
credited the cache for the ~1 250 staged files, which get a new scratch path
every pass and can never be answered. Gathering afresh for the timed run, as
a real second pass does, gives the 400 ms above. Each of the three was found
by a Codex review of the measurement rather than of the code.

The obstacle is that `.workspaceFile` is one kind over two sorts of file. A
revision is only ever replaced — written once under a timestamped name,
deleted by compaction, never rewritten where it sits. A document is staged
into a scratch directory named `lamp-sync-<UUID>` per pass, so it has a new
path and a new inode every time; caching it would never hit and would leave
a dead entry behind on every pass. The kind cannot tell them apart. The
exporter chooses between them per file.

## Decision

`LampSyncLocalFiles.Candidate` gains `isFixedAtItsPath`, false by default,
and the app sets it per file. `describe` consults the cache when
`kind.keepsDigestAgainstIdentity || candidate.isFixedAtItsPath`, with
`0007`'s filesystem and process-lifetime conditions unchanged.

The claim is narrower than it sounds, and the name is chosen to say so. It is
**not** "these bytes will not change" — compaction deletes a revision and
writes a replacement, which is the whole of `0009`. It is "they will not
change *under a reader*": what changes at this path arrives as a different
file, or as nothing.

That makes a second thing possible, and it closes half of a gap `0010` had
to leave open. `LampSyncLocalFile` carries the claim, and a pass **refuses to
publish a file that claimed to be fixed and whose copy does not hash to what
the gather hashed**. This catches what a check of the leaf cannot:
`copyItem` resolves the directories on the way to a file, so replacing a
workspace's `context` directory with a symbolic link after the export yields
an ordinary copy holding bytes from outside the library — other bytes, and so
another digest.

Three details of that check, each of them a review finding:

- **The bytes, not the file's identity.** Comparing device and inode was the
  first version, and it refused good uploads: a context file is a hard link
  into a shared store, and consolidating that store links the object over the
  path and sets permissions on the inode, so the inode moves and `st_ctime`
  with it while the file is byte-for-byte what it was — on an ordinary pass,
  caused by the pass's own import. The *cache* still keys on the whole
  identity; that is where `st_ctime` earns its place.
- **After the copy, not before.** The copy is what resolved the path, so no
  amount of swapping a path about during the copy gets other bytes published
  under a digest that was not theirs.
- **Only where the bytes came from the gather.** `reconcile` may replace a
  file atomically and hand back the same URL, which is within what a fixed
  candidate promises, so the URL cannot stand for "the gathered file".
- **Only while the file is still there.** A file that has gone never reaches
  the comparison: the copy fails first, and that is reported as changed
  rather than failed, because compaction removing a revision mid-pass is no
  error. The first version read a failed `stat` as "a different file" and
  turned ordinary compaction into an error the writer would see.

For anything that made no claim, a change between the plan and the upload is
ordinary, and `0009` says to publish what is held now.

**What this does not close.** If the directories on the way to a candidate
are replaced *before* `describe` hashes it, the gathered digest is the
outside file's digest as well, the two agree, and the bytes are published.
The comparison catches a substitution after the gather, not one before it.
Resolving the path once and reading the bytes and the identity through the
same open file is `0012`, which three review rounds asked for in three
different places. It closes the windows inside the gather and inside the
upload; the one between them stays, and `0012` says why it is not safe to
close yet.

On the Mac the exporter's record carries it: a file left where it lives is
recorded with the claim, and everything staged into the scratch directory is
recorded without it — including the two files the export writes there itself,
a transcript and the portable ledger.

## Consequences

- Digesting falls from about 720 ms to about 335 ms at 250 workspaces.
  12 750 of the 14 000 candidates carry the claim; the rest are documents,
  skills, the selection, transcripts and ledgers, which are read as before
  and are most of what the 335 ms is.
- The trust widens in *who may nominate a file*, not in *what a digest
  means*. `LampSyncFilePlan.Local.digest` is still SHA-256 of the bytes at
  that path, which is what the model assumes, so `SyncMerge.lean` is
  untouched — as it was for `0007`.
- If an app ever makes the claim wrongly, for a file rewritten in place, the
  identity still catches the rewrite on a filesystem `0007` trusts: `st_ctime`
  moves. What is lost is a margin, not the invariant. Held by
  `aFixedFileRewrittenInPlaceIsStillNoticed`.
- The cache has no eviction, so an entry for a revision compaction has since
  deleted stays for the life of the process. About 300 bytes each, bounded by
  the revisions a session sees; a few megabytes at 250 workspaces.
- **A cache is scoped to the volume its maker checked.** `0007`'s first
  condition is a property of a filesystem, decided by asking what the library
  root sits on — and a library can have another volume mounted inside it. Its
  files were never cached before, so the coarseness did not matter; making a
  workspace file eligible is what exposed it. `LampSyncDigestCache` now takes
  the trusted `st_dev` and reads anything from another device instead of
  answering for it.
- A digest is remembered only under an identity the file still has, and only
  where the cache would keep it at all. The stat and the read are two opens,
  so a path whose directories changed in between would otherwise have its
  replacement's digest saved under the original's identity — and restoring
  the original would be answered wrongly for the rest of the process. `0012`
  closed that properly: the identity and the bytes now come from one
  descriptor, so there is no second resolution to disagree.
- `Verification/coverage.json`'s boundary prose for `LampSyncLocalFile.swift`
  has to name the new condition, since that sentence is where this trust is
  written down.

## What it must not break

- **A file rewritten in place with its date put back is still noticed**, claim
  or no claim. That is `0001`'s case and it is still the point of the key.
- **A staged file is still read every pass.** It has a new path every pass, so
  a cache would only grow; held by the second half of
  `aFileTheAppSaysIsFixedAtItsPathIsKept`.
- A file that has gone by the time the pass publishes is still
  `changedDuringPass` and not a failure, claim or no claim. Held by
  `aFixedFileCompactionRemovedIsChangedAndNotAFailure`.
- **A context file relinked to the shared object, with the same bytes, is
  still published.** Held by
  `aFixedFileRelinkedWithTheSameBytesIsStillPublished`, which fails if the
  comparison is of the file rather than of its bytes.
- A file on a volume mounted inside a trusted library is still read every
  pass: `aCacheDoesNotAnswerForAFileOnAnotherVolume`.
- The phone is unchanged: it never sets the flag.

## Rejected

- **Splitting `.workspaceFile` into two kinds.** Not blocked by the model —
  both halves stay unlisted — but it would make `LampSyncFolderLayout.kind(of:)`
  recognise `Revisions/` and `Context/`, which is core encoding the
  exporter's folder layout: the duplication `0008` refused. It ripples
  through `isTakenInTogether`, `isListed`, `isMedia`, the Mac's install and a
  conformance table, and it freezes as a kind what is a per-file choice the
  exporter has already changed once, when skills and the selection moved from
  recorded to staged.
- **A set of paths handed to `describe` beside the candidates.** A second
  structure that must agree with the first, keyed by the same strings, saying
  nothing the candidate cannot.
- **Caching every kind the cache is passed.** The staged files would leave a
  dead entry per file per pass, and `0007`'s reason for keeping decks and
  review marks out — "nothing to save and a trust to avoid" — would go with
  it.
- **Naming it `bytesAreFixedAtThisPath`.** A revision's bytes are not fixed
  at its path for the length of a pass; the file is. Fable's objection, and
  it is the distinction the whole record turns on.
- **Leaving it alone.** Measured honestly it is about 400 ms, a fifth of
  a local pass, and the files it covers are the ones that grow.
