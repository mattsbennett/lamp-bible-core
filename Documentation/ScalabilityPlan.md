# Scalability: where Lamp slows down as a library grows

Written 2026-11-24 against core `a844870`, macOS `c35b1c4`, iOS `da513ae`. Line
numbers are from those trees and will drift; the names are the durable part.

This is a plan, not a description of the code. Strike an item when it lands, and
delete the file when the work is done. The decisions behind it keep their own
records, which outlive this file: `decisions/0001`–`0007`.

The question it answers: when someone holds many modules, many writings and many
decks, what gets slow? The short answer is that several surfaces read a whole
corpus and filter it in memory, and a few of them do it **on a timer** or **on
every save**, so the cost arrives while the person is working rather than when
they ask for something.

## What was measured

Phase 0 ran: `Tests/LampCoreTests/LampScaleMeasurementTests.swift`, Release,
quiet M-series Mac, synthetic corpora built through the real APIs
(`savePersonalDevotional`, `LampPersonalWritingFile.archive`,
`LampModuleCompiler`, `LampPresentationDeckStore.save`). Run it with
`LAMP_SCALE=1 swift test -c release --filter LampScaleMeasurementTests`.

Writings of ~10 KB each, beside an installed 365-entry collection:

| | 250 | 1 000 | 4 000 |
| --- | --- | --- | --- |
| `devotionals()` — what every save reloads | 19 ms | 54 ms | 125 ms |
| `personalDevotional(id:)` — one row | 0.2 ms | 0.2 ms | 0.2 ms |
| `personalArchive(.writing)` — what every pass compiles | **435 ms** | **1 749 ms** | **3 599 ms** |

Decks of 40 slides:

| | 25 | 100 | 400 |
| --- | --- | --- | --- |
| `decks()` | 20 ms | 84 ms | 364 ms |
| the same files, `decodeUnvalidated` | 6 ms | 26 ms | 111 ms |
| a stat of each file | 0.0 ms | 0.1 ms | 0.4 ms |

Book modules of ~200 KB each:

| | 50 | 200 |
| --- | --- | --- |
| `installedModules()`, nothing cached | 14 ms | 38 ms |
| the same, warm | 2.7 ms | 10.4 ms |
| open each and read its sections | 25 ms | 86 ms |
| open file descriptors held afterwards | +51 | **+201** |

SHA-256 of a mapped file runs at 2.43 GB/s (Debug or Release — it is CryptoKit).

Taken again after the work, Release, same harness:

| | before | after |
| --- | --- | --- |
| `personalArchive(.writing)`, 250 writings, nothing changed | 435 ms | **0.40 ms** |
| `decks()`, 25 decks, nothing changed | 20 ms | **1 ms** |

And with modules of a realistic size — 50 book modules of about 12.5 MB, 625 MB
in all — rather than the fixture's 200 KB:

| | 50 modules × 12.5 MB |
| --- | --- |
| `installedModules()`, nothing cached | 21 ms |
| the same, warm | 2.4 ms |
| open each and read its sections | **1 297 ms** (26 ms a module) |
| open descriptors held afterwards | **+48** — the bound, doing its job |

So the per-module open cost is what grows with a module's size, 26 ms at
12.5 MB where it was 0.43 ms at 200 KB, which is the case for reading the
translation being opened and leaving the rest until something asks (2f). And
the descriptor count stops at the cache's limit rather than at one per module.

Three caveats the numbers carry. The fixture's prose repeats, so it compresses
far better than real writing — 760 KB for 4 000 writings — which understates the
compress and digest terms of an archive while leaving the insert and `VACUUM`
terms honest. The fixture's modules are 200 KB, so the per-module open cost is
understated for a real commentary of several hundred MB, where the comment on
`openReadOnlyDatabase` records roughly 200 ms. And a measurement on a quiet
machine is a floor, not what a person with a busy Mac sees.

What the numbers say. The archive compile is about **0.9 ms per writing**, and
about **thirty times** the cost of reading the whole list; at 1 000 writings it
is 1.7 s of the library actor on every pass, which during a writing session is
every six to ten seconds. Reading one writing instead of all of them is 0.2 ms
against 125 ms. Listing decks from stats instead of decoding them is 0.4 ms
against 364 ms, and validation is about 70% of that 364 ms — the share Debug put
at 94%. Each module costs one open descriptor, which at a few hundred modules is
the ceiling to watch rather than the milliseconds.

Filtering writings on the main actor with
`localizedCaseInsensitiveContains` over title and body, measured separately in a
Debug build, cost 10 ms at 250 writings, 37 ms at 1 000 and 155 ms at 4 000; the
Release figure will be lower but it is Foundation, so not by much.

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

10. **One SQLite connection per module, never evicted — and one descriptor
    each.** Measured: +201 descriptors at 200 modules, against a 256 soft limit
    for a process launched by launchd, which neither app raises. See
    `decisions/0006`.
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

### Deliberately left alone, then not

Hashing every candidate file on every pass (`LampSyncLocalFile.swift`,
`describe`) was `decisions/0001`: linear at 2.43 GB/s, only on change, and the
shortcut would lose a file restored at the same size with its date preserved.

`decisions/0007` supersedes it. Both of 0001's reasons moved the same day. The
key it rejected was a modification date, where `LampDatabaseFileRevision` also
carries the inode and the kernel's change time — which `0003` then relied on,
with a test that rewrites a file in place, puts the date back, and watches the
listing notice. And hashing was cheap *compared with the per-pass compile*,
which `0002` cached away; it is now the largest thing a pass does.

0007 is gated rather than general: identity is trusted only where the
filesystem maintains a change time and does not reuse inodes (`apfs`, `hfs`),
only for the kinds whose bytes are worth it — modules and media — and only
within one process, so the first pass of a session still reads everything. On a
NAS or a USB stick it changes nothing, because there the key would degrade to
the `(size, mtime)` that 0001 was right to refuse.

**Landed** for core and the Mac: `LampSyncDigestCache`,
`LampSyncIdentityTrust`, `LampSyncFileKind.keepsDigestAgainstIdentity`, and the
Mac's one cache per library root. The phone still hashes its media and book
pictures every pass — `LibrarySyncPass` — which is 3e below.

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

### Phase 0 — measure (done for the library; the rest outstanding)

`Tests/LampCoreTests/LampScaleMeasurementTests.swift`, behind `LAMP_SCALE=1`,
with its sizes as environment variables. **The gate is passed:** the archive
compile is the largest term by a wide margin, so 1d stays first.

Measured since: `installedModules()` against modules of a realistic size
(above), and the Mac's own per-pass work, which turned up something the plan
had the wrong size for. `MacScaleMeasurementTests`, Debug — the work is file
copies and stats, which Release does not speed up — with each workspace
holding a draft, five documents, a context file and fifty revisions:

| | 50 workspaces | 250 workspaces |
| --- | --- | --- |
| export and enumerate, per pass | 711 ms | **3 602 ms** |
| files staged | 3 002 | 15 002 |
| the six-second local-work probe | 19 ms | 96 ms |

About **14 ms a workspace**, linear, and **now the largest single thing a pass
does**: the compile it used to sit behind is 0.40 ms when nothing changed, and
the hashing is identity-cached. At a thousand writings with workspaces that is
some fourteen seconds of copying per pass, and a pass runs whenever anything
personal changes. The probe is about 0.4 ms a workspace, so ~400 ms every six
seconds at a thousand.

The plan had this as a secondary term (see the weak points, item 6). It is
not, and the reason it is built that way is good — the published path is not
the stored path, and the mapping has one home in the exporter, so the gather
runs the real exporter into a scratch directory rather than reimplementing the
mapping as path arithmetic. Changing that is a design question, not a
micro-fix, and it is with Fable rather than guessed at. **This is the next
item**, ahead of anything else outstanding.

One measurement is still untaken, and it no longer blocks anything: **peak
memory on the phone's writings and deck loads**. It was there to gate 3a and
3b. 3a is done, and 3b is the owner's call for other reasons — what a search
matches, and a reader that would have to fetch by id — so the memory figure is
worth taking when that decision is made, with `XCTMemoryMetric` over a seeded
collection, and not before.

### Phase 1 — core enablers

- ~~**1a. Decoded-deck listing cache**~~ **done**, `decisions/0003`. Keyed on
  the file's identity as `stat` reports it — device, inode, size, modification
  time and **change time** — holding the decoded *and validated* deck, so
  `decks()` lists by stat and reads only what moved. The change time is what
  makes it sound: nothing in userspace sets it, so a rewrite in place with the
  date put back still reads as changed.
- ~~**1b. Single-item reads**~~ **done**. `devotional(moduleID:id:)`, sharing
  its row mapping with the whole-collection read; the agent tools now read one
  row rather than the corpus.
- ~~**1c. Persist module metadata**~~ **done**, `decisions/0005`.
  `Indexes/InstalledModules.json`, keyed by `LampDatabaseFileRevision` and the
  `.lamp` byte count, so a launch inspects only what is new or changed. A
  changed file is inspected again, a vanished one is dropped, and an index that
  will not read is simply absent.
- ~~**1d. Cache the personal archives**~~ **done**, `decisions/0002`. Keyed on
  a revision each table keeps by trigger — not the device-wide change stamp
  (useless) and not the sync ledger (unsound: five writers change rows without
  stamping it). Read the record before touching it; both wrong keys are in
  there with what they broke.
- ~~**1e. Batched chapter sidecars**~~ **done**: `moduleVerseNotes(moduleIDs:…)`
  and `moduleVerseHighlights(moduleIDs:…)`, so a page turn is one crossing onto
  the library's actor rather than one per installed notes and highlights
  module.

### Phase 2 — Mac

- ~~**2a. Every deck poller through 1a**~~ **done by 1a itself**: all four
  (`SlideStudioView`, `DevotionalsAndQuizzesView`, `DevotionalEditorView`,
  `ManuscriptNotesRefreshSupport`) call `store.decks()`, so all four now stat
  rather than decode. One shared deck list per library root is still worth
  doing — three loops asking the same question is three times the stats and
  three copies of the answer — but it is tidying, not cost.
- ~~**2b. Deck sync decodes once**~~ **done in the part that counted**: the
  per-file pass no longer stages decks at all. It was copying every deck and
  every deck image into a scratch directory on every pass for
  `workspaceFiles` to skip them — `theWorkspaceStagingDoesNotCarryDecks` holds
  it. The remaining sweeps (`applyDeletions`,
  `removeDecksOfDeletedWritings`) still decode the library's decks when a
  deletion is in play, which is not every pass; they want the bytes for the
  pull plan, so sharing one read with `exportDecks` means changing what the
  plan is given. Left, with the reason.
- ~~**2c. A save reloads one writing**~~ **done**, `decisions/0004`: the copy
  the save reads back is spliced into the list in
  `LampDevotional.libraryOrder`, which core now names. The full reload stays
  where the save was refused because a newer copy had arrived, and after a
  pass. A new writing and a deletion are one row each too. Held by
  `WritingListSpliceTests`, which checks the list against the library's own
  after every kind of change.
- ~~**2d. The list filter**~~ **done**, bar the owner's question below: the
  header takes the count it is given, the category chips are counted in one
  walk rather than one filter each, and **bodies** are searched off the main
  actor after a 150 ms settle, their answer kept while a newer scan runs. What
  a row shows — title, subtitle, author, series, summary, tags — is still
  matched as you type, so titles match at once and bodies a moment later.
- ~~**2e. Index the revision folder**~~ **done**: the decoded history is kept
  per workspace against `historyToken` — a listing, not a read — so a record
  decodes only what is new. Four workspaces at a time, least recently used
  first. The on-disk format, the compaction policy and `replacedRevisionIDs`
  are untouched.
- ~~**2f. Launch**~~ **done**: `refreshLibrary` reads the modules, the
  translation being opened and the highlight sets, then publishes; the
  writings, the quizzes and the other translations' book names follow in
  `loadTheRestOfTheLibrary`, each published as it arrives. `refreshNow()`
  waits for all of it, because its caller is a writing arriving from the
  phone — a test caught that the day the deferral landed.
- ~~**2g. Skip re-encoding attributed transcripts**~~ **dropped.** Written and
  reverted. The saving is one decode and encode per conversation, and copying
  the file instead changes what a pass publishes from the canonical encoding
  to whatever the file happens to hold — so two Macs on different builds would
  trade the same conversation back and forth. Not worth that for a term the
  measurements never show.

### Phase 3 — iOS

- ~~**3a. Deck entries through 1a**~~ **done**: `PresentationDeckStorage.entries()`
  goes through `LampPresentationDeckStore.decks()`, so the phone's listing
  reads only the deck files that moved — and `linkedWritingIDs()` and
  `entries(forWriting:)`, which each ask again, inherit it. `revisions(in:)`
  still reads the bytes, which a merge needs.
- **3b. A list projection** `[M, and the owner's call]`. Still open, and it
  splits in two. `DevotionalStorage.getDevotionals` fetches every row and
  `toDevotional()` parses each one's content JSON — confirmed — so drawing a
  list of titles decodes every writing. Not done here because the row hands
  the decoded writing straight to `DevotionalView`, so a projection needs the
  reader to fetch by id, and that is the phone's main surface: worth seeing
  drawn before it ships. The other half, pushing the search into SQL, changes
  what matches — SQLite's `NOCASE` folds ASCII only, where the current filter
  folds Unicode, so a Greek or Hebrew query would stop matching case. That is
  the owner's decision, the same one as FTS below.
- ~~**3c. Reuse the change-keyed export cache in the pass**~~ **done**:
  `exportedBytes` is kept against the count the database keeps of changes to
  that collection, and migration v45 extends those triggers from writings to
  notes and highlights. Held by
  `testNotesAndHighlightsAreCountedForTheirOwnCollection`.
- **3d. Drop and rebuild FTS around bulk imports** `[S]`, only if a
  measurement says import time matters. Not measured yet.
- ~~**3e. The digest cache on the phone**~~ **done**, `decisions/0007`: the
  phone's media and book pictures go through the same gate and the same cache.

### Phase 4 — the descriptor ceiling, and two maybes

- ~~**4a. Bound the open-database cache**~~ **done**, `decisions/0006`. The
  limit is measured: a GUI-launched app gets **256** open files, so one
  descriptor per module really was a ceiling. The cache keeps forty-eight
  connections and the Mac app raises its own soft limit to 8 192.
- Streaming bundle extraction, and the manifest's size on the wire — only if
  iOS reports low memory, or Phase 0's remaining measurements show a multi-MB
  bundle.

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
