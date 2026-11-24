# 0006. The open-database cache is bounded

Status: Accepted, 2026-11-24, held by `LampOpenDatabaseBoundTests`. The limit
is measured now and it is the bad case: **256**. A throwaway background app
bundle, launched with `open` so that launchd gave it its environment, reported
`soft=256 hard=unlimited`.

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

On this Mac `launchctl limit maxfiles` is **256 soft**, unlimited hard, and a
GUI-launched process really does inherit it: a probe app bundle launched with
`open` reported `soft=256`, against 1 048 576 for a terminal shell. Neither app
raised it — `setrlimit` appeared nowhere in either repo — so the earlier test
run was fine only because it ran under the shell's limit.

If that is really the limit the shipped app runs under, then somewhere around two
hundred-odd modules the app stops being able to open anything at all — not just
a module, but a file, a socket, a WebDAV connection — and the failure will look
like a library that has gone bad rather than like a limit.

## Decision

Bound the cache: keep the most recently used connections up to a limit well
under the descriptor budget — of the order of 32 — and close the rest.

Nothing else is evicted with a connection — see the consequences; the first
draft of this record said the module's versification and Strong's fingerprint
had to go with it, and that was wrong.

Nothing is pinned either. The draft proposed pinning the bundled database and
the translation being read; with a bound of forty-eight and least-recently-used
eviction, the translation a reader is reading is the last thing that would be
evicted, and a pin is a rule to maintain for no gain. If a fan-out across one
kind ever makes this matter, pin then, with the measurement in hand.

Both halves are in. The cache keeps the forty-eight most recently used
connections; the Mac app raises its own soft limit to 8 192 at launch, which
the unlimited hard limit allows and which covers everything else a reader opens
— pictures, workspace files, sockets. The bound is the half that does not
depend on the limit staying raised, which is why both are here rather than
either alone.

## Consequences

- A library of any size holds a bounded number of handles, and the cost of a
  cache miss is one open — which is what the cache was there to avoid, so the
  limit wants to be comfortably above how many modules one screen reads from
  (a chapter with notes and highlights from several modules, a search across a
  kind).
- A search that fans out across more modules than the bound will thrash it. That
  is acceptable: a fan-out already reads every module once, and the alternative
  is failing to open the next one.
- Eviction drops the reference and nothing else: a reader already inside
  `queue.read` holds its own, and the file closes when the last holder lets go.
- What is **not** evicted with a connection is that module's versification or
  its Strong's fingerprint. Those describe the file's contents, which have not
  changed — evicting for space is not the same event as the file moving, and
  re-deriving them is the cost the cache exists to avoid. They are still
  dropped where they should be: when the file's revision moves.
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
