# 0014. A bulk import keeps its search index triggers, for now

Status: Accepted as a **rejection**, 2026-11-24. Item 3d of
`../ScalabilityPlan.md` is measured and designed and does **not** land. Two
of this record's three answers were wrong, both caught by running the tests
rather than by reading. Reviewed by Fable, which corrected the third.

## Context

Importing a module inserts its rows into a content table whose external-content
FTS5 index is kept by per-row triggers. For a full Bible — 31 000 verses — that
is 918–936 ms with the triggers attached against about 380 ms without them,
measured on the phone's own schema. Importing a Bible is a progress bar
somebody waits on, so the item was worth doing.

## What was tried, in order, and what each got wrong

**One: drop the insert trigger, then index the rows the index does not have.**
Measured as the best instrument — 26–58 ms whatever is installed, where
`'rebuild'` grows with the content table (23 ms with nothing installed, 280 ms
with six translations). It corrupts the index:

```
SQLite error 11: database disk image is malformed
- while executing `UPDATE dictionary_entries SET search_text = ? WHERE rowid = ?`
```

Dropping only the *insert* trigger leaves rows in the content table with no
entry in the index. The **update** trigger is still installed, and its first
statement is a `'delete'` command naming the old values — and FTS5's contract
for `'delete'` on an external-content table is that the row and values must be
what was indexed. Telling it to delete what it never had corrupts the index.
The import fills `search_text` after copying (`DictionarySearchText.fill`, and
the same for a commentary's footnotes), so every dictionary import met this.

There is no supported way to remove an external-content entry without the old
values: the commands are `'delete'`, `'delete-all'` and `'rebuild'`.

**Two: drop all three triggers, then `'rebuild'`.** Correct against that
corruption, and right whatever the import did to the content table — which
matters because a replacement deletes the previous module's rows in the same
transaction. It still breaks the two module-import rollback tests
(`testFailedSQLiteCopyRollsBackInstalledModule`,
`testFailedSQLiteMetadataSaveRollsBackCopiedRows`), and a serial run on a
quiet machine showed more: `FOREIGN KEY constraint failed` inserting into
`dictionary_entries` and `book_modules`, and several imports failing with a
temporary database that "couldn't be removed". **That interaction is not
explained.** What is established is narrow and reproducible: with the wrapper
present those tests fail, with it absent they pass, confirmed by removing it
and checking the symbol is gone rather than trusting a revert.

**Three: scoping the rebuild by module kind.** The first version rebuilt
every index for an unmapped kind, on the reasoning that it was "slow rather
than wrong". That had it backwards, and Fable caught it: an index whose
triggers were never dropped is **exact** — the triggers kept it so — and the
only bad state is dropped-and-not-rebuilt, which the wrapper cannot produce.
So a kind that touches no indexed rows must rebuild **nothing**. The version
that nearly shipped would have had a reading-plan import rebuild every verse
in the library for no reason.

## Decision

The import keeps its triggers. Nothing in the import path changes.

## Consequences

- A Bible import stays at about 930 ms of per-row index writes. Measured, and
  the fix for it is designed and unshipped.
- The corruption mechanism is written down, which is the part worth keeping:
  **an external-content FTS5 index must never be told to delete what it does
  not have**, so its triggers are all-or-nothing per index. Anyone reaching
  for "drop the insert trigger and batch the rest" will find this first.
- `TranslationImportTests` keeps the assertion the attempt earned: an
  imported translation's verses are **in the search index**, asked of the
  index for that translation rather than through a ranked search across the
  library, where with other Bibles installed "shepherd" fills any limit long
  before reaching a psalter imported a moment ago. Nothing asserted that
  before.
- `ImportIndexMeasurementTests` keeps the measurement and an
  `'integrity-check'` over every external-content index, which is the
  assertion whose absence let the corruption through: the rollback tests
  caught it only because the import then threw.

## What would finish it

1. Explain the interaction between dropping these triggers and the import's
   temporary database. The repro is one command and two tests.
2. Then land variant two, scoped per kind with an exhaustive switch and no
   `default`, commentary deliberately excluded until measured — its index can
   run to hundreds of megabytes, and `SearchIndexRepair` rebuilds it in
   batches on its own connection precisely because a long write on the
   main-thread database freezes the app. A `'rebuild'` inside the import's
   transaction is that long write.
3. Add the exactness tests for a dictionary replacement and a translation
   replacement, which this record's attempts did not have.

## Rejected

- **Landing it on the signal available.** Variant one passed every test I
  expected to be implicated and was caught by a rollback test nobody had on
  the list; variant two passes the import tests in isolation and fails them
  in a suite. A corrupt FTS index on somebody's phone costs them a repair
  cycle, which is not worth a progress bar.
- **`'delete-all'` then reindex.** Same cost as `'rebuild'` and no better
  guarantee.
- **Keeping the delete trigger and dropping insert and update.** Sound only
  while the import body never updates a row that was already indexed, which
  is true today and which any later edit to the body would break silently.
