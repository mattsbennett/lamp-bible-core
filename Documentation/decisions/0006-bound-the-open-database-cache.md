# 0006. The open-database cache is bounded

Status: Accepted, 2026-11-24, held by `LampOpenDatabaseBoundTests`. The limit
the apps run under is now measured, and it was the low number: see the
Context.

## Context

`LampLibrary.openReadOnlyDatabase` keeps a connection per module database for
the life of the process, so that a library answering many small queries does
not pay the open each time — measured in its own comment at roughly 200 ms
for a database of a few hundred megabytes. Nothing evicted a connection;
`forgetOpenDatabases` drops them all at once, and only on module install,
module removal and bundle extraction.

Phase 0 measured what that costs in descriptors rather than in milliseconds:
200 installed book modules, each opened once, left **+201 open file
descriptors** (`LampScaleMeasurementTests.measuresModuleListingAndOpening`).
One per module, and a module whose word lists are attached will take two.

On this Mac `launchctl limit maxfiles` is 256 soft, unlimited hard, and a
process launched by launchd — the app from the Finder, not from a terminal —
inherits that soft limit. The test run itself was fine only because a
terminal shell had already raised its own limit to 1 048 576.

**That was the open question of the first version of this record, and the
answer is that the limit is real.** A throwaway `Probe.app`, launched the way
the Finder launches an app, read `RLIMIT_NOFILE` and reported **soft 256**.
So somewhere around two hundred-odd modules the app would stop being able to
open anything at all — not just a module, but a file, a socket, a WebDAV
connection — and the failure would look like a library that had gone bad
rather than like a limit.

## Decision

Bound the cache: keep the most recently used connections, **forty-eight** of
them, and drop the rest. Forty-eight is comfortably above how many modules
one screen reads from and comfortably below the budget.

Everything derived from a dropped file goes with it: that module's entry in
`versifications` and in `strongsFingerprints`.

The Mac also raises its own soft limit to 8 192 at launch
(`LampBibleMacApp.raiseTheOpenFileLimit`), which is the second half of the
decision and not a substitute for the first: a reader opens pictures,
workspace files and network connections too. The hard limit is unlimited for
this process, so raising the soft one asks nobody's permission, and a failure
is ignored because the bound cache is what keeps the app working either way.

## Consequences

- A library of any size holds a bounded number of handles, and the cost of a
  miss is one open — which is what the cache was there to avoid, so the
  limit matters: a chapter with notes and highlights from several modules, or
  a search across a kind, must fit inside it.
- A search that fans out across more modules than the bound will thrash it.
  Acceptable: a fan-out already reads every module once, and the alternative
  is failing to open the next one.
- Eviction drops the reference and lets the last reader release the file;
  GRDB's `DatabaseQueue` serialises its own access, so nothing is closed
  under a call mid-read.
- `forgetOpenDatabases` stays as it is. It is correctness — a file replaced
  underneath a handle — not a cache policy.

## What it must not break

- **A module replaced while its connection is not cached is still noticed.**
  The first version of this evicted the connection and *kept* the
  versification and the Strong's fingerprint, on the reasoning that evicting
  for space is not the same event as the file changing. That was wrong, and a
  Codex review showed why: the invalidation of those caches is exactly the
  revision comparison that happens when a path is opened again. Evict the
  connection and that comparison has nothing to compare, so a translation
  replaced by another process after an eviction would be reopened fresh with
  its old versification still in hand. They are dropped together now.

## Rejected

- **Raising the limit alone.** It moves the ceiling without bounding
  anything, and a limit raised at launch is one `setrlimit` away from being
  wrong again on a system whose soft limit is lower.
- **Closing connections on a timer.** The cost of an open is proportional to
  the database's size; evicting by age would close the expensive ones as
  readily as the cheap ones.
- **One connection with every module ATTACHed.** SQLite's attach limit is
  small, and it would make every query's name resolution depend on what else
  is installed.
