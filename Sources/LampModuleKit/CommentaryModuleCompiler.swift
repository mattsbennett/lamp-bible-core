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
    var orderIndex: Int
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
    /// Each 2.3 verse note's passage, and each declared id at its verse,
    /// so neither is given twice.
    /// Compared byte for byte, as SQLite compares them and a link names
    /// them: as strings, `é` and `e\u{301}` were one. Found by Codex.
    private var versePassages: Set<[UInt8]> = []
    private var declaredAtVerse: Set<[UInt8]> = []
    /// The passages a source-tracked volume's entries give verse rows on,
    /// which are paragraphs of one printed note, many to a verse.
    private var entryPassages: Set<[UInt8]> = []
    /// Each 2.3 row's own start, for its units to start no earlier.
    private var startByRowID: [String: Int] = [:]
    /// The chapter whose units are being read, as the volume writes it.
    private var writtenChapter = 0
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
        if rich, !sourceOrdered { orderAsReaders() }
    }

    /// A 2.3 volume's rows in the order a reader shows a chapter's: by the
    /// chapter each is filed in, its introduction first, then by verse, a
    /// heading (section) before a passage (pericope) before a verse note at
    /// one verse, and rows at one verse of one kind in the order the volume
    /// gives them, a unit before its own units. `ev` is no part of it. Each
    /// row keeps its parent by `parent_id`, wherever it falls: a reader
    /// lists a chapter's rows by `order_index`, and a subsection filed in a
    /// later chapter than its section (1,195 in the study Bible), numbered
    /// beneath that section, came before every note of its own chapter.
    /// Found by Codex. Written list by list, a section on 1:20 came before
    /// the note on 1:2. A 2.2 volume is numbered as written, as it always
    /// was, and a source-tracked one in its printed order, which may return
    /// to an earlier passage.
    private mutating func orderAsReaders() {
        func rank(_ row: CommentaryUnitRow) -> Int {
            if row.level == 0 { return 0 }
            switch row.unitType {
            case "section": return 1
            case "pericope": return 2
            default: return 3
            }
        }
        // By what each row stores, and nothing else: every row a 2.3 volume
        // places by verse gives its own (`refuseUnplaced`), so a unit's own
        // units at its verse follow it by kind and the order written, and
        // one naming another verse goes there. Each rule that guessed an
        // unplaced row's place from its parent's left the guess unstored, or
        // let one more child above its parent — five review rounds running.
        // Found by Codex; the rule replaced on the planner's advice.
        let numbered = units.enumerated().sorted { first, second in
            let a = first.element, b = second.element
            return (a.chapter, a.level == 0 ? 0 : 1, a.startVerse, rank(a), first.offset)
                < (b.chapter, b.level == 0 ? 0 : 1, b.startVerse, rank(b), second.offset)
        }
        units = numbered.enumerated().map { place, row in
            var row = row.element
            row.orderIndex = place
            return row
        }
    }

    private mutating func appendUnits(chapters: [Any]) throws {
        if sourceOrdered {
            var ordered: [(order: Int, chapter: Int, pericope: [String: Any], path: String)] = []
            for (chapterIndex, value) in chapters.enumerated() {
                let chapter = try JSONSupport.requiredObject(value, path: "/chapters")
                let number = try chapterNumber(of: chapter, path: "/chapters/\(chapterIndex)/chapter", legacyPath: "/chapters/chapter")
                // A source-tracked volume is built from its pericopae alone:
                // anything else a 2.3 chapter
                // gives — a section, a verse, an introduction — would be left
                // out unseen. Judged by what is built, not a list of what is
                // not, which review found one more of twice. Found by Codex.
                // Any such field, given empty or not, as any 2.3 unit's; its
                // notes are Rule A's to refuse. Found by Codex.
                for key in chapter.keys.sorted() where rich && !["chapter", "pericopae", "footnotes", "footnoteIds"].contains(key) {
                    issues.append(.init(
                        severity: .error, path: "/chapters/\(chapterIndex)/\(LampBookUnread.escaped(key))",
                        message: "A source-tracked volume is built from its pericopae, in printed order; its \(key) would be left out."
                    ))
                }
                for (index, value) in units(chapter, "pericopae", at: "/chapters/\(chapterIndex)").enumerated() {
                    let pericope = try JSONSupport.requiredObject(value, path: "/chapters/pericopae")
                    // A printed place is a whole number: quoted it was read as
                    // none, a fraction as the whole below it. Found by Codex.
                    if rich, let given = pericope["sourceOrder"], !(given is NSNull), LampCommentaryBlocks.wholeNumber(given) == nil {
                        issues.append(.init(
                            severity: .error, path: "/chapters/\(chapterIndex)/pericopae/\(index)/sourceOrder",
                            message: "A printed order is a whole number."
                        ))
                    }
                    ordered.append((
                        JSONSupport.integer(pericope["sourceOrder"]) ?? ordered.count, number, pericope,
                        "/chapters/\(chapterIndex)/pericopae/\(index)"
                    ))
                }
            }
            for item in ordered.sorted(by: { $0.order < $1.order }) {
                writtenChapter = item.chapter
                try appendPericope(item.pericope, chapter: item.chapter, parentID: nil, path: item.path)
            }
            return
        }
        for (chapterIndex, chapterValue) in chapters.enumerated() {
            let path = "/chapters/\(chapterIndex)"
            let chapter = try JSONSupport.requiredObject(chapterValue, path: path)
            let chapterNumber = try chapterNumber(of: chapter, path: "\(path)/chapter", legacyPath: "\(path)/chapter")
            // A chapter's body is its introduction: blocks given to it were
            // read by nothing, and lost. Found by Codex. Its fields read
            // whole, as every 2.3 unit's are.
            readWhole(chapter, as: "chapter", allowed: Self.chapterKeys, path: path)
            writtenChapter = chapterNumber
            try appendIntroduction(of: chapter, chapter: chapterNumber, path: path)
            try appendChildren(
                of: chapter,
                [("sections", .section, "\(path)/sections"), ("pericopae", .pericope, "\(path)/pericopae"), ("verses", .verse, "\(path)/verses")],
                chapter: chapterNumber, parentID: nil, sectionLevel: 1, parentFootnotes: meaningful(chapter["footnotes"]), path: path
            )
        }
    }

    /// A chapter's number: in 2.3 a whole one, where `0.5` was read as
    /// chapter 0 and let its units' verses sit in no chapter. Found by Codex.
    /// A 2.2 chapter is read as it was.
    private func chapterNumber(of chapter: [String: Any], path: String, legacyPath: String) throws -> Int {
        guard rich else { return try JSONSupport.requiredInteger(chapter["chapter"], path: legacyPath) }
        guard let number = LampCommentaryBlocks.wholeNumber(chapter["chapter"]) else {
            throw ModuleCompilationError.invalidValue(path: path, expected: "a whole chapter number")
        }
        // One its book has, or 0: a verse made from chapter 22 of John, for
        // an introduction or a passage given none, was filed where no reader
        // looks. Found by Codex.
        if (1...66).contains(bookNumber), !(0...LampCanonicalBooks.verseCounts[bookNumber - 1].count).contains(number) {
            throw ModuleCompilationError.invalidValue(
                path: path, expected: "a chapter of book \(bookNumber), from 0 to \(LampCanonicalBooks.verseCounts[bookNumber - 1].count)"
            )
        }
        return number
    }

    private enum UnitKind { case section, pericope, verse }

    /// A container's units, list by list, each unit's own beneath it and
    /// each read as it is written; a 2.3 volume's are then numbered as a
    /// reader shows them (`orderAsReaders`).
    private mutating func appendChildren(
        of container: [String: Any],
        _ lists: [(key: String, kind: UnitKind, legacyPath: String)],
        chapter: Int,
        parentID: String?,
        sectionLevel: Int,
        parentFootnotes: Any?,
        path: String
    ) throws {
        for list in lists {
            for (index, value) in units(container, list.key, at: path).enumerated() {
                let unitPath = "\(path)/\(list.key)/\(index)"
                let unit = try JSONSupport.requiredObject(value, path: rich ? unitPath : list.legacyPath)
                switch list.kind {
                case .section:
                    try appendSection(unit, chapter: chapter, parentID: parentID, level: sectionLevel, path: unitPath)
                case .pericope:
                    try appendPericope(unit, chapter: chapter, parentID: parentID, path: unitPath)
                case .verse:
                    try appendVerse(unit, chapter: chapter, parentID: parentID, parentFootnotes: parentFootnotes, path: unitPath)
                }
            }
        }
    }

    private mutating func appendIntroduction(of chapter: [String: Any], chapter chapterNumber: Int, path: String) throws {
        guard let introduction = meaningfulText(chapter["introduction"], path: path) else { return }
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

    /// The fields each 2.3 unit may give, all of them read: one the builder
    /// does not read is refused where written, not left out unseen.
    /// Reviewing commit 5 found one such field after another; a check of the
    /// whole unit ends the class. `footnotes` and `footnoteIds` are Rule A's
    /// to refuse; `source`, `sourceChapter`, `classification` and a heading
    /// pericope's `basis` (the NIC extractor's, found by Codex) say where a
    /// printed volume's text came from, which no reader shows. A split
    /// heading's `remainder` and `textEnd` are not among them: whether they
    /// repeat what an entry holds cannot be told here, and kept they were
    /// once the only copy of a paragraph. A 2.3 conversion drops them.
    /// Found by Codex. A section's `level` is the depth it was
    /// printed at; its nesting is the depth it is shown at, so a top-level
    /// section printed at level 2 (5 in the study Bible) is shown at the top.
    /// Refused, it would refuse the study Bible (found by Codex; kept).
    private static let chapterKeys: Set<String> = ["chapter", "introduction", "sections", "pericopae", "verses", "footnotes", "footnoteIds"]
    private static let sectionKeys: Set<String> = [
        "id", "title", "sv", "ev", "level", "introduction", "blocks", "subsections", "pericopae", "footnotes", "footnoteIds",
    ]
    private static let pericopeKeys: Set<String> = [
        "id", "title", "sv", "ev", "introduction", "translation", "commentary", "blocks", "content", "verses",
        "source", "sourceOrder", "sourceChapter", "basis", "footnotes", "footnoteIds",
    ]
    private static let verseKeys: Set<String> = [
        "sv", "ev", "suffix", "title", "translation", "commentary", "blocks", "footnotes", "footnoteIds",
    ]
    private static let entryKeys: Set<String> = [
        "type", "sv", "ev", "content", "blocks", "displayPrefixLength", "source", "sourceChapter", "classification",
        "footnotes", "footnoteIds",
    ]

    /// The id a 2.3 section or pericope declares: words, or refused where
    /// written. A number was read as none, and a link naming it found
    /// nothing. Found by Codex.
    private mutating func declaredID(of unit: [String: Any], path: String) -> String? {
        guard let given = unit["id"], !(given is NSNull) else { return nil }
        guard let id = given as? String else {
            issues.append(.init(severity: .error, path: "\(path)/id", message: "An id is a string."))
            return nil
        }
        return id
    }

    private mutating func readWhole(_ unit: [String: Any], as kind: String, allowed: Set<String>, path: String) {
        guard rich else { return }
        for key in unit.keys.sorted() where !allowed.contains(key) {
            issues.append(.init(
                severity: .error, path: "\(path)/\(LampBookUnread.escaped(key))",
                message: "A 2.3 \(kind) gives no `\(key)`: nothing reads it, so it would be left out."
            ))
        }
    }

    /// A 2.3 unit's own verse and end, where given: whole verse numbers in
    /// a chapter of this book, the end no earlier than the start the row
    /// keeps — its own, or the one it takes from `inherited`. A fractional
    /// `sv` was truncated and taken as the unit's own, a string one passed
    /// over for its passage's (found reviewing commit 5). Chapter 0 only for
    /// a unit written in chapter 0, at any depth: elsewhere a verse there was
    /// filed out of its chapter, and no link names it. Found by Codex.
    private mutating func checkOwnVerse(_ unit: [String: Any], path: String, inherited: Int?) {
        guard rich else { return }
        var start = inherited
        for key in ["sv", "ev"] {
            guard let given = unit[key], !(given is NSNull) else { continue }
            guard let verse = LampCommentaryBlocks.wholeNumber(given), verse > 0 else {
                issues.append(.init(
                    severity: .error, path: "\(path)/\(key)",
                    message: "A verse is a whole number: book × 1,000,000 + chapter × 1,000 + verse."
                ))
                if key == "sv" { start = nil }
                continue
            }
            // An end may run into a later book, as an outline over the end of
            // one book and the start of the next does. Found by Codex.
            let book = verse / 1_000_000
            if key == "ev", book > bookNumber, book <= 66 {
                if verse / 1_000 % 1_000 == 0 {
                    issues.append(.init(severity: .error, path: "\(path)/ev", message: "A unit's verse is in a chapter; \(verse) names none."))
                }
            } else if book != bookNumber {
                issues.append(.init(
                    severity: .error, path: "\(path)/\(key)",
                    message: "A unit's verse is in its own book (\(bookNumber)); \(verse) is not."
                ))
            } else if verse / 1_000 % 1_000 == 0, writtenChapter != 0 {
                issues.append(.init(
                    severity: .error, path: "\(path)/\(key)",
                    message: "A unit's verse is in a chapter; \(verse) names none."
                ))
            }
            // In a chapter its book has, by the grid every Lamp translation
            // shares: filed in one it has not, a unit was in no chapter a
            // reader opens. Found by Codex.
            if (1...66).contains(book), verse / 1_000 % 1_000 > LampCanonicalBooks.verseCounts[book - 1].count {
                issues.append(.init(
                    severity: .error, path: "\(path)/\(key)",
                    message: "Book \(book) has \(LampCanonicalBooks.verseCounts[book - 1].count) chapters; \(verse) is past them."
                ))
            }
            if key == "sv" {
                start = verse
            } else if let start, verse < start {
                issues.append(.init(severity: .error, path: "\(path)/ev", message: "A passage ends no earlier than it starts."))
            }
        }
    }

    /// A 2.3 section or pericope, in a volume placed by verse, gives the verse
    /// it is placed at: given none, it was placed at its chapter's first
    /// verse or its parent's, a guess no reader could look it up by.
    private mutating func refuseUnplaced(_ unit: [String: Any], as kind: String, path: String) {
        guard rich, !sourceOrdered, unit["sv"] == nil || unit["sv"] is NSNull else { return }
        issues.append(.init(
            severity: .error, path: "\(path)/sv",
            message: "A 2.3 \(kind) gives the verse it starts at, `sv`, which is where it is placed and found."
        ))
    }

    /// A 2.3 unit placed by verse starts no earlier than the unit it is
    /// written under, as every subsection in the study Bible does. Listed
    /// by verse, one that started earlier came before its parent, and a
    /// reader's outline above it found the parent in another chapter, read
    /// a passage as a heading, or took a later heading as its own — three
    /// review rounds running. Found by Codex.
    private mutating func refuseStartBeforeParent(_ unit: [String: Any], parentID: String?, path: String) {
        guard rich, !sourceOrdered, let parentID, let parentStart = startByRowID[parentID],
              let start = LampCommentaryBlocks.wholeNumber(unit["sv"]), start < parentStart else { return }
        issues.append(.init(
            severity: .error, path: "\(path)/sv",
            message: "A unit starts no earlier than the one it is written under (\(parentStart)); \(start) is before it."
        ))
    }

    /// The chapter a 2.3 unit is filed under: its own verse's, where it
    /// gives one in this book, so a reader looking up that chapter finds it
    /// wherever the volume wrote it. A 2.2 unit keeps the chapter it is in.
    private func filed(_ unit: [String: Any], in chapter: Int) -> Int {
        guard rich, let verse = LampCommentaryBlocks.wholeNumber(unit["sv"]), verse > 0, verse / 1_000_000 == bookNumber else {
            return chapter
        }
        return verse / 1_000 % 1_000
    }

    private mutating func appendSection(
        _ section: [String: Any],
        chapter: Int,
        parentID: String?,
        level: Int,
        path: String
    ) throws {
        readWhole(section, as: "section", allowed: Self.sectionKeys, path: path)
        checkOwnVerse(section, path: path, inherited: rich ? try defaultStartVerse(chapter: chapter) : nil)
        let chapter = filed(section, in: chapter)
        let id = "\(moduleID):\(bookNumber):section:\(chapter):\(orderIndex)"
        refuseUnplaced(section, as: "section", path: path)
        refuseStartBeforeParent(section, parentID: parentID, path: path)
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
            declaredID: rich ? declaredID(of: section, path: path) : nil
        )

        try appendChildren(
            of: section,
            [("subsections", UnitKind.section, "/chapters/sections/subsections"), ("pericopae", .pericope, "/chapters/sections/pericopae")],
            chapter: chapter, parentID: id, sectionLevel: level + 1, parentFootnotes: nil, path: path
        )
    }

    private mutating func appendPericope(
        _ pericope: [String: Any],
        chapter: Int,
        parentID: String?,
        path: String
    ) throws {
        readWhole(pericope, as: "pericope", allowed: Self.pericopeKeys, path: path)
        checkOwnVerse(pericope, path: path, inherited: rich ? try defaultStartVerse(chapter: chapter) : nil)
        let chapter = filed(pericope, in: chapter)
        // Read only in printed order, which a volume that is not
        // source-tracked does not keep: there its passages are numbered by
        // verse. Found by Codex.
        if rich, !sourceOrdered, pericope["sourceOrder"] != nil {
            issues.append(.init(
                severity: .error, path: "\(path)/sourceOrder",
                message: "Only a source-tracked volume keeps a printed order; here passages are ordered by verse."
            ))
        }
        let id = "\(moduleID):\(bookNumber):pericope:\(chapter):\(orderIndex)"
        refuseUnplaced(pericope, as: "pericope", path: path)
        refuseStartBeforeParent(pericope, parentID: parentID, path: path)
        // Content entries are a source-tracked volume's, in printed order;
        // here a passage's rows are placed by verse, and an entry's place
        // would be a guess. Found planning step 4, commit 6.
        if rich, !sourceOrdered, pericope["content"] != nil, !(pericope["content"] is NSNull) {
            issues.append(.init(
                severity: .error, path: "\(path)/content",
                message: "Content entries belong to a source-tracked volume; give this passage's body as blocks or commentary."
            ))
        }
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
        // Its entries are refused here by themselves, so not told again.
        let body = sourceOrdered ? nil : richBody(of: pericope, path: path, replacing: ["commentary"])
        // One body: a 2.3 pericope's `commentary` beside the entries it is
        // built from is refused, as its `blocks` there are. Found by Codex.
        // In a source-tracked volume, the body goes on the entries, given
        // or not. Found by Codex.
        if rich, sourceOrdered, pericope["commentary"] != nil, !(pericope["commentary"] is NSNull),
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
        if rich, sourceOrdered, let content = pericope["content"], !(content is NSNull), !(content is [Any]) {
            issues.append(.init(severity: .error, path: "\(path)/content", message: "A pericope's content entries are a list."))
        }
        // Entries refused outside a source-tracked volume are not built as
        // well: their faults, and their passages, would be told beside the
        // one fault that matters. Found by Codex.
        let readsEntries = !rich || sourceOrdered
        if rich, readsEntries, let content = JSONSupport.array(pericope["content"]) {
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
            declaredID: rich ? declaredID(of: pericope, path: path) : nil
        )

        // Read as a list first, so one given as an object is told too.
        // Found by Codex.
        // Content entries the builder uses, a list; a `null` is none. Found
        // by Codex.
        let entries = readsEntries && pericope["content"] is [Any]
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
        if readsEntries, let content = JSONSupport.array(pericope["content"]) {
            let parentStart = try JSONSupport.integer(pericope["sv"]) ?? defaultStartVerse(chapter: chapter)
            for (index, value) in content.enumerated() {
                let block = try JSONSupport.requiredObject(value, path: rich ? "\(path)/content/\(index)" : "/pericopae/content/\(index)")
                let role = try JSONSupport.requiredString(block["type"], path: rich ? "\(path)/content/\(index)/type" : "/pericopae/content/type")
                readWhole(block, as: "content entry", allowed: Self.entryKeys, path: "\(path)/content/\(index)")
                checkOwnVerse(block, path: "\(path)/content/\(index)", inherited: parentStart)
                // Printed indexes belong to indices_json, not the last passage.
                if role == "index" {
                    // A 2.3 index is the volume's `indices`: an entry here was
                    // passed over, its text written nowhere. Found by Codex.
                    if rich {
                        issues.append(.init(
                            severity: .error, path: "\(path)/content/\(index)",
                            message: "A printed index is given in the volume's indices, not as a passage's entry."
                        ))
                    }
                    continue
                }
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
                // A verse row here is one more paragraph of a printed note, so
                // others on its verse are welcome; a verse note there is not.
                // Found by Codex.
                if rich, kind == "verse" {
                    let passage = Array("\(start)|\(end ?? start)|".utf8)
                    entryPassages.insert(passage)
                    if versePassages.contains(passage) {
                        issues.append(.init(
                            severity: .error, path: "\(path)/content/\(index)",
                            message: "A verse note on this passage is given already; an entry's note and a verse note would answer one lookup."
                        ))
                    }
                }
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

        try appendChildren(
            of: pericope, [("verses", .verse, "/chapters/pericopae/verses")],
            chapter: chapter, parentID: id, sectionLevel: 1, parentFootnotes: footnotes, path: path
        )
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
        readWhole(verse, as: "verse", allowed: Self.verseKeys, path: path)
        checkOwnVerse(verse, path: path, inherited: nil)
        refuseStartBeforeParent(verse, parentID: parentID, path: path)
        let chapter = filed(verse, in: chapter)
        let suffix = JSONSupport.string(verse["suffix"]) ?? ""
        // A suffix is words: given otherwise, the note was stored as one with
        // none. Found by Codex.
        if rich, let given = verse["suffix"], !(given is NSNull), !(given is String) {
            issues.append(.init(severity: .error, path: "\(path)/suffix", message: "A suffix is a string, such as \"b\"."))
        }
        // A NUL ends a stored suffix there, so `a` and `a\0b` would be one.
        // Found by Codex.
        if rich, suffix.contains("\0") {
            issues.append(.init(severity: .error, path: "\(path)/suffix", message: "A suffix holds no NUL character."))
        }
        // One verse note on a passage: a second at the same verses and
        // suffix would be a second answer to one lookup, in no set order.
        // No `ev` is an end at `sv`, as a lookup reads it. Found by Codex.
        // An entry's verse rows count too: a passage link opened whichever
        // came first. Found by Codex.
        let passage = Array("\(startVerse)|\(LampCommentaryBlocks.wholeNumber(verse["ev"]) ?? startVerse)|\(suffix)".utf8)
        if rich, !versePassages.insert(passage).inserted || entryPassages.contains(passage) {
            issues.append(.init(
                severity: .error, path: path,
                message: "A verse note on this passage is given already; give one note, or tell them apart by `suffix`."
            ))
        }
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
        if rich { startByRowID[id] = startVerse }
        // A link names a unit by its verse and declared id, so one id twice
        // at one verse names two. Found planning step 4.
        // A NUL ends a stored id there, so `a` and `a\0b` would be one.
        // Found by Codex.
        if rich, let declaredID, declaredID.contains("\0") {
            issues.append(.init(severity: .error, path: "\(path)/id", message: "An id holds no NUL character."))
        }
        // An empty id names nothing: a link's `unit` is refused empty.
        // Found by Codex.
        if rich, declaredID?.isEmpty == true {
            issues.append(.init(severity: .error, path: "\(path)/id", message: "An id is not empty."))
        }
        if rich, let declaredID, !declaredAtVerse.insert(Array("\(startVerse)|\(declaredID)".utf8)).inserted {
            issues.append(.init(
                severity: .error, path: "\(path)/id",
                message: "Another unit at this verse declares the id \"\(declaredID)\"; a link would name both."
            ))
        }
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
