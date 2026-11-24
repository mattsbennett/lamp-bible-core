# 0005. What a module is survives a launch

Status: Proposed.

## Context

`LampLibrary.installedDatabases()` lists the databases folder and, for each file,
either takes the module's metadata from an in-memory cache keyed by the file's
revision and the `.lamp` byte count, or opens the database and inspects it. The
cache lives for the process, so every launch inspects every module file again.

The Mac then compounds it: `refreshLibrary` asks for `installedModules()`, then
`translationBooks` for **every** installed translation — opening each
translation's database — then every devotional and every quiz module, as
sequential awaits on one actor, before the library has been read. Opening a
connection is not free: the comment on `openReadOnlyDatabase` records roughly
200 ms for a database of a few hundred megabytes, because it maps the file, reads
the header and parses the schema.

So launch is proportional to the number of modules installed, and the constant is
a database open.

## Decision

Persist the inspected metadata to `Indexes/InstalledModules.json`, keyed by
`LampDatabaseFileRevision` and the `.lamp` byte count — the same key the
in-memory cache already uses. A cold launch inspects only files that are new or
whose key moved.

Separately, the Mac reads book names for the translation it is opening and leaves
the rest until something asks.

## Consequences

- A changed revision must always re-inspect. The index is a cache of an answer
  about a file, never a record of what the library contains: the files are that
  record, and a module whose file is gone is gone (see the comment on
  `installedDatabases` about five old copies of NIC).
- The index must be safe to delete. Anything that treats its absence as "no
  modules" is a bug; the fallback is the work we do today.
- It must be safe for two processes to hold the library — the app and each
  `lamp-mcp` do — so write it atomically and treat an unreadable or stale index
  as absent rather than repairing it in place.
- Deferring `translationBooks` means the reader's own translation is read first
  and the rest arrive later. Anything that asks "what books does translation X
  have?" during launch has to tolerate not knowing yet; check what reads
  `model.translationBookNames` before moving it.

## Rejected

- **A single index of every module's metadata written at install time.** It would
  go stale the moment a module file arrived by sync rather than through install,
  which is exactly how modules arrive on a second device.
- **Keeping connections open across launches** — not a thing — or raising the
  connection cache's limit, which 0001's sibling problem (hundreds of open
  handles at several hundred modules) argues against rather than for. A bound on
  that cache is a separate decision, once measured.
