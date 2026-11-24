# 0006. The open-database cache is bounded

Status: Proposed. The number of descriptors is measured; the limit the apps
actually run under is not, and that is the one thing to confirm before building
this.

## Context

`LampLibrary.openReadOnlyDatabase` keeps a connection per module database for
the life of the process, so that a library answering many small queries does not
pay the open each time — measured in its own comment at roughly 200 ms for a
database of a few hundred megabytes. Nothing evicts a connection;
`forgetOpenDatabases` drops them all at once, and only on module install, module
removal and bundle extraction.

Phase 0 measured what that costs in descriptors rather than in milliseconds: 200
installed book modules, each opened once, left **+201 open file descriptors**
(`LampScaleMeasurementTests.measuresModuleListingAndOpening`). One per module,
and a module whose word lists are attached will take two.

On this Mac `launchctl limit maxfiles` is **256 soft**, unlimited hard. A process
launched by launchd — the app from the Finder, not from a terminal — inherits
that soft limit, and neither app raises it: `setrlimit` appears nowhere in either
repo. The test run itself was fine only because a terminal shell had already
raised its own limit to 1 048 576.

If that is really the limit the shipped app runs under, then somewhere around two
hundred-odd modules the app stops being able to open anything at all — not just
a module, but a file, a socket, a WebDAV connection — and the failure will look
like a library that has gone bad rather than like a limit.

## Decision

Bound the cache: keep the most recently used connections up to a limit well
under the descriptor budget — of the order of 32 — and close the rest.

Two things have to be evicted together with a connection, because they are keyed
alongside it and describe the file it was opened on: that module's entry in
`versifications`, and in `strongsFingerprints`.

Pin the connections that a reader is never long without: the bundled database,
and the translation being read.

**Before building it**, confirm the limit under which the app actually runs
(read `RLIMIT_NOFILE` at launch and log it), because the answer decides whether
this is a ceiling a person can hit or a tidiness exercise. If it is 256, raising
it with `setrlimit` is a legitimate second half of this decision — but a bound
cache is the part that does not depend on a limit staying raised.

## Consequences

- A library of any size holds a bounded number of handles, and the cost of a
  cache miss is one open — which is what the cache was there to avoid, so the
  limit wants to be comfortably above how many modules one screen reads from
  (a chapter with notes and highlights from several modules, a search across a
  kind).
- A search that fans out across more modules than the bound will thrash it. That
  is acceptable: a fan-out already reads every module once, and the alternative
  is failing to open the next one.
- Eviction must not be able to close a connection another call is mid-read on.
  GRDB's `DatabaseQueue` serialises its own access, so eviction has to drop the
  reference and let the last reader release it, not close the file.
- `forgetOpenDatabases` stays as it is. It is correctness — a file replaced
  underneath a handle — and not a cache policy.

## Rejected

- **Raising the limit alone.** It moves the ceiling without bounding anything,
  and a limit raised at launch is one `setrlimit` away from being wrong again on
  a system where the soft limit is lower.
- **Closing connections on a timer.** The cost of an open is proportional to the
  database's size; evicting by age would close the big ones that are expensive
  to reopen as readily as the small ones.
- **One connection with every module ATTACHed.** SQLite's attach limit is small,
  and it would make every query's name resolution depend on what else is
  installed.
