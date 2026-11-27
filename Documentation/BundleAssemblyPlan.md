# Core assembles the bundled module library — plan

Status: **Proposed, 2026-11-27.** Planned by Fable; its load-bearing claims
checked against the code (see "Verified"). The owner's direction: core owns
bundle assembly, after the rich-modules steps 3–6
(`RichModulesPlan.md`, Revision 1); bundled module IDs are kept. Nothing here
is in the code. A decision record takes the next free number when item 0a is
written.

## Why

Everything the apps read should have one writer. The bundle is the largest
second one: `lamp-bible-modules/scripts/bundle_all.py` fills one shared
database in the apps' library layout (a `modules` registry plus `module_id`
columns) through Python importers per kind, each with its own row-building and
text walks. The commentary series compile showed what that costs: held row by
row to the Python, the port had fallen behind core in IDs, fields and search
text (`CommentarySeriesCompiler.swift`'s header; `RichModulesPlan.md` step 2).

## Shape: land compiled modules

Each module is compiled by the compiler that builds its standalone `.lamp`,
and one declared landing in core copies its rows into the library layout
(`ATTACH`, `INSERT … SELECT`).

- **Why not write the layout directly:** six compilers would each gain a
  second schema and insert path — in the files steps 3–6 are rewriting — and
  the second layout would be pinned by nothing. It moves the drift into Swift
  rather than removing it.
- **Why landing fits:** plan, quiz and book standalone tables already are the
  bundle's tables; only translations and dictionaries need real column
  mapping. Content with no module kind (`books`, `genres`, `book_genres`,
  `lexicons`, `lexicon_mappings`, the `modules` rows) gets small dedicated
  writers.
- **Commentaries land per volume, not from a series file.** A volume compiled
  under module ID `crossrefs` already gives the bundle's book rows
  (`crossrefs:13`) and unit prefix; a series file would also rename
  `commentary_series.id`, which the bundle keeps (`XRef`, `TSKe`).
- **The landing is declared apart from `LampModuleCompiledSchema.tables(for:)`.**
  The phone's `CompiledModuleLandingTests` walks that function, and anything
  added to it fails there.

## Parity

Reference: `bundle_all.py` on the same inputs, the same day, with the same
core binary for `search-words`; comparison builds pass
`--include-pending-rights`, since the release bundle holds no book modules;
small fixtures cover shapes the real inputs lack (footnotes, parent units,
source-tracked commentary); identity lists are also checked against the
bundles that shipped (D4).

Compared, in order:

1. **Schema** — normalised `sqlite_master` and `table_info` (36 indexes and 3
   triggers in the reference).
2. **Identity** — every value an app may store: `translations.id`;
   `lexicons.id/key_type/language`; `modules.id/type/name/series_id/
   series_abbrev/file_path`; `commentary_series.id/name`; `plans.id`;
   `quiz_modules.id/plan_id`; `book_modules.id`; `book_genres.id`;
   `books.id/osis_id`.
3. **Rows** — by natural key, never rowid; `*_json` compared parsed; each
   difference classed as JSON form, whitespace or value.
4. **Order** — keys in rowid order, which readers depend on.
5. **Search** — per-row token streams through `fts5vocab … 'instance'`,
   `integrity-check`, and `search_words`/`search_word_lists`.
6. **Artifact** — raw DEFLATE both apps open, `quick_check`, size.

Every difference gets a ledger entry (`BUNDLE_PARITY.json` in the modules
repository): table, column, class, decision (core, bundle, input or
invisible), reason, readers by file:line. A run fails on an undecided
difference and on an entry that matches nothing.

Differences expected from reading both writers: core's unit IDs (`:<sv>` on
verse units; `chapter_intro` for tske's chapter introductions); quiz row
order (core sorts age groups; every read has an `ORDER BY`); JSON byte form;
dictionary `search_text`, `metadata_json`, integer entry IDs and a hard-coded
`modules.version`; Python's `--` to em dash in translations (YLT: 5,456
verses); `lexicon_mappings` in JSON object order, which a sort reproduces.

## Order of work

**Now (touches no core source, so cannot collide with steps 3–6):**

- **Item 0, modules repository.** `scripts/bundle_compare.py` with the six
  comparisons and the ledger; `tests/test_bundle_compare.py` (one fixture
  bundle built twice is clean; a mutated cell, dropped row, swapped rows,
  renamed index and reordered JSON keys are each reported in their class).
  Run it on two fresh real builds first, to learn whether the Python
  reference is itself deterministic. Plus `audit_bundle_rights(archive)`:
  every module the built database holds must have a releasable rights record
  — restricted always fails, pending unless asked for — keyed for
  commentaries by `modules.series_id`; called at the end of
  `bundle_all.main()`.
- **Item 0a, core.** This document, and a `Proposed` decision record.

**After rich-modules steps 3–6:**

1. Layout DDL, the landing, and `lamp-module land <library.db> <source>`,
   proven on plans (3 modules, 1,098 rows, a compiler rich-modules does not
   touch), with `books`, `genres` and `book_genres`.
2. Quizzes (27,375 rows).
3. Dictionaries, `lexicons`, the mapping and the registry rows.
4. Translations (294,825 verses), after the translation track's columns.
5. Commentaries, after rich step 4.
6. Books, after rich steps 3 and 5 (only pending-rights builds hold any).
7. The flip: finalisation (search words, `ANALYZE`, `VACUUM`, check,
   compress) moves into `lamp-module bundle`; the record goes to `Accepted`.

Each item switches one kind in `bundle_all.py` to `lamp-module land`, builds
both ways, and must be clean against the ledger; a mixed bundle is shippable
at every step.

**Working rules.** `core_module_builder.py` runs `swift build -c release` on
the shared core checkout with no lock, from whatever its tree holds: parity
and release builds run under `~/.claude/bin/buildlock`, from a worktree at a
named commit, which is recorded. The modules checkout is shared: stage by
path. The Lean model and `coverage.json` do not model the module bundle
("bundle" there is sync's settings bundle); no Lean change is needed if new
core files avoid the coverage patterns `LampSync*`, `LampShared*` and
`LampPersonal*`, and the phone's covered import in `ModuleSyncManager.swift`
is left alone.

## The Python importers

Deleted kind by kind, in the commit after that kind's parity run is recorded.
`bundle_all.py` stays as the thin caller (rights gate, inputs, audit, review
status). `commentary_units.py` and `commentary_series_to_sqlite.py` go with
the commentary item — after rich step 4 they cannot read a 2.3 commentary,
so kept they would be a wrong reference — with the tests and
`build_nic_modules.py` that import them moved first. `writer_agreement.py`
retires at the flip. The comparator stays, as the release-to-release diff.

## Where the apps read the bundle

**Phone** — reads the bundle in place and never imports it
(`Lamp Bible/Data/BundledModuleDatabase.swift`): open and marker (`:34-135`),
translations (`:166-493`, `:1467-2197`), dictionaries and registry
(`:499-622`), books (`:627-683`), commentary by series ID and name
(`:688-1020`), mappings (`:1025-1072`), lexicons (`:1093-1115`,
`:2204-2221`), plans and quizzes (`:1120-1295`), Bible books and genres
(`:1304-1379`); raw reads in `ModuleSearch.swift`, `SearchView.swift`,
`ModuleInfoSheet.swift`, `StrongsIndex.swift`. It stores its default
commentary **by series name** (`UserModels.swift:48`), so
`commentary_series.name` is as load-bearing as an ID.

**Mac** — reads only through core: `LampLibrary.swift` (extract and marker
`:5248-5342`, module list `:5344-5421`, the bundle fallback `:5055-5067`, and
each kind's reads), `LampModuleSearch.swift`, `LampModuleRecord.swift`,
`LampBookGenre.swift`. It stores its default commentary by module ID
(`LampBibleMacApp.swift:393`).

Unit IDs are read only within a session (a search hit's lookup, a rendering
cache), never stored. Both Xcode projects copy the same bundle file; the Mac
stamps its hash.

## Owner decisions

Decided 2026-11-27:

- **D1.** Bundled commentary unit IDs take **core's form** for the 61,108
  rows, as the series decision went; the landing does not rewrite them. Book
  and module IDs do not change.
- **D2.** Typed dashes stay **a JSON pre-step in the thin caller**, as
  `translation_to_sqlite.py` already has; not in core's compiler, where it
  would change every import.
- **D6.** `books` and `genres` **stay JSON inputs**.

Open:

- **D3.** Whether plans, quizzes and dictionaries may land before steps 3–6
  finish; their compilers are untouched by that work.
- **D4.** Which bundle hashes are in the released Mac and phone builds, and
  where the last Python-built reference is kept (`modules_db/**` is
  gitignored).
- **D5.** Archive size: Apple's zlib compresses less tightly than Python's
  level 9. Measure, then accept or add a level-9 path.

No app migration is needed under any of these.

## Verified

Checked in the code before this was written:

- The phone reads the bundle through `BundledModuleDatabase.swift` and stores
  its default commentary as `defaultCommentarySeries`, a series name
  (`UserModels.swift:48`).
- The phone's `testEveryColumnACompiledModuleHoldsHasSomewhereToGo` walks
  `LampModuleCompiledSchema.tables(for:)` (`Lamp_BibleTests.swift:2756`).
- `bundle_all.py`'s rights gate admits everything when no rights records are
  loaded, and never a restricted module (`:143-171`).
- The bundle on disk: `modules` rows only for commentaries (2), dictionaries
  (5) and the lexicon mapping (1); `book_modules` empty; commentary series
  `TSKe` and `XRef`.
- A volume's book rows are `<module>:<book>` (`CommentaryModuleCompiler.swift`).
