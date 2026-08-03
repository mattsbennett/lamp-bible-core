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
        var builder = CommentaryUnitBuilder(moduleID: moduleID, bookNumber: bookNumber)
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

    init(moduleID: String, bookNumber: Int) {
        self.moduleID = moduleID
        self.bookNumber = bookNumber
    }

    mutating func append(chapters: [Any]) throws {
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
        let footnotes = meaningful(pericope["footnotes"])
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

        for verseValue in JSONSupport.array(pericope["verses"]) ?? [] {
            let verse = try JSONSupport.requiredObject(verseValue, path: "/chapters/pericopae/verses")
            try appendVerse(verse, chapter: chapter, parentID: id, parentFootnotes: footnotes)
        }
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
