import CryptoKit
import Foundation
import GRDB
import LampModuleKit

/// A persistent, module-native Lamp Bible library.
///
/// Installable `.lamp` files remain the portable source of truth. A verified,
/// decompressed SQLite copy is stored beside them so readers can open chapters
/// immediately without recomputing a database on every launch.
public actor LampLibrary {
    public nonisolated let rootURL: URL

    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootURL = applicationSupport
                .appendingPathComponent("Lamp Bible", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        }
    }

    public func installedModules() throws -> [LampInstalledModule] {
        try prepareDirectories()
        let databaseURLs = try fileManager.contentsOfDirectory(
            at: databasesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return databaseURLs
            .filter { $0.pathExtension.lowercased() == "sqlite" }
            .compactMap { databaseURL in
                let storageKey = databaseURL.deletingPathExtension().lastPathComponent
                let lampURL = modulesURL
                    .appendingPathComponent(storageKey)
                    .appendingPathExtension("lamp")
                let byteCount = (try? lampURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return try? inspectDatabase(
                    at: databaseURL,
                    fallbackID: nil,
                    compressedByteCount: byteCount
                )
            }
            .sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> LampInstalledModule {
        guard sourceURL.pathExtension.lowercased() == "lamp" else {
            throw LampLibraryError.invalidFileExtension
        }

        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let compressedData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampLibraryError.decompressionFailed
        }

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-install-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: temporaryURL, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let module = try inspectDatabase(
            at: temporaryURL,
            fallbackID: sourceURL.deletingPathExtension().lastPathComponent,
            compressedByteCount: compressedData.count
        )
        try validateIdentifier(module.id)
        try prepareDirectories()

        let storageKey = storageKey(for: module.id)
        let installedDatabaseURL = databasesURL
            .appendingPathComponent(storageKey)
            .appendingPathExtension("sqlite")
        let installedModuleURL = modulesURL
            .appendingPathComponent(storageKey)
            .appendingPathExtension("lamp")

        // The database is written first. If the second write fails, an existing
        // portable module remains intact and the derived database is recoverable.
        try databaseData.write(to: installedDatabaseURL, options: [.atomic])
        try compressedData.write(to: installedModuleURL, options: [.atomic])
        return module
    }

    public func remove(moduleID: String) throws {
        let storageKey = storageKey(for: moduleID)
        let databaseURL = databasesURL
            .appendingPathComponent(storageKey)
            .appendingPathExtension("sqlite")
        let moduleURL = modulesURL
            .appendingPathComponent(storageKey)
            .appendingPathExtension("lamp")

        guard fileManager.fileExists(atPath: databaseURL.path)
                || fileManager.fileExists(atPath: moduleURL.path) else {
            throw LampLibraryError.moduleNotFound(moduleID)
        }
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        if fileManager.fileExists(atPath: moduleURL.path) {
            try fileManager.removeItem(at: moduleURL)
        }
        let userQueue = try openUserDatabase()
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM selected_plans WHERE plan_id = ?", arguments: [moduleID])
            try db.execute(sql: "DELETE FROM completed_readings WHERE plan_id = ?", arguments: [moduleID])
        }
    }

    public func translationBooks(moduleID: String) throws -> [LampTranslationBook] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            if tables.contains("books") && tables.contains("translation_meta") {
                return try Row.fetchAll(db, sql: """
                    SELECT id, book_id, name, testament, chapter_count
                    FROM books
                    ORDER BY id
                    """).map(makeBook)
            }
            if tables.contains("translation_books") {
                return try Row.fetchAll(db, sql: """
                    SELECT book_number AS id, book_id, name, testament, chapter_count
                    FROM translation_books
                    WHERE translation_id = ?
                    ORDER BY book_number
                    """, arguments: [moduleID]).map(makeBook)
            }
            throw LampLibraryError.notATranslation(moduleID)
        }
    }

    public func chapter(
        moduleID: String,
        bookNumber: Int,
        chapterNumber: Int
    ) throws -> LampChapter {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            let compact = tables.contains("translation_meta") && tables.contains("verses")
            let book: LampTranslationBook
            let verses: [LampVerse]
            let headings: [LampHeading]

            if compact {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, book_id, name, testament, chapter_count
                    FROM books WHERE id = ?
                    """, arguments: [bookNumber]) else {
                    throw LampLibraryError.moduleNotFound(moduleID)
                }
                book = makeBook(row)
                let verseColumns = try columnNames(in: db, table: "verses")
                let annotations = verseColumns.contains("annotations_json")
                    ? "annotations_json" : "NULL AS annotations_json"
                let footnotes = verseColumns.contains("footnotes_json")
                    ? "footnotes_json" : "NULL AS footnotes_json"
                let footnoteReferences = verseColumns.contains("footnote_refs_json")
                    ? "footnote_refs_json" : "NULL AS footnote_refs_json"
                let poetry = verseColumns.contains("poetry_json")
                    ? "poetry_json" : "NULL AS poetry_json"
                verses = try Row.fetchAll(db, sql: """
                    SELECT ref AS id, verse AS number, text, paragraph,
                           \(annotations), \(footnotes), \(footnoteReferences), \(poetry)
                    FROM verses
                    WHERE book = ? AND chapter = ?
                    ORDER BY verse
                    """, arguments: [bookNumber, chapterNumber]).map(makeVerse)
                if tables.contains("headings") {
                    headings = try Row.fetchAll(db, sql: """
                        SELECT id, before_verse, level, text
                        FROM headings
                        WHERE book = ? AND chapter = ?
                        ORDER BY before_verse, level, id
                        """, arguments: [bookNumber, chapterNumber]).map(makeHeading)
                } else {
                    headings = []
                }
            } else if tables.contains("translation_verses") {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT book_number AS id, book_id, name, testament, chapter_count
                    FROM translation_books
                    WHERE translation_id = ? AND book_number = ?
                    """, arguments: [moduleID, bookNumber]) else {
                    throw LampLibraryError.moduleNotFound(moduleID)
                }
                book = makeBook(row)
                let verseColumns = try columnNames(in: db, table: "translation_verses")
                let annotations = verseColumns.contains("annotations_json")
                    ? "annotations_json" : "NULL AS annotations_json"
                let footnotes = verseColumns.contains("footnotes_json")
                    ? "footnotes_json" : "NULL AS footnotes_json"
                let footnoteReferences = verseColumns.contains("footnote_refs_json")
                    ? "footnote_refs_json" : "NULL AS footnote_refs_json"
                let poetry = verseColumns.contains("poetry_json")
                    ? "poetry_json" : "NULL AS poetry_json"
                verses = try Row.fetchAll(db, sql: """
                    SELECT ref AS id, verse AS number, text, paragraph,
                           \(annotations), \(footnotes), \(footnoteReferences), \(poetry)
                    FROM translation_verses
                    WHERE translation_id = ? AND book = ? AND chapter = ?
                    ORDER BY verse
                    """, arguments: [moduleID, bookNumber, chapterNumber]).map(makeVerse)
                if tables.contains("translation_headings") {
                    headings = try Row.fetchAll(db, sql: """
                        SELECT id, before_verse, level, text
                        FROM translation_headings
                        WHERE translation_id = ? AND book = ? AND chapter = ?
                        ORDER BY before_verse, level, id
                        """, arguments: [moduleID, bookNumber, chapterNumber]).map(makeHeading)
                } else {
                    headings = []
                }
            } else {
                throw LampLibraryError.notATranslation(moduleID)
            }

            guard !verses.isEmpty else {
                throw LampLibraryError.emptyChapter(book: bookNumber, chapter: chapterNumber)
            }
            return LampChapter(
                translationID: moduleID,
                book: book,
                number: chapterNumber,
                verses: verses,
                headings: headings
            )
        }
    }

    public func verseStudyData(
        moduleID: String,
        reference: Int
    ) throws -> LampVerseStudyData? {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            let table: String
            let condition: String
            let arguments: StatementArguments

            if tables.contains("translation_meta") && tables.contains("verses") {
                table = "verses"
                condition = "ref = ?"
                arguments = [reference]
            } else if tables.contains("translation_verses") {
                table = "translation_verses"
                condition = "translation_id = ? AND ref = ?"
                arguments = [moduleID, reference]
            } else {
                throw LampLibraryError.notATranslation(moduleID)
            }

            let columns = try columnNames(in: db, table: table)
            let projection: (String) -> String = { column in
                columns.contains(column) ? column : "NULL AS \(column)"
            }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT text,
                       \(projection("annotations_json")),
                       \(projection("footnotes_json")),
                       \(projection("footnote_refs_json"))
                FROM \(table)
                WHERE \(condition)
                LIMIT 1
                """, arguments: arguments) else {
                return nil
            }

            let annotationsJSON: String? = row["annotations_json"]
            let footnotesJSON: String? = row["footnotes_json"]
            let footnoteReferencesJSON: String? = row["footnote_refs_json"]
            let verseText: String = row["text"]
            return LampVerseStudyData(
                translationID: moduleID,
                reference: reference,
                annotations: verseAnnotations(from: annotationsJSON, verseText: verseText),
                footnotes: verseFootnotes(from: footnotesJSON),
                footnoteReferences: verseFootnoteReferences(from: footnoteReferencesJSON)
            )
        }
    }

    public func searchTranslations(
        query: String,
        moduleIDs: Set<String>? = nil,
        limit: Int = 100
    ) throws -> [LampTranslationSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let resultLimit = min(max(limit, 1), 500)
        let ftsQuery = trimmedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
        let translations = try installedModules().filter {
            $0.kind == .translation && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }
        let perTranslationLimit = moduleIDs == nil && translations.count > 1
            ? max(1, resultLimit / translations.count)
            : resultLimit
        var results: [LampTranslationSearchResult] = []

        for translation in translations where results.count < resultLimit {
            let queue = try openDatabase(moduleID: translation.id)
            let remainingLimit = min(perTranslationLimit, resultLimit - results.count)
            let moduleResults = try queue.read { db -> [LampTranslationSearchResult] in
                let tables = try tableNames(in: db)
                let rows: [Row]

                if tables.contains("translation_meta") && tables.contains("verses") {
                    if tables.contains("verses_fts") {
                        rows = try Row.fetchAll(db, sql: """
                            SELECT v.ref, v.book, b.name AS book_name,
                                   v.chapter, v.verse, v.text
                            FROM verses_fts
                            JOIN verses v ON v.id = verses_fts.rowid
                            JOIN books b ON b.id = v.book
                            WHERE verses_fts MATCH ?
                            ORDER BY bm25(verses_fts), v.ref
                            LIMIT ?
                            """, arguments: [ftsQuery, remainingLimit])
                    } else {
                        rows = try Row.fetchAll(db, sql: """
                            SELECT v.ref, v.book, b.name AS book_name,
                                   v.chapter, v.verse, v.text
                            FROM verses v
                            JOIN books b ON b.id = v.book
                            WHERE v.text LIKE ? COLLATE NOCASE
                            ORDER BY v.ref
                            LIMIT ?
                            """, arguments: ["%\(trimmedQuery)%", remainingLimit])
                    }
                } else if tables.contains("translation_verses") {
                    if tables.contains("translation_verses_fts") {
                        rows = try Row.fetchAll(db, sql: """
                            SELECT v.ref, v.book, b.name AS book_name,
                                   v.chapter, v.verse, v.text
                            FROM translation_verses_fts
                            JOIN translation_verses v ON v.id = translation_verses_fts.rowid
                            JOIN translation_books b
                              ON b.translation_id = v.translation_id
                             AND b.book_number = v.book
                            WHERE translation_verses_fts MATCH ?
                              AND v.translation_id = ?
                            ORDER BY bm25(translation_verses_fts), v.ref
                            LIMIT ?
                            """, arguments: [ftsQuery, translation.id, remainingLimit])
                    } else {
                        rows = try Row.fetchAll(db, sql: """
                            SELECT v.ref, v.book, b.name AS book_name,
                                   v.chapter, v.verse, v.text
                            FROM translation_verses v
                            JOIN translation_books b
                              ON b.translation_id = v.translation_id
                             AND b.book_number = v.book
                            WHERE v.translation_id = ?
                              AND v.text LIKE ? COLLATE NOCASE
                            ORDER BY v.ref
                            LIMIT ?
                            """, arguments: [translation.id, "%\(trimmedQuery)%", remainingLimit])
                    }
                } else {
                    throw LampLibraryError.notATranslation(translation.id)
                }

                return rows.map { row in
                    LampTranslationSearchResult(
                        translationID: translation.id,
                        translationName: translation.name,
                        translationAbbreviation: translation.abbreviation,
                        reference: row["ref"],
                        bookNumber: row["book"],
                        bookName: row["book_name"],
                        chapterNumber: row["chapter"],
                        verseNumber: row["verse"],
                        text: row["text"]
                    )
                }
            }
            results.append(contentsOf: moduleResults)
        }
        return results
    }

    public func searchDictionaries(
        query: String,
        moduleIDs: Set<String>? = nil,
        limit: Int = 100
    ) throws -> [LampDictionaryResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let resultLimit = min(max(limit, 1), 500)
        let dictionaries = try installedModules().filter {
            $0.kind == .dictionary && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }
        let perDictionaryLimit = moduleIDs == nil && dictionaries.count > 1
            ? max(1, resultLimit / dictionaries.count)
            : resultLimit
        var results: [LampDictionaryResult] = []

        for dictionary in dictionaries where results.count < resultLimit {
            let queue = try openDatabase(moduleID: dictionary.id)
            let queryLimit = min(perDictionaryLimit, resultLimit - results.count)
            let entries = try queue.read { db -> [LampDictionaryResult] in
                let tables = try tableNames(in: db)
                guard tables.contains("dictionary_entries") else {
                    throw LampLibraryError.unsupportedModuleSchema
                }
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(dictionary_entries)")
                    .compactMap { $0["name"] as String? })
                guard columns.contains("senses_json") else {
                    throw LampLibraryError.unsupportedModuleSchema
                }
                var searchColumns = ["key", "lemma", "transliteration", "senses_json"]
                if columns.contains("search_text") { searchColumns.append("search_text") }
                let conditions = searchColumns.map { "\($0) LIKE ? COLLATE NOCASE" }
                    .joined(separator: " OR ")
                let pattern = "%\(trimmedQuery)%"
                var queryArguments = StatementArguments(
                    Array(repeating: pattern, count: searchColumns.count)
                )
                queryArguments += [trimmedQuery, trimmedQuery, queryLimit]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, key, lemma, transliteration, pronunciation, senses_json
                    FROM dictionary_entries
                    WHERE \(conditions)
                    ORDER BY
                        CASE
                            WHEN key = ? COLLATE NOCASE THEN 0
                            WHEN lemma = ? COLLATE NOCASE THEN 1
                            ELSE 2
                        END,
                        key, lemma
                    LIMIT ?
                    """, arguments: queryArguments)

                return rows.map { row in
                    let sensesJSON: String? = row["senses_json"]
                    return LampDictionaryResult(
                        entryID: row["id"],
                        moduleID: dictionary.id,
                        moduleName: dictionary.name,
                        key: row["key"],
                        lemma: row["lemma"],
                        transliteration: row["transliteration"],
                        pronunciation: row["pronunciation"],
                        senses: dictionarySenses(from: sensesJSON)
                    )
                }
            }
            results.append(contentsOf: entries)
        }
        return results
    }

    public func commentary(
        bookNumber: Int,
        chapterNumber: Int,
        reference: Int? = nil,
        moduleIDs: Set<String>? = nil
    ) throws -> [LampCommentaryUnit] {
        let commentaries = try installedModules().filter {
            $0.kind == .commentary && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }
        var results: [LampCommentaryUnit] = []

        for commentaryModule in commentaries {
            let queue = try openDatabase(moduleID: commentaryModule.id)
            let units = try queue.read { db -> [LampCommentaryUnit] in
                let tables = try tableNames(in: db)
                guard tables.contains("commentary_units") else { return [] }

                var condition = "book = ? AND chapter = ?"
                var arguments: StatementArguments = [bookNumber, chapterNumber]
                if let reference {
                    condition += " AND ((sv <= ? AND COALESCE(ev, sv) >= ?) OR level = 0)"
                    arguments += [reference, reference]
                }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, book, chapter, sv, ev, unit_type, level, title,
                           introduction_json, translation_json, commentary_json,
                           footnotes_json, order_index
                    FROM commentary_units
                    WHERE \(condition)
                    ORDER BY order_index, sv, level
                    """, arguments: arguments)

                return rows.map { row in
                    let introductionJSON: String? = row["introduction_json"]
                    let translationJSON: String? = row["translation_json"]
                    let commentaryJSON: String? = row["commentary_json"]
                    let footnotesJSON: String? = row["footnotes_json"]
                    let scriptureLinks = [
                        introductionJSON,
                        translationJSON,
                        commentaryJSON,
                        footnotesJSON,
                    ].flatMap(scriptureLinks(fromJSONString:))
                    return LampCommentaryUnit(
                        unitID: row["id"],
                        moduleID: commentaryModule.id,
                        moduleName: commentaryModule.name,
                        seriesAbbreviation: commentaryModule.abbreviation,
                        bookNumber: row["book"],
                        chapterNumber: row["chapter"],
                        startReference: row["sv"],
                        endReference: row["ev"],
                        unitType: row["unit_type"],
                        level: row["level"],
                        title: row["title"],
                        introduction: plainText(fromJSONString: introductionJSON),
                        translation: plainText(fromJSONString: translationJSON),
                        commentary: plainText(fromJSONString: commentaryJSON),
                        footnotes: plainText(fromJSONString: footnotesJSON),
                        scriptureLinks: scriptureLinks,
                        orderIndex: row["order_index"]
                    )
                }
            }
            results.append(contentsOf: units)
        }
        return results
    }

    public func readingPlans() throws -> [LampReadingPlan] {
        let modules = try installedModules().filter { $0.kind == .plan }
        return try modules.compactMap { module in
            let queue = try openDatabase(moduleID: module.id)
            return try queue.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id, name, description, author, full_description,
                           duration, readings_per_day
                    FROM plans
                    WHERE id = ?
                    LIMIT 1
                    """, arguments: [module.id]) else {
                    return nil
                }
                return LampReadingPlan(
                    id: row["id"],
                    name: row["name"],
                    description: row["description"],
                    author: row["author"],
                    fullDescription: row["full_description"],
                    duration: row["duration"],
                    readingsPerDay: row["readings_per_day"]
                )
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func readingPlanDay(moduleID: String, day: Int) throws -> LampReadingPlanDay? {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            guard let readingsJSON = try String.fetchOne(db, sql: """
                SELECT readings_json
                FROM plan_days
                WHERE plan_id = ? AND day = ?
                """, arguments: [moduleID, day]),
                  let data = readingsJSON.data(using: .utf8),
                  let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            let readings = try values.enumerated().map { index, value -> LampPlanReading in
                guard let start = value["sv"] as? NSNumber,
                      let end = value["ev"] as? NSNumber else {
                    throw LampLibraryError.unsupportedModuleSchema
                }
                return LampPlanReading(
                    id: index,
                    startReference: start.intValue,
                    endReference: end.intValue
                )
            }
            return LampReadingPlanDay(planID: moduleID, day: day, readings: readings)
        }
    }

    public func selectedPlanIDs() throws -> Set<String> {
        let queue = try openUserDatabase()
        return try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT plan_id FROM selected_plans"))
        }
    }

    public func setPlanSelected(moduleID: String, selected: Bool) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            if selected {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO selected_plans (plan_id, selected_at) VALUES (?, ?)",
                    arguments: [moduleID, Date()]
                )
            } else {
                try db.execute(sql: "DELETE FROM selected_plans WHERE plan_id = ?", arguments: [moduleID])
            }
        }
    }

    public func completedReadings(
        planID: String? = nil,
        year: Int? = nil
    ) throws -> [LampCompletedReading] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            var conditions: [String] = []
            var arguments = StatementArguments()
            if let planID {
                conditions.append("plan_id = ?")
                arguments += [planID]
            }
            if let year {
                conditions.append("year = ?")
                arguments += [year]
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
            return try Row.fetchAll(db, sql: """
                SELECT id, plan_id, day, reading_index, year, completed_at
                FROM completed_readings
                \(whereClause)
                ORDER BY completed_at
                """, arguments: arguments).map { row in
                    LampCompletedReading(
                        id: row["id"],
                        planID: row["plan_id"],
                        day: row["day"],
                        readingIndex: row["reading_index"],
                        year: row["year"],
                        completedAt: row["completed_at"]
                    )
                }
        }
    }

    public func setReadingCompleted(
        planID: String,
        day: Int,
        readingIndex: Int,
        year: Int,
        completed: Bool
    ) throws {
        let id = "\(planID)_\(day)_r\(readingIndex)_\(year)"
        let queue = try openUserDatabase()
        try queue.write { db in
            if completed {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO completed_readings (
                        id, plan_id, day, reading_index, year, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [id, planID, day, readingIndex, year, Date()])
            } else {
                try db.execute(sql: "DELETE FROM completed_readings WHERE id = ?", arguments: [id])
            }
        }
    }

    public func verseNotes(reference: Int) throws -> [LampVerseNote] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, title, content,
                       verse_refs_json, footnotes_json, last_modified
                FROM personal_notes
                WHERE verse_id = ?
                ORDER BY last_modified DESC, id
                """, arguments: [reference]).map(makeVerseNote)
        }
    }

    public func moduleVerseNotes(moduleID: String, reference: Int) throws -> [LampVerseNote] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            guard tables.contains("note_entries") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            let columns = try columnNames(in: db, table: "note_entries")
            let references = columns.contains("verse_refs_json")
                ? "verse_refs_json"
                : columns.contains("verse_refs")
                    ? "verse_refs AS verse_refs_json" : "NULL AS verse_refs_json"
            let footnotes = columns.contains("footnotes_json")
                ? "footnotes_json" : "NULL AS footnotes_json"
            let title = columns.contains("title") ? "title" : "NULL AS title"
            let modified = columns.contains("last_modified")
                ? "last_modified" : "NULL AS last_modified"
            return try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, \(title), content,
                       \(references), \(footnotes), \(modified)
                FROM note_entries
                WHERE verse_id = ?
                ORDER BY last_modified DESC, id
                """, arguments: [reference]).map(makeVerseNote)
        }
    }

    public func moduleVerseNotes(
        moduleID: String,
        bookNumber: Int,
        chapterNumber: Int
    ) throws -> [LampVerseNote] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            guard tables.contains("note_entries") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            let columns = try columnNames(in: db, table: "note_entries")
            guard columns.contains("book"), columns.contains("chapter"), columns.contains("verse") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            let references = columns.contains("verse_refs_json")
                ? "verse_refs_json"
                : columns.contains("verse_refs")
                    ? "verse_refs AS verse_refs_json" : "NULL AS verse_refs_json"
            let footnotes = columns.contains("footnotes_json")
                ? "footnotes_json" : "NULL AS footnotes_json"
            let title = columns.contains("title") ? "title" : "NULL AS title"
            let modified = columns.contains("last_modified")
                ? "last_modified" : "NULL AS last_modified"
            return try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, \(title), content,
                       \(references), \(footnotes), \(modified)
                FROM note_entries
                WHERE book = ? AND chapter = ?
                ORDER BY verse, last_modified DESC, id
                """, arguments: [bookNumber, chapterNumber]).map(makeVerseNote)
        }
    }

    public func verseNotes(bookNumber: Int, chapterNumber: Int) throws -> [LampVerseNote] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, title, content,
                       verse_refs_json, footnotes_json, last_modified
                FROM personal_notes
                WHERE book = ? AND chapter = ?
                ORDER BY verse, last_modified DESC, id
                """, arguments: [bookNumber, chapterNumber]).map(makeVerseNote)
        }
    }

    public func saveVerseNote(_ note: LampVerseNote) throws {
        let queue = try openUserDatabase()
        let referencesData = try JSONEncoder().encode(note.verseReferences)
        let referencesJSON = String(decoding: referencesData, as: UTF8.self)
        let footnotes = note.footnotes.map { footnote -> [String: String] in
            var value = ["id": footnote.id, "content": footnote.content]
            if let kind = footnote.kind { value["type"] = kind }
            return value
        }
        let footnotesData = try JSONSerialization.data(withJSONObject: footnotes, options: [.sortedKeys])
        let footnotesJSON = String(decoding: footnotesData, as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO personal_notes (
                    id, module_id, verse_id, book, chapter, verse,
                    title, content, verse_refs_json, footnotes_json, last_modified
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    note.id,
                    note.moduleID,
                    note.reference,
                    note.bookNumber,
                    note.chapterNumber,
                    note.verseNumber,
                    note.title,
                    note.content,
                    referencesJSON,
                    footnotesJSON,
                    Int(note.lastModified.timeIntervalSince1970),
                ])
        }
    }

    @discardableResult
    public func setPersonalVerseNote(
        reference: Int,
        title: String? = nil,
        content: String
    ) throws -> LampVerseNote? {
        let noteID = "personal-notes:\(reference)"
        let meaningfulTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if meaningfulTitle?.isEmpty != false && meaningfulContent.isEmpty {
            try deleteVerseNote(id: noteID)
            return nil
        }
        let existing = try verseNotes(reference: reference)
            .first { $0.id == noteID }
        let note = LampVerseNote(
            id: noteID,
            reference: reference,
            title: meaningfulTitle?.isEmpty == false ? title : nil,
            content: content,
            verseReferences: existing?.verseReferences ?? [],
            footnotes: existing?.footnotes ?? []
        )
        try saveVerseNote(note)
        return note
    }

    public func deleteVerseNote(id: String) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM personal_notes WHERE id = ?", arguments: [id])
        }
    }

    public func verseHighlights(
        translationID: String,
        reference: Int
    ) throws -> [LampVerseHighlight] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT h.id, h.set_id, s.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h
                JOIN highlight_sets s ON s.id = h.set_id
                WHERE s.translation_id = ? AND h.ref = ?
                ORDER BY h.sc, h.ec, h.id
                """, arguments: [translationID, reference]).map(makeVerseHighlight)
        }
    }

    public func moduleVerseHighlights(
        moduleID: String,
        reference: Int
    ) throws -> [LampVerseHighlight] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            try readModuleHighlights(in: db, referenceRange: reference...reference)
        }
    }

    public func moduleVerseHighlights(
        moduleID: String,
        bookNumber: Int,
        chapterNumber: Int
    ) throws -> [LampVerseHighlight] {
        let startReference = bookNumber * 1_000_000 + chapterNumber * 1_000 + 1
        let endReference = bookNumber * 1_000_000 + chapterNumber * 1_000 + 999
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            try readModuleHighlights(in: db, referenceRange: startReference...endReference)
        }
    }

    public func verseHighlights(
        translationID: String,
        bookNumber: Int,
        chapterNumber: Int
    ) throws -> [LampVerseHighlight] {
        let startReference = bookNumber * 1_000_000 + chapterNumber * 1_000 + 1
        let endReference = bookNumber * 1_000_000 + chapterNumber * 1_000 + 999
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT h.id, h.set_id, s.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h
                JOIN highlight_sets s ON s.id = h.set_id
                WHERE s.translation_id = ? AND h.ref BETWEEN ? AND ?
                ORDER BY h.ref, h.sc, h.ec, h.id
                """, arguments: [translationID, startReference, endReference]).map(makeVerseHighlight)
        }
    }

    @discardableResult
    public func saveVerseHighlight(
        translationID: String,
        reference: Int,
        startOffset: Int,
        endOffset: Int,
        style: LampHighlightStyle = .highlight,
        color: String? = nil,
        setID: String? = nil
    ) throws -> LampVerseHighlight {
        let normalizedColor = color.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        }
        let normalizedStartOffset = max(startOffset, 0)
        let normalizedEndOffset = max(endOffset, normalizedStartOffset)
        let resolvedSetID = setID ?? "personal-highlights:\(translationID)"
        let now = Int(Date().timeIntervalSince1970)
        let queue = try openUserDatabase()
        return try queue.write { db in
            try db.execute(sql: """
                INSERT INTO highlight_sets (
                    id, name, description, translation_id, created, last_modified
                ) VALUES (?, ?, NULL, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET last_modified = excluded.last_modified
                """, arguments: [resolvedSetID, "My Highlights", translationID, now, now])
            try db.execute(sql: """
                INSERT INTO highlights (set_id, ref, sc, ec, style, color)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    resolvedSetID,
                    reference,
                    normalizedStartOffset,
                    normalizedEndOffset,
                    style.rawValue,
                    normalizedColor,
                ])
            return LampVerseHighlight(
                id: db.lastInsertedRowID,
                setID: resolvedSetID,
                translationID: translationID,
                reference: reference,
                startOffset: normalizedStartOffset,
                endOffset: normalizedEndOffset,
                style: style,
                color: normalizedColor
            )
        }
    }

    public func deleteVerseHighlight(id: Int64) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM highlights WHERE id = ?", arguments: [id])
        }
    }

    public func deleteVerseHighlights(setID: String, reference: Int) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM highlights WHERE set_id = ? AND ref = ?",
                arguments: [setID, reference]
            )
        }
    }

    public func deleteVerseHighlights(translationID: String, reference: Int) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM highlights
                WHERE ref = ? AND set_id IN (
                    SELECT id FROM highlight_sets WHERE translation_id = ?
                )
                """, arguments: [reference, translationID])
        }
    }

    public func personalNotesDocument(
        bookNumber: Int,
        moduleID requestedModuleID: String? = nil,
        name requestedName: String? = nil,
        author: String? = nil
    ) throws -> LampPortableStudyDocument {
        let queue = try openUserDatabase()
        let notes = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, title, content,
                       verse_refs_json, footnotes_json, last_modified
                FROM personal_notes
                WHERE module_id = 'personal-notes' AND book = ?
                ORDER BY chapter, verse, last_modified, id
                """, arguments: [bookNumber]).map(makeVerseNote)
        }
        guard !notes.isEmpty else {
            throw LampLibraryError.noPersonalNotes(book: bookNumber)
        }

        let abbreviation = LampBibleReferenceFormatter.bookAbbreviation(bookNumber)
        let moduleID = requestedModuleID
            ?? "personal-notes-\(safeExportIdentifier(abbreviation.lowercased()))"
        let name = requestedName ?? "My Notes — \(LampBibleReferenceFormatter.bookName(bookNumber))"
        let groupedNotes = Dictionary(grouping: notes, by: \.chapterNumber)
        let chapters: [[String: Any]] = groupedNotes.keys.sorted().map { chapterNumber in
            let chapterNotes = groupedNotes[chapterNumber] ?? []
            var chapter: [String: Any] = ["chapter": chapterNumber]
            if let introduction = chapterNotes.first(where: { $0.verseNumber == 0 }) {
                chapter["introduction"] = introduction.content
                if !introduction.footnotes.isEmpty {
                    chapter["footnotes"] = introduction.footnotes.map { footnote -> [String: String] in
                        var value = ["id": footnote.id, "content": footnote.content]
                        if let kind = footnote.kind { value["type"] = kind }
                        return value
                    }
                }
                let modified = Int(introduction.lastModified.timeIntervalSince1970)
                if modified > 0 { chapter["lastModified"] = modified }
            }
            chapter["verses"] = chapterNotes
                .filter { $0.verseNumber > 0 }
                .map { note -> [String: Any] in
                    var verse: [String: Any] = [
                        "sv": note.reference,
                        "commentary": note.content,
                    ]
                    if let endReference = note.verseReferences.first,
                       endReference >= note.reference {
                        verse["ev"] = endReference
                    }
                    if let title = note.title, !title.isEmpty {
                        verse["title"] = title
                    }
                    if !note.footnotes.isEmpty {
                        verse["footnotes"] = note.footnotes.map { footnote -> [String: String] in
                            var value = ["id": footnote.id, "content": footnote.content]
                            if let kind = footnote.kind { value["type"] = kind }
                            return value
                        }
                    }
                    let modified = Int(note.lastModified.timeIntervalSince1970)
                    if modified > 0 { verse["lastModified"] = modified }
                    return verse
                }
            return chapter
        }
        var meta: [String: Any] = [
            "schemaVersion": "1.1",
            "id": moduleID,
            "type": "notes",
            "name": name,
        ]
        if let author, !author.isEmpty { meta["author"] = author }
        let root: [String: Any] = [
            "meta": meta,
            "book": abbreviation,
            "bookNumber": bookNumber,
            "chapters": chapters,
        ]
        return LampPortableStudyDocument(
            moduleID: moduleID,
            kind: .notes,
            name: name,
            jsonData: try prettyJSONData(root)
        )
    }

    public func personalHighlightsDocument(
        translationID: String,
        moduleID requestedModuleID: String? = nil,
        name requestedName: String? = nil
    ) throws -> LampPortableStudyDocument {
        let setID = "personal-highlights:\(translationID)"
        let queue = try openUserDatabase()
        let export = try queue.read { db -> (created: Int?, modified: Int?, highlights: [LampVerseHighlight]) in
            let metadata = try Row.fetchOne(db, sql: """
                SELECT created, last_modified
                FROM highlight_sets WHERE id = ?
                """, arguments: [setID])
            let highlights = try Row.fetchAll(db, sql: """
                SELECT h.id, h.set_id, s.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h
                JOIN highlight_sets s ON s.id = h.set_id
                WHERE h.set_id = ?
                ORDER BY h.ref, h.sc, h.ec, h.id
                """, arguments: [setID]).map(makeVerseHighlight)
            let created: Int? = metadata?["created"]
            let modified: Int? = metadata?["last_modified"]
            return (created, modified, highlights)
        }
        guard !export.highlights.isEmpty else {
            throw LampLibraryError.noPersonalHighlights(translationID: translationID)
        }

        let safeTranslationID = safeExportIdentifier(translationID)
        let moduleID = requestedModuleID ?? "personal-highlights-\(safeTranslationID)"
        let name = requestedName ?? "My Highlights — \(translationID)"
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": moduleID,
            "type": "highlights",
            "name": name,
            "translationId": translationID,
        ]
        if let created = export.created { meta["created"] = created }
        if let modified = export.modified { meta["lastModified"] = modified }
        let groupedHighlights = Dictionary(grouping: export.highlights, by: \.reference)
        let verses: [[String: Any]] = groupedHighlights.keys.sorted().map { reference in
            let spans: [[String: Any]] = (groupedHighlights[reference] ?? []).map { highlight in
                var span: [String: Any] = [
                    "sc": highlight.startOffset,
                    "ec": highlight.endOffset,
                    "style": highlight.style.rawValue,
                ]
                if let color = highlight.color { span["color"] = color }
                return span
            }
            return ["ref": reference, "highlights": spans]
        }
        let root: [String: Any] = ["meta": meta, "verses": verses]
        return LampPortableStudyDocument(
            moduleID: moduleID,
            kind: .highlights,
            name: name,
            jsonData: try prettyJSONData(root)
        )
    }

    public func importPersonalStudyData(from sourceURL: URL) throws -> LampStudyImportResult {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard fileExtension == "json" || fileExtension == "lamp" else {
            throw LampLibraryError.invalidStudyDataExtension
        }
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        if fileExtension == "lamp" {
            return try importPersonalStudyArchive(
                try Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                fallbackModuleID: sourceURL.deletingPathExtension().lastPathComponent
            )
        }

        let jsonData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let inspection = try ModuleJSONInspector().inspect(jsonData)
        guard inspection.canCompile,
              let kind = inspection.kind,
              kind == .notes || kind == .highlights else {
            throw LampLibraryError.unsupportedModuleSchema
        }
        let moduleID = inspection.metadata.id
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-study-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let moduleURL = temporaryDirectory
            .appendingPathComponent(moduleID)
            .appendingPathExtension("lamp")
        _ = try LampModuleCompiler().compile(
            data: jsonData,
            sourceFilename: sourceURL.lastPathComponent,
            destinationURL: moduleURL
        )
        return try importPersonalStudyArchive(
            try Data(contentsOf: moduleURL, options: [.mappedIfSafe]),
            fallbackModuleID: moduleID
        )
    }

    private var modulesURL: URL {
        rootURL.appendingPathComponent("Modules", isDirectory: true)
    }

    private func safeExportIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let identifier = String(scalars)
        return identifier.isEmpty ? "study-data" : identifier
    }

    private func prettyJSONData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LampLibraryError.unsupportedModuleSchema
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func importPersonalStudyArchive(
        _ compressedData: Data,
        fallbackModuleID: String
    ) throws -> LampStudyImportResult {
        guard let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampLibraryError.decompressionFailed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-study-import-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer { try? fileManager.removeItem(at: databaseURL) }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try queue.read { db in
            let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard quickCheck == ["ok"] else {
                throw LampLibraryError.integrityCheckFailed(quickCheck.joined(separator: "; "))
            }
            let tables = try tableNames(in: db)
            let formatRow = tables.contains("module_format")
                ? try Row.fetchOne(db, sql: "SELECT module_id, module_type FROM module_format LIMIT 1")
                : nil
            let formatModuleID: String? = formatRow?["module_id"]
            let formatType: String? = formatRow?["module_type"]
            let declaredKind = formatType.flatMap(LampModuleKind.init(rawValue:))
            let moduleID = formatModuleID ?? fallbackModuleID

            if declaredKind == .notes || tables.contains("note_entries") {
                let columns = try columnNames(in: db, table: "note_entries")
                let references = columns.contains("verse_refs_json")
                    ? "verse_refs_json"
                    : columns.contains("verse_refs")
                        ? "verse_refs AS verse_refs_json"
                        : "NULL AS verse_refs_json"
                let footnotes = columns.contains("footnotes_json")
                    ? "footnotes_json" : "NULL AS footnotes_json"
                let title = columns.contains("title") ? "title" : "NULL AS title"
                let modified = columns.contains("last_modified")
                    ? "last_modified" : "NULL AS last_modified"
                let module = columns.contains("module_id")
                    ? "module_id" : "'\(moduleID.replacingOccurrences(of: "'", with: "''"))' AS module_id"
                let notes = try Row.fetchAll(db, sql: """
                    SELECT id, \(module), verse_id, \(title), content,
                           \(references), \(footnotes), \(modified)
                    FROM note_entries
                    ORDER BY verse_id, id
                    """).map(makeVerseNote)
                return try mergeImportedNotes(notes, moduleID: moduleID)
            }
            if declaredKind == .highlights
                || (tables.contains("highlights")
                    && (tables.contains("highlight_meta") || tables.contains("highlight_sets"))) {
                let highlights = try readModuleHighlights(
                    in: db,
                    referenceRange: 1_000_000...66_999_999
                )
                return try mergeImportedHighlights(highlights, moduleID: moduleID)
            }
            throw LampLibraryError.unsupportedModuleSchema
        }
    }

    private func mergeImportedNotes(
        _ notes: [LampVerseNote],
        moduleID: String
    ) throws -> LampStudyImportResult {
        let queue = try openUserDatabase()
        let importTimestamp = Int(Date().timeIntervalSince1970)
        var importedCount = 0
        var skippedCount = 0
        try queue.write { db in
            for note in notes {
                let components = LampBibleReferenceFormatter.components(of: note.reference)
                guard (1...66).contains(components.book),
                      components.chapter > 0 else {
                    skippedCount += 1
                    continue
                }
                let id = "personal-notes:\(note.reference)"
                let incomingTimestamp = Int(note.lastModified.timeIntervalSince1970)
                let existing = try Row.fetchOne(db, sql: """
                    SELECT last_modified FROM personal_notes WHERE id = ?
                    """, arguments: [id])
                let existingTimestamp: Int? = existing?["last_modified"]
                if let existingTimestamp,
                   incomingTimestamp == 0 || incomingTimestamp <= existingTimestamp {
                    skippedCount += 1
                    continue
                }
                let referencesData = try JSONEncoder().encode(note.verseReferences)
                let footnotes = note.footnotes.map { footnote -> [String: String] in
                    var value = ["id": footnote.id, "content": footnote.content]
                    if let kind = footnote.kind { value["type"] = kind }
                    return value
                }
                let footnotesData = try JSONSerialization.data(
                    withJSONObject: footnotes,
                    options: [.sortedKeys]
                )
                try db.execute(sql: """
                    INSERT OR REPLACE INTO personal_notes (
                        id, module_id, verse_id, book, chapter, verse,
                        title, content, verse_refs_json, footnotes_json, last_modified
                    ) VALUES (?, 'personal-notes', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        id,
                        note.reference,
                        components.book,
                        components.chapter,
                        components.verse,
                        note.title,
                        note.content,
                        String(decoding: referencesData, as: UTF8.self),
                        String(decoding: footnotesData, as: UTF8.self),
                        incomingTimestamp > 0 ? incomingTimestamp : importTimestamp,
                    ])
                importedCount += 1
            }
        }
        return LampStudyImportResult(
            moduleID: moduleID,
            kind: .notes,
            importedCount: importedCount,
            skippedCount: skippedCount
        )
    }

    private func mergeImportedHighlights(
        _ highlights: [LampVerseHighlight],
        moduleID: String
    ) throws -> LampStudyImportResult {
        let queue = try openUserDatabase()
        let now = Int(Date().timeIntervalSince1970)
        var importedCount = 0
        var skippedCount = 0
        try queue.write { db in
            for translationGroup in Dictionary(grouping: highlights, by: \.translationID) {
                let translationID = translationGroup.key
                let setID = "personal-highlights:\(translationID)"
                try db.execute(sql: """
                    INSERT INTO highlight_sets (
                        id, name, description, translation_id, created, last_modified
                    ) VALUES (?, 'My Highlights', NULL, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET last_modified = excluded.last_modified
                    """, arguments: [setID, translationID, now, now])
                for highlight in translationGroup.value {
                    let components = LampBibleReferenceFormatter.components(of: highlight.reference)
                    guard (1...66).contains(components.book),
                          components.chapter > 0,
                          components.verse > 0,
                          highlight.startOffset >= 0,
                          highlight.endOffset > highlight.startOffset else {
                        skippedCount += 1
                        continue
                    }
                    let color = normalizedHighlightColor(highlight.color)
                    let exists = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM highlights
                            WHERE set_id = ? AND ref = ? AND sc = ? AND ec = ?
                              AND style = ? AND COALESCE(color, '') = COALESCE(?, '')
                        )
                        """, arguments: [
                            setID,
                            highlight.reference,
                            highlight.startOffset,
                            highlight.endOffset,
                            highlight.style.rawValue,
                            color,
                        ]) ?? false
                    if exists {
                        skippedCount += 1
                        continue
                    }
                    try db.execute(sql: """
                        INSERT INTO highlights (set_id, ref, sc, ec, style, color)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            setID,
                            highlight.reference,
                            highlight.startOffset,
                            highlight.endOffset,
                            highlight.style.rawValue,
                            color,
                        ])
                    importedCount += 1
                }
            }
        }
        return LampStudyImportResult(
            moduleID: moduleID,
            kind: .highlights,
            importedCount: importedCount,
            skippedCount: skippedCount
        )
    }

    private func normalizedHighlightColor(_ color: String?) -> String? {
        guard var color else { return nil }
        if color.hasPrefix("#") { color.removeFirst() }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let isHex = [6, 8].contains(color.count)
            && color.unicodeScalars.allSatisfy(hexDigits.contains)
        return isHex ? color.uppercased() : color
    }

    private var databasesURL: URL {
        rootURL.appendingPathComponent("Databases", isDirectory: true)
    }

    private var userDatabaseURL: URL {
        rootURL.appendingPathComponent("UserData.sqlite")
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: modulesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: databasesURL, withIntermediateDirectories: true)
    }

    private func openDatabase(moduleID: String) throws -> DatabaseQueue {
        let url = databasesURL
            .appendingPathComponent(storageKey(for: moduleID))
            .appendingPathExtension("sqlite")
        guard fileManager.fileExists(atPath: url.path) else {
            throw LampLibraryError.moduleNotFound(moduleID)
        }
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private func openUserDatabase() throws -> DatabaseQueue {
        try prepareDirectories()
        let queue = try DatabaseQueue(path: userDatabaseURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS selected_plans (
                    plan_id TEXT PRIMARY KEY,
                    selected_at DATETIME NOT NULL
                );
                CREATE TABLE IF NOT EXISTS completed_readings (
                    id TEXT PRIMARY KEY,
                    plan_id TEXT NOT NULL,
                    day INTEGER NOT NULL,
                    reading_index INTEGER NOT NULL,
                    year INTEGER NOT NULL,
                    completed_at DATETIME NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_completed_readings_plan_year
                    ON completed_readings(plan_id, year);
                CREATE TABLE IF NOT EXISTS personal_notes (
                    id TEXT PRIMARY KEY,
                    module_id TEXT NOT NULL,
                    verse_id INTEGER NOT NULL,
                    book INTEGER NOT NULL,
                    chapter INTEGER NOT NULL,
                    verse INTEGER NOT NULL,
                    title TEXT,
                    content TEXT NOT NULL,
                    verse_refs_json TEXT,
                    footnotes_json TEXT,
                    last_modified INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_personal_notes_verse
                    ON personal_notes(verse_id);
                CREATE INDEX IF NOT EXISTS idx_personal_notes_chapter
                    ON personal_notes(book, chapter, verse);
                CREATE TABLE IF NOT EXISTS highlight_sets (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    translation_id TEXT NOT NULL,
                    created INTEGER NOT NULL,
                    last_modified INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_highlight_sets_translation
                    ON highlight_sets(translation_id);
                CREATE TABLE IF NOT EXISTS highlights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    set_id TEXT NOT NULL REFERENCES highlight_sets(id) ON DELETE CASCADE,
                    ref INTEGER NOT NULL,
                    sc INTEGER NOT NULL,
                    ec INTEGER NOT NULL,
                    style INTEGER NOT NULL,
                    color TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_highlights_set_ref
                    ON highlights(set_id, ref, sc);
                """)
            let personalNoteColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(personal_notes)")
                .compactMap { $0["name"] as String? }
            if !personalNoteColumns.contains("footnotes_json") {
                try db.execute(sql: "ALTER TABLE personal_notes ADD COLUMN footnotes_json TEXT")
            }
        }
        return queue
    }

    private func makeVerseNote(_ row: Row) -> LampVerseNote {
        let referencesJSON: String? = row["verse_refs_json"]
        let references = referencesJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        let modifiedTimestamp: Int? = row["last_modified"]
        let footnotesJSON: String? = row["footnotes_json"]
        return LampVerseNote(
            id: row["id"],
            moduleID: row["module_id"],
            reference: row["verse_id"],
            title: row["title"],
            content: row["content"],
            verseReferences: references,
            footnotes: verseFootnotes(from: footnotesJSON),
            lastModified: Date(timeIntervalSince1970: TimeInterval(modifiedTimestamp ?? 0))
        )
    }

    private func makeVerseHighlight(_ row: Row) -> LampVerseHighlight {
        let rawStyle: Int = row["style"]
        return LampVerseHighlight(
            id: row["id"],
            setID: row["set_id"],
            translationID: row["translation_id"],
            reference: row["ref"],
            startOffset: row["sc"],
            endOffset: row["ec"],
            style: LampHighlightStyle(rawValue: rawStyle) ?? .highlight,
            color: row["color"]
        )
    }

    private func readModuleHighlights(
        in db: Database,
        referenceRange: ClosedRange<Int>
    ) throws -> [LampVerseHighlight] {
        let tables = try tableNames(in: db)
        if tables.contains("highlight_meta") && tables.contains("highlights") {
            return try Row.fetchAll(db, sql: """
                SELECT h.id, m.id AS set_id, m.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h
                CROSS JOIN highlight_meta m
                WHERE h.ref BETWEEN ? AND ?
                ORDER BY h.ref, h.sc, h.ec, h.id
                """, arguments: [referenceRange.lowerBound, referenceRange.upperBound])
                .map(makeVerseHighlight)
        }
        if tables.contains("highlight_sets") && tables.contains("highlights") {
            return try Row.fetchAll(db, sql: """
                SELECT h.id, h.set_id, s.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h
                JOIN highlight_sets s ON s.id = h.set_id
                WHERE h.ref BETWEEN ? AND ?
                ORDER BY h.ref, h.sc, h.ec, h.id
                """, arguments: [referenceRange.lowerBound, referenceRange.upperBound])
                .map(makeVerseHighlight)
        }
        throw LampLibraryError.unsupportedModuleSchema
    }

    private func inspectDatabase(
        at url: URL,
        fallbackID: String?,
        compressedByteCount: Int
    ) throws -> LampInstalledModule {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            let integrityResults = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard integrityResults == ["ok"] else {
                throw LampLibraryError.integrityCheckFailed(integrityResults.joined(separator: "; "))
            }

            let tables = try tableNames(in: db)
            let formatRow = tables.contains("module_format")
                ? try Row.fetchOne(db, sql: "SELECT module_id, module_type FROM module_format LIMIT 1")
                : nil
            let formatID: String? = formatRow?["module_id"]
            let formatType: String? = formatRow?["module_type"]
            let declaredKind = formatType.flatMap(LampModuleKind.init(rawValue:))

            if tables.contains("translation_meta"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name, abbreviation, language FROM translation_meta LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .translation,
                    name: row["name"],
                    abbreviation: row["abbreviation"],
                    language: row["language"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("translations"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name, abbreviation, language FROM translations LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .translation,
                    name: row["name"],
                    abbreviation: row["abbreviation"],
                    language: row["language"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("module_metadata"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name, language FROM module_metadata LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .dictionary,
                    name: row["name"],
                    language: row["language"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("commentary_books"),
               let row = try Row.fetchOne(db, sql: "SELECT * FROM commentary_books LIMIT 1") {
                let moduleID: String? = row.hasColumn("module_id") ? row["module_id"] : nil
                let title: String? = row["title"]
                let seriesAbbreviation: String? = row.hasColumn("series_abbrev") ? row["series_abbrev"] : nil
                guard let id = formatID ?? moduleID ?? fallbackID else {
                    throw LampLibraryError.missingModuleMetadata
                }
                return LampInstalledModule(
                    id: id,
                    kind: declaredKind ?? .commentary,
                    name: title ?? id,
                    abbreviation: seriesAbbreviation,
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("plans"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name FROM plans LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .plan,
                    name: row["name"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("note_entries") {
                let row = tables.contains("module_meta")
                    ? try Row.fetchOne(db, sql: "SELECT id, name FROM module_meta LIMIT 1")
                    : nil
                let metadataID: String? = row?["id"]
                let metadataName: String? = row?["name"]
                guard let id = formatID ?? metadataID ?? fallbackID else {
                    throw LampLibraryError.missingModuleMetadata
                }
                return LampInstalledModule(
                    id: id,
                    kind: declaredKind ?? .notes,
                    name: metadataName ?? id,
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("highlight_meta"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name FROM highlight_meta LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .highlights,
                    name: row["name"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("highlight_sets"),
               let row = try Row.fetchOne(db, sql: "SELECT * FROM highlight_sets LIMIT 1") {
                let metadataModuleID: String? = row.hasColumn("module_id") ? row["module_id"] : nil
                let setID: String? = row["id"]
                let name: String? = row["name"]
                guard let id = formatID ?? metadataModuleID ?? setID ?? fallbackID else {
                    throw LampLibraryError.missingModuleMetadata
                }
                return LampInstalledModule(
                    id: id,
                    kind: declaredKind ?? .highlights,
                    name: name ?? id,
                    compressedByteCount: compressedByteCount
                )
            }
            throw LampLibraryError.unsupportedModuleSchema
        }
    }

    private func tableNames(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
        ))
    }

    private func columnNames(in db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .compactMap { $0["name"] as String? })
    }

    private func validateIdentifier(_ identifier: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-") )
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LampLibraryError.unsafeModuleIdentifier(identifier)
        }
    }

    private func storageKey(for moduleID: String) -> String {
        SHA256.hash(data: Data(moduleID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeBook(_ row: Row) -> LampTranslationBook {
        LampTranslationBook(
            id: row["id"],
            osisID: row["book_id"],
            name: row["name"],
            testament: row["testament"],
            chapterCount: row["chapter_count"]
        )
    }

    private func makeVerse(_ row: Row) -> LampVerse {
        let paragraph: Int? = row["paragraph"]
        let text: String = row["text"]
        let annotationsJSON: String? = row["annotations_json"]
        let footnotesJSON: String? = row["footnotes_json"]
        let footnoteReferencesJSON: String? = row["footnote_refs_json"]
        let poetryJSON: String? = row["poetry_json"]
        return LampVerse(
            id: row["id"],
            number: row["number"],
            text: text,
            beginsParagraph: paragraph == 1,
            annotations: verseAnnotations(from: annotationsJSON, verseText: text),
            hasFootnotes: hasJSONArrayEntries(footnotesJSON)
                || hasJSONArrayEntries(footnoteReferencesJSON),
            poetry: versePoetry(from: poetryJSON)
        )
    }

    private func makeHeading(_ row: Row) -> LampHeading {
        LampHeading(
            id: row["id"],
            beforeVerse: row["before_verse"],
            level: row["level"],
            text: row["text"]
        )
    }

    private func dictionarySenses(from json: String?) -> [LampDictionarySense] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return values.compactMap { value in
            guard let object = value as? [String: Any] else { return nil }
            return LampDictionarySense(
                partOfSpeech: plainText(from: object["partOfSpeech"] ?? object["part_of_speech"]),
                gloss: plainText(from: object["gloss"]),
                shortDefinition: plainText(from: object["shortDefinition"] ?? object["short_definition"]),
                definition: plainText(from: object["definition"] ?? object["def"]),
                usage: plainText(from: object["usage"])
            )
        }
    }

    private func verseAnnotations(from json: String?, verseText: String) -> [LampVerseAnnotation] {
        guard let values = jsonArray(from: json) else { return [] }
        return values.compactMap { value in
            guard let object = value as? [String: Any],
                  let kind = stringValue(object["type"] ?? object["kind"]),
                  let start = integerValue(object["start"]),
                  let end = integerValue(object["end"]) else {
                return nil
            }
            let data = object["data"] as? [String: Any]
            return LampVerseAnnotation(
                kind: kind,
                startOffset: start,
                endOffset: end,
                text: stringValue(object["text"])
                    ?? substring(of: verseText, from: start, to: end),
                strongs: stringValue(data?["strongs"] ?? object["strongs"]),
                morphology: stringValue(data?["morphology"] ?? object["morphology"]),
                lemma: stringValue(data?["lemma"] ?? object["lemma"]),
                startReference: integerValue(data?["sv"] ?? object["sv"]),
                endReference: integerValue(data?["ev"] ?? object["ev"])
            )
        }
    }

    private func substring(of text: String, from start: Int, to end: Int) -> String? {
        guard start >= 0, end > start, end <= text.count else { return nil }
        let lowerBound = text.index(text.startIndex, offsetBy: start)
        let upperBound = text.index(text.startIndex, offsetBy: end)
        return String(text[lowerBound..<upperBound])
    }

    private func verseFootnotes(from json: String?) -> [LampVerseFootnote] {
        guard let values = jsonArray(from: json) else { return [] }
        return values.compactMap { value in
            guard let object = value as? [String: Any],
                  let id = stringValue(object["id"]),
                  let content = plainText(from: object["content"] ?? object["text"]) else {
                return nil
            }
            return LampVerseFootnote(
                id: id,
                kind: stringValue(object["type"] ?? object["kind"]),
                content: content
            )
        }
    }

    private func verseFootnoteReferences(from json: String?) -> [LampVerseFootnoteReference] {
        guard let values = jsonArray(from: json) else { return [] }
        return values.compactMap { value in
            guard let object = value as? [String: Any],
                  let id = stringValue(object["id"]),
                  let offset = integerValue(object["offset"] ?? object["start"]) else {
                return nil
            }
            return LampVerseFootnoteReference(footnoteID: id, offset: offset)
        }
    }

    private func versePoetry(from json: String?) -> LampVersePoetry? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let indent = integerValue(object["indent"]) ?? 0
        let stanzaBreak = (object["stanzaBreak"] as? NSNumber)?.boolValue
            ?? (object["stanza_break"] as? NSNumber)?.boolValue
            ?? false
        return LampVersePoetry(indent: indent, stanzaBreak: stanzaBreak)
    }

    private func hasJSONArrayEntries(_ json: String?) -> Bool {
        jsonArray(from: json)?.isEmpty == false
    }

    private func scriptureLinks(fromJSONString json: String?) -> [LampScriptureLink] {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        var links: [LampScriptureLink] = []
        collectScriptureLinks(from: value, into: &links)
        var seen: Set<String> = []
        return links.filter { seen.insert($0.id).inserted }
    }

    private func collectScriptureLinks(from value: Any, into links: inout [LampScriptureLink]) {
        if let values = value as? [Any] {
            for value in values {
                collectScriptureLinks(from: value, into: &links)
            }
            return
        }
        guard let object = value as? [String: Any] else { return }

        let parentText = stringValue(object["text"])
        if let annotations = object["annotations"] as? [Any] {
            for annotationValue in annotations {
                guard let annotation = annotationValue as? [String: Any],
                      let kind = stringValue(annotation["type"] ?? annotation["kind"])?.lowercased(),
                      kind == "scripture" || kind == "crossref" || kind == "cross-reference" else {
                    continue
                }
                let annotationData = annotation["data"] as? [String: Any]
                guard let startReference = integerValue(annotationData?["sv"] ?? annotation["sv"]) else {
                    continue
                }
                let startOffset = integerValue(annotation["start"])
                let endOffset = integerValue(annotation["end"])
                let derivedText = startOffset.flatMap { start in
                    endOffset.flatMap { end in
                        parentText.flatMap { substring(of: $0, from: start, to: end) }
                    }
                }
                links.append(LampScriptureLink(
                    text: stringValue(annotation["text"]) ?? derivedText,
                    startReference: startReference,
                    endReference: integerValue(annotationData?["ev"] ?? annotation["ev"])
                ))
            }
        }

        for (key, nestedValue) in object where key != "annotations" {
            collectScriptureLinks(from: nestedValue, into: &links)
        }
    }

    private func jsonArray(from json: String?) -> [Any]? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func plainText(fromJSONString json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return plainText(from: value)
    }

    private func plainText(from value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let values = value as? [Any] {
            let text = values.compactMap { plainText(from: $0) }.joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            for key in ["text", "content", "value", "note", "body"] {
                if let text = plainText(from: object[key]) { return text }
            }
            let ignoredKeys: Set<String> = ["id", "type", "style", "level", "annotations"]
            let text = object
                .filter { !ignoredKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
                .compactMap { plainText(from: $0.value) }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
