import Foundation
import GRDB

extension LampModuleCompiler {
    func compileCommentary(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let bookNumber = try JSONSupport.requiredInteger(root["bookNumber"], path: "/bookNumber")
        let chapters = try JSONSupport.requiredArray(root["chapters"], path: "/chapters")
        let title = try JSONSupport.requiredString(
            JSONSupport.firstValue(in: meta, keys: ["title", "name"]),
            path: "/meta/title"
        )
        let queue = try makeDatabaseQueue(at: databaseURL)
        var builder = CommentaryUnitBuilder(
            moduleID: moduleID,
            bookNumber: bookNumber,
            footnotes: JSONSupport.array(root["footnotes"]) ?? [],
            sourceOrdered: JSONSupport.object(root["extraction"])?["sourceTracked"] as? Bool == true
        )
        try builder.append(chapters: chapters)

        try queue.write { db in
            try createCommentarySchema(in: db)
            try createFormatMetadata(in: db, kind: .commentary, moduleID: moduleID)

            try db.execute(
                sql: """
                    INSERT INTO commentary_books (
                        id, module_id, book_number, series_full, series_abbrev,
                        title, description, author, editor, publisher, year,
                        abbreviations_json, front_matter_json, indices_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "\(moduleID):\(bookNumber)",
                    moduleID,
                    bookNumber,
                    JSONSupport.string(meta["seriesFull"]),
                    JSONSupport.string(meta["seriesAbbrev"]),
                    title,
                    // The schema has asked for a description all along and
                    // nothing stored it, while the series bundler did
                    // (commentary_series_to_sqlite.py), so the two writers
                    // disagreed on a volume's own words about itself.
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["editor"]),
                    JSONSupport.string(meta["publisher"]),
                    JSONSupport.integer(meta["year"]),
                    try JSONSupport.jsonString(root["abbreviations"]),
                    try JSONSupport.jsonString(root["frontMatter"]),
                    try JSONSupport.jsonString(root["indices"]),
                ]
            )

            for row in builder.units {
                try CommentaryUnitTable.insert(row, moduleID: moduleID, book: bookNumber, in: db)
            }
            try db.execute(sql: "INSERT INTO commentary_units_fts(commentary_units_fts) VALUES('rebuild')")
        }

        try optimize(queue)
        return ["commentary_books": 1, "commentary_units": builder.units.count]
    }

    private func createCommentarySchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE commentary_books (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL,
                book_number INTEGER NOT NULL,
                series_full TEXT,
                series_abbrev TEXT,
                title TEXT,
                description TEXT,
                author TEXT,
                editor TEXT,
                publisher TEXT,
                year INTEGER,
                abbreviations_json TEXT,
                front_matter_json TEXT,
                indices_json TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_comm_books_module ON commentary_books(module_id)")
        try db.execute(sql: "CREATE INDEX idx_comm_books_book ON commentary_books(book_number)")
        try db.execute(sql: CommentaryUnitTable.createSQL(withModule: true))
        try db.execute(sql: "CREATE INDEX idx_comm_units_module ON commentary_units(module_id)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_verse ON commentary_units(sv, ev)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_book_chapter ON commentary_units(book, chapter)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_parent ON commentary_units(parent_id)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_type ON commentary_units(unit_type)")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE commentary_units_fts USING fts5(
                title, search_text, footnotes_text,
                content='commentary_units', content_rowid='rowid'
            )
            """)
    }
}

/// A commentary's unit rows as both files hold them — a volume compiled
/// alone, and each volume of a series — in one place, so a column added
/// reaches both: their columns are the same, in the same order, but for the
/// volume's own `module_id`, which a series file leaves to the phone to
/// fill. Written twice, the two had a DDL and an INSERT each (step 4).
/// Each file names its own indexes, the series as its Python writer did.
enum CommentaryUnitTable {
    /// Every column, in order, with its declaration.
    static let columns: [(name: String, declaration: String)] = [
        ("id", "TEXT PRIMARY KEY"),
        ("module_id", "TEXT NOT NULL"),
        ("book", "INTEGER NOT NULL"),
        ("chapter", "INTEGER"),
        ("sv", "INTEGER NOT NULL"),
        ("ev", "INTEGER"),
        ("unit_type", "TEXT NOT NULL"),
        ("level", "INTEGER NOT NULL DEFAULT 1"),
        ("parent_id", "TEXT"),
        ("title", "TEXT"),
        ("suffix", "TEXT"),
        ("introduction_json", "TEXT"),
        ("translation_json", "TEXT"),
        ("commentary_json", "TEXT"),
        ("footnotes_json", "TEXT"),
        ("search_text", "TEXT NOT NULL DEFAULT ''"),
        ("order_index", "INTEGER NOT NULL DEFAULT 0"),
        ("footnotes_text", "TEXT NOT NULL DEFAULT ''"),
    ]

    /// The columns a file holds: a series file's lack only `module_id`.
    static func columns(withModule: Bool) -> [(name: String, declaration: String)] {
        withModule ? columns : columns.filter { $0.name != "module_id" }
    }

    static func createSQL(withModule: Bool) -> String {
        "CREATE TABLE commentary_units (\n"
            + columns(withModule: withModule).map { "    \($0.name) \($0.declaration)" }.joined(separator: ",\n")
            + "\n)"
    }

    /// A row, its module given where the file holds one.
    static func insert(_ row: CommentaryUnitRow, moduleID: String?, book: Int, in db: Database) throws {
        let names = columns(withModule: moduleID != nil).map(\.name)
        let values: [String: DatabaseValueConvertible?] = [
            "id": row.id, "module_id": moduleID, "book": book, "chapter": row.chapter,
            "sv": row.startVerse, "ev": row.endVerse, "unit_type": row.unitType, "level": row.level,
            "parent_id": row.parentID, "title": row.title, "suffix": row.suffix,
            "introduction_json": row.introductionJSON, "translation_json": row.translationJSON,
            "commentary_json": row.commentaryJSON, "footnotes_json": row.footnotesJSON,
            "search_text": row.searchText, "order_index": row.orderIndex, "footnotes_text": row.footnotesText,
        ]
        // Every column given a value, or none is written: a column added
        // here without one is a failure, not a NULL.
        let arguments = try names.map { name -> DatabaseValueConvertible? in
            guard let value = values[name] else {
                throw ModuleCompilationError.invalidValue(path: "commentary_units.\(name)", expected: "a value from the row")
            }
            return value
        }
        try db.execute(
            sql: "INSERT INTO commentary_units (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(arguments)
        )
    }
}

struct CommentaryUnitRow {
    let id: String
    let chapter: Int
    let startVerse: Int
    let endVerse: Int?
    let unitType: String
    let level: Int
    let parentID: String?
    let title: String?
    let suffix: String?
    let introductionJSON: String?
    let translationJSON: String?
    let commentaryJSON: String?
    let footnotesJSON: String?
    let searchText: String
    let footnotesText: String
    let orderIndex: Int
}

struct CommentaryUnitBuilder {
    let moduleID: String
    let bookNumber: Int
    private(set) var units: [CommentaryUnitRow] = []
    private var introducedChapters: Set<Int> = []
    private var orderIndex = 0
    private let footnotesByID: [String: Any]
    /// Each note's place in the document's notes, which is their printed order.
    private let footnoteOrder: [String: Int]
    private let sourceOrdered: Bool

    init(moduleID: String, bookNumber: Int, footnotes: [Any] = [], sourceOrdered: Bool = false) {
        self.moduleID = moduleID
        self.bookNumber = bookNumber
        self.sourceOrdered = sourceOrdered
        var definitions: [String: Any] = [:]
        var order: [String: Int] = [:]
        for (index, value) in footnotes.enumerated() {
            if let note = JSONSupport.object(value), let id = JSONSupport.string(note["id"]) {
                definitions[id] = value
                if order[id] == nil { order[id] = index }
            }
        }
        self.footnotesByID = definitions
        self.footnoteOrder = order
    }

    mutating func append(chapters: [Any]) throws {
        if sourceOrdered {
            var ordered: [(order: Int, chapter: Int, pericope: [String: Any])] = []
            for value in chapters {
                let chapter = try JSONSupport.requiredObject(value, path: "/chapters")
                let number = try JSONSupport.requiredInteger(chapter["chapter"], path: "/chapters/chapter")
                for value in JSONSupport.array(chapter["pericopae"]) ?? [] {
                    let pericope = try JSONSupport.requiredObject(value, path: "/chapters/pericopae")
                    ordered.append((JSONSupport.integer(pericope["sourceOrder"]) ?? ordered.count, number, pericope))
                }
            }
            for item in ordered.sorted(by: { $0.order < $1.order }) {
                try appendPericope(item.pericope, chapter: item.chapter, parentID: nil)
            }
            return
        }
        for (chapterIndex, chapterValue) in chapters.enumerated() {
            let path = "/chapters/\(chapterIndex)"
            let chapter = try JSONSupport.requiredObject(chapterValue, path: path)
            let chapterNumber = try JSONSupport.requiredInteger(chapter["chapter"], path: "\(path)/chapter")

            if let introduction = meaningful(chapter["introduction"]) {
                let title = "Chapter \(chapterNumber) Introduction"
                // A chapter given twice, each with an introduction, keeps the
                // first ID as it was and tells the next apart by its place:
                // the same ID twice stopped the compile. Found by Codex.
                var introductionID = "\(moduleID):\(bookNumber):chapter_intro:\(chapterNumber)"
                if !introducedChapters.insert(chapterNumber).inserted {
                    introductionID += ":\(orderIndex)"
                }
                appendRow(
                    id: introductionID,
                    chapter: chapterNumber,
                    startVerse: defaultStartVerse(chapter: chapterNumber),
                    unitType: "section",
                    level: 0,
                    title: title,
                    introduction: introduction,
                    searchText: makeSearchText(title, introduction, nil, nil)
                )
            }

            for sectionValue in JSONSupport.array(chapter["sections"]) ?? [] {
                let section = try JSONSupport.requiredObject(sectionValue, path: "\(path)/sections")
                try appendSection(section, chapter: chapterNumber, parentID: nil, level: 1)
            }
            for pericopeValue in JSONSupport.array(chapter["pericopae"]) ?? [] {
                let pericope = try JSONSupport.requiredObject(pericopeValue, path: "\(path)/pericopae")
                try appendPericope(pericope, chapter: chapterNumber, parentID: nil)
            }
            for verseValue in JSONSupport.array(chapter["verses"]) ?? [] {
                let verse = try JSONSupport.requiredObject(verseValue, path: "\(path)/verses")
                try appendVerse(
                    verse,
                    chapter: chapterNumber,
                    parentID: nil,
                    parentFootnotes: meaningful(chapter["footnotes"])
                )
            }
        }
    }

    private mutating func appendSection(
        _ section: [String: Any],
        chapter: Int,
        parentID: String?,
        level: Int
    ) throws {
        let id = "\(moduleID):\(bookNumber):section:\(chapter):\(orderIndex)"
        let introduction = meaningful(section["introduction"])
        appendRow(
            id: id,
            chapter: chapter,
            startVerse: JSONSupport.integer(section["sv"]) ?? defaultStartVerse(chapter: chapter),
            endVerse: JSONSupport.integer(section["ev"]),
            unitType: "section",
            level: level,
            parentID: parentID,
            title: JSONSupport.string(section["title"]),
            introduction: introduction,
            searchText: makeSearchText(JSONSupport.string(section["title"]), introduction, nil, nil)
        )

        for subsectionValue in JSONSupport.array(section["subsections"]) ?? [] {
            let subsection = try JSONSupport.requiredObject(subsectionValue, path: "/chapters/sections/subsections")
            try appendSection(subsection, chapter: chapter, parentID: id, level: level + 1)
        }
        for pericopeValue in JSONSupport.array(section["pericopae"]) ?? [] {
            let pericope = try JSONSupport.requiredObject(pericopeValue, path: "/chapters/sections/pericopae")
            try appendPericope(pericope, chapter: chapter, parentID: id)
        }
    }

    private mutating func appendPericope(
        _ pericope: [String: Any],
        chapter: Int,
        parentID: String?
    ) throws {
        let id = "\(moduleID):\(bookNumber):pericope:\(chapter):\(orderIndex)"
        let introduction = meaningful(pericope["introduction"])
        let translation = meaningful(pericope["translation"])
        let scopedNotes = (JSONSupport.array(pericope["footnoteIds"]) ?? []).compactMap { value in
            JSONSupport.string(value).flatMap { footnotesByID[$0] }
        }
        let scopedNotesValue: Any? = scopedNotes.isEmpty ? nil : scopedNotes
        var footnotes = meaningful(pericope["footnotes"]) ?? scopedNotesValue
        // Each block carries the notes it cites, so the passage's own row keeps
        // none of them: repeating them would open every passage with all of
        // its notes. A note no block cites (its marker was lost) goes to the
        // block citing its nearest neighbour in the notes' order, the earlier
        // of two at the same distance, which is where its marker was. Where no
        // block cites anything, the notes go after the passage's last
        // paragraph, where they were printed; only a passage with no
        // paragraph keeps them on its own row.
        var placed: [Int: [Any]] = [:]
        if let content = JSONSupport.array(pericope["content"]), let notes = JSONSupport.array(footnotes) {
            var citing: [String: Int] = [:]
            var neighbours: [String] = []
            var lastText: Int?
            for (index, value) in content.enumerated() {
                guard let block = JSONSupport.object(value), JSONSupport.string(block["type"]) != "index",
                      let text = JSONSupport.object(block["content"]) else { continue }
                let references = JSONSupport.array(text["footnote_refs"]) ?? []
                if JSONSupport.string(block["type"]) != "heading"
                    || !(JSONSupport.array(text["annotations"]) ?? []).isEmpty || !references.isEmpty {
                    lastText = index
                }
                for reference in references {
                    guard let noteID = JSONSupport.object(reference).flatMap({ JSONSupport.string($0["id"]) }),
                          citing[noteID] == nil else { continue }
                    citing[noteID] = index
                    if footnoteOrder[noteID] != nil { neighbours.append(noteID) }
                }
            }
            var kept: [Any] = []
            for note in notes {
                let noteID = JSONSupport.object(note).flatMap { JSONSupport.string($0["id"]) }
                if let noteID, citing[noteID] != nil { continue }
                guard let noteID, let position = footnoteOrder[noteID], !neighbours.isEmpty else {
                    if let lastText { placed[lastText, default: []].append(note) } else { kept.append(note) }
                    continue
                }
                let nearest = neighbours.min { first, second in
                    let a = footnoteOrder[first]!, b = footnoteOrder[second]!
                    let distanceA = abs(a - position), distanceB = abs(b - position)
                    return distanceA != distanceB ? distanceA < distanceB : (a < position && b > position)
                }!
                placed[citing[nearest]!, default: []].append(note)
            }
            footnotes = kept.isEmpty ? nil : kept
        }
        appendRow(
            id: id,
            chapter: chapter,
            startVerse: JSONSupport.integer(pericope["sv"]) ?? defaultStartVerse(chapter: chapter),
            endVerse: JSONSupport.integer(pericope["ev"]),
            unitType: "pericope",
            level: 1,
            parentID: parentID,
            title: JSONSupport.string(pericope["title"]),
            introduction: introduction,
            translation: translation,
            footnotes: footnotes,
            searchText: makeSearchText(JSONSupport.string(pericope["title"]), introduction, translation, nil)
        )

        if let content = JSONSupport.array(pericope["content"]) {
            let parentStart = JSONSupport.integer(pericope["sv"]) ?? defaultStartVerse(chapter: chapter)
            for (index, value) in content.enumerated() {
                let block = try JSONSupport.requiredObject(value, path: "/pericopae/content/\(index)")
                let role = try JSONSupport.requiredString(block["type"], path: "/pericopae/content/type")
                // Printed indexes belong to indices_json, not the last passage.
                if role == "index" { continue }
                let sourceText = try JSONSupport.requiredObject(block["content"], path: "/pericopae/content/content")
                let text = displayContent(sourceText, prefixLength: JSONSupport.integer(block["displayPrefixLength"]) ?? 0)
                let start = JSONSupport.integer(block["sv"]) ?? parentStart
                let end = JSONSupport.integer(block["ev"]) ?? JSONSupport.integer(pericope["ev"])
                let blockChapter = (start / 1_000) % 1_000
                var seenNotes = Set<String>()
                let scoped = (JSONSupport.array(text["footnote_refs"]) ?? []).compactMap { value -> Any? in
                    guard let reference = JSONSupport.object(value), let id = JSONSupport.string(reference["id"]) else { return nil }
                    guard seenNotes.insert(id).inserted else { return nil }
                    return footnotesByID[id]
                }
                let heading = role == "heading"
                    && (JSONSupport.array(text["annotations"]) ?? []).isEmpty
                    && (JSONSupport.array(text["footnote_refs"]) ?? []).isEmpty
                let isTranslation = role == "translation"
                let kind = heading ? "section" : (role == "commentary" && JSONSupport.integer(block["sv"]) != nil ? "verse" : "pericope")
                appendRow(
                    id: "\(moduleID):\(bookNumber):\(kind):\(blockChapter):\(orderIndex)",
                    chapter: blockChapter,
                    startVerse: start,
                    endVerse: end,
                    unitType: kind,
                    level: heading ? 2 : 1,
                    parentID: id,
                    title: heading ? JSONSupport.string(text["text"]) : nil,
                    translation: isTranslation ? text : nil,
                    commentary: !heading && !isTranslation ? text : nil,
                    footnotes: (scoped + (placed[index] ?? [])).isEmpty ? nil : scoped + (placed[index] ?? []),
                    searchText: makeSearchText(heading ? JSONSupport.string(text["text"]) : nil, nil, isTranslation ? text : nil, !heading && !isTranslation ? text : nil)
                )
            }
            return
        }

        for verseValue in JSONSupport.array(pericope["verses"]) ?? [] {
            let verse = try JSONSupport.requiredObject(verseValue, path: "/chapters/pericopae/verses")
            try appendVerse(verse, chapter: chapter, parentID: id, parentFootnotes: footnotes)
        }
    }

    /// Canonical blocks retain printed verse labels for source verification.
    /// The reader projection removes that label, adjusting Python/code-point
    /// offsets (not Swift grapheme-cluster or UTF-16 offsets) at the same time.
    private func displayContent(_ original: [String: Any], prefixLength: Int) -> [String: Any] {
        guard prefixLength > 0, let originalText = JSONSupport.string(original["text"]) else { return original }
        let scalars = Array(originalText.unicodeScalars)
        let trim = min(prefixLength, scalars.count)
        let text = String(String.UnicodeScalarView(scalars.dropFirst(trim)))
        var result = original
        result["text"] = text
        if let annotations = JSONSupport.array(original["annotations"]) {
            result["annotations"] = annotations.compactMap { value -> [String: Any]? in
                guard var annotation = JSONSupport.object(value),
                      let start = JSONSupport.integer(annotation["start"]),
                      let end = JSONSupport.integer(annotation["end"]), end > trim else { return nil }
                let newStart = max(0, start - trim)
                let newEnd = end - trim
                annotation["start"] = newStart
                annotation["end"] = newEnd
                if annotation["text"] != nil, newEnd <= scalars.count - trim {
                    annotation["text"] = String(String.UnicodeScalarView(scalars[(newStart + trim)..<(newEnd + trim)]))
                }
                return annotation
            }
        }
        if let references = JSONSupport.array(original["footnote_refs"]) {
            result["footnote_refs"] = references.compactMap { value -> [String: Any]? in
                guard var reference = JSONSupport.object(value), let offset = JSONSupport.integer(reference["offset"]) else { return nil }
                reference["offset"] = max(0, offset - trim)
                return reference
            }
        }
        return result
    }

    private mutating func appendVerse(
        _ verse: [String: Any],
        chapter: Int,
        parentID: String?,
        parentFootnotes: Any?
    ) throws {
        let startVerse = try JSONSupport.requiredInteger(verse["sv"], path: "/chapters/verses/sv")
        let suffix = JSONSupport.string(verse["suffix"]) ?? ""
        let translation = meaningful(verse["translation"])
        let commentary = meaningful(verse["commentary"])
        let ownFootnotes = meaningful(verse["footnotes"])
        appendRow(
            id: "\(moduleID):\(bookNumber):verse:\(chapter):\(orderIndex):\(startVerse)\(suffix)",
            chapter: chapter,
            startVerse: startVerse,
            endVerse: JSONSupport.integer(verse["ev"]),
            unitType: "verse",
            level: 1,
            parentID: parentID,
            suffix: suffix.isEmpty ? nil : suffix,
            translation: translation,
            commentary: commentary,
            footnotes: ownFootnotes ?? parentFootnotes,
            searchText: makeSearchText(nil, nil, translation, commentary)
        )
    }

    private mutating func appendRow(
        id: String,
        chapter: Int,
        startVerse: Int,
        endVerse: Int? = nil,
        unitType: String,
        level: Int,
        parentID: String? = nil,
        title: String? = nil,
        suffix: String? = nil,
        introduction: Any? = nil,
        translation: Any? = nil,
        commentary: Any? = nil,
        footnotes: Any? = nil,
        searchText: String
    ) {
        units.append(CommentaryUnitRow(
            id: id,
            chapter: chapter,
            startVerse: startVerse,
            endVerse: endVerse,
            unitType: unitType,
            level: level,
            parentID: parentID,
            title: title,
            suffix: suffix,
            introductionJSON: try? JSONSupport.jsonString(introduction),
            translationJSON: try? JSONSupport.jsonString(translation),
            commentaryJSON: try? JSONSupport.jsonString(commentary),
            footnotesJSON: try? JSONSupport.jsonString(footnotes),
            searchText: searchText,
            footnotesText: JSONSupport.plainText(footnotes),
            orderIndex: orderIndex
        ))
        orderIndex += 1
    }

    private func defaultStartVerse(chapter: Int) -> Int {
        bookNumber * 1_000_000 + chapter * 1_000 + 1
    }

    private func meaningful(_ value: Any?) -> Any? {
        guard let value, JSONSupport.isMeaningful(value) else { return nil }
        return value
    }

    private func makeSearchText(_ values: Any?...) -> String {
        values.map(JSONSupport.plainText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
