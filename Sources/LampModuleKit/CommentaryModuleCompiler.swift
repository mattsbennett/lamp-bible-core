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
        var builder = CommentaryUnitBuilder(
            moduleID: moduleID,
            bookNumber: bookNumber,
            footnotes: JSONSupport.array(root["footnotes"]) ?? [],
            sourceOrdered: JSONSupport.object(root["extraction"])?["sourceTracked"] as? Bool == true,
            rich: JSONSupport.string(meta["schemaVersion"]) == "2.3"
        )
        builder.hasTopLevelFootnoteIDs = root["footnoteIds"] != nil
        if builder.rich, let given = root["footnotes"], !(given is NSNull), !(given is [Any]) {
            throw ModuleCompilationError.invalidValue(path: "/footnotes", expected: "a list of notes")
        }
        try builder.append(chapters: chapters)
        // A unit the builder refused would be lost or misread: none is
        // written, as an inspection of the same volume says.
        if let refused = builder.issues.first(where: { $0.severity == .error }) {
            throw ModuleCompilationError.invalidValue(path: refused.path, expected: refused.message)
        }
        // Opened once the volume is known to build: opened first, a volume
        // that could not was told as a database that could not be made.
        // Found by Codex.
        let queue = try makeDatabaseQueue(at: databaseURL)

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
    /// A 2.3 unit's blocks as written; nil where its body is today's form.
    var blocksJSON: String? = nil
    /// The id a 2.3 section or pericope declares, which a link names it by.
    var declaredID: String? = nil
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
    /// Whether the volume is 2.3, whose units may give their body as
    /// blocks and declare ids; a volume of an earlier version is built as it
    /// always was.
    let rich: Bool
    /// What the builder found that a reader would lose or misread, for the
    /// inspector to report and the compile to refuse on an error.
    private(set) var issues: [ModuleValidationIssue] = []
    private var blockIDs: Set<String> = []
    /// The volume's notes as written, for Rule A's checks.
    private let rawFootnotes: [Any]
    /// The notes some 2.3 row cites.
    private var citedNotes: Set<String> = []
    /// Each 2.3 note, written as an older reader opens it (Rule B1).
    private var readableNotes: [String: Any] = [:]

    /// Whether the volume gives a top-level `footnoteIds`, which a 2.3
    /// volume does not.
    var hasTopLevelFootnoteIDs = false

    init(moduleID: String, bookNumber: Int, footnotes: [Any] = [], sourceOrdered: Bool = false, rich: Bool = false) {
        self.moduleID = moduleID
        self.bookNumber = bookNumber
        self.sourceOrdered = sourceOrdered
        self.rich = rich
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
        self.rawFootnotes = footnotes
    }

    mutating func append(chapters: [Any]) throws {
        if rich {
            checkFootnoteDefinitions()
            refuseScopedFootnotes(chapters, path: "/chapters")
            if hasTopLevelFootnoteIDs {
                issues.append(.init(
                    severity: .error, path: "/footnoteIds",
                    message: "A 2.3 volume defines its notes once, in its top-level footnotes, and a unit cites them; none are listed here."
                ))
            }
        }
        try appendUnits(chapters: chapters)
        if rich { checkFootnotesCited() }
    }

    private mutating func appendUnits(chapters: [Any]) throws {
        if sourceOrdered {
            var ordered: [(order: Int, chapter: Int, pericope: [String: Any], path: String)] = []
            for (chapterIndex, value) in chapters.enumerated() {
                let chapter = try JSONSupport.requiredObject(value, path: "/chapters")
                let number = try JSONSupport.requiredInteger(chapter["chapter"], path: "/chapters/chapter")
                // A source-tracked volume is built from its pericopae alone:
                // anything else a 2.3 chapter
                // gives — a section, a verse, an introduction — would be left
                // out unseen. Judged by what is built, not a list of what is
                // not, which review found one more of twice. Found by Codex.
                for key in chapter.keys.sorted() where rich && !["chapter", "pericopae"].contains(key) {
                    guard let value = chapter[key], JSONSupport.isMeaningful(value) else { continue }
                    issues.append(.init(
                        severity: .error, path: "/chapters/\(chapterIndex)/\(key)",
                        message: "A source-tracked volume is built from its pericopae, in printed order; its \(key) would be left out."
                    ))
                }
                for (index, value) in units(chapter, "pericopae", at: "/chapters/\(chapterIndex)").enumerated() {
                    let pericope = try JSONSupport.requiredObject(value, path: "/chapters/pericopae")
                    ordered.append((
                        JSONSupport.integer(pericope["sourceOrder"]) ?? ordered.count, number, pericope,
                        "/chapters/\(chapterIndex)/pericopae/\(index)"
                    ))
                }
            }
            for item in ordered.sorted(by: { $0.order < $1.order }) {
                try appendPericope(item.pericope, chapter: item.chapter, parentID: nil, path: item.path)
            }
            return
        }
        for (chapterIndex, chapterValue) in chapters.enumerated() {
            let path = "/chapters/\(chapterIndex)"
            let chapter = try JSONSupport.requiredObject(chapterValue, path: path)
            let chapterNumber = try JSONSupport.requiredInteger(chapter["chapter"], path: "\(path)/chapter")
            // A chapter's body is its introduction: blocks given to it were
            // read by nothing, and lost. Found by Codex. (Each unit's fields
            // read whole is step 4, commit 6.)
            if rich, chapter["blocks"] != nil {
                issues.append(.init(
                    severity: .error, path: "\(path)/blocks",
                    message: "A chapter's body is its introduction; blocks here are read by nothing."
                ))
            }

            if let introduction = meaningfulText(chapter["introduction"], path: path) {
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
                    startVerse: try defaultStartVerse(chapter: chapterNumber),
                    unitType: "section",
                    level: 0,
                    title: title,
                    introduction: introduction,
                    path: "\(path)/introduction",
                    searchText: makeSearchText(title, introduction, nil, nil)
                )
            }

            for (index, sectionValue) in units(chapter, "sections", at: path).enumerated() {
                let section = try JSONSupport.requiredObject(sectionValue, path: "\(path)/sections")
                try appendSection(section, chapter: chapterNumber, parentID: nil, level: 1, path: "\(path)/sections/\(index)")
            }
            for (index, pericopeValue) in units(chapter, "pericopae", at: path).enumerated() {
                let pericope = try JSONSupport.requiredObject(pericopeValue, path: "\(path)/pericopae")
                try appendPericope(pericope, chapter: chapterNumber, parentID: nil, path: "\(path)/pericopae/\(index)")
            }
            for (index, verseValue) in units(chapter, "verses", at: path).enumerated() {
                let verse = try JSONSupport.requiredObject(verseValue, path: "\(path)/verses")
                try appendVerse(
                    verse,
                    chapter: chapterNumber,
                    parentID: nil,
                    parentFootnotes: meaningful(chapter["footnotes"]),
                    path: "\(path)/verses/\(index)"
                )
            }
        }
    }

    private mutating func appendSection(
        _ section: [String: Any],
        chapter: Int,
        parentID: String?,
        level: Int,
        path: String
    ) throws {
        let id = "\(moduleID):\(bookNumber):section:\(chapter):\(orderIndex)"
        // A 2.3 section's body may be its blocks, then shown where its
        // introduction is today: an older reader shows a section by it.
        let body = richBody(of: section, path: path, replacing: ["introduction"])
        let introduction = body?.legacy ?? meaningfulText(section["introduction"], path: path)
        appendRow(
            id: id,
            chapter: chapter,
            startVerse: try JSONSupport.integer(section["sv"]) ?? defaultStartVerse(chapter: chapter),
            endVerse: JSONSupport.integer(section["ev"]),
            unitType: "section",
            level: level,
            parentID: parentID,
            title: JSONSupport.string(section["title"]),
            introduction: introduction,
            path: path,
            searchText: makeSearchText(JSONSupport.string(section["title"]), body?.searchText ?? introduction, nil, nil),
            blocksJSON: body?.blocksJSON,
            declaredID: rich ? JSONSupport.string(section["id"]) : nil
        )

        for (index, subsectionValue) in units(section, "subsections", at: path).enumerated() {
            let subsection = try JSONSupport.requiredObject(subsectionValue, path: "/chapters/sections/subsections")
            try appendSection(subsection, chapter: chapter, parentID: id, level: level + 1, path: "\(path)/subsections/\(index)")
        }
        for (index, pericopeValue) in units(section, "pericopae", at: path).enumerated() {
            let pericope = try JSONSupport.requiredObject(pericopeValue, path: "/chapters/sections/pericopae")
            try appendPericope(pericope, chapter: chapter, parentID: id, path: "\(path)/pericopae/\(index)")
        }
    }

    private mutating func appendPericope(
        _ pericope: [String: Any],
        chapter: Int,
        parentID: String?,
        path: String
    ) throws {
        let id = "\(moduleID):\(bookNumber):pericope:\(chapter):\(orderIndex)"
        // A 2.3 pericope's own body as blocks, in place of a source-tracked
        // pericope's `content`, which carries its blocks on each entry.
        // In a source-tracked volume, never on the pericope: each entry keeps
        // its own passage and row. Found by Codex.
        if rich, sourceOrdered, pericope["blocks"] != nil {
            issues.append(.init(
                severity: .error, path: "\(path)/blocks",
                message: "In a source-tracked volume, blocks go on the pericope's content entries, each with its own passage."
            ))
        }
        let body = sourceOrdered ? nil : richBody(of: pericope, path: path, replacing: ["content", "commentary"])
        // One body: a 2.3 pericope's `commentary` beside the entries it is
        // built from is refused, as its `blocks` there are. Found by Codex.
        // In a source-tracked volume, the body goes on the entries, given
        // or not. Found by Codex.
        if rich, pericope["content"] is [Any] || sourceOrdered, pericope["commentary"] != nil, !(pericope["commentary"] is NSNull),
           pericope["blocks"] == nil {
            issues.append(.init(
                severity: .error, path: "\(path)/commentary",
                message: "A pericope built from its content entries gives no body of its own beside them."
            ))
        }
        // Each entry's blocks, read once: the notes they cite decide where a
        // passage's notes go before its rows are written.
        var entryBodies: [Int: LampCommentaryBlocks.Body] = [:]
        // Entries are a list: one written as an object was walked by
        // nothing, and lost. Found by Codex.
        if rich, let content = pericope["content"], !(content is NSNull), !(content is [Any]) {
            issues.append(.init(severity: .error, path: "\(path)/content", message: "A pericope's content entries are a list."))
        }
        if rich, let content = JSONSupport.array(pericope["content"]) {
            for (index, value) in content.enumerated() {
                guard let entry = JSONSupport.object(value), entry["blocks"] != nil else { continue }
                let entryPath = "\(path)/content/\(index)"
                let role = JSONSupport.string(entry["type"])
                // Each role whose body is the row's commentary: a paragraph's
                // is, as a commentary entry's. Found by Codex. A heading is
                // kept as a title, a translation in its own column.
                if !["commentary", "paragraph", "bibliography", "abbreviations"].contains(role ?? "") {
                    issues.append(.init(
                        severity: .error, path: "\(entryPath)/blocks",
                        message: "Only an entry whose body is commentary gives it as blocks; a \(role ?? "untyped") entry keeps its content."
                    ))
                    continue
                }
                if entry["displayPrefixLength"] != nil {
                    issues.append(.init(
                        severity: .error, path: "\(entryPath)/displayPrefixLength",
                        message: "A printed label cannot be trimmed from blocks: give the blocks as they are to be read."
                    ))
                    continue
                }
                if let entryBody = richBody(of: entry, path: entryPath, replacing: ["content"]) {
                    entryBodies[index] = entryBody
                }
            }
        }
        let introduction = meaningfulText(pericope["introduction"], path: path)
        let translation = meaningfulText(pericope["translation"], path: path)
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
        // Not for 2.3, whose rows carry the notes their own texts cite
        // (Rule A, `appendRow`): placing a note on a row that does not cite
        // it is what that rule leaves behind.
        if !rich, let content = JSONSupport.array(pericope["content"]), let notes = JSONSupport.array(footnotes) {
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
            startVerse: try JSONSupport.integer(pericope["sv"]) ?? defaultStartVerse(chapter: chapter),
            endVerse: JSONSupport.integer(pericope["ev"]),
            unitType: "pericope",
            level: 1,
            parentID: parentID,
            title: JSONSupport.string(pericope["title"]),
            introduction: introduction,
            translation: translation,
            // A 2.3 pericope's body written as today's, kept: a 2.2 pericope's
            // `commentary` was never read, and dropped it would be lost.
            // Found by Codex.
            commentary: body?.legacy ?? (rich && !sourceOrdered ? meaningfulText(pericope["commentary"], path: path) : nil),
            footnotes: footnotes,
            path: path,
            searchText: makeSearchText(
                JSONSupport.string(pericope["title"]), introduction, translation,
                body?.searchText ?? (rich && !sourceOrdered ? meaningful(pericope["commentary"]) : nil)
            ),
            blocksJSON: body?.blocksJSON,
            declaredID: rich ? JSONSupport.string(pericope["id"]) : nil
        )

        // Read as a list first, so one given as an object is told too.
        // Found by Codex.
        // Content entries the builder uses, a list; a `null` is none. Found
        // by Codex.
        let entries = pericope["content"] is [Any]
        if rich, entries, pericope["verses"] != nil, !(pericope["verses"] is [Any]) {
            _ = units(pericope, "verses", at: path)
        }
        if rich, entries, !(JSONSupport.array(pericope["verses"]) ?? []).isEmpty {
            // A pericope built from its entries visits no verse beside them:
            // a 2.3 verse there would be left out unseen. Found by Codex.
            issues.append(.init(
                severity: .error, path: "\(path)/verses",
                message: "A pericope given as content entries is built from them; its verses would be left out."
            ))
        }
        if let content = JSONSupport.array(pericope["content"]) {
            let parentStart = try JSONSupport.integer(pericope["sv"]) ?? defaultStartVerse(chapter: chapter)
            for (index, value) in content.enumerated() {
                let block = try JSONSupport.requiredObject(value, path: rich ? "\(path)/content/\(index)" : "/pericopae/content/\(index)")
                let role = try JSONSupport.requiredString(block["type"], path: rich ? "\(path)/content/\(index)/type" : "/pericopae/content/type")
                // Printed indexes belong to indices_json, not the last passage.
                if role == "index" { continue }
                let entryBody = entryBodies[index]
                // An entry whose blocks were refused is not written: the
                // issue says why, and the compile stops on it.
                if rich, block["blocks"] != nil, entryBody == nil { continue }
                let text: [String: Any]
                if let entryBody {
                    text = entryBody.legacy
                } else {
                    let sourceText = try JSONSupport.requiredObject(
                        block["content"], path: rich ? "\(path)/content/\(index)/content" : "/pericopae/content/content"
                    )
                    // Checked as written, before its label is trimmed: the
                    // trim drops a marker it cannot read and makes 3.5 a 3.
                    // Found by Codex.
                    if rich {
                        // Only where a trim follows, or a heading is kept as its
                        // title alone: otherwise the row's own check reads the
                        // same text, and each fault was told twice. Found by
                        // Codex.
                        let titleOnly = role == "heading"
                            && (JSONSupport.array(sourceText["annotations"]) ?? []).isEmpty
                            && (JSONSupport.array(sourceText["footnote_refs"]) ?? []).isEmpty
                        if (JSONSupport.integer(block["displayPrefixLength"]) ?? 0) > 0 || titleOnly {
                            _ = writtenForOlderReaders(sourceText, path: "\(path)/content/\(index)")
                        }
                        // A whole count of scalars within the text: a fraction
                        // trimmed what it truncated to, and one past the end
                        // the whole body. Found by Codex.
                        if let given = block["displayPrefixLength"], !(given is NSNull) {
                            let length = (sourceText["text"] as? String)?.unicodeScalars.count ?? 0
                            if let count = LampCommentaryBlocks.wholeNumber(given), count >= 0, count <= length {
                                // A note span within the label is trimmed with
                                // it, its citation lost. Found by Codex.
                                for value in (sourceText["annotations"] as? [Any]) ?? [] {
                                    guard let annotation = value as? [String: Any], annotation["type"] as? String == "footnote",
                                          let end = LampCommentaryBlocks.wholeNumber(annotation["end"]), end <= count else { continue }
                                    issues.append(.init(
                                        severity: .error, path: "\(path)/content/\(index)",
                                        message: "A footnote span lies within the label to be trimmed, and would be lost with it."
                                    ))
                                }
                            } else {
                                issues.append(.init(
                                    severity: .error, path: "\(path)/content/\(index)/displayPrefixLength",
                                    message: "A label's length is a whole number of characters within its text (\(length))."
                                ))
                            }
                        }
                    }
                    text = displayContent(sourceText, prefixLength: JSONSupport.integer(block["displayPrefixLength"]) ?? 0)
                }
                let start = JSONSupport.integer(block["sv"]) ?? parentStart
                // A 2.3 entry on its own verse ends there unless it says
                // otherwise: given the passage's end, it was found at every
                // verse to it. Found by Codex. 2.2 keeps the passage's end.
                // Its own verse as read, so a null `sv` inherits both ends.
                // Found by Codex.
                let end = rich && JSONSupport.integer(block["sv"]) != nil
                    ? JSONSupport.integer(block["ev"])
                    : JSONSupport.integer(block["ev"]) ?? JSONSupport.integer(pericope["ev"])
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
                            path: "\(path)/content/\(index)",
                    searchText: entryBody.map { makeSearchText(nil, nil, nil, $0.searchText) }
                        ?? makeSearchText(heading ? JSONSupport.string(text["text"]) : nil, nil, isTranslation ? text : nil, !heading && !isTranslation ? text : nil),
                    blocksJSON: entryBody?.blocksJSON
                )
            }
            return
        }

        for (index, verseValue) in units(pericope, "verses", at: path).enumerated() {
            let verse = try JSONSupport.requiredObject(verseValue, path: "/chapters/pericopae/verses")
            try appendVerse(verse, chapter: chapter, parentID: id, parentFootnotes: footnotes, path: "\(path)/verses/\(index)")
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
                      let end = JSONSupport.integer(annotation["end"]),
                      // A 2.3 page marked at the first kept character is kept
                      // there, at 0: dropped, the newer reader lost it.
                      // Found by Codex.
                      end > trim || (rich && start == trim && end == trim) else { return nil }
                // Not counted below the trim, so a start far below zero is
                // not subtracted from. Found by Codex.
                let newStart = start <= trim ? 0 : start - trim
                let newEnd = end - trim
                annotation["start"] = newStart
                annotation["end"] = newEnd
                // A span ending before it starts names no text to slice:
                // sliced, it stopped the process. Found by Codex.
                if annotation["text"] != nil, newEnd <= scalars.count - trim, newEnd >= newStart {
                    annotation["text"] = String(String.UnicodeScalarView(scalars[(newStart + trim)..<(newEnd + trim)]))
                }
                return annotation
            }
        }
        if let references = JSONSupport.array(original["footnote_refs"]) {
            result["footnote_refs"] = references.compactMap { value -> [String: Any]? in
                guard var reference = JSONSupport.object(value), let offset = JSONSupport.integer(reference["offset"]) else { return nil }
                // Not subtracted from where it falls in the trim: a very
                // negative offset overflowed. Found by Codex.
                reference["offset"] = offset <= trim ? 0 : offset - trim
                return reference
            }
        }
        return result
    }

    private mutating func appendVerse(
        _ verse: [String: Any],
        chapter: Int,
        parentID: String?,
        parentFootnotes: Any?,
        path: String
    ) throws {
        // At the verse's own path in 2.3, which an author can find. Found by
        // Codex.
        let startVerse = try JSONSupport.requiredInteger(verse["sv"], path: rich ? "\(path)/sv" : "/chapters/verses/sv")
        let suffix = JSONSupport.string(verse["suffix"]) ?? ""
        let translation = meaningfulText(verse["translation"], path: path)
        let body = richBody(of: verse, path: path, replacing: ["commentary"])
        let commentary = body?.legacy ?? meaningfulText(verse["commentary"], path: path)
        let ownFootnotes = meaningful(verse["footnotes"])
        appendRow(
            id: "\(moduleID):\(bookNumber):verse:\(chapter):\(orderIndex):\(startVerse)\(suffix)",
            chapter: chapter,
            startVerse: startVerse,
            endVerse: JSONSupport.integer(verse["ev"]),
            unitType: "verse",
            level: 1,
            parentID: parentID,
            // A 2.3 note's printed range, where its passage is not one run
            // of verses: `sv` and `ev` stay the run it is found by (D7).
            // Found by Codex.
            // Its NUL a space, as in search text: bound, a NUL ended the
            // title there. Found by Codex.
            title: rich ? JSONSupport.string(verse["title"])?.replacingOccurrences(of: "\0", with: " ") : nil,
            suffix: suffix.isEmpty ? nil : suffix,
            translation: translation,
            commentary: commentary,
            footnotes: ownFootnotes ?? parentFootnotes,
            path: path,
            searchText: makeSearchText(nil, nil, translation, body?.searchText ?? commentary),
            blocksJSON: body?.blocksJSON
        )
    }

    /// The units a list gives, where the builder reads them: in a 2.3
    /// volume, one given as anything but a list is refused, not walked as
    /// none and its units lost. Found by Codex.
    private mutating func units(_ container: [String: Any], _ key: String, at path: String) -> [Any] {
        let value = container[key]
        if rich, let value, !(value is NSNull), !(value is [Any]) {
            issues.append(.init(severity: .error, path: "\(path)/\(key)", message: "Expected a list of units."))
        }
        return JSONSupport.array(value) ?? []
    }

    /// Rule A: the definitions of the notes `texts` cite, each once, in the
    /// order first cited, from the volume's one list; a note cited and not
    /// defined is refused at the citing unit. Nil where none is cited.
    private mutating func notes(citedBy texts: [Any?], path: String) -> Any? {
        var notes: [Any] = []
        var seen = Set<String>()
        for text in texts {
            for id in LampCommentaryBlocks.citedFootnoteIDs(in: JSONSupport.object(text)) where seen.insert(id).inserted {
                guard let note = footnotesByID[id] else {
                    issues.append(.init(
                        severity: .error, path: path,
                        message: "Cites note \u{201C}\(id)\u{201D}, which the volume's footnotes do not define; its marker would open nothing."
                    ))
                    continue
                }
                citedNotes.insert(id)
                notes.append(readableNotes[id] ?? note)
            }
        }
        return notes.isEmpty ? nil : notes
    }

    /// Links in plain 2.3 texts that open nothing, by the inspector's rule.
    private mutating func warnAboutDeadLinks(in texts: [Any?], path: String) {
        // Each annotation read alone, as the phone reads them: one it cannot
        // read hid every other from the check. Found by Codex. Each checked
        // writable first: one holding an infinity raises where no `try?`
        // reaches.
        func decode<T: Decodable>(_ value: Any, as type: T.Type) -> T? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        let decoded = texts.compactMap { text -> LampBookAnnotatedText? in
            guard let object = JSONSupport.object(text), let words = object["text"] as? String else { return nil }
            // A link that will not decode opens nothing: told as one over no
            // words, not passed over. Found by Codex.
            let annotations = ((object["annotations"] as? [Any]) ?? []).compactMap { value -> LampBookAnnotation? in
                decode(value, as: LampBookAnnotation.self)
                    ?? ((value as? [String: Any])?["type"] as? String == "link" ? LampBookAnnotation(type: "link", start: 0, end: 0) : nil)
            }
            return LampBookAnnotatedText(text: words, annotations: annotations)
        }
        // Held to the phone's bounds, not clipped as a block's are: an older
        // phone passes over a span that runs past its text. Found by Codex.
        ModuleJSONInspector.warnAboutDeadLinks(in: decoded, path: path, containingKind: "commentary", strictBounds: true, issues: &issues)
    }

    /// Rule B1: a 2.3 text, or a note holding one, as an older reader opens
    /// it (`LampCommentaryBlocks.writtenForOlderReaders`), what would blank
    /// it on that reader refused at `path`.
    private mutating func writtenForOlderReaders(_ value: Any?, path: String, inNote: Bool = false) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        guard var object = JSONSupport.object(value) else {
            // A text given as words, or as a list of texts, is stored where
            // the phone reads one annotated text: refused. Found by Codex.
            if !inNote, JSONSupport.isMeaningful(value) {
                issues.append(.init(severity: .error, path: path, message: "A 2.3 text is one object with its words in `text`; an older reader shows nothing else."))
            }
            return value
        }
        if inNote {
            guard let content = JSONSupport.object(object["content"]) else { return value }
            object["content"] = LampCommentaryBlocks.writtenForOlderReaders(content, path: path, issues: &issues)
            return object
        }
        return LampCommentaryBlocks.writtenForOlderReaders(object, path: path, issues: &issues)
    }

    /// Rule A's checks of the volume as a whole, before and after its units
    /// are built: notes defined only in its top-level list, each once and
    /// readable; and every one of them cited by some row.
    private mutating func checkFootnoteDefinitions() {
        for (index, value) in rawFootnotes.enumerated() {
            let path = "/footnotes/\(index)"
            guard let note = JSONSupport.object(value), let id = note["id"] as? String, !id.isEmpty else {
                issues.append(.init(severity: .error, path: path, message: "A note needs an id, as words."))
                continue
            }
            if footnoteOrder[id] != index {
                issues.append(.init(
                    severity: .error, path: "\(path)/id",
                    message: "Another note has the id \u{201C}\(id)\u{201D}; a marker could open either."
                ))
            }
            guard let content = JSONSupport.object(note["content"]), content["text"] is String else {
                issues.append(.init(severity: .error, path: "\(path)/content", message: "A note's content needs its text, as words."))
                continue
            }
            // Written once as an older reader opens it, and refused once, at
            // its definition, where it would blank the phone: checked at each
            // row citing it, a bad note was reported at its good citations.
            // Found by Codex.
            // A note cites no note: the phone's note sheet opens none, so a
            // marker there leads nowhere. Found by Codex.
            if !LampCommentaryBlocks.citedFootnoteIDs(in: content).isEmpty
                || !((content["footnote_refs"] as? [Any]) ?? []).isEmpty {
                issues.append(.init(
                    severity: .error, path: "\(path)/content",
                    message: "A note cites no other note; a reader opens none from inside a note."
                ))
            }
            if footnoteOrder[id] == index {
                var readable = note
                readable["content"] = LampCommentaryBlocks.writtenForOlderReaders(content, path: "\(path)/content", issues: &issues)
                // Told once, where it is defined, if JSON cannot store it:
                // told at each row citing it, the note itself went unnamed.
                // Found by Codex.
                warnAboutDeadLinks(in: [readable["content"]], path: "\(path)/content")
                if !JSONSerialization.isValidJSONObject(readable) {
                    issues.append(.init(severity: .error, path: path, message: "This note holds a value JSON cannot store, such as an infinite number."))
                }
                readableNotes[id] = readable
            }
        }
    }

    private mutating func checkFootnotesCited() {
        for (index, value) in rawFootnotes.enumerated() {
            guard let id = JSONSupport.object(value).flatMap({ $0["id"] as? String }),
                  footnoteOrder[id] == index, !citedNotes.contains(id) else { continue }
            issues.append(.init(
                severity: .error, path: "/footnotes/\(index)",
                message: "No unit cites note \u{201C}\(id)\u{201D}, so no reader could open it: cite it where it belongs, or leave it out."
            ))
        }
    }

    /// Rule A: in a 2.3 volume, notes are defined in its top-level list
    /// alone. One scan of the chapters, blocks and all, not of each place a
    /// unit is built.
    private mutating func refuseScopedFootnotes(_ value: Any, path: String) {
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                let nested = object[key]!
                // By presence, empty or not, blocks included: Rule A has no
                // place for either. Found by Codex.
                if key == "footnotes" || key == "footnoteIds" {
                    _ = nested
                    issues.append(.init(
                        severity: .error, path: "\(path)/\(key)",
                        message: "A 2.3 volume defines its notes once, in its top-level footnotes, and a unit cites them; none are defined or listed here."
                    ))
                } else {
                    refuseScopedFootnotes(nested, path: "\(path)/\(key)")
                }
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() { refuseScopedFootnotes(nested, path: "\(path)/\(index)") }
        }
    }

    /// A 2.3 unit's body given as `blocks`, read once (`LampCommentaryBlocks`),
    /// or nil where it gives none — or gives one this volume's version does
    /// not read. `blocks` beside today's form of the body is refused, by the
    /// key alone: no rule could say where a figure falls between two bodies.
    private mutating func richBody(
        of unit: [String: Any], path: String, replacing legacyKeys: [String]
    ) -> LampCommentaryBlocks.Body? {
        guard rich, let blocks = unit["blocks"] else { return nil }
        for key in legacyKeys where unit[key] != nil {
            issues.append(.init(
                severity: .error, path: "\(path)/\(key)",
                message: "A unit gives its body as blocks or as \(key), not both: neither says where the other goes."
            ))
            return nil
        }
        return LampCommentaryBlocks.body(blocks, path: "\(path)/blocks", blockIDs: &blockIDs, issues: &issues)
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
        path: String = "",
        searchText: String,
        blocksJSON: String? = nil,
        declaredID: String? = nil
    ) {
        // A 2.3 row carries the notes its own texts cite (Rule A), its texts
        // and those notes written as an older reader opens them (Rule B1). A
        // row of an earlier version carries what its caller gives, as it
        // always has.
        var introduction = introduction, translation = translation, commentary = commentary
        var footnotes = footnotes
        if rich {
            introduction = writtenForOlderReaders(introduction, path: path)
            translation = writtenForOlderReaders(translation, path: path)
            commentary = writtenForOlderReaders(commentary, path: path)
            // Its links held to the rule a block's are, in the text it stores:
            // the texts given as written, not a blocks body's projection,
            // whose links its blocks were checked for. Found by Codex.
            let projected = blocksJSON == nil ? nil : (unitType == "section" ? "introduction" : "commentary")
            warnAboutDeadLinks(
                in: [projected == "introduction" ? nil : introduction, translation, projected == "commentary" ? nil : commentary],
                path: path
            )
            footnotes = notes(citedBy: [introduction, translation, commentary], path: path)
        }
        // A 2.3 row's text that cannot be stored as JSON is told, not stored
        // as nothing: one bad value in a carried note emptied the row's
        // notes. Found by Codex.
        func stored(_ value: Any?, _ column: String) -> String? {
            do {
                return try JSONSupport.jsonString(value)
            } catch {
                if rich {
                    issues.append(.init(severity: .error, path: path, message: "Its \(column) holds a value JSON cannot store, such as an infinite number."))
                }
                return nil
            }
        }
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
            introductionJSON: stored(introduction, "introduction"),
            translationJSON: stored(translation, "translation"),
            commentaryJSON: stored(commentary, "commentary"),
            footnotesJSON: stored(footnotes, "notes"),
            // A NUL anywhere in a 2.3 row's words is a space: bound as search
            // text it ended the string there, and the block words after a
            // translation's NUL were never indexed. Found by Codex.
            searchText: rich ? searchText.replacingOccurrences(of: "\0", with: " ") : searchText,
            // A 2.3 row's notes searched by what the phone opens of each, its
            // content's words: by the note's own keys, a top-level `text` beside
            // its content hid the note. Found by Codex.
            footnotesText: rich
                ? (JSONSupport.array(footnotes) ?? []).compactMap { JSONSupport.object(JSONSupport.object($0)?["content"])?["text"] as? String }
                    .filter { !$0.isEmpty }.joined(separator: " ").replacingOccurrences(of: "\0", with: " ")
                : JSONSupport.plainText(footnotes),
            orderIndex: orderIndex,
            blocksJSON: blocksJSON,
            declaredID: declaredID
        ))
        orderIndex += 1
    }

    /// A chapter's first verse, for a unit that names none. A chapter no
    /// verse reference can hold is refused: counted on, one large enough
    /// overflowed and stopped the process, inspection included. Found by
    /// Codex.
    /// A 2.3 chapter held to 0...999; a 2.2 one built as it always was, any
    /// chapter whose verse can be counted (a `chapter: -1` introduction did,
    /// and does), only an overflow refused where it once stopped the process.
    /// Found by Codex.
    private func defaultStartVerse(chapter: Int) throws -> Int {
        if rich, !((0...999).contains(chapter) && (0...999).contains(bookNumber)) {
            throw ModuleCompilationError.invalidValue(path: "/chapters/chapter", expected: "a chapter from 0 to 999")
        }
        let (book, bookOverflow) = bookNumber.multipliedReportingOverflow(by: 1_000_000)
        let (chapterPart, chapterOverflow) = chapter.multipliedReportingOverflow(by: 1_000)
        let (sum, sumOverflow) = book.addingReportingOverflow(chapterPart)
        let (verse, verseOverflow) = sum.addingReportingOverflow(1)
        guard !(bookOverflow || chapterOverflow || sumOverflow || verseOverflow) else {
            throw ModuleCompilationError.invalidValue(path: "/chapters/chapter", expected: "a chapter whose verse can be counted")
        }
        return verse
    }

    /// A unit's text, or nil for one with nothing in it. A 2.3 text given
    /// and empty is still held to Rule B1 first: `{}` has no words to keep,
    /// and was dropped unremarked. Found by Codex.
    private mutating func meaningfulText(_ value: Any?, path: String) -> Any? {
        if rich, let value, !(value is NSNull), !JSONSupport.isMeaningful(value) {
            _ = writtenForOlderReaders(value, path: path)
        }
        return meaningful(value)
    }

    private func meaningful(_ value: Any?) -> Any? {
        guard let value, JSONSupport.isMeaningful(value) else { return nil }
        return value
    }

    private func makeSearchText(_ values: Any?...) -> String {
        values.map(JSONSupport.plainText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
