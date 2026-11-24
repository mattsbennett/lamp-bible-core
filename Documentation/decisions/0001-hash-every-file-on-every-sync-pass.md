# 0001. A sync pass hashes every file it publishes, every time

Status: Superseded by `0007`, 2026-11-24, the same day it was written. Both of
its reasons moved within hours: the key it rejects is weaker than the one
available (`st_ctime` is the kernel's, which `0003` then relied on), and the
comparison that made hashing look cheap was against a compile that `0002`
cached away. Left as written — the two rejections at the foot of it still
stand, and 0007 carries them forward.

## Context

A pass asks the library what it holds, and hands the plan a digest per path. The
digest is taken by reading the file, every pass, for every candidate — modules,
media, decks, deck images, review marks, workspace files.

The scalability pass of 2026-11-24 proposed caching those digests against the
file's size, inode and modification date, re-verifying only on a schedule. On
paper it is the obvious win: the hashing is the one part of a pass that is
plainly proportional to the whole library's bytes.

Measured, it is not the expensive part. SHA-256 over a mapped file runs at
2.43 GB/s on an M-series Mac, so a 10 GB library is about four seconds of a
detached task, and a pass only runs when something changed. The compile of the
editable collections — a temp database, `ANALYZE`, `VACUUM`, zlib (see 0002) —
costs more per byte by two orders of magnitude.

## Decision

Keep hashing. Do not key a digest on a modification date.

The one optimisation left open is running `describe` in a task group, which
changes no inputs.

## Consequences

- A pass stays proportional to the library's bytes in its cheapest term, which
  is the term we understand best.
- A file replaced at the same size with its date preserved — a restore from a
  backup, `cp -p`, `rsync -t`, a sync tool outside Lamp — is still noticed and
  still published. An mtime-keyed cache would skip it for ever, and the file
  would silently never reach another device.
- `LampSyncFilePlan.Local.digest` is an input to decisions the Lean model covers
  (`Verification/SyncMerge.lean`). Feeding it a cached value would mean a value
  the model's assumptions no longer describe.
- iOS already avoids the work where it can without weakening anything:
  read-only module files are listed as `heldWithoutAFile` from the hash stored
  at install (`LibrarySyncPass`), because a module file is immutable at its
  path. That is the shape to copy if another kind qualifies.

## Rejected

- **Digest cache keyed on (volume, inode, size, mtime), re-verified daily.**
  Loses a restored file until the schedule comes round, and makes the window
  during which a device is wrong a tunable rather than zero.
- **Trusting the server's ETag as the local digest.** An ETag is the server's
  opinion about what it holds, not a statement about this device's bytes; the
  plan deliberately keeps the two apart.
