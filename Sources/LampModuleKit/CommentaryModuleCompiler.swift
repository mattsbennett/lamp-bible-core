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
                        title, author, editor, publisher, year, abbreviations_json,
                        front_matter_json, indices_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "\(moduleID):\(bookNumber)",
                    moduleID,
                    bookNumber,
                    JSONSupport.string(meta["seriesFull"]),
                    JSONSupport.string(meta["seriesAbbrev"]),
                    title,
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
                try db.execute(
                    sql: """
                        INSERT INTO commentary_units (
                            id, module_id, book, chapter, sv, ev, unit_type, level,
                            parent_id, title, suffix, introduction_json, translation_json,
                            commentary_json, footnotes_json, search_text, order_index
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row.id,
                        moduleID,
                        bookNumber,
                        row.chapter,
                        row.startVerse,
                        row.endVerse,
                        row.unitType,
                        row.level,
                        row.parentID,
                        row.title,
                        row.suffix,
                        row.introductionJSON,
                        row.translationJSON,
                        row.commentaryJSON,
                        row.footnotesJSON,
                        row.searchText,
                        row.orderIndex,
                    ]
                )
            }
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
        try db.execute(sql: """
            CREATE TABLE commentary_units (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL,
                book INTEGER NOT NULL,
                chapter INTEGER,
                sv INTEGER NOT NULL,
                ev INTEGER,
                unit_type TEXT NOT NULL,
                level INTEGER NOT NULL DEFAULT 1,
                parent_id TEXT,
                title TEXT,
                suffix TEXT,
                introduction_json TEXT,
                translation_json TEXT,
                commentary_json TEXT,
                footnotes_json TEXT,
                search_text TEXT NOT NULL DEFAULT '',
                order_index INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_comm_units_module ON commentary_units(module_id)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_verse ON commentary_units(sv, ev)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_book_chapter ON commentary_units(book, chapter)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_parent ON commentary_units(parent_id)")
        try db.execute(sql: "CREATE INDEX idx_comm_units_type ON commentary_units(unit_type)")
    }
}

private struct CommentaryUnitRow {
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
    let orderIndex: Int
}

private struct CommentaryUnitBuilder {
    let moduleID: String
    let bookNumber: Int
    private(set) var units: [CommentaryUnitRow] = []
    private var orderIndex = 0
    private let footnotesByID: [String: Any]
    private let sourceOrdered: Bool

    init(moduleID: String, bookNumber: Int, footnotes: [Any] = [], sourceOrdered: Bool = false) {
        self.moduleID = moduleID
        self.bookNumber = bookNumber
        self.sourceOrdered = sourceOrdered
        var definitions: [String: Any] = [:]
        for value in footnotes {
            if let note = JSONSupport.object(value), let id = JSONSupport.string(note["id"]) {
                definitions[id] = value
            }
        }
        self.footnotesByID = definitions
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
                appendRow(
                    id: "\(moduleID):\(bookNumber):chapter_intro:\(chapterNumber)",
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
        let footnotes = meaningful(pericope["footnotes"]) ?? scopedNotesValue
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
                    footnotes: scoped.isEmpty ? nil : scoped,
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
