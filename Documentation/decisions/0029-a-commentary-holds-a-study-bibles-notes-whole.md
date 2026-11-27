# 0029. A commentary holds a study Bible's notes whole

Status: Proposed, 2026-11-26. The schema awaits the owner's sign-off; the
first item is in the code (`CommentaryCompiledShapeTests`,
`acommentaryWithTheRicherFormatsAdditionsStillReads`, and
`awordInABookTableIsSearchable` as a known issue). Planned by Fable, with
measurements from the converter; the owner asked for it. The plan and its
order of work are in `../RichModulesPlan.md`.

## Context

A modern study Bible's notes hold maps, charts, illustrations, lists, small
capitals and links to other notes, to introductions and to articles. A
commentary can hold paragraphs with bold, italic, scripture and footnotes, one
Bible book per file, and nothing else. The first source is a study Bible
converted for the owner's personal use: 16,000 notes, 469 objects printed in
them, 364 tables (73 cells spanning rows), 1,183 small-capital runs, about 40
articles and about 300 standalone charts and maps.

## Decision

Verse-keyed content is a commentary; page-read content is a book module; a
reading plan is a plan module. **Links cross modules; content does not**: a
reader never opens a second module to draw the first.

A note's body is the book model's blocks, one model for both kinds, with a
`figure` container for a printed object (title, era, caption, then images,
paragraphs, lists, tables and headings in printed order). Stored beside what
is stored today, never instead of it: `commentary_units.blocks_json`,
`commentary_books.media_json`, and a `commentary_front_matter` table for
introductions, each read only by a reader that knows it. The columns read
today keep a text projection of the same note, so an older app shows its
words. Links are by module kind, declared ID and passage or section, never a
stored row ID. Picture files live outside the module, under a sync folder of
their own.

Owner's calls: introductions are commentary front matter; an object printed
both inline and standalone is stored twice, the second in the book for a
gallery; core compiles commentary series; only phone builds from 2026-11-08 on
need read the new shape.

## Consequences

- An older reader shows a note's words and not its pictures or tables'
  layout, and no introductions.
- The gallery copy puts 220 pictures on the server twice and finds a chart's
  words in both modules.
- Both apps need a front-matter reader, the figure container, the new link
  forms and a commentary media folder: briefs follow the core work.
- Book table cells, in no search text today, will be — from the decoded
  blocks, through the reader's own table layout, so the index cannot show
  what the reader does not.

## Rejected

- **Articles as commentary units with book 0.** `book` and `sv` are
  `NOT NULL`, the phone reads an unknown unit type as a verse, and search
  titles a hit by its verse.
- **Introductions as units, or as blocks inside `front_matter_json`.** An old
  phone lists units across the module and would show them; front matter has
  no index, so a hit could not land on a section.
- **Reusing book media for commentary pictures.** Book media refuses any ID
  another kind of module holds, so a commentary's pictures cannot sit there.
- **Small capitals as an `emphasis` style.** Both older readers draw an
  unknown emphasis style as italic; a new type is ignored instead.
- **Indexing table cells by walking the raw JSON.** Tried first, in this
  record's first item: adding `cells` to `plainText`'s keys. It made a second
  reading of every table beside `LampBookTableLayout`, and four review rounds
  each found another place the two disagreed (order, duplicate columns,
  spans, a missing column, an overflowing span, cells on a block not drawn as
  a table), one of which led a search hit into a table the reader traps on.
  Taken out before it landed.
- **A gallery that refers to the commentary's pictures.** Every book-media
  rule is keyed on the owning book, and removing the commentary would blank
  the gallery.
