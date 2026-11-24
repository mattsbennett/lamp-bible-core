# Scalability: where Lamp slows down as a library grows

Written 2026-11-24 against core `a844870`, macOS `c35b1c4`, iOS `da513ae`. Line
numbers are from those trees and will drift; the names are the durable part.

This is a plan, not a description of the code. Strike an item when it lands, and
delete the file when the work is done. The decisions behind it keep their own
records, which outlive this file: `decisions/0001`–`0005`.

The question it answers: when someone holds many modules, many writings and many
decks, what gets slow? The short answer is that several surfaces read a whole
corpus and filter it in memory, and a few of them do it **on a timer** or **on
every save**, so the cost arrives while the person is working rather than when
they ask for something.

## What was measured

Synthetic corpora on a quiet M-series Mac, in a **Debug** build. Release is
2–5× faster for Swift-side work and no faster for SQLite, zlib, CryptoKit or
Foundation's JSON, so these are shape rather than release figures. Phase 0 below
replaces them with Release numbers.

| Measured | small | medium | large |
| --- | --- | --- | --- |
| `LampPresentationDeckStore.decks()`, 40-slide decks | 25 decks: 114 ms | 100: 490 ms | 400: 1 750 ms |
| the same files through `decodeUnvalidated` | 8 ms | 32 ms | 109 ms |
| writings filtered with `localizedCaseInsensitiveContains` over title + body | 250 (2.4 MB): 10 ms | 1 000 (9.9 MB): 37 ms | 4 000 (39 MB): 155 ms |
| SHA-256 of a mapped file | | | 2.43 GB/s |

Two things fall out of that table. Validating a deck costs about sixteen times
decoding it, and every listing validates every deck. And hashing is not where
sync time goes.

## The weak points

Ordered by what it costs the person, worst first.

1. **Slide Studio re-reads, decodes and validates every deck in the library once
   a second.** `SlideStudioView.swift:421` loop → `refreshDecksFromDisk:1348` →
   `LampPresentationDeckStore.decks()` (`LampPresentationDeck.swift:1609`), whose
   `decode:1740` always runs `LampPresentationDeckValidator.errors`. The read is
   detached and the result compared before assignment, so the main thread only
   sees churn on change — but at 100 decks a tick is half a second of a core, and
   at 400 the poll no longer keeps up with itself. The poll exists only for
   writers outside the process: in-app writers already announce themselves
   through `SlideStudioInbox.deckFilesChanged()`. Nothing in either app watches a
   directory.

2. **Every sync pass recompiles the whole personal corpus into a fresh SQLite
   file.** `LibrarySyncController.swift:1063` →
   `LampSyncMacPassLibrary.editableCollections:492` → `LampLibrary.personalArchive`
   (`LampLibrary.swift:6345`) → `LampPersonalFile.archive`
   (`LampPersonalFile.swift:40`): a temp database, every row inserted, `ANALYZE`,
   `VACUUM`, zlib, and then a decompress to verify. Once for writings, once for
   notes, **once per highlight set**, on the `LampLibrary` actor, every pass. An
   autosave moves `personalChangeStamp`, the 6-second probe sees it and starts a
   pass, so while someone writes this runs every 6–10 seconds and chapter reads
   queue behind it. The cost is per byte at insert-and-VACUUM speed — tens of
   MB/s, not the 2.4 GB/s of hashing — and being C it does not improve in
   Release. iOS pays the same through `LibrarySyncPass.exportedBytes:712`.

3. **Saving a writing reloads every writing.** `LibraryModel.swift:1506, 1703,
   1714, 1857` set `devotionals = try await library.devotionals()`, and autosave
   fires 1.5 s after a change. `LampLibrary.devotionals():1829` reads
   `personal_devotionals` with `SELECT *` (`:1943` — content, content JSON, media
   JSON per row) and the whole `devotional_entries` table of every installed
   devotional collection, decoding content JSON per row for those
   (`:1889`), then sorts the lot — inside one synchronous actor call. Personal
   rows are *not* JSON-decoded (`makePersonalDevotional:5804` reads the stored
   columns), so the cost there is I/O and row materialisation.

4. **The Mac writings list filters full text on the main actor, per keystroke
   and per reload.** `DevotionalsAndQuizzesView.swift:196` is evaluated in `body`
   at `:220` and again for the header count at `:546`, and the category chips
   filter the whole array once per chip at `:523`. Not debounced. Because the
   editor sits beside the list, every autosave's reassignment from (3) re-runs it
   even when nobody is searching.

5. **"Which decks belong to this writing?" decodes every deck, every two seconds,
   in two places.** `DevotionalEditorView.swift:5270` and
   `DevotionalsAndQuizzesView.swift:1380`, both through
   `LinkedPresentationDeckLookup.groupedByDevotional:105`. With the editor, the
   list and Slide Studio open, the library's decks are decoded and validated about
   twice a second.

6. **Deck sync decodes every deck two or three times per pass and copies every
   deck image into scratch.** `PresentationDeckSyncSupport.swift:73, 143, 175,
   214`; `exportDecks:166` plus `copyAssets`, whose output the per-file path then
   discards (`LampSyncLocalFiles.swift:252`). `removeDecksOfDeletedWritings:123`
   runs on every pass once any writing has ever been deleted.

7. **Revision history keeps a full before-and-after copy per edit and reads the
   whole folder on every record.** `AgentRevisionSupport.swift:324` says so;
   `record:526` → `storedRevisions:735` decodes every revision file, then
   compacts. Per autosave, per writing. On its own actor, and the tiers bound the
   count by age — but the folder is then exported and hashed by every pass.

8. **Cold launch is O(modules).** `LibraryModel.refreshLibrary:1926` asks for
   `installedModules()`, then `translationBooks` for **every** translation
   (opening each database), `highlightSets`, `readingPlans`, `devotionals()`,
   `quizModules()` (opening each quiz database) and `completedReadings`, as
   sequential awaits. `installedDatabases` (`LampLibrary.swift:146`) caches module
   metadata in memory only, so every launch re-inspects every module file.

9. **Everything serialises on one actor.** `public actor LampLibrary` wraps
   blocking GRDB reads in synchronous `throws` methods with no suspension points,
   so `devotionals()`, `personalArchive`, `quizModules` and `translationBooks`
   each hold the actor and a cooperative thread for their whole duration. This is
   the multiplier under (2), (3) and (8).

10. **One SQLite connection per module, never evicted.**
    `LampLibrary.openReadOnlyDatabase:4977`. Dropped only on module install
    (`:189`), remove (`:356`) and bundle extraction (`:5205`) — not on ordinary
    writes. Launch opens every translation, devotional and quiz module, so a
    library of several hundred modules holds hundreds of handles plus attached
    word lists. Whether that approaches the descriptor limit is unmeasured.

11. **iOS holds more in memory than it needs.**
    `DevotionalPickerView.loadDevotionals:756` decodes every writing's content
    JSON to draw a list of titles (`DevotionalModels.swift:831`), filtering with
    `lowercased().contains` — the slower of the two forms measured above — while
    `devotional_fts` (`ModuleDatabase.swift:336`) goes unused by the list.
    `PresentationDeckStorage.entries():96` decodes, validates *and retains the
    bytes* of every deck in both stores, and `linkedWritingIDs:130` and
    `entries(forWriting:):125` each call it again.

12. **Smaller, confirmed.** The MCP agent path reads one writing by loading the
    corpus (`LampAgentLibrary.swift:470, 491`) though `personalDevotional(id:)`
    exists. A page turn asks every notes and every highlights module serially
    (`LibraryModel.chapterContents:2077`), each an indexed query on a cached
    connection, so microseconds a hop except after an install. Bundle extraction
    inflates the whole database into memory (`LampLibrary.swift:5163`) and keys
    freshness on the archive's byte size (`:5130`). The sync manifest holds an
    entry per path ever synced and travels whole on every pass.

### Deliberately left alone

See `decisions/0001-hash-every-file-on-every-sync-pass.md`.

**Hashing every candidate file on every pass** (`LampSyncLocalFile.swift:76`).
It is linear at 2.43 GB/s, it runs only when something changed, and the comment's
argument is sound: a file replaced at the same size with its date preserved — a
restore, `cp -p`, `rsync -t` — would be skipped for ever by an mtime shortcut. A
stat-keyed digest cache would also feed a changed input to decisions the Lean
model covers. iOS already does the cheaper thing where it can: read-only modules
are listed as `heldWithoutAFile` from a stored hash
(`LibrarySyncPass.swift:705`). The only safe win is running `describe` in a task
group.

### Already right

Worth not rebuilding: the revision-based sync plan (`LampSyncFilePlan`), FTS5
indexes in both apps, iOS's memoised writings filter, the metadata-only
local-work probe, the bounded search-answer cache, tiered revision compaction,
lazy stacks in the module shelves, the background Strong's index with per-book
yields, and the cheap pre-pass probes. The command palette and unified search are
debounced and go through FTS; note and highlight lookups have the indexes they
need; the iOS widget reads a small app-group file and never opens a module.

## The plan

`[core]` must land in `lamp-bible-core` first, since both apps depend on it.
`[mac]` and `[ios]` are independent. Effort: S = hours, M = a day or two,
L = longer.

No new file matching `Sources/LampCore/LampSync*.swift`,
`Sources/LampModuleKit/LampSync*.swift`, `Sources/LampCore/LampPersonal*.swift`
or the Mac's `LampBibleMacSupport/*Sync*.swift` without an entry in
`Verification/coverage.json` — `SyncVerificationCoverageTests` fails on an
unaccounted sync source. Caching that changes neither bytes nor decisions needs
no change to `Verification/SyncMerge.lean`.

### Phase 0 — measure (S–M, no risk)

A corpus generator and measurements in core's test target, behind an environment
gate so an ordinary run skips them, built the way
`LampLibrarySearchPerformanceTests.swift:37` already builds modules
(`LampModuleCompiler().compile`). Tests ship with nothing.

- Corpus: 50 / 200 / 500 synthetic modules at 1–5 MB; 250 / 1 000 / 4 000
  writings at ~10 KB, a quarter with a workspace of five documents, fifty
  revisions and three transcripts; 25 / 100 / 400 decks of 40 slides; a thousand
  small media files.
- Measure in Release: `installedModules()` cold, `translationBooks` across every
  translation, `devotionals()`, `personalArchive(.writing)`,
  `LampPresentationDeckStore.decks()`, the Mac's `exportPortableWorkspaces` and
  `exportDecks`, peak resident size on the iOS deck and writing loads, and the
  open descriptor count at 500 modules.
- **Gate:** if the archive compile is not the largest term of a pass at 1 000
  writings, 1d drops down the order.

### Phase 1 — core enablers

- **1a. Decoded-deck listing cache** `[core, M]`, `decisions/0003`. A cache keyed on the file's
  size, modification date and resource identifier, holding the decoded **and
  validated** deck, so `decks()` lists by stat and decodes only what changed.
  `decode` keeps validating; `save`/`encoded` and the bytes sync merges on are
  untouched. Test that a rewrite at the same size with a preserved date, and a
  replacement with a new inode, both invalidate.
- **1b. Single-item reads** `[core, S]`. Add `devotional(moduleID:id:)`; point
  `LampAgentLibrary.readDevotional` and `personalDevotionalRevision` at it and at
  `personalDevotional(id:)`. One line each.
- **1c. Persist module metadata** `[core, M]`, `decisions/0005`. Write `installedMetadata` to
  `Indexes/InstalledModules.json` keyed by `LampDatabaseFileRevision` and the
  `.lamp` byte count, so a cold `installedDatabases` inspects only what is new or
  changed. A changed revision must always re-inspect.
- **1d. Cache the personal archives** `[core, M]`, `decisions/0002`. Key the writings and notes
  archive bytes by `personalChangeStamp()` **and** the media listing
  `normalizingMediaIn` reads (a missing picture refuses the archive, so media
  presence is an input), and build off the actor. The bytes must stay identical —
  the digest tests pin them.
- **1e. Batched chapter sidecars** `[core, S, optional]`.
  `moduleVerseNotes(moduleIDs:)` / `moduleVerseHighlights(moduleIDs:)` in one
  actor hop.

### Phase 2 — Mac

- **2a. Every deck poller through 1a** `[S after 1a]`: `SlideStudioView:1357`,
  `DevotionalsAndQuizzesView:105`, `DevotionalEditorView:5278`,
  `ManuscriptNotesRefreshSupport:86` — ideally one shared deck list per library
  root rather than three loops. The intervals can stay once a listing is stats.
- **2b. Deck sync decodes once** `[S–M]`: read the list once per pass and hand it
  to `exportDecks`, `applyDeletions` and `removeDecksOfDeletedWritings`; skip
  `exportDecks` and `copyAssets` on the per-file path, which discards them. The
  `.backup` archive path must still carry decks and assets.
- **2c. A save reloads one writing** `[M]`, `decisions/0004`: `LibraryModel:1703, 1714, 1857` fetch
  `personalDevotional(id:)` and splice. Keep the full reload where a newer copy
  arrived and after a pass, and keep the error fallback at `:1715`.
- **2d. The list filter** `[S, then M]`: pass the already-computed count to the
  header instead of recomputing it, and fold the chip counts into one pass; then
  compute the filtered array off the main actor on a settle.
- **2e. Index the revision folder** `[M]`: hold a decoded list per workspace
  validated by `historyToken`, so `record` decodes only new files. The on-disk
  format, the compaction policy and `replacedRevisionIDs` stay as they are.
- **2f. Launch** `[M, after 1c]`: read `translationBooks` for the translation
  being opened and the rest lazily; load `devotionals()` and `quizModules()` when
  their sections first appear — checking what else reads `model.devotionals`
  (`SlideStudioView:1402`, TodayView). Verify against signposts what actually
  delays first paint; the splash waits on the first chapter, not on these.
- **2g. Skip re-encoding attributed transcripts** `[S]`: `SyncSupport.swift:349`
  copies unchanged when the transcript already carries this install's mark.

### Phase 3 — iOS

- **3a. Deck entries through 1a** `[S]` and stop retaining every deck's bytes on
  `PresentationDeckEntry`; `revisions(in:)` keeps them for the merge.
- **3b. A list projection** `[M]`, `decisions/0004`: push the filter into SQL and draw rows without
  decoding `content` until one is opened.
- **3c. Reuse the change-keyed export cache in the pass** `[S–M]`: key
  `exportedBytes` the way `exportDigest(ofCollection:)` already keys itself.
- **3d. Drop and rebuild FTS around bulk imports** `[S]`, only if Phase 0 says
  import time matters.

### Phase 4 — only if Phase 0 says so

An LRU bound on `openDatabases` (evicting `versifications` and
`strongsFingerprints` with it), streaming bundle extraction, and the manifest's
size on the wire.

## Owner decisions

Four of these are product calls, not engineering ones.

- Routing writing search through FTS (2d's third step, 3b) changes what matches:
  tokens and prefixes instead of substrings.
- Capping revision history, or storing diffs instead of full copies, changes a
  format both Macs read.
- The deck listing cache (1a) is the first place in this codebase that trusts a
  modification date for anything. It is safe in practice — writers replace a deck
  atomically, so the inode moves — but the principle has been held deliberately.
- The archive cache (1d) keys on the same ledger stamp sync already trusts to
  decide whether to run a pass at all.
