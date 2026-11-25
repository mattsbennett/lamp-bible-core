# 0014. A bulk import drops its search index triggers and rebuilds once

Status: Accepted for the phone, 2026-11-24, held by
`testAKindThatTouchesNoIndexedRowsRebuildsNothing`,
`testAnImportLeavesEveryIndexAgreeingWithItsContent` and the two
module-import rollback tests that caught each wrong version. Item 3d of
`../ScalabilityPlan.md`. Designed with Fable, which corrected the version
that nearly shipped.

**Three answers, two of them wrong.** Both wrong ones are below, because each
looked right and was caught only by running the tests.

## Context

Importing a module inserts its rows into a content table whose
external-content FTS5 index is kept by per-row triggers. A full Bible —
31 000 verses — is **918–936 ms** with the triggers attached against about
**380 ms** without them, measured on the phone's own schema. Importing a
Bible is a progress bar somebody waits on.

## Decision

Around the row copy, inside the transaction the import already runs in:

1. Drop **all three** triggers of the indexes this kind of module can leave
   stale.
2. Copy the rows.
3. `INSERT INTO <index>(<index>) VALUES ('rebuild')` for each, and reinstall
   the triggers.

All of it transactional, so a crash rolls back to the old rows, the old index
and the old triggers alike. `ATTACH` and `DETACH` are already outside the
transaction.

## The first wrong answer: drop only the insert trigger

Measured as the better instrument, and it is — indexing only the rows the
index lacks is **26–58 ms whatever is installed**, where `'rebuild'` grows
with the content table (23 ms with nothing installed, 280 ms with six
translations). It corrupts the index:

```
SQLite error 11: database disk image is malformed
- while executing `UPDATE dictionary_entries SET search_text = ? WHERE rowid = ?`
```

Dropping only the insert trigger leaves rows with no entry in the index. The
**update** trigger is still installed, and its first statement is a
`'delete'` command naming the old values — and FTS5's contract for `'delete'`
on an external-content table is that the row and values must be what was
indexed. Telling it to delete what it never had corrupts the index. The
import fills `search_text` after copying, so every dictionary import met it.

**So the triggers are all-or-nothing per index.** That is the part of this
record to remember. There is no supported way to remove an external-content
entry without the old values: the commands are `'delete'`, `'delete-all'` and
`'rebuild'`.

A narrower variant is sound *today* — drop insert and update, keep delete,
then index what `_docsize` lacks — but only while the import body never
updates a row that was already indexed, which any later edit would break
silently. Rebuilding reads the content table as it stands and is right
whatever happened to it.

## The second wrong answer: rebuild everything for an unmapped kind

The rebuild is scoped by module kind, because a dictionary's few thousand
rows should not rebuild every verse. The first scoping defaulted to rebuilding
**all** indexes for any kind not named, reasoning that it was "slow rather
than wrong".

It had it backwards, and Fable caught it: **an index whose triggers were
never dropped is exact** — the triggers kept it so — and the only bad state
is dropped-and-not-rebuilt, which this cannot produce. So a kind that touches
no indexed rows must rebuild **nothing**.

And it was not merely slow. Rebuilding every index during a book or plan
import, while another module's rows were mid-replacement, failed the
module-landing tests with `FOREIGN KEY constraint failed` and imports whose
temporary database "couldn't be removed". For an afternoon that looked like
evidence that the whole item was unshippable; it was evidence of this.

The switch is exhaustive over `LampModuleKind` with no `default`, so a new
kind is a compile error rather than a silent choice either way. Commentary is
deliberately out until measured: its index can run to hundreds of megabytes,
and `SearchIndexRepair` rebuilds it in batches on its own connection
precisely because a long write on the main-thread database freezes the app.
A `'rebuild'` inside the import's transaction is that long write.

## Consequences

- A Bible import's index work drops from about 930 ms to about 380 ms plus a
  rebuild of 23–280 ms depending on what is installed.
- A kind with no indexed rows of its own pays nothing: its triggers stay on
  and keep their indexes exact.
- `TranslationImportTests` asserts an imported translation's verses are **in
  the search index**, asked of that translation's rows rather than through a
  ranked search across the library, where with other Bibles installed
  "shepherd" fills any limit long before reaching a psalter imported a moment
  ago.

## What it must not break

- **An index agrees with its content table after an import.**
  `'integrity-check'` with rank 1, over every external-content index. Its
  absence is what let the first wrong answer through: the rollback tests
  caught that corruption only because the import then threw.
- A module replacement still removes the previous module's rows and their
  entries — the rebuild reads the content table afterwards, so it is right
  however the body got there.
- A failed import still rolls back completely, which is what the two rollback
  tests check, and both fail against either wrong version.

## Rejected

- **`'delete-all'` then reindex.** The cost of `'rebuild'` with no better
  guarantee.
- **Indexing only the additions** as the general answer. Sound only when the
  body neither deletes nor updates, and a replacement does both.
- **Landing any of this on a parallel test run.** Five simulator clones
  contending for one SSD turned a 40-second suite into 570 seconds and a
  different handful of failures each time, which is how the second wrong
  answer survived as long as it did. Serially — `-parallel-testing-enabled
  NO` — the suite is deterministic, and that is the only signal this change
  should ever have been judged on.
