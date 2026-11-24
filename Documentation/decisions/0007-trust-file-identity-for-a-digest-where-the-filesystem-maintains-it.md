# 0007. A pass may trust file identity for a digest, where the filesystem maintains one

Status: Accepted for core and the Mac, 2026-11-24, held by
`LampSyncDigestCacheTests`. Supersedes `0001`, whose Decision no longer follows
from its Context — see below. The phone still hashes its media and book
pictures on every pass; that is Phase 3 of the plan.

## Context

`0001` decided that a sync pass hashes every candidate file on every pass, and
rejected a cache keyed on the file's metadata. Both of its reasons have moved.

**The key it rejected was weaker than the one available.** 0001 argued from a
modification date: a file replaced at the same size with its date preserved —
`cp -p`, `rsync -t`, a restore — would be skipped for ever. True of a date.
`LampDatabaseFileRevision` captures device, inode, size, modification time
**and change time**, and `st_ctime` on a local Darwin filesystem is the
kernel's own: it is set on any change to the inode and there is no call that
sets it to a chosen value. Every case 0001 names moves it or moves the inode.
`0003` already relies on this for listing decks, with a test that rewrites a
file in place, puts the date back, and watches the listing notice.

**Hashing was cheap compared to something that is no longer there.** 0001
measured hashing against the per-pass compile of the collections: 2.43 GB/s
against 0.9 ms a writing. `0002` cached that compile away, so hashing is now
the largest thing a pass does on a big library — the Mac's own comment says a
second and a half of it — and a pass runs every six to ten seconds while
someone writes. The cost that matters is not the CPU in a detached task; it is
that the whole library goes through the page cache every pass, evicting what
the reader is using, and on the phone it is battery and heat.

**And the trust is not uniform across filesystems.** This is the part that
decides the shape. There is no capability bit for "maintains a change time".
On APFS and HFS+ it is maintained, and inode numbers are not reused (APFS
allocates from a monotonic counter; HFS+ recycles only after 2^32). On
exFAT/FAT there is no change time in the format at all — the driver synthesises
one — and inode numbers come from the directory entry's position, so a
same-name replacement often reuses one: the key silently degrades to
`(size, mtime)`, which is exactly what 0001 refused. On SMB the client maps the
server's `ChangeTime`, which a Windows or Samba-on-ext4 server maintains, a
share backed by exFAT cannot, and some servers simply mirror the write time —
and the client cannot tell which. NFS and SMB also cache attributes for
seconds, so a stat can report the state before another machine's write.

A library can live on any of those. It can live on a NAS.

## Decision

A pass may take a candidate's digest from a cache keyed on
`LampDatabaseFileRevision`, under three conditions, and must hash otherwise:

1. **Only where the filesystem maintains the key.** The library root's
   `statfs(2).f_fstypename` is `apfs` or `hfs`. Anything else — `smbfs`, `nfs`,
   `exfat`, `msdos`, `ntfs`, `webdav`, a FUSE mount — hashes every file every
   pass, exactly as 0001 required. On a NAS this decision changes nothing,
   which is the point: it is correct there by construction rather than by
   argument.
2. **Only for the kinds that are immutable at a path**: a module file, a book
   picture, a deck image, a writing's media, a note's media. Those are the
   bytes, and the codebase already states that immutability where it publishes
   them. Everything else keeps hashing: workspace files are exported fresh into
   scratch every pass and so have new inodes anyway, review marks and the
   compiled collections are small, and decks are mutable.
3. **Only within one process lifetime.** The cache is in memory, so the first
   pass after launch hashes everything. Persisting it would buy almost nothing
   — the first pass already runs off the main thread, and a device number
   changes on every remount of an external volume, so entries would miss after
   a reboot where it would matter most — and it would add state to the one
   subsystem with a model, with a format to version.

What the plan receives is unchanged: `LampSyncFilePlan.Local.digest` is still
SHA-256 of the bytes at that path. `LampSyncFileRecords` keeps digests, not
identities. `Verification/SyncMerge.lean` is untouched.

## Consequences

- A pass over an unchanged library on APFS becomes a stat per file instead of a
  read of every byte. On a 10 GB library that is seconds of I/O and the page
  cache left alone, every six to ten seconds while someone writes.
- The assumption moves from "a digest is always read from the file" to "a
  digest is of the bytes at that path, obtained by reading them or from an
  identity that cannot have changed without the bytes changing". That sentence
  has to be written where the old one is: the boundary prose in
  `Verification/coverage.json` for `LampSyncLocalFile.swift`, and the comment on
  `describe`. `SyncVerificationCoverageTests` checks that a sync source has an
  entry, not that the prose is true, so this is for readers — and it is the one
  place the trust is written down.
- `LampDatabaseFileRevision` has to be reachable from `LampModuleKit`, which
  cannot import `LampCore`. It moves there; `LampCore` imports `LampModuleKit`
  already.
- A file that has vanished or cannot be read is still reported as `Unreadable`
  from a stat, never served from the cache.

## What it must not break

- **A file replaced at the same size with its date preserved is still
  noticed** — by the change time or the inode where the key is trusted, and by
  hashing everywhere else. Tested both ways, including with the filesystem type
  forced to `smbfs` and `exfat` to prove every file is hashed there.
- A replacement with *identical* bytes still yields the same digest and no
  upload.
- Never a modification date alone. Never the server's ETag as a local digest.
  Both rejections carry forward from 0001.

## Rejected

- **Trusting identity on every filesystem.** Correct on APFS, wrong on a USB
  stick and possibly wrong on a NAS, and nothing in the API distinguishes them.
- **Persisting the cache.** See condition 3; and across launches the inode's
  namespace (`st_dev`) is the part that moves.
- **A size threshold instead of a kind list.** A stat costs the same either
  way, and "immutable at a path" is a property the code already states, where
  "large" is a guess.
- **Hashing on a schedule** (daily, or every tenth pass). It makes the window
  in which a device is wrong a tunable rather than zero, which is what 0001 was
  right to refuse.
