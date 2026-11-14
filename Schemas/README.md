# Bible Module Schemas

This directory contains JSON schemas for Bible study modules used by the Lamp Bible app.

`lamp-module inspect` runs lamp-bible-core's own checks of module JSON, which follow these schemas and add what JSON Schema can't express (BBCCCVVV consistency, duplicate keys, spans), and `lamp-module build` compiles it into a `.lamp`. The two commentary examples here are checked and compiled by the test suite.

## Overview

| Schema | Purpose | Examples |
|--------|---------|----------|
| `translation_schema.json` | Bible translations | KJV, BSB, ESV, NIV |
| `lexicon_schema.json` | Dictionaries and lexicons | Strong's, BDB, WSD, ISBE |
| `lexicon_mapping_schema.json` | Cross-lexicon mappings | Strong's → BDB |
| `commentary_schema.json` | Verse-keyed commentaries (per book) | NICNT Matthew, NICOT Genesis |
| `commentary_series_schema.json` | Commentary series metadata | NICNT, NICOT, WBC |
| `notes_schema.json` | User Bible notes (verse-keyed) | Personal study notes |
| `devotional_schema.json` | Longer-form content (not verse-keyed) | Sermons, devotionals, reflections |
| `book_schema.json` | Hierarchical long-form publications | Study books, monographs, reference works |
| `highlight_schema.json` | Verse highlights (translation-specific) | User highlights |
| `plan_schema.json` | Bible reading plans | Bible Companion, M'Cheyne |

All schemas share common definitions for annotations, verse references and metadata; notes, devotionals and books also share media references.

**Schema Versions:**
- Commentary: v2.2 (source-ordered blocks, published-volume provenance)
- Lexicon: v2.1 (dictionaries only)
- Notes: v1.1 (adds media support)
- Devotional: v1.1 (adds media support)
- Book: v1.0

---

## Translation Schema

The translation schema supports Bible translations with offset-based annotations for Strong's numbers, morphology, footnotes, and formatting.

### Structure

```
Module (one file per translation)
├── meta                        # Translation metadata
│   ├── id                      # Unique identifier (e.g., "KJV", "BSBs")
│   ├── type                    # "translation"
│   ├── name                    # Display name (e.g., "King James Version")
│   ├── abbreviation            # Short code (e.g., "KJV")
│   ├── language                # ISO code (e.g., "en")
│   ├── textDirection           # "ltr" or "rtl"
│   ├── translationPhilosophy   # "formal", "dynamic", "optimal", "literal"
│   ├── features                # Feature flags (strongs, morphology, etc.)
│   ├── versification           # "standard", "kjv", "vulgate", or a Paratext code
│   └── versificationMappings   # Verses placed differently from it, e.g. "ROM 14:24-26 = ROM 16:25-27"
│
└── books[]                     # Bible books
    └── Book
        ├── id                  # Abbreviation (e.g., "Gen", "Matt")
        ├── name                # Full name (e.g., "Genesis")
        ├── number              # Canonical number (1-66)
        ├── testament           # "OT" or "NT"
        └── chapters[]
            └── Chapter
                ├── chapter         # Chapter number
                ├── headings[]      # Section headings
                │   └── { text, beforeVerse, level }
                └── verses[]
                    └── Verse
                        ├── v           # Verse number
                        ├── ref         # BBCCCVVV reference
                        ├── content     # Text with annotations
                        ├── footnotes[] # Verse footnotes
                        ├── paragraph   # Paragraph start marker
                        └── poetry      # Poetry formatting
```

### Verse Content

Verse content is an annotated text object:

```json
{
  "v": 1,
  "ref": 1001001,
  "content": {
    "text": "In the beginning God created the heaven and the earth.",
    "annotations": [
      {
        "type": "strongs",
        "start": 0,
        "end": 2,
        "text": "In",
        "data": { "strongs": "H7225", "morphology": "Ncfsa" }
      },
      {
        "type": "strongs",
        "start": 17,
        "end": 20,
        "text": "God",
        "data": { "strongs": "H430", "lemma": "אֱלֹהִים" }
      }
    ]
  },
  "paragraph": true
}
```

### Annotation Types

| Type | Description | Data Fields |
|------|-------------|-------------|
| `strongs` | Strong's number link | `strongs`, `morphology`, `lemma` |
| `footnote` | Footnote marker | `id` |
| `red-letter` | Words of Jesus | - |
| `added` | Added/implied words (italics) | - |
| `divine-name` | Divine name (LORD) | - |
| `selah` | Selah marker | - |
| `variant` | Textual variant | `reading`, `witnesses` |

### Section Headings

Headings are stored separately from verse text and reference which verse they precede:

```json
{
  "chapter": 1,
  "headings": [
    { "text": "Psalms 1–41", "beforeVerse": 1, "level": 1 },
    { "text": "The Two Paths", "beforeVerse": 1, "level": 2 }
  ],
  "verses": [...]
}
```

### Translation ID Conventions

- Strong's-enabled translations use an 's' suffix: `KJVs`, `BSBs`, `ASVs`, `WEBs`
- Non-Strong's translations use plain IDs: `NIV`, `ESV`, `YLT`, `BBE`

---

## Lexicon Schema

The lexicon schema supports Bible dictionaries, Greek/Hebrew lexicons, and word study resources.

### Structure

```
Module
├── meta                        # Module metadata
│   ├── id                      # Unique identifier (e.g., "strongs_greek")
│   ├── type                    # "dictionary"
│   ├── name                    # Display name
│   ├── keyType                 # Key format: "strongs-hebrew", "strongs-greek", "bdb", etc.
│   └── language                # "hebrew", "greek", "english"
│
└── entries[]                   # Dictionary entries
    └── Entry
        ├── key                 # Lookup key (e.g., "H1234", "G5678", "BDB123")
        ├── lemma               # Hebrew/Greek word form
        ├── transliteration     # Romanized form
        ├── pronunciation       # Pronunciation guide
        └── senses[]            # Different meanings/usages
            └── Sense
                ├── id                  # Sense number (1, 2, 3...)
                ├── partOfSpeech        # Grammatical category
                ├── shortDefinition     # Brief gloss
                ├── definition          # Full definition (string or annotatedText)
                ├── derivation          # Etymology
                ├── gloss               # One-word translation
                ├── usage               # Usage notes
                ├── references[]        # Bible verses where this sense occurs
                │   └── { sv, ev? }     # Verse refs in BBCCCVVV format
                ├── septuagintHebrew[]  # Hebrew words the Septuagint renders with this word
                │   └── { text, stem?, strongs? }
                └── translationUsages[] # How word is translated in Bible versions
                    └── { version, translations[] }
                        └── { word, count? }
```

### Entry Example

```json
{
  "key": "G26",
  "lemma": "ἀγάπη",
  "transliteration": "agape",
  "pronunciation": "ag-ah'-pay",
  "senses": [{
    "id": 1,
    "partOfSpeech": "noun",
    "definition": "love, i.e. affection or benevolence; specially a love-feast",
    "derivation": "from G25",
    "translationUsages": [{
      "version": "KJV",
      "translations": [
        {"word": "love", "count": 86},
        {"word": "charity", "count": 27},
        {"word": "dear", "count": 1}
      ]
    }],
    "references": [
      {"sv": 40024012},
      {"sv": 45005005, "ev": 45005008}
    ]
  }]
}
```

### Annotations

Text fields can be plain strings or `annotatedText` objects with inline annotations:

```json
{
  "text": "See also logos (G3056) in John 1:1",
  "annotations": [
    {
      "type": "strongs",
      "start": 16,
      "end": 21,
      "text": "G3056",
      "data": { "strongs": "G3056" }
    },
    {
      "type": "scripture",
      "start": 26,
      "end": 34,
      "text": "John 1:1",
      "data": { "sv": 43001001 }
    }
  ]
}
```

**Annotation Types:**
- `scripture` - Bible verse reference
- `strongs` - Strong's number reference
- `greek` / `hebrew` - Original language word
- `footnote` - Footnote marker
- `crossref` - Cross-reference to another entry
- `lexicon-ref` - Reference to another lexicon entry
- `abbrev` - Abbreviation with expansion
- `page` - Page number reference

---

## Lexicon Mapping Schema

The lexicon mapping schema enables cross-referencing between different lexicons (e.g., linking Strong's numbers to BDB entries).

### Structure

```
Mapping
├── meta                        # Mapping metadata
│   ├── schemaVersion           # "1.0"
│   ├── id                      # Unique identifier (e.g., "strongs_hebrew_to_bdb")
│   ├── type                    # "lexicon-mapping"
│   ├── name                    # Human-readable name
│   ├── description             # Purpose description
│   ├── source                  # Source lexicon keyType (e.g., "strongs-hebrew")
│   └── target                  # Target lexicon keyType (e.g., "bdb")
│
└── mappings                    # Map of source keys to target key arrays
    └── { "H1234": ["BDB123", "BDB124"], ... }
```

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "strongs_hebrew_to_bdb",
    "type": "lexicon-mapping",
    "name": "Strong's Hebrew to BDB",
    "description": "Maps Strong's Hebrew numbers to BDB entry keys",
    "source": "strongs-hebrew",
    "target": "bdb"
  },
  "mappings": {
    "H1": ["BDB1"],
    "H2": ["BDB2", "BDB3"],
    "H430": ["BDB42", "BDB43"]
  }
}
```

### Use Cases

- **One-to-many mappings**: A single Strong's number may map to multiple BDB entries when the Hebrew word has distinct meanings
- **Lexicon chaining**: Follow references from translation → Strong's → BDB → TWOT
- **Reverse lookups**: Generate inverse mappings programmatically

---

## Commentary Schema

The commentary schema supports structured verse-keyed commentaries with hierarchical organization.

### Structure

```
Module
├── meta                        # Module metadata
│   ├── id                      # Unique identifier (e.g., "NIC_Matt")
│   ├── type                    # "commentary"
│   ├── seriesAbbrev            # Series abbreviation (e.g., "NICNT")
│   ├── seriesFull              # Full series name
│   ├── title                   # Volume title (or `name`; one is required)
│   ├── description             # Module description
│   └── author, editor, publisher, year
│
├── book                        # Bible book abbreviation (e.g., "Matt")
├── bookNumber                  # Canonical book number (1-66)
│
├── abbreviations[]             # Abbreviations used in this volume
│
├── frontMatter                 # Front matter content
│   ├── dedication
│   ├── editorPreface
│   ├── authorPreface
│   ├── introduction
│   └── bibliography[]
│
├── sourceVolumes[]             # Published-volume details, checked at build time; not stored
│
├── chapters[]                  # Chapter commentaries
│   └── Chapter
│       ├── chapter             # Chapter number
│       ├── introduction        # Chapter introduction
│       │
│       │   # OPTION A: Hierarchical with sections
│       ├── sections[]
│       │   └── Section
│       │       ├── title       # "I. The Coming of the Messiah"
│       │       ├── level       # Nesting depth (1=top, 2=sub, etc.)
│       │       ├── sv, ev      # Verse range
│       │       ├── introduction
│       │       ├── subsections[]   # Nested sections
│       │       └── pericopae[]     # Passage units
│       │
│       │   # OPTION B: Flat with pericopae only
│       ├── pericopae[]
│       │   └── Pericope
│       │       ├── id          # "1:1-17"
│       │       ├── title       # "The Genealogy of Jesus Christ"
│       │       ├── sv, ev      # Verse range
│       │       ├── introduction
│       │       ├── translation # Author's translation of passage
│       │       ├── verses[]    # Individual verse commentary
│       │       └── footnotes[]
│       │
│       │   # OPTION C: Simple verse-by-verse
│       └── verses[]
│           └── Verse
│               ├── sv          # Verse ref (BBCCCVVV)
│               ├── ev          # End verse (for ranges)
│               ├── suffix      # Partial verse ("a", "b")
│               ├── translation # Verse translation
│               ├── commentary  # Commentary text
│               └── footnotes[]
│
└── indices                     # Optional lookup indices
    ├── subjects
    ├── authors
    ├── scriptures
    ├── greekWords
    └── hebrewWords
```

### Hierarchy Visual

```
Chapter 1
│
├── Section: "I. The Coming of the Messiah (1:1-2:23)"
│   │
│   ├── Pericope: "The Genealogy of Jesus Christ (1:1-17)"
│   │   ├── Introduction: "Matthew begins with a genealogy..."
│   │   ├── Translation: "The book of the genealogy..."
│   │   └── Verses:
│   │       ├── 1:1  → "The phrase 'son of David' emphasizes..."
│   │       ├── 1:2  → "Abraham was chosen by God..."
│   │       └── ...
│   │
│   └── Pericope: "The Birth of Jesus Christ (1:18-25)"
│       └── ...
│
└── Section: "II. The Early Years (3:1-4:25)"
    └── ...
```

### Pericope vs Verse

| Concept | Description | Example |
|---------|-------------|---------|
| **Pericope** | A passage unit covering multiple verses | "1:1-17", "The Genealogy" |
| **Verse** | Commentary on a single verse (or partial verse) | "1:1", "1:1a" |

**Pericopae** group verses into logical units that commentators discuss together. They typically have:
- A descriptive title
- An introduction discussing the passage as a whole
- Sometimes the author's translation of the full passage
- Then verse-by-verse commentary

**Verses** contain the actual commentary text for individual verses. The `suffix` field handles partial verses (e.g., "1:1a" and "1:1b").

### Chapter Example

```json
{
  "chapter": 1,
  "introduction": { "text": "Matthew's Gospel opens with..." },
  "sections": [{
    "id": "I",
    "title": "I. The Coming of the Messiah (1:1-2:23)",
    "level": 1,
    "sv": 40001001,
    "ev": 40002023,
    "pericopae": [{
      "id": "1:1-17",
      "title": "The Genealogy of Jesus Christ",
      "sv": 40001001,
      "ev": 40001017,
      "introduction": {
        "text": "Matthew begins with a genealogy to establish Jesus' credentials..."
      },
      "verses": [
        {
          "sv": 40001001,
          "translation": { "text": "The book of the genealogy of Jesus Christ..." },
          "commentary": { "text": "The phrase 'son of David' emphasizes Jesus' royal lineage..." }
        },
        {
          "sv": 40001002,
          "commentary": { "text": "Abraham was the father of Isaac..." }
        }
      ],
      "footnotes": [
        { "id": "1", "content": { "text": "See also Luke 3:23-38 for..." } }
      ]
    }]
  }]
}
```

---

## Commentary Series Schema

The commentary series schema provides top-level metadata for commentary series that spans multiple book volumes. Since commentaries are stored per-book, this schema captures series-level information like editor prefaces, shared abbreviations, and bibliographies.

### Structure

```
Series
├── meta                        # Series metadata
│   ├── id                      # Unique series ID (e.g., "NICNT", "WBC")
│   ├── type                    # "commentary-series"
│   ├── name                    # Full series name
│   ├── abbreviation            # Short form (e.g., "NICNT")
│   ├── description             # Series description
│   ├── editor                  # Series editor(s)
│   ├── publisher               # Publisher name
│   ├── testament               # "OT", "NT", or "both"
│   ├── language                # Primary language
│   └── website                 # Publisher/series website
│
├── editorPreface               # General editor's preface (annotatedText)
├── introduction                # "About this Series" content (annotatedText)
│
├── abbreviations[]             # Shared abbreviations across all volumes
│   └── { abbrev, expansion, category }
│
├── bibliography[]              # Shared bibliography/resources
│   └── { subsection, content }
│
└── volumes[]                   # List of volumes in the series (informational)
    └── VolumeInfo
        ├── id                  # Volume ID (e.g., "NICNT_Matt")
        ├── book                # Bible book abbreviation
        ├── bookNumber          # Canonical book number (1-66)
        ├── title               # Volume title
        ├── author              # Volume author
        ├── year                # Publication year
        └── edition             # Edition info
```

### Series vs Book Commentary

| Scope | Series Schema | Book Schema |
|-------|---------------|-------------|
| Coverage | Entire series | Single Bible book |
| Metadata | Series editor, publisher | Volume author, title |
| Abbreviations | Shared across series | Volume-specific additions |
| Bibliography | Common resources | Volume-specific citations |
| Content | No verse content | Full commentary text |

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "NICNT",
    "type": "commentary-series",
    "name": "New International Commentary on the New Testament",
    "abbreviation": "NICNT",
    "description": "A scholarly evangelical commentary series...",
    "editor": "Gordon D. Fee",
    "publisher": "Eerdmans",
    "testament": "NT",
    "language": "english"
  },
  "editorPreface": {
    "text": "The New International Commentary on the New Testament..."
  },
  "abbreviations": [
    { "abbrev": "BDAG", "expansion": "Bauer, Danker, Arndt, Gingrich", "category": "publication" },
    { "abbrev": "LXX", "expansion": "Septuagint", "category": "bible" }
  ],
  "bibliography": [
    {
      "subsection": "Reference Works",
      "content": { "text": "BDAG. A Greek-English Lexicon of the New Testament..." }
    }
  ],
  "volumes": [
    { "book": "Matt", "bookNumber": 40, "title": "The Gospel of Matthew", "author": "R.T. France", "year": 2007 },
    { "book": "Mark", "bookNumber": 41, "title": "The Gospel of Mark", "author": "William L. Lane", "year": 1974 }
  ]
}
```

---

## Notes Schema

The notes schema is a simplified subset of the commentary schema, optimized for personal note-taking with markdown import/export support. Notes are **verse-keyed** (tied to specific Bible passages).

### Structure

```
Module (one file per book)
├── meta                        # Module metadata
│   ├── id                      # Unique identifier (e.g., "user_notes")
│   ├── type                    # "notes"
│   ├── name                    # Display name (e.g., "My Bible Notes")
│   ├── author                  # Note author's name
│   └── schemaVersion           # Schema version (1.0)
│
├── book                        # Bible book abbreviation (e.g., "Matt")
├── bookNumber                  # Canonical book number (1-66)
│
└── chapters[]                  # Chapter notes
    └── ChapterNotes
        ├── chapter             # Chapter number
        ├── introduction        # Chapter-level notes (string or annotatedText)
        ├── footnotes[]         # Chapter-level footnotes
        └── verses[]            # Verse notes
            └── VerseNote
                ├── sv              # Start verse (BBCCCVVV)
                ├── ev              # End verse for ranges (optional)
                ├── commentary      # Note content (string or annotatedText)
                ├── footnotes[]     # Verse-level footnotes
                └── lastModified    # Unix timestamp
```

### Notes vs Commentary vs Devotional

| Feature | Notes | Commentary | Devotional |
|---------|-------|------------|------------|
| Verse-keyed | Yes | Yes | No |
| Complexity | Simple flat structure | Hierarchical (sections/pericopae) | Block-based |
| Scope | User notes | Published commentaries | Standalone content |
| Editing | In-app editable | Read-only | In-app editable |
| Export | Markdown round-trip | N/A | Markdown round-trip |
| One file per | Book | Book | Devotional |

### Markdown Format

Notes can be exported to and imported from markdown for editing and backup. Import/export is handled directly by the iOS app.

```markdown
---
id: user_notes
type: notes
name: "My Bible Notes"
author: "John Doe"
book: Matt
bookNumber: 40
---

# Matthew

## Chapter 1

### General Notes

Chapter-level notes about Matthew chapter 1...

### 1:1

The genealogy begins with Abraham[^1:1-1], establishing Jesus' Jewish heritage.

[^1:1-1]: See also Luke 3:23-38 for a different genealogy.

### 1:2-4

Notes covering a verse range with multiple footnotes[^1:2-1] and references[^1:2-2].

[^1:2-1]: First footnote for this range.
[^1:2-2]: Second footnote for this range.
```

**Single-file format** (all books in one file):

```markdown
[^Gen-1:30-1]: Footnote includes book abbreviation for uniqueness.
```

**Format Features:**

- YAML frontmatter preserves metadata
- `## Chapter N` headings organize by chapter
- `### General Notes` for chapter-level notes
- `### 1:1` or `### 1:2-5` for verse notes
- Footnote format: `[^chapter:verse-number]` (file-per-book) or `[^Book-chapter:verse-number]` (single file)
- Standard markdown footnote syntax: `[^id]` inline, `[^id]: text` definition

---

## Devotional Schema

The devotional schema supports longer-form content like sermons, devotionals, and reflections. Unlike notes and commentaries, devotionals are **not verse-keyed** - they are standalone documents that may reference scripture but are not organized by Bible passage.

### Key Features

- **Block-based content**: Supports paragraphs, lists (bullet and numbered), blockquotes, and headings
- **User-editable**: Designed for in-app creation and editing
- **Markdown export**: Full round-trip support for external editing
- **Tagging and filtering**: Date field and tags for organization
- **Rich annotations**: Scripture references, Strong's numbers, links, emphasis

### Structure

```
Devotional
├── meta                        # Devotional metadata
│   ├── schemaVersion           # "1.0"
│   ├── id                      # Unique identifier (UUID recommended)
│   ├── type                    # "devotional"
│   ├── title                   # Devotional title
│   ├── subtitle                # Optional subtitle
│   ├── author                  # Author name
│   ├── date                    # User-entered date (YYYY-MM-DD)
│   ├── tags[]                  # User-defined tags for filtering
│   ├── category                # One kind, open vocabulary, stored as written and compared
│   │                           # without case; suggested: devotional, exhortation, reflection,
│   │                           # study, prayer (any case takes that spelling); "sermon" reads as exhortation
│   ├── series                  # Optional series info
│   │   └── { id, name, order }
│   ├── keyScriptures[]         # Primary scripture references
│   │   └── { sv, ev?, label }
│   ├── created                 # Unix timestamp
│   └── lastModified            # Unix timestamp
│
├── summary                     # Brief summary (string or annotatedText)
│
├── content                     # Main content (two formats)
│   │
│   │   # OPTION A: Flat array of content blocks
│   └── contentBlock[]
│       └── { type, content, level?, listType?, items[] }
│   │
│   │   # OPTION B: Structured with sections
│   └── { introduction[], sections[], conclusion[] }
│       └── Section
│           ├── id, level, title
│           ├── blocks[]        # Content blocks
│           └── subsections[]   # Nested sections
│
├── footnotes[]                 # Document-level footnotes
│   └── { id, content }
│
└── relatedDevotionals[]        # IDs of related devotionals
```

### Content Blocks

Content is organized into blocks, each with a specific type:

| Block Type | Description | Fields |
|------------|-------------|--------|
| `paragraph` | Regular paragraph | `content` (annotatedText) |
| `heading` | Inline heading | `content`, `level` (1-6) |
| `list` | Bullet or numbered list | `listType`, `items[]` |
| `blockquote` | Quote block | `content` |

### List Structure

Lists support nesting for complex outlines:

```json
{
  "type": "list",
  "listType": "numbered",
  "items": [
    {
      "content": { "text": "First point about John 3:16", "annotations": [...] }
    },
    {
      "content": { "text": "Second point with sub-items" },
      "children": [
        { "content": { "text": "Sub-point A" } },
        { "content": { "text": "Sub-point B" } }
      ]
    },
    {
      "content": { "text": "Third point" }
    }
  ]
}
```

Maps to markdown:
```markdown
1. First point about John 3:16
2. Second point with sub-items
   - Sub-point A
   - Sub-point B
3. Third point
```

### Annotation Types

| Type | Description | Data Fields |
|------|-------------|-------------|
| `scripture` | Bible verse reference | `sv`, `ev`, `refs[]` |
| `strongs` | Strong's number | `strongs` |
| `greek` | Greek word | - |
| `hebrew` | Hebrew word | - |
| `link` | External URL | `url` |
| `emphasis` | Text styling | `style` (bold/italic/underline) |
| `quote` | Quote attribution | `source` |

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "type": "devotional",
    "title": "The Meaning of Grace",
    "author": "John Smith",
    "date": "2024-01-15",
    "tags": ["grace", "salvation", "gospel"],
    "category": "devotional",
    "keyScriptures": [
      { "sv": 49002008, "ev": 49002009, "label": "Ephesians 2:8-9" }
    ],
    "created": 1705312800,
    "lastModified": 1705312800
  },
  "summary": "An exploration of God's grace as described in Ephesians 2.",
  "content": [
    {
      "type": "paragraph",
      "content": {
        "text": "Grace is one of the most beautiful words in Scripture...",
        "annotations": []
      }
    },
    {
      "type": "heading",
      "level": 2,
      "content": { "text": "What is Grace?" }
    },
    {
      "type": "paragraph",
      "content": {
        "text": "Paul tells us in Ephesians 2:8-9 that we are saved by grace through faith.",
        "annotations": [
          {
            "type": "scripture",
            "start": 17,
            "end": 32,
            "text": "Ephesians 2:8-9",
            "data": { "sv": 49002008, "ev": 49002009 }
          }
        ]
      }
    },
    {
      "type": "list",
      "listType": "bullet",
      "items": [
        { "content": { "text": "Grace is unmerited favor" } },
        { "content": { "text": "Grace cannot be earned" } },
        { "content": { "text": "Grace is a gift from God" } }
      ]
    }
  ],
  "footnotes": []
}
```

### Markdown Export Format

```markdown
---
id: 550e8400-e29b-41d4-a716-446655440000
type: devotional
title: "The Meaning of Grace"
author: "John Smith"
date: 2024-01-15
tags: [grace, salvation, gospel]
category: devotional
keyScriptures:
  - ref: "Ephesians 2:8-9"
    sv: 49002008
    ev: 49002009
---

Grace is one of the most beautiful words in Scripture...

## What is Grace?

Paul tells us in [Ephesians 2:8-9] that we are saved by grace through faith.

- Grace is unmerited favor
- Grace cannot be earned
- Grace is a gift from God
```

---

## Book Schema

The book schema represents a complete long-form publication in one module. It
is distinct from the 66 canonical books of the Bible and
from devotionals, which are single standalone documents. A book can contain
front matter, parts, chapters, nested sections, appendices, and back matter.

### Structure

```
Book
├── meta                        # Publication and module metadata
│   ├── schemaVersion           # "1.0"
│   ├── id                      # Unique module identifier
│   ├── type                    # "book"
│   ├── title, subtitle
│   ├── author, editor
│   ├── publisher, year, edition, isbn
│   ├── language                # BCP 47 language tag
│   ├── textDirection           # "ltr" or "rtl"
│   ├── copyright, license
│   ├── tags[]
│   └── coverMediaId            # Optional reference into media[]
│
├── sections[]                  # Ordered, recursive publication structure
│   └── Section
│       ├── id                  # Unique within the book
│       ├── type                # front-matter, part, chapter, section,
│       │                       # appendix, back-matter, or other
│       ├── number              # Optional displayed number/label
│       ├── title, subtitle
│       ├── order               # Optional explicit sibling order
│       ├── keyScriptures[]     # Optional { sv, ev?, label } references
│       ├── content[]           # Paragraph/list/quote/heading/table/media blocks
│       └── sections[]          # Nested sections
│
├── footnotes[]                 # Book-wide footnote definitions
└── media[]                     # Images/audio referenced by ID
```

Each section must have content or child sections. Section IDs only need to be
unique within their module; the bundler namespaces them when writing SQLite.
Array order is authoritative unless a section supplies an explicit `order`.

Annotation `start`/`end` and `footnote_refs[].offset` are Unicode scalar
(code point) offsets into `text`: Python `str` indices, not UTF-16 units,
bytes, or grapheme clusters. A Hebrew word with vowel points therefore counts
each point.

A `page` annotation marks where a printed page begins. Its `pageNum` is the
page number printed in the source: an integer, or a lower-case roman numeral
string such as `"xiv"` for front matter. An unnumbered page between numbered
ones takes its place in their sequence. A page outside any printed sequence,
as in a source without printed page numbers, has no `page` annotation.

Tables use a semantic grid rather than flattened display text. A table block
contains `columnCount` and ordered `rows`; each row contains cells with
annotated `content`, a zero-based `column`, optional `header`, and optional
`colSpan`/`rowSpan`. Empty and spanning cells therefore retain the source
layout, while scripture and footnote annotations remain attached to the text
inside each cell.

```json
{
  "type": "table",
  "columnCount": 2,
  "rows": [
    {
      "cells": [
        {
          "content": { "text": "Prophecy" },
          "column": 0,
          "header": true,
          "colSpan": 2
        }
      ]
    },
    {
      "cells": [
        { "content": { "text": "Daniel 2" }, "column": 0 },
        { "content": { "text": "Irenaeus" }, "column": 1 }
      ]
    }
  ]
}
```

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "example-study-book",
    "type": "book",
    "title": "An Example Study Book",
    "author": "Example Author",
    "language": "en"
  },
  "sections": [
    {
      "id": "part-1",
      "type": "part",
      "title": "Part One",
      "sections": [
        {
          "id": "chapter-1",
          "type": "chapter",
          "number": 1,
          "title": "Beginnings",
          "keyScriptures": [
            { "sv": 1001001, "ev": 1001003, "label": "Genesis 1:1-3" }
          ],
          "content": [
            {
              "type": "paragraph",
              "content": {
                "text": "The opening words point us to Genesis 1:1.",
                "annotations": [
                  {
                    "type": "scripture",
                    "start": 30,
                    "end": 41,
                    "data": { "sv": 1001001 }
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
```

### In a compiled module

The SQLite representation uses `book_modules`, `book_sections`, and
`book_sections_fts`. Nested sections are flattened with `parent_id`, `depth`,
and `order_index`, while each section's rich content remains JSON.

---

## Highlight Schema

The highlight schema stores user verse highlights. Each file is associated with a specific translation, since character offsets depend on the exact verse text.

### Structure

```
Highlights
├── meta                        # Highlight file metadata
│   ├── schemaVersion           # "1.0"
│   ├── id                      # Unique identifier
│   ├── type                    # "highlights"
│   ├── name                    # Display name (e.g., "My Highlights")
│   ├── description             # Optional description
│   ├── translationId           # Associated translation (e.g., "ESV", "BSBs")
│   ├── created                 # Unix timestamp
│   └── lastModified            # Unix timestamp
│
└── verses[]                    # Verses with highlights
    └── VerseHighlights
        ├── ref                 # Verse reference (BBCCCVVV)
        └── highlights[]        # Array of highlight spans
            └── Highlight
                ├── sc          # Start character offset (0-indexed)
                ├── ec          # End character offset (exclusive)
                ├── style       # Style ID (maps to app-defined colors)
                └── color       # Optional color hint for import/export
```

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "my_highlights_esv",
    "type": "highlights",
    "name": "My Highlights",
    "translationId": "ESV",
    "created": 1705312800,
    "lastModified": 1705312800
  },
  "verses": [
    {
      "ref": 43003016,
      "highlights": [
        { "sc": 0, "ec": 16, "style": 0, "color": "yellow" },
        { "sc": 24, "ec": 35, "style": 1, "color": "blue" }
      ]
    },
    {
      "ref": 45008028,
      "highlights": [
        { "sc": 0, "ec": 52, "style": 0, "color": "yellow" }
      ]
    }
  ]
}
```

In this example for John 3:16 ("For God so loved the world..."):
- First highlight: characters 0-16 ("For God so loved") - yellow (style 0)
- Second highlight: characters 24-35 ("gave his only") - blue (style 1)

### Styles and Colors

- `style` (required): Integer ID that maps to app-defined highlight styles
- `color` (optional): Color hint for import/export portability

The app defines what each style ID means (color, underline, etc.). The `color` field is a hint for when highlights are imported - the app can map it to the closest matching style.

### Translation Association

Highlights are tied to a specific translation because:
- Character offsets depend on exact verse text
- Different translations have different word counts and positions
- Importing highlights to a different translation would require remapping

When exporting/importing highlights, the `translationId` must match.

---

## Plan Schema

The plan schema supports Bible reading plans, organizing daily reading assignments across a full year (366 days).

### Structure

```
Plan
├── meta                        # Plan metadata
│   ├── schemaVersion           # "1.0"
│   ├── id                      # Unique identifier (e.g., "bible_companion")
│   ├── type                    # "plan"
│   ├── name                    # Full plan name
│   ├── description             # Brief description
│   ├── author                  # Plan author
│   ├── source                  # Source work or edition
│   ├── license                 # Content licence or public-domain status
│   ├── fullDescription         # Extended description/introduction
│   ├── duration                # Number of days (typically 366)
│   └── readingsPerDay          # Typical readings per day
│
└── days[]                      # Daily reading assignments
    └── PlanDay
        ├── day                 # Day number (1-366)
        └── readings[]          # Reading assignments
            └── Reading
                ├── sv          # Start verse (BBCCCVVV)
                └── ev          # End verse (BBCCCVVV, use 999 for "end of chapter")
```

### Example

```json
{
  "meta": {
    "schemaVersion": "1.0",
    "id": "bible_companion",
    "type": "plan",
    "name": "Bible Companion",
    "description": "Read through the Bible in one year with OT, NT, and Psalms/Proverbs daily.",
    "author": "Robert Murray M'Cheyne",
    "source": "M'Cheyne Bible reading plan",
    "license": "Public Domain",
    "duration": 366,
    "readingsPerDay": 4
  },
  "days": [
    {
      "day": 1,
      "readings": [
        { "sv": 1001001, "ev": 1001999 },
        { "sv": 40001001, "ev": 40001999 },
        { "sv": 15001001, "ev": 15001006 },
        { "sv": 20001001, "ev": 20001007 }
      ]
    },
    {
      "day": 2,
      "readings": [
        { "sv": 1002001, "ev": 1002999 },
        { "sv": 40002001, "ev": 40002999 },
        { "sv": 15001007, "ev": 15002012 },
        { "sv": 20001008, "ev": 20001019 }
      ]
    }
  ]
}
```

### Verse Reference Convention

- Use `999` for the verse number to indicate "end of chapter"
- Example: `1001999` = Genesis 1 (entire chapter)
- This avoids hardcoding verse counts that may vary by versification

---

## Verse Reference Format (BBCCCVVV)

All verse references use an 8-digit integer format:

```
BBCCCVVV
││└──┴── Verse (001-176)
│└────── Chapter (001-150)
└─────── Book (01-66)
```

**Examples:**
- `01001001` = Genesis 1:1
- `40001001` = Matthew 1:1
- `43003016` = John 3:16
- `66022021` = Revelation 22:21

**Book Numbers:**
- 01-39: Old Testament (Genesis through Malachi)
- 40-66: New Testament (Matthew through Revelation)

**Special Values:**
- Verse `999` = "end of chapter" (used in plans to avoid hardcoding verse counts)

---

## Shared Definitions

Several definitions are shared across multiple schemas:

### annotatedText

Used in: translations, lexicons, commentaries, notes, devotionals

```json
{
  "text": "God's love for the world is the theme of John 3:16.",
  "annotations": [
    {
      "type": "scripture",
      "start": 41,
      "end": 50,
      "text": "John 3:16",
      "data": { "sv": 43003016 }
    }
  ],
  "footnote_refs": [
    { "id": "1", "offset": 51 }
  ]
}
```

### annotation

Common annotation types across schemas:

| Type | Used In | Purpose |
|------|---------|---------|
| `scripture` | All | Bible verse reference |
| `strongs` | All | Strong's number |
| `greek` / `hebrew` | Lexicon, commentary | Original language |
| `footnote` | Translation, commentary | Footnote marker |
| `crossref` | Lexicon, commentary | Cross-reference |
| `lexicon-ref` | Lexicon, commentary | Link to lexicon entry |
| `abbrev` | Commentary | Abbreviation expansion |
| `bold` / `italic` | Commentary | Printed emphasis |
| `link` | Devotional | External URL |
| `emphasis` | Devotional | Bold/italic/underline |
| `quote` | Devotional | Quote attribution |
| `media` | Notes, devotionals, books | Embedded image or audio |

### footnote

```json
{
  "id": "1",
  "content": {
    "text": "Footnote text with optional annotations",
    "annotations": [...]
  }
}
```

### mediaReference

Used in: notes (v1.1+), devotionals (v1.1+), books

Media references allow embedding images and audio files in module content. The files are not part of the JSON or the compiled module; see [Media in compiled modules](#media-in-compiled-modules).

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "type": "image",
  "filename": "fig-1.jpg",
  "mimeType": "image/jpeg",
  "size": 245000,
  "width": 800,
  "height": 600,
  "alt": "Map of ancient Jerusalem",
  "caption": "The city of Jerusalem in the first century",
  "created": 1705312800
}
```

**Image-specific fields:**
- `width`, `height`: Image dimensions in pixels
- `alt`: Alt text for accessibility

**Audio-specific fields:**
- `duration`: Duration in seconds
- `waveform`: Array of normalized samples (0-1) for visualization
- `transcription`: Optional speech-to-text content

### media annotation

Media annotations are used to embed images and audio inline within text:

```json
{
  "type": "media",
  "start": 0,
  "end": 0,
  "data": {
    "mediaId": "550e8400-e29b-41d4-a716-446655440000",
    "mediaType": "image",
    "caption": "Optional caption text",
    "alignment": "center"
  }
}
```

**Data fields for media annotations:**
- `mediaId`: Reference to item in top-level `media` array
- `mediaType`: "image" or "audio"
- `caption`: Optional caption text
- `alignment`: Image alignment ("left", "center", "right", "full")

### Top-level media array

The schemas that support media (notes, devotionals, books) have a top-level `media` array containing all media references used in that module:

```json
{
  "meta": { ... },
  "content": { ... },
  "media": [
    {
      "id": "img-001",
      "type": "image",
      "filename": "diagram.png",
      "mimeType": "image/png",
      "width": 1200,
      "height": 800
    },
    {
      "id": "audio-001",
      "type": "audio",
      "filename": "pronunciation.m4a",
      "mimeType": "audio/mp4",
      "duration": 3.5,
      "waveform": [0.1, 0.3, 0.8, 0.5, 0.2]
    }
  ]
}
```

### Media in compiled modules

A `.lamp` is a single compressed SQLite database (raw DEFLATE, written by `lamp-module build`),
so it carries a module's media references but never the images or audio themselves. The files
travel by their own sync path:

- **Books**: `BookMedia/<module>/<path>`, landing in the app's `Media/Books/<module>/`.
- **Devotionals**: `DevotionalMedia/<module>/<writing>/<file>`.
- **Notes**: `NoteMedia/<module>/<verse>/<file>`.

In the compiled database, devotional content and notes link a file as `![caption](media/<id>)`,
and the matching entries are in `devotional_entries.media_json` and `note_entries.media_json`.
Those folders carry what the reader writes in Lamp. Nothing yet places a published notes
module's files there, so its references reach the app without their images.
