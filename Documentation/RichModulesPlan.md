# Rich commentary and translation modules — plan

Status: **Proposed; the schema signed off by the owner on 2026-11-26.**
Revised once (below) for the owner's decisions and the converter's
measurements. Steps 1 (068cf57), 2 and 2a (5e3049f) are in the code; the
rest is not yet.
Planned 2026-11-26 (Fable), every load-bearing claim checked
against the code before this was written (see "Verified").

The JSON fragments here are drafts of shape. The schema files written in
steps 3 and 4 are the specification, and are reviewed when written.

Two tracks, one shared piece:

- **Commentary track** (record 0029): pictures, tables, lists, small caps and
  internal links in commentary notes, and where a study Bible's articles,
  standalone charts and maps live.
- **Translation track** (its record takes the next free number when
  written; 0030 and 0032, each named for it in turn, were taken first):
  poetry lines within a verse, in-text
  cross-references, inline styles in translation footnotes, heading kinds.
- **Shared:** the inline set (`italic`, `bold`, `smallcaps`, `scripture`,
  `link`) and the link address, `linkTarget`. Nothing else.

The request came from a study Bible converted for the owner's personal use;
the format is generic and names no publisher.

## The split

| Content | Home | Why |
|---|---|---|
| Verse and range notes, outline headings, inline maps and charts | Commentary series | Keyed to verses |
| Verse-keyed article paragraphs | A second commentary series | Keyed to verses |
| Book introductions | Commentary front matter (owner, D1) | See "Revision 1" |
| Articles, standalone objects (a second copy of the 220 printed both ways, owner D3), front matter, lists of charts and maps | Book module | Read as pages; blocks, pictures, search and sync exist |
| Reading plan | Plan module | Exists |
| Concordance | Out of scope | The apps search the verse text |

**Links cross modules; content does not.** A reader never opens a second
module to draw the first.

Rejected homes for articles: a commentary unit type with book 0 (`book` and
`sv` are `NOT NULL`; the phone reads an unknown unit type as a verse; search
titles a hit from `sv`; the Mac groups by start verse); a separate table
(invisible to old readers but needs a new search path, compiled-schema entry,
phone landing table and article browser).

## One block model

Core's book model (`LampBookContentBlock`, `LampBookAnnotatedText`,
`LampBookTextResolver`, `LampBookTableLayout`) is already drawn by both apps'
book readers. Commentary uses none of it today: the phone has its own model
and `CommentaryRenderer`, and the Mac draws plain strings. Commentary adopts
the book model. It needs:

- block `id`, `role`, `title`, `subtitle`, `notes`, `legend`; row `label`;
  cell `align` and `label`;
- annotation `smallcaps`, and `data.target` on `link` and `scripture`;
- the resolver to accept commentary spellings (`bold`/`italic` as types);
- `LampBookTableLayout` to honour `rowSpan`, decoded and never used today.

`smallcaps` is a new annotation type, not an `emphasis` style: both old
readers draw an unknown emphasis style as italic. It covers the capitals as
written ("ORD" in "LORD"), so text, offsets and search do not move. The
translation keeps its semantic `divine-name` for verse text.

## Link address

```json
"linkTarget": {
  "type": "object",
  "description": "A place in an installed module, by kind and declared ID. Never a stored row ID.",
  "properties": {
    "kind":    { "type": "string", "enum": ["commentary", "book"] },
    "module":  { "type": "string", "minLength": 1 },
    "sv":      { "$ref": "#/definitions/verseRef" },
    "ev":      { "$ref": "#/definitions/verseRef" },
    "suffix":  { "type": "string" },
    "section": { "type": "string", "minLength": 1 },
    "book":    { "type": "integer", "minimum": 1, "maximum": 66 },
    "unit":    { "type": "string", "minLength": 1 },
    "anchor":  { "type": "string", "minLength": 1 }
  },
  "oneOf": [
    { "description": "A commentary passage",
      "required": ["sv"], "not": { "anyOf": [ { "required": ["section"] }, { "required": ["book"] } ] },
      "properties": { "kind": { "const": "commentary" } } },
    { "description": "A commentary volume's front matter",
      "required": ["book", "section"],
      "not": { "anyOf": [ { "required": ["sv"] }, { "required": ["ev"] }, { "required": ["suffix"] }, { "required": ["unit"] } ] },
      "properties": { "kind": { "const": "commentary" } } },
    { "description": "A book section",
      "required": ["kind", "section"],
      "not": { "anyOf": [ { "required": ["sv"] }, { "required": ["book"] }, { "required": ["unit"] } ] },
      "properties": { "kind": { "const": "book" } } }
  ]
}
```

Exactly one route per target (found by Codex): a passage, a volume's front
matter, or a book section; `book`, `unit` and the front-matter form are
described under Revision 1. An omitted `kind` means this module's, so a
target inside a book module with only `section` is a book section.

- `kind` is required with `module`; both omitted means this module.
- A note is found by passage (`sv`, `ev`, `suffix`), never by row ID: unit IDs
  embed the build's order index and the phone prefixes them on import.
- A note-to-note link is a `scripture` annotation that also carries
  `data.target`: an old reader opens the passage, a new one opens the note.
- URLs: `lampbible://commentary?module=&sv=[&ev=][&suffix=][&unit=][&anchor=]` (new);
  `lampbible://book?module=&section=[&anchor=]` (one new parameter).

## Commentary 2.3

- `meta.schemaVersion` gains `"2.3"`; a top-level `media` array of the book
  schema's `mediaReference`.
- `verseCommentary.blocks`, `pericope.blocks`, `section.blocks`: the body in
  full, in reading order — the **one** ordered body of a 2.3 unit. A unit
  gives `blocks` or the body it gives today (`commentary`, or a 2.2
  source-tracked pericope's `content`), never both: the inspector refuses
  both together, since no rule could say where a figure falls between two
  paragraphs split across two arrays. A source-tracked pericope is
  different: each of its `content` entries carries its own `sv`/`ev` and
  becomes a row of its own (`CommentaryModuleCompiler.swift:368-388`), so
  its rich body goes on the **entry**, as `content[].blocks` beside the
  entry's range, never on the pericope — mapped onto one pericope array the
  entries' lookup points would be lost. Found by Codex.
- Stored: `commentary_units.blocks_json` (NULL when `commentary_json` is the
  whole body) and `commentary_books.media_json`. No new table, no index change.
- `commentary_json` keeps a **projection** written by the compiler, so old
  readers show text. It is **one** annotated-text object, as today — the
  blocks' text joined with blank lines and each annotation's offsets rebased
  into the joined text — never an array: an older phone decodes
  `commentary_json` as one `AnnotatedText` and shows a blank note for anything
  else (found by Codex). Step 4's tests hold a multi-block note's projection
  to that. Paragraphs keep only 2.2 annotation types; a list as a
  line per item; a table as its title, a line per row, its notes; a picture as
  its title, subtitle and caption.
- `search_text` is built from the projection, so it covers list items, table
  titles and cells, table notes, and picture titles and captions. Alt text is
  left out: not on screen.
- Apps detect the shape by column, as they already do for `footnotes_text`.
  The new columns are `mayBeAbsent`/`mayBeNull` in `LampModuleCompiledSchema`
  and are **not** added to the import check.
- Discontinuous ranges: the hull in `sv`/`ev`, the printed range as title.
- Each unit is filed by its own `sv`'s chapter, not the `chapters[]` entry it
  sits in.

## Media

- Metadata only in the module (`media_json`); files never inside the `.lamp`.
- Server: `CommentaryMedia/<module>/<path>`, a new media kind beside
  `BookMedia`; uploaded only where absent, never listed. Book media cannot be
  reused as it stands: it refuses any ID another kind of module holds.
- A series is one module, so its volumes share one media folder. Series
  compilation refuses two volumes naming one `filename` for different
  media, or one media `id` for different files, rather than let
  upload-only-where-absent keep whichever came first (found by Codex).
- Mac: `Media/Commentaries/<module>/`, a reserved name.
- Phone: its session chooses; today's cache is one folder per ID across kinds.
- No web addresses: an `http(s)` filename is refused, so reading a personal
  module fetches nothing.
- A personal module is listed `restricted` in the modules repo's
  `CONTENT_RIGHTS.json`, so no release bundle can include it.
- The new kind touches `LampSyncFileKind`, `kind(of:)`, the format-3 guard,
  `LampSyncLocalDeletion`, and the `deleteTarget`/`filePlanAction`
  conformance tables in `Verification/`, in one commit agreed with both apps.

## Translation track

- **Poetry lines** in `poetry_json` (stored whole, no SQL change):
  `poetry.lines: [{ offset, indent, stanzaBreak? }]`. Text stays joined by
  single spaces, so search and Strong's offsets do not move. Fixed in
  `TranslationCollector`, which the USFM, OSIS and SWORD readers share; today
  a `\q` inside a verse only sets the next verse's indent.
- **Cross-references**: `verses.cross_references_json`, a nullable column —
  not footnotes, or old apps would draw every letter as a footnote marker.
  `[{ label, offset, refs: [verseRange], text }]`. USFM `\x` fills it too.
- **Heading kinds**: `headings.kind` nullable column (`section`, `division`,
  `superscription`, `acrostic`, `speaker`); `level` stays.
- **Footnotes** take the shared inline set.
- Nothing new goes in a verse's `annotations_json`: the phone decodes it as a
  closed enum, and one unknown type blanks every tag on the verse.
- The offset unit (Characters, as the collector counts, or code points, as
  core reads) is settled in the first item.

## Order of work

Commentary first (the converter waits on it); the translation track's first
item shares nothing with it and can run alongside.

Commentary:

1. **Pin and record.** Pin today's compiled commentary rows; a failing test
   that a book table's cell text is searchable, fixed by adding `cells` to
   `JSONSupport.plainText`'s keys; a commentary carrying the two new columns
   still imports, reads and searches. Draft record 0029.
2. Shared block and annotation model, `rowSpan`, the link route.
3. Commentary 2.3 in the compiler: schema, inspector checks, projection,
   columns, chapter-by-own-verse.
4. Series compilation in core (owner decision 5).
5. Core readers return blocks, media, and resolve links.
6. The media kind, with the Lean tables, agreed with both apps.
7. Docs, record to Accepted, hand-off briefs for the apps.

Translation: poetry lines; heading kinds; cross-references and `\x`;
footnote styles (after commentary step 2); its record and docs.

## Owner decisions

Decided:

- **D1** Introductions live in **commentary front matter** (against the
  first plan's book-module recommendation).
- **D3** Objects printed both inline and standalone are stored **twice**:
  in the note, and in the book module for a browsable gallery.
- **D5** Series compilation moves **into core**.
- **D10** Psalm superscriptions are **headings with a kind**.

Defaults kept until the owner says otherwise: D2 a second commentary series
for verse-keyed article paragraphs; D4 concordance out; D6 a new
`CommentaryMedia/` folder; D7 hull plus printed title.

- **D8** Only current phone builds (from iOS 22b59eb, 2026-11-08) need read
  a new module. So footnote `smallcaps` and `link` go in the footnote's own
  `annotations`; no `marks` array.
- **D9** Step 1 may land before the schema is signed off.

## Revision 1 (2026-11-26)

Supersedes the first plan where they differ.

**Figures.** A printed object is a container block:

```json
"figure": {
  "properties": {
    "type":     { "const": "figure" },
    "id":       { "type": "string", "minLength": 1 },
    "role":     { "type": "string", "description": "Not interpreted, e.g. map, chart" },
    "title":    { "$ref": "#/definitions/textValue" },
    "subtitle": { "$ref": "#/definitions/textValue", "description": "e.g. an era or date" },
    "caption":  { "$ref": "#/definitions/annotatedText",
                  "description": "The figure's one caption, over all its images" },
    "children": { "type": "array", "items": { "$ref": "#/definitions/figureChild" },
                  "description": "image, paragraph, list, table, heading, in printed order; never a figure" },
    "notes":    { "type": "array", "items": { "$ref": "#/definitions/annotatedText" } }
  },
  "required": ["type", "children"]
}
```

`figureChild` is `contentBlock` with `type` limited to `image`,
`paragraph`, `list`, `table` and `heading`, so a figure inside a figure fails
validation rather than only its description (found by Codex).

Title, subtitle, caption and notes move off `image` and `table` onto the
figure; several images are consecutive `image` children carrying only alt
text, and a figure's caption is never copied into them. Title is optional
(eight objects have none). A figure of several titled parts — up to five,
each with its own table or image — marks each later part with a `heading`
child (the book schema's existing block, `level` and `content`), which keeps
"never a figure inside a figure". Measured by the converter against every
object's child order. Old readers see one
projection — title, subtitle, caption, each child, notes — in a commentary's
`commentary_json`, and in a book in the stored figure's `content`, which both
book readers draw for an unknown block type (iOS `BookModuleView.swift:1439-1444`,
Mac `BookModulesView.swift:1680-1683`). An old book reader shows a figure's
words but not its pictures; accepted. `plainText`'s keys gain `cells`,
`subtitle` and `notes`.

**Front matter.** `frontMatter.sections: [frontMatterSection]`, each
`{ id, title, blocks, sections }`. Stored in a new table, one row per section,
with its own FTS index, shaped like `book_sections`:

```sql
CREATE TABLE commentary_front_matter (
    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, book_number INTEGER NOT NULL,
    section_id TEXT NOT NULL, parent_id TEXT, title TEXT NOT NULL,
    depth INTEGER NOT NULL, order_index INTEGER NOT NULL,
    blocks_json TEXT NOT NULL, search_text TEXT NOT NULL DEFAULT ''
);
```

A `section_id` is unique within its book, nested sections included — a
search hit and a link both name a section by `{book, section}` — and the
compiler refuses a duplicate (found by Codex).

Not rows in `commentary_units` (an old phone lists units across the module
and would show them; `sv` is `NOT NULL`), and not blocks in
`front_matter_json` (no index, and a hit could not land on a section). A new
table is invisible to old readers. `LampModuleTableShape` gains a way to say
a whole table may be absent. Search gains a front-matter query; a result
gains an optional link target. `linkTarget` gains `book`
(`{ book, section, anchor? }` in a commentary target), and the URL
`lampbible://commentary?module=&book=&section=[&anchor=]`.

**A link to one of two units on the same passage.** A section and a
pericope, or an outline heading and a note, may share `sv`, `ev` and
`suffix`, so a passage alone does not name one unit (found by Codex,
reviewing step 1). `linkTarget` gains `unit`, valid only with `sv`: the
declared id of a section or pericope starting at `sv`.

- With `unit`: the row with that declared id and that `sv` (and `ev` if
  given); the lowest `order_index` if several.
- Without: the row whose passage is exactly the target's, a verse unit before
  a pericope before a section.
- Nothing matches: the passage itself, as an old reader opens it.
- `anchor` is only ever a block inside the unit found **or a row below it**:
  a source-tracked pericope's entries are rows of their own, each holding
  its own blocks, so an anchor is looked for in the found row, then its
  descendants in order (found by Codex). Block ids are unique within a
  volume, so the search is unambiguous.

Stored as `commentary_units.declared_id` (nullable; NULL for a verse note),
written in step 4 for every section and pericope that gives an id — today
both writers drop it (`CommentaryModuleCompiler.swift:261`, `:291`). The 2.3
inspector refuses two verse notes in a volume on one (`sv`, `ev`, `suffix`),
and two units at one `sv` with one declared id. Rejected: `anchor` naming a
unit as well as a block (a block inside a section could no longer be named,
and section ids such as `I` recur across chapters); a unit type plus level
(fragile, and the type is the compiler's choice, not the author's); an id on
every unit (16,000 ids restating their passage, and no link into an existing
commentary).

**From the phone's review** (lamp-bible-ios-e4, against iOS 315a281):

- The phone's `CompiledModuleLandingTests` fails for any table or column
  `LampModuleCompiledSchema` declares that the phone has no landing or
  `notKept` reason for — `mayBeAbsent` does not help. So the commit that
  declares `blocks_json`, `media_json`, `declared_id` or
  `commentary_front_matter` is a **cross-repo landing**: the phone session is
  told the exact shape before it is pushed and lands its migration the same
  day.
- The phone copies rows into its own tables and keeps its own FTS. The shape
  names the index too: `commentary_front_matter_fts (title, search_text)`,
  external-content on `commentary_front_matter`, `content_rowid='rowid'`, as
  `commentary_units_fts` is; search finds it by table presence.
- Front matter's `parent_id` names a row `id`, which the phone renames per
  module on import as it does for units. A link never names a row `id`: a
  front-matter target is `{ book, section: section_id, anchor? }`, a unit
  target a passage, `unit` and `anchor`.
- `CommentaryMedia` refuses an ID another kind holds, as book media does; the
  phone takes an item list from `media_json` in `LampSyncReferencedMedia`'s
  form, with the same safe-path check, into `ModuleMediaCache/<module>/`.

**From the converter's run of today's tools.** Today's inspector calls a
commentary declaring `schemaVersion` 2.3 valid, and today's compiler ignores
`blocks`, so a note written only as blocks compiles to an empty unit. The 2.3
work begins by refusing a commentary version core does not support.

**Gallery copy.** The book module declares its own `media` and keeps its own
files under `BookMedia/<book>/`; no reference into the commentary's media
(every book-media rule is keyed on the owning book, and removing the
commentary would blank the gallery). The converter uses the same relative
path and the same figure `id` in both modules. The 220 pictures upload twice,
and a search for a chart's words finds it in both modules.

**Order of work, commentary track** (replaces the first plan's):

1. Pin and record: golden compiled rows (including `front_matter_json`);
   tolerance of the new columns and the new table; the book table-cell
   search test as a known issue; record 0029 drafted. No behaviour change.
   (First planned with a fix — `cells` added to `plainText`'s keys — that
   was itself the defect: it made the index a second reading of a table
   beside `LampBookTableLayout`, and four Codex rounds each found another
   place they disagreed. Taken back out; see step 3.)
2. **Done.** Series compilation in core with no format change:
   `LampModuleCompiler.compileSeries`, and `lamp-module build-series
   <series.json> <volumes folder> [output.lamp]`, each listed volume read
   from `<volume id>.json`, in canonical order. Held row by row to
   `commentary_series_to_sqlite.py` on a two-volume series (one
   source-tracked): every table, column and row matched but three, each the
   Python port having fallen behind core's builder, and each core's now —
   verse and chapter-introduction IDs (no reader stores a unit's ID), a
   pericope's own `commentary` (not in the schema; no volume in the modules
   repository uses it), and search text joined with spaces rather than
   newlines (the index reads both the same). Pinned in
   `CommentarySeriesCompilerTests`. Then held to it on real data: NIC from
   today's sources, 57 volumes and 86,333 units, matched in every column but
   search-text whitespace; XRef and TSKe build as well. A series' `volumes`
   entries name the files only when they give an `id` (the converter's);
   otherwise the list describes the printed volumes, as the schema says, and
   every commentary volume in the folder and its subfolders is built, as the
   Python built them — NIC lists Hamilton's Genesis as two volumes in one
   file. Volumes are read one at a time; the peak is producing the `.lamp`
   itself (1 GB for NIC's 375 MB database, compressed and verified), as for
   any large module. The manifest is checked in one pass before it chooses
   anything (`seriesManifestIssues`), and a volume's issues carry its file's
   name, its warnings reaching the build's result: four review rounds had
   each found another field read as absent when malformed. The refusal of
   an unsupported commentary
   `schemaVersion` landed here rather than in step 4: with a series command,
   a 2.3 volume could otherwise have been built and lost its blocks.
2a. **Done.** Bound the table layout, its own commit before step 3: saturating
   `column + span`, a capped column count (a named constant, at least twice
   the widest real table: 64, measured against the widest of 691 bundled
   tables, 24 columns, and the study Bible's 364, 13 columns, none with a
   span past its table's last column), a cell
   at or past the cap left out, `columnWeights` bounded too. The inspector
   warns about an over-wide table and the compile goes on, as the
   repository settled for IDs (`LampModuleCompiler.swift:96-110`): a refusal
   at compile time turns a module that works on one device into one that
   works on neither. Today a wide enough span traps any reader that opens
   the section.
3. **One walk over decoded blocks** — done, as `LampBookDrawnText`, for
   book search; the projections in steps 4 and 5 use it too (lands with the strict table checks in
   `awordInABookTableIsSearchable`, replacing its known issue: the phrase in
   the reader's column order, every shown cell present, the full-text match)
   for a section's drawn text, in reading
   order, as the readers draw it (`LampPortableBookJSON.decodeArray`, then by
   type; a table's rows through `LampBookTableLayout.placements`). The book
   compiler's search text, the commentary projection and the figure
   projection all use it; `plainText` stays for annotated text and footnote
   lists. Media metadata is not indexed (the readers disagree: the Mac falls
   back to a picture's `alt`, the phone to its media caption). Then the
   shared model — **done but for the link routes**:
   `LampBookContentBlock` reads `id`, `role`, `title`, `subtitle`,
   `children`, `notes` and `legend`, a row and a cell their `label` and a
   cell its `align`, each field read on its own so a malformed one is absent
   rather than the loss of the block; `LampLinkTarget` with one destination
   per target, read in the kind of module it is in; the resolver's
   `smallcaps`, `bold`, `italic` and link targets; `book_schema.json`'s
   `figure`, `figureChild`, `linkTarget` and `legendEntry`. Search takes a
   figure as today's readers draw it, its `content`;
   `LampBookDrawnText.figureText` gives its own words for the projections
   steps 4 and 5 write into that `content`. A link's target and a scripture
   annotation's note are two attributes, `bookLinkTarget` beside `link` and
   `bookScriptureTarget` beside `bookScripture`, each pair set and cleared
   together: one attribute for both, three reviews in turn found an overlap
   that paired one annotation's target with another's address or passage.
   The resolver judges a target in the kind of module the text is in
   (`containingKind`, a book's by default), and one naming no place there is
   no target. `rowSpan`: `LampBookTableLayout.grid` lays a table's rows
   out together, each first alone by `placements(of:columnCount:)`; a cell
   reaches down over the gaps and blank cells below it (nothing but their
   place: no words, every field but column and spans at its default; judged
   whole, since two reviews in turn found a listed check missing a drawn
   field), as one covered slot per row, and stops above any other cell and
   at the table's end. So a span never hides what a cell holds, and every
   cell with words is where the row alone puts it — search and the section
   index stay on the per-row walk. The bundled books hold 151 such cells in 36 tables,
   the study Bible 73 in 22; one bundled cell stops above words, and the
   inspector warns of a span cut short. Readers draw it in step 6 (both lay
   tables out with SwiftUI `Grid`, which spans no rows). The planned list:
   figure, row and cell additions, `smallcaps`, `link` and its
   target, resolver cases, `rowSpan`, the link forms.
4. Commentary 2.3 in the compiler, volume and series (an unsupported
   `schemaVersion` is refused already, from step 2; 2.3 joins the supported
   set here). Last, declare the shape, landed with the phone's migration. Requirements found reviewing step 1, for the schema
   files and the compiler written here:
   - `linkTarget`'s schema and the compiler's check of a link against the
     module it is in agree: a same-module `{ section }` inside a book is a
     book section; `module` without `kind` is refused.
   - The projection carries `footnote_refs` as well as `annotations`,
     rebased into the joined text; for a source-tracked entry given
     `blocks`, the cited notes are collected from the blocks' own
     `footnote_refs` and attached to that entry's row, as they are from its
     `content` today (`CommentaryModuleCompiler.swift:308-324`, `:371-375`). Units without a source order are ordered by `sv`, an
   outline heading before a note at the same `sv`: today a chapter's
   sections, pericopae and verses are written array by array, so a section
   at 1:20 is ordered before the note on 1:2. A source-tracked commentary
   keeps its printed order, which may return to an earlier passage
   (`compilesSourceOrderedCommentaryBlocksAndScopedNotes`; found by Codex).
5. Book compiler: figure projection, search keys.
6. Core readers: blocks, media, front matter, front-matter search, link
   resolution.
7. `CommentaryMedia/` kind with the Lean tables, agreed with both apps
   **before any file is written under it**. The Mac's engine keys folder
   listings by name and every synced kind needs explicit membership, or a
   deletion resurrects and a stray copy not named for its ID shadows the real
   one (lamp-bible-macos-bd, via the converter's session). The converter
   uploads nothing under `CommentaryMedia/` or `BookMedia/` for the study
   Bible until the kind is agreed.
8. Docs and hand-off.

Follow-up for the modules repository, after step 5: the Python bundler walks
`rows` and `cells` itself (`bundle_book_modules.py`, `extract_plain_text`), in
array order on any block, so a bundled book and the same book imported keep
different search text. It should take a section's search text from core.

**Translation knock-on.** Footnotes now need `link` (a translation footnote
links to a book section). A phone build before iOS 22b59eb loses every
footnote on a verse at one unknown annotation type; by D8 those builds are not
served, so `smallcaps` and `link` go in the footnote's `annotations`.

## Verified

Checked in the code before this was written:

- Book media refuses IDs held as another kind
  (`LampBookMediaFiles.swift:248-257`, `:280-292`).
- `JSONSupport.plainText` walks `rows` but not `cells` (`JSONSupport.swift:81-85`);
  book rows are `{cells: [...]}` (`book_schema.json`), so cell text is unsearched.
- An unknown `emphasis` style is drawn italic (`LampBookText.swift`, the
  resolver's `emphasis` case); `link` with `data.url` already exists there.
- `rowSpan` is decoded (`LampBookModels.swift:209-247`) and used nowhere else.
- Unit IDs embed the order index (`CommentaryModuleCompiler.swift:291`).
- The phone decodes verse annotations as a closed enum through `try?`, so one
  unknown type loses the verse's array (iOS `ModuleModels.swift:2244-2252`, `:2651-2653`).
- The phone copies only the columns its own table holds (iOS
  `ModuleSyncManager.swift:508-514`), so new columns are dropped, not fatal.
- The import check requires only today's commentary columns
  (`LampPortableModuleInspector.swift:328-358`).
- There is no bundled cross-references table; `cross_references_json` exists
  only on quiz questions.
