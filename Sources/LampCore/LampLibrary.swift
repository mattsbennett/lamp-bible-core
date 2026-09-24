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
    private let bundledModulesArchiveURL: URL?
    private let isStagingLibrary: Bool
    private var cachedBundledDatabaseURL: URL?
    private var cachedBundledModules: [LampInstalledModule]?
    private var openDatabases: [String: DatabaseQueue] = [:]

    public init(
        rootURL: URL? = nil,
        bundledModulesArchiveURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.isStagingLibrary = false
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

    private init(
        stagingRootURL: URL,
        bundledModulesArchiveURL: URL?,
        fileManager: FileManager
    ) {
        self.rootURL = stagingRootURL
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.fileManager = fileManager
        self.isStagingLibrary = true
    }

    public func installedModules() throws -> [LampInstalledModule] {
        try prepareDirectories()
        let databaseURLs = try fileManager.contentsOfDirectory(
            at: databasesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let localModules = databaseURLs
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
                    compressedByteCount: byteCount,
                    // Already verified when it was installed.
                    verifyIntegrity: false
                )
            }
        var modulesByKey = Dictionary(
            uniqueKeysWithValues: try bundledModules().map { ("\($0.kind.rawValue):\($0.id)", $0) }
        )
        for module in localModules {
            modulesByKey["\(module.kind.rawValue):\(module.id)"] = module
        }
        return modulesByKey.values.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> LampInstalledModule {
        // Installing replaces a database file that a cached connection may be
        // holding open, so no connection outlives this call.
        defer { forgetOpenDatabases() }
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
        try LampPortableModuleInspector.validateOwnership(
            databaseURL: temporaryURL,
            expectedID: module.id,
            kind: module.kind,
            verifyIntegrity: false // inspectDatabase just completed quick_check.
        )
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

    /// Returns the portable formats that can faithfully represent an installed
    /// user module. Every user module retains its original `.lamp` archive;
    /// document-oriented modules additionally have a readable Markdown form.
    public func supportedExportFormats(moduleID: String) throws -> [LampModuleExportFormat] {
        let module = try installedModuleForExport(moduleID: moduleID)
        var formats: [LampModuleExportFormat] = [.lamp]
        if Self.supportsMarkdownExport(for: module.kind) {
            formats.append(.markdown)
        }
        return formats
    }

    public nonisolated static func supportsMarkdownExport(for kind: LampModuleKind) -> Bool {
        switch kind {
        case .book, .devotional, .notes:
            true
        case .translation, .dictionary, .commentary, .plan, .highlights, .quiz:
            false
        }
    }

    public nonisolated static func supportedExportFormats(
        for personalModule: LampPersonalModule
    ) -> [LampModuleExportFormat] {
        switch personalModule {
        case .writing, .notes:
            [.lamp, .markdown]
        case .highlights:
            [.lamp]
        }
    }

    /// Exports a user-installed module. Lamp exports copy the exact portable
    /// archive that was installed, preserving all module-specific structure.
    public func exportModule(
        moduleID: String,
        format: LampModuleExportFormat,
        to destinationURL: URL
    ) throws {
        let module = try installedModuleForExport(moduleID: moduleID)
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { destinationURL.stopAccessingSecurityScopedResource() }
        }

        switch format {
        case .lamp:
            let sourceURL = modulesURL
                .appendingPathComponent(storageKey(for: module.id))
                .appendingPathExtension("lamp")
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw LampLibraryError.invalidPersonalContent(
                    "The portable copy of \(module.name) is unavailable. Reinstall the module and try again."
                )
            }
            try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                .write(to: destinationURL, options: [.atomic])

        case .markdown:
            guard Self.supportsMarkdownExport(for: module.kind) else {
                throw LampLibraryError.invalidPersonalContent(
                    "\(module.name) cannot be represented as Markdown. Export it as a Lamp module instead."
                )
            }
            try markdownExport(for: module)
                .write(to: destinationURL, atomically: true, encoding: .utf8)
        }
    }

    /// Exports one of the default editable collections as a portable module.
    /// Unlike installed-module exports, this archive is assembled from the
    /// current contents of the user's library at export time.
    public func exportPersonalModule(
        _ personalModule: LampPersonalModule,
        format: LampModuleExportFormat,
        to destinationURL: URL
    ) throws {
        guard Self.supportedExportFormats(for: personalModule).contains(format) else {
            throw LampLibraryError.invalidPersonalContent(
                "\(personalModule.name) cannot be represented as Markdown. Export it as a Lamp module instead."
            )
        }
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { destinationURL.stopAccessingSecurityScopedResource() }
        }

        switch format {
        case .lamp:
            try personalModuleArchive(for: personalModule)
                .write(to: destinationURL, options: [.atomic])
        case .markdown:
            let markdown: String
            switch personalModule {
            case .writing:
                markdown = devotionalMarkdown(
                    title: personalModule.name,
                    entries: try personalDevotionals()
                )
            case .notes:
                markdown = notesMarkdown(
                    title: personalModule.name,
                    notes: try allPersonalNotes()
                )
            case .highlights:
                throw LampLibraryError.invalidPersonalContent(
                    "My Highlights cannot be represented as Markdown."
                )
            }
            try (markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
                .write(to: destinationURL, atomically: true, encoding: .utf8)
        }
    }

    public func remove(moduleID: String) throws {
        defer { forgetOpenDatabases() }
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

    public func translationWordCount(
        moduleID: String,
        startReference: Int,
        endReference: Int
    ) throws -> Int {
        let lowerBound = min(startReference, endReference)
        let upperBound = max(startReference, endReference)
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            let tables = try tableNames(in: db)
            let table: String
            let condition: String
            let arguments: StatementArguments
            if tables.contains("translation_meta") && tables.contains("verses") {
                table = "verses"
                condition = "ref BETWEEN ? AND ?"
                arguments = [lowerBound, upperBound]
            } else if tables.contains("translation_verses") {
                table = "translation_verses"
                condition = "translation_id = ? AND ref BETWEEN ? AND ?"
                arguments = [moduleID, lowerBound, upperBound]
            } else {
                throw LampLibraryError.notATranslation(moduleID)
            }
            let texts = try String.fetchAll(
                db,
                sql: "SELECT text FROM \(table) WHERE \(condition) ORDER BY ref",
                arguments: arguments
            )
            return texts.reduce(into: 0) { count, text in
                count += text.split(whereSeparator: { $0.isWhitespace }).count
            }
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
                let searchCondition = searchColumns.map { "\($0) LIKE ? COLLATE NOCASE" }
                    .joined(separator: " OR ")
                let pattern = "%\(trimmedQuery)%"
                var queryArguments = StatementArguments()
                let moduleCondition: String
                if columns.contains("module_id") {
                    moduleCondition = "module_id = ? AND"
                    queryArguments += [dictionary.id]
                } else {
                    moduleCondition = ""
                }
                queryArguments += StatementArguments(
                    Array(repeating: pattern, count: searchColumns.count)
                )
                queryArguments += [trimmedQuery, trimmedQuery, queryLimit]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, key, lemma, transliteration, pronunciation, senses_json
                    FROM dictionary_entries
                    WHERE \(moduleCondition) (\(searchCondition))
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
                    let idValue: DatabaseValue = row["id"]
                    let entryID = String.fromDatabaseValue(idValue)
                        ?? Int64.fromDatabaseValue(idValue).map(String.init)
                        ?? "\(dictionary.id):\(row["key"] as String)"
                    return LampDictionaryResult(
                        entryID: entryID,
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

    /// Returns dictionary entries whose keys exactly match the supplied keys.
    ///
    /// This is deliberately separate from ``searchDictionaries``: lexicon keys
    /// are identifiers, and a text search can also return entries that merely
    /// cite an identifier in their definition.
    public func dictionaryEntries(
        keys: [String],
        moduleIDs: Set<String>? = nil
    ) throws -> [LampDictionaryResult] {
        var seenKeys = Set<String>()
        let normalizedKeys = keys.compactMap { key -> String? in
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !normalized.isEmpty, seenKeys.insert(normalized).inserted else { return nil }
            return normalized
        }
        guard !normalizedKeys.isEmpty else { return [] }

        let dictionaries = try installedModules().filter {
            $0.kind == .dictionary && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }
        let placeholders = Array(repeating: "?", count: normalizedKeys.count).joined(separator: ", ")
        var results: [LampDictionaryResult] = []

        for dictionary in dictionaries {
            let queue = try openDatabase(moduleID: dictionary.id)
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

                var arguments = StatementArguments()
                let moduleCondition: String
                if columns.contains("module_id") {
                    moduleCondition = "module_id = ? AND"
                    arguments += [dictionary.id]
                } else {
                    moduleCondition = ""
                }
                arguments += StatementArguments(normalizedKeys)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, key, lemma, transliteration, pronunciation, senses_json
                    FROM dictionary_entries
                    WHERE \(moduleCondition) key COLLATE NOCASE IN (\(placeholders))
                    ORDER BY key, lemma
                    """, arguments: arguments)

                return rows.map { row in
                    let sensesJSON: String? = row["senses_json"]
                    let idValue: DatabaseValue = row["id"]
                    let entryID = String.fromDatabaseValue(idValue)
                        ?? Int64.fromDatabaseValue(idValue).map(String.init)
                        ?? "\(dictionary.id):\(row["key"] as String)"
                    return LampDictionaryResult(
                        entryID: entryID,
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

        let keyOrder = Dictionary(uniqueKeysWithValues: normalizedKeys.enumerated().map { ($1, $0) })
        return results.sorted {
            let lhsOrder = keyOrder[$0.key.uppercased()] ?? Int.max
            let rhsOrder = keyOrder[$1.key.uppercased()] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return $0.moduleName.localizedStandardCompare($1.moduleName) == .orderedAscending
        }
    }

    /// Resolves a lexicon key through the mappings embedded in the bundled
    /// module database (for example, a Strong's Hebrew key to one or more BDB
    /// entry keys).
    public func lexiconMappings(sourceKey: String) throws -> [String] {
        let uppercasedKey = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedKey: String
        if let prefix = uppercasedKey.first, prefix == "H" || prefix == "G" {
            let remainder = uppercasedKey.dropFirst()
            let digits = remainder.prefix { $0.isNumber }
            let suffix = remainder.dropFirst(digits.count)
            let unpaddedDigits = String(digits.drop { $0 == "0" })
            normalizedKey = String(prefix)
                + (unpaddedDigits.isEmpty && !digits.isEmpty ? "0" : unpaddedDigits)
                + suffix
        } else {
            normalizedKey = uppercasedKey
        }
        guard !normalizedKey.isEmpty,
              let databaseURL = try preparedBundledDatabaseURL() else { return [] }

        let queue = try openReadOnlyDatabase(at: databaseURL)
        return try queue.read { db in
            guard try tableNames(in: db).contains("lexicon_mappings") else { return [] }
            // No `COLLATE NOCASE`. `idx_mapping_source` is a binary index, so the
            // collation made this a full table scan rather than an index search —
            // and it bought nothing: the key has already been uppercased above, and
            // every stored key is uppercase.
            let rows = try Row.fetchAll(db, sql: """
                SELECT target_keys_json
                FROM lexicon_mappings
                WHERE source_key = ?
                ORDER BY id
                """, arguments: [normalizedKey])

            var seenTargets = Set<String>()
            return rows.flatMap { row -> [String] in
                let json: String = row["target_keys_json"]
                let targets = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                return targets.compactMap { target in
                    let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !normalized.isEmpty, seenTargets.insert(normalized).inserted else { return nil }
                    return normalized
                }
            }
        }
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
                let columns = try columnNames(in: db, table: "commentary_units")
                if columns.contains("module_id") {
                    condition = "module_id = ? AND " + condition
                    arguments = [commentaryModule.id, bookNumber, chapterNumber]
                }
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

    public func bookModules(moduleIDs: Set<String>? = nil) throws -> [LampBook] {
        let modules = try installedModules().filter {
            $0.kind == .book && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }
        var books: [LampBook] = []

        for module in modules {
            let queue = try openDatabase(moduleID: module.id)
            if let book = try queue.read({ db -> LampBook? in
                guard try tableNames(in: db).contains("book_modules"),
                      let row = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM book_modules WHERE id = ? LIMIT 1",
                        arguments: [module.id]
                      ) else { return nil }
                let tagsJSON: String? = row["tags_json"]
                let tags = tagsJSON
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                let editable: Int = row["is_editable"]
                let createdTimestamp: Int? = row["created"]
                let modifiedTimestamp: Int? = row["last_modified"]
                return LampBook(
                    id: row["id"],
                    title: row["title"],
                    subtitle: row["subtitle"],
                    description: row["description"],
                    author: row["author"],
                    editor: row["editor"],
                    publisher: row["publisher"],
                    year: row["year"],
                    edition: row["edition"],
                    isbn: row["isbn"],
                    language: row["language"],
                    textDirection: row["text_direction"],
                    copyright: row["copyright"],
                    license: row["license"],
                    version: row["version"],
                    tags: tags,
                    coverMediaID: row["cover_media_id"],
                    isEditable: editable != 0,
                    created: createdTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    lastModified: modifiedTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    footnotesJSON: row["footnotes_json"],
                    mediaJSON: row["media_json"]
                )
            }) {
                books.append(book)
            }
        }

        return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func bookSections(moduleID: String) throws -> [LampBookSection] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            guard try tableNames(in: db).contains("book_sections") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM book_sections
                WHERE module_id = ?
                ORDER BY rowid
                """, arguments: [moduleID]).map { row in
                    let scripturesJSON: String? = row["key_scriptures_json"]
                    let contentJSON: String = row["content_json"]
                    return LampBookSection(
                        id: row["id"],
                        moduleID: row["module_id"],
                        sectionID: row["section_id"],
                        parentID: row["parent_id"],
                        type: row["section_type"],
                        number: row["number"],
                        title: row["title"],
                        subtitle: row["subtitle"],
                        depth: row["depth"],
                        orderIndex: row["order_index"],
                        keyScriptures: devotionalScriptureLinks(from: scripturesJSON),
                        contentJSON: contentJSON,
                        content: plainText(fromJSONString: contentJSON) ?? ""
                    )
                }
        }
    }

    public func devotionals(
        moduleIDs: Set<String>? = nil,
        query: String? = nil
    ) throws -> [LampDevotional] {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [LampDevotional] = []
        if moduleIDs == nil || moduleIDs?.contains("personal-devotionals") == true {
            results += try personalDevotionals(query: trimmedQuery)
        }
        let modules = try installedModules().filter {
            $0.kind == .devotional && (moduleIDs == nil || moduleIDs?.contains($0.id) == true)
        }

        for module in modules {
            let queue = try openDatabase(moduleID: module.id)
            let entries = try queue.read { db -> [LampDevotional] in
                guard try tableNames(in: db).contains("devotional_entries") else { return [] }
                let columns = try columnNames(in: db, table: "devotional_entries")
                var conditions: [String] = []
                var arguments = StatementArguments()
                if columns.contains("module_id") {
                    conditions.append("module_id = ?")
                    arguments += [module.id]
                }
                if let trimmedQuery, !trimmedQuery.isEmpty {
                    conditions.append("(title LIKE ? COLLATE NOCASE OR search_text LIKE ? COLLATE NOCASE)")
                    let pattern = "%\(trimmedQuery)%"
                    arguments += [pattern, pattern]
                }
                let whereClause = conditions.isEmpty
                    ? "" : "WHERE \(conditions.joined(separator: " AND "))"
                return try Row.fetchAll(db, sql: """
                    SELECT * FROM devotional_entries
                    \(whereClause)
                    ORDER BY COALESCE(series_name, ''), COALESCE(series_order, 0),
                             COALESCE(date, ''), title
                    """, arguments: arguments).map { row in
                        let contentJSON: String = row["content_json"]
                        let summaryJSON: String? = row["summary_json"]
                        let footnotesJSON: String? = row["footnotes_json"]
                        let scripturesJSON: String? = row["key_scriptures_json"]
                        let createdTimestamp: Int? = row["created"]
                        let modifiedTimestamp: Int? = row["last_modified"]
                        let tags: String? = row["tags"]
                        return LampDevotional(
                            id: row["id"],
                            moduleID: module.id,
                            moduleName: module.name,
                            title: row["title"],
                            subtitle: row["subtitle"],
                            author: row["author"],
                            date: row["date"],
                            tags: tags?.split(separator: ",").map {
                                String($0).trimmingCharacters(in: .whitespaces)
                            } ?? [],
                            category: row["category"],
                            seriesName: row["series_name"],
                            seriesOrder: row["series_order"],
                            keyScriptures: devotionalScriptureLinks(from: scripturesJSON),
                            summary: plainText(fromJSONString: summaryJSON),
                            content: LampPortableDevotionalContent.plainText(from: contentJSON)
                                ?? contentJSON,
                            contentJSON: contentJSON,
                            footnotes: plainText(fromJSONString: footnotesJSON),
                            mediaJSON: columns.contains("media_json") ? row["media_json"] : nil,
                            created: createdTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            lastModified: modifiedTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                        )
                    }
            }
            results.append(contentsOf: entries)
        }
        return results.sorted(by: devotionalSort)
    }

    public func personalDevotionals(query: String? = nil) throws -> [LampDevotional] {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queue = try openUserDatabase()
        return try queue.read { db in
            var sql = "SELECT * FROM personal_devotionals"
            var arguments = StatementArguments()
            if let trimmedQuery, !trimmedQuery.isEmpty {
                let pattern = "%\(trimmedQuery)%"
                sql += """
                     WHERE title LIKE ? COLLATE NOCASE
                       OR COALESCE(subtitle, '') LIKE ? COLLATE NOCASE
                       OR COALESCE(author, '') LIKE ? COLLATE NOCASE
                       OR COALESCE(summary, '') LIKE ? COLLATE NOCASE
                       OR content LIKE ? COLLATE NOCASE
                       OR tags_json LIKE ? COLLATE NOCASE
                    """
                arguments = [pattern, pattern, pattern, pattern, pattern, pattern]
            }
            sql += " ORDER BY COALESCE(series_name, ''), COALESCE(series_order, 0), COALESCE(devotional_date, ''), title"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(makePersonalDevotional)
        }
    }

    @discardableResult
    public func savePersonalDevotional(
        _ devotional: LampDevotional,
        preserveLastModified: Bool = false
    ) throws -> LampDevotional {
        let title = devotional.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthoredContent = [
            devotional.title,
            devotional.subtitle,
            devotional.author,
            devotional.tags.joined(separator: ""),
            devotional.seriesName,
            devotional.summary,
            devotional.content,
            devotional.footnotes,
        ]
            .compactMap { $0 }
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !devotional.keyScriptures.isEmpty
        guard hasAuthoredContent else {
            throw LampLibraryError.invalidPersonalContent("Add devotional content before saving.")
        }
        let identifier = devotional.id.isEmpty ? UUID().uuidString : devotional.id
        try validateIdentifier(identifier)
        let queue = try openUserDatabase()
        let prior = try queue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT content, content_json, media_json FROM personal_devotionals WHERE id = ?",
                arguments: [identifier]
            )
        }
        let priorContent: String? = prior?["content"]
        let storedContentJSON: String? = prior?["content_json"]
        let storedMediaJSON: String? = prior?["media_json"]
        let now = Date()
        let created = devotional.created ?? now
        let saved = LampDevotional(
            id: identifier,
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: title.isEmpty ? "Untitled" : title,
            subtitle: devotional.subtitle?.nilIfBlank,
            author: devotional.author?.nilIfBlank,
            date: devotional.date?.nilIfBlank,
            tags: devotional.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            category: devotional.category?.nilIfBlank,
            seriesName: devotional.seriesName?.nilIfBlank,
            seriesOrder: devotional.seriesOrder,
            keyScriptures: devotional.keyScriptures,
            summary: devotional.summary?.nilIfBlank,
            content: devotional.content,
            contentJSON: devotional.contentJSON
                ?? (priorContent == devotional.content ? storedContentJSON : nil),
            footnotes: devotional.footnotes?.nilIfBlank,
            mediaJSON: devotional.mediaJSON ?? storedMediaJSON,
            created: created,
            lastModified: preserveLastModified ? (devotional.lastModified ?? now) : now,
            isEditable: true
        )
        let tagsJSON = String(decoding: try JSONEncoder().encode(saved.tags), as: UTF8.self)
        let scriptures = saved.keyScriptures.map { scripture -> [String: Any] in
            var value: [String: Any] = ["sv": scripture.startReference]
            if let end = scripture.endReference { value["ev"] = end }
            if let text = scripture.text { value["label"] = text }
            return value
        }
        let scripturesData = try JSONSerialization.data(withJSONObject: scriptures, options: [.sortedKeys])
        let scripturesJSON = String(decoding: scripturesData, as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO personal_devotionals (
                    id, title, subtitle, author, devotional_date, tags_json,
                    category, series_name, series_order, key_scriptures_json,
                    summary, content, content_json, footnotes, media_json, created, last_modified
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    author = excluded.author,
                    devotional_date = excluded.devotional_date,
                    tags_json = excluded.tags_json,
                    category = excluded.category,
                    series_name = excluded.series_name,
                    series_order = excluded.series_order,
                    key_scriptures_json = excluded.key_scriptures_json,
                    summary = excluded.summary,
                    content = excluded.content,
                    content_json = excluded.content_json,
                    footnotes = excluded.footnotes,
                    media_json = excluded.media_json,
                    last_modified = excluded.last_modified
                """, arguments: [
                    saved.id,
                    saved.title,
                    saved.subtitle,
                    saved.author,
                    saved.date,
                    tagsJSON,
                    saved.category,
                    saved.seriesName,
                    saved.seriesOrder,
                    scripturesJSON,
                    saved.summary,
                    saved.content,
                    saved.contentJSON,
                    saved.footnotes,
                    saved.mediaJSON,
                    Int(created.timeIntervalSince1970),
                    Int((saved.lastModified ?? now).timeIntervalSince1970),
                ])
        }
        return saved
    }

    public func deletePersonalDevotional(id: String) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM personal_devotionals WHERE id = ?", arguments: [id])
        }
    }

    public func personalDevotionalDocument(id: String) throws -> LampPortableStudyDocument {
        guard let devotional = try personalDevotionals().first(where: { $0.id == id }) else {
            throw LampLibraryError.moduleNotFound(id)
        }
        var meta: [String: Any] = [
            "schemaVersion": "1.1",
            "id": devotional.id,
            "type": "devotional",
            "title": devotional.title,
            "tags": devotional.tags,
            "created": Int((devotional.created ?? Date()).timeIntervalSince1970),
            "lastModified": Int((devotional.lastModified ?? Date()).timeIntervalSince1970),
        ]
        if let subtitle = devotional.subtitle { meta["subtitle"] = subtitle }
        if let author = devotional.author { meta["author"] = author }
        if let date = devotional.date { meta["date"] = date }
        if let category = devotional.category { meta["category"] = category }
        if let seriesName = devotional.seriesName {
            var series: [String: Any] = ["name": seriesName]
            if let order = devotional.seriesOrder { series["order"] = order }
            meta["series"] = series
        }
        meta["keyScriptures"] = devotional.keyScriptures.map { scripture in
            var value: [String: Any] = ["sv": scripture.startReference]
            if let end = scripture.endReference { value["ev"] = end }
            if let text = scripture.text { value["label"] = text }
            return value
        }
        let content: Any
        if let contentJSON = devotional.contentJSON {
            content = try JSONSerialization.jsonObject(with: Data(contentJSON.utf8))
        } else {
            content = [["type": "paragraph", "content": ["text": devotional.content]]]
        }
        var root: [String: Any] = ["meta": meta, "content": content]
        if let mediaJSON = devotional.mediaJSON {
            guard let media = try JSONSerialization.jsonObject(
                with: Data(mediaJSON.utf8)
            ) as? [Any] else {
                throw LampLibraryError.invalidPersonalContent("Invalid devotional media metadata.")
            }
            root["media"] = media
        }
        if let summary = devotional.summary { root["summary"] = summary }
        if let footnotes = devotional.footnotes { root["footnotes"] = [footnotes] }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return LampPortableStudyDocument(
            moduleID: devotional.id,
            kind: .devotional,
            name: devotional.title,
            jsonData: data
        )
    }

    public func personalDevotionalCandidates(from sourceURL: URL) throws -> [LampDevotional] {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ["json", "lamp"].contains(fileExtension) else {
            throw LampLibraryError.invalidStudyDataExtension
        }
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let devotionals: [LampDevotional]
        if fileExtension == "json" {
            devotionals = [try personalDevotional(fromJSONData: sourceData)]
        } else {
            guard let databaseData = try? (sourceData as NSData).decompressed(using: .zlib) as Data else {
                throw LampLibraryError.decompressionFailed
            }
            let temporaryURL = fileManager.temporaryDirectory
                .appendingPathComponent("lamp-devotional-import-\(UUID().uuidString)")
                .appendingPathExtension("sqlite")
            try databaseData.write(to: temporaryURL, options: [.atomic])
            defer { try? fileManager.removeItem(at: temporaryURL) }
            devotionals = try devotionalsFromDatabase(at: temporaryURL)
        }
        guard !devotionals.isEmpty else { throw LampLibraryError.unsupportedModuleSchema }
        return devotionals
    }

    @discardableResult
    public func importPersonalDevotional(from sourceURL: URL) throws -> [LampDevotional] {
        let devotionals = try personalDevotionalCandidates(from: sourceURL)
        let existing = Dictionary(uniqueKeysWithValues: try personalDevotionals().map { ($0.id, $0) })
        return try devotionals.compactMap { devotional in
            if let local = existing[devotional.id] {
                let sameCore = local.title == devotional.title
                    && local.subtitle == devotional.subtitle
                    && local.author == devotional.author
                    && local.date == devotional.date
                    && local.tags == devotional.tags
                    && local.category == devotional.category
                    && local.seriesName == devotional.seriesName
                    && local.seriesOrder == devotional.seriesOrder
                    && local.keyScriptures == devotional.keyScriptures
                    && local.summary == devotional.summary
                    && local.content == devotional.content
                    && local.footnotes == devotional.footnotes
                if sameCore,
                   (local.mediaJSON == nil && devotional.mediaJSON != nil
                    || local.contentJSON == nil && devotional.contentJSON != nil) {
                    var enriched = local
                    enriched.mediaJSON = local.mediaJSON ?? devotional.mediaJSON
                    enriched.contentJSON = local.contentJSON ?? devotional.contentJSON
                    return try savePersonalDevotional(enriched, preserveLastModified: true)
                }
                let decision = LampSyncMerge.decide(
                    localModified: local.lastModified.map { Int($0.timeIntervalSince1970) },
                    incomingModified: devotional.lastModified.map { Int($0.timeIntervalSince1970) },
                    sameContent: sameCore
                        && (local.contentJSON == devotional.contentJSON
                            || devotional.contentJSON == nil)
                        && (local.mediaJSON == devotional.mediaJSON
                            || devotional.mediaJSON == nil)
                )
                if decision == .conflict {
                    throw LampLibraryError.syncConflict("devotional \(devotional.id)")
                }
                guard decision == .incoming else { return nil }
            }
            return try savePersonalDevotional(devotional, preserveLastModified: true)
        }
    }

    public func storePersonalDevotionalMedia(
        from sourceURL: URL,
        devotionalID: String
    ) throws -> URL {
        try validateIdentifier(devotionalID)
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let destinationDirectory = rootURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Devotionals", isDirectory: true)
            .appendingPathComponent(devotionalID, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let safeName = sourceName
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let filename = "\(safeName.isEmpty ? "attachment" : safeName)-\(UUID().uuidString.prefix(8))"
            + (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension.lowercased())")
        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    public func quizModules(planID: String? = nil) throws -> [LampQuizModule] {
        let modules = try installedModules().filter { $0.kind == .quiz }
        return try modules.compactMap { module in
            let queue = try openDatabase(moduleID: module.id)
            return try queue.read { db in
                var sql = "SELECT * FROM quiz_modules WHERE id = ?"
                var arguments: StatementArguments = [module.id]
                if let planID {
                    sql += " AND plan_id = ?"
                    arguments += [planID]
                }
                guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
                    return nil
                }
                let ageGroupsJSON: String = row["age_groups_json"]
                let ageGroups = ageGroupsJSON.data(using: .utf8).flatMap {
                    try? JSONDecoder().decode([LampQuizAgeGroup].self, from: $0)
                } ?? []
                let questionCount: Int? = row["questions_per_reading"]
                return LampQuizModule(
                    id: row["id"],
                    planID: row["plan_id"],
                    name: row["name"],
                    description: row["description"],
                    questionsPerReading: questionCount ?? 0,
                    ageGroups: ageGroups
                )
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func quizQuestions(
        moduleID: String,
        day: Int,
        startReference: Int? = nil,
        endReference: Int? = nil,
        ageGroup: String? = nil
    ) throws -> [LampQuizQuestion] {
        let queue = try openDatabase(moduleID: moduleID)
        return try queue.read { db in
            guard try tableNames(in: db).contains("quiz_questions") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            var conditions = ["quiz_module_id = ?", "day = ?"]
            var arguments: StatementArguments = [moduleID, day]
            if let startReference {
                conditions.append("sv = ?")
                arguments += [startReference]
            }
            if let endReference {
                conditions.append("ev = ?")
                arguments += [endReference]
            }
            if let ageGroup {
                conditions.append("age_group = ?")
                arguments += [ageGroup]
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM quiz_questions
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY sv, ev, age_group, question_index
                """, arguments: arguments).map { row in
                    let questionJSON: String = row["question_json"]
                    let answerJSON: String = row["answer_json"]
                    let questionContent = annotatedText(fromJSONString: questionJSON)
                    let answerContent = annotatedText(fromJSONString: answerJSON)
                    let referencesJSON: String? = row["references_json"]
                    let crossReferencesJSON: String? = row["cross_references_json"]
                    let christFocused: Int = row["christ_focused"]
                    return LampQuizQuestion(
                        id: row["id"],
                        moduleID: moduleID,
                        day: row["day"],
                        startReference: row["sv"],
                        endReference: row["ev"],
                        ageGroup: row["age_group"],
                        questionIndex: row["question_index"],
                        question: questionContent.text,
                        questionAnnotations: questionContent.annotations,
                        answer: answerContent.text,
                        answerAnnotations: answerContent.annotations,
                        theme: row["theme"],
                        isChristFocused: christFocused != 0,
                        references: integerArray(fromJSONString: referencesJSON),
                        crossReferences: integerArray(fromJSONString: crossReferencesJSON)
                    )
                }
        }
    }

    public func searchModules(
        query: String,
        kinds: Set<LampModuleKind>? = nil,
        moduleIDs: Set<String>? = nil,
        limit: Int = 200
    ) throws -> [LampModuleSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let resultLimit = min(max(limit, 1), 500)
        let installed = try installedModules()
        let wants: (LampModuleKind) -> Bool = { kinds == nil || kinds?.contains($0) == true }
        let includesModule: (String) -> Bool = { moduleIDs == nil || moduleIDs?.contains($0) == true }
        var results: [LampModuleSearchResult] = []

        if wants(.translation), results.count < resultLimit {
            let translationIDs = Set(installed.filter {
                $0.kind == .translation && includesModule($0.id)
            }.map(\.id))
            if !translationIDs.isEmpty {
                let matches = try searchTranslations(
                    query: trimmedQuery,
                    moduleIDs: translationIDs,
                    limit: resultLimit - results.count
                )
                results += matches.map { match in
                    LampModuleSearchResult(
                        id: "translation:\(match.id)",
                        kind: .translation,
                        moduleID: match.translationID,
                        moduleName: match.translationName,
                        title: "\(match.bookName) \(match.chapterNumber):\(match.verseNumber)",
                        subtitle: match.translationAbbreviation,
                        snippet: match.text,
                        startReference: match.reference
                    )
                }
            }
        }

        if wants(.dictionary), results.count < resultLimit {
            let dictionaryIDs = Set(installed.filter {
                $0.kind == .dictionary && includesModule($0.id)
            }.map(\.id))
            if !dictionaryIDs.isEmpty {
                let matches = try searchDictionaries(
                    query: trimmedQuery,
                    moduleIDs: dictionaryIDs,
                    limit: resultLimit - results.count
                )
                results += matches.map { match in
                    let definition = match.senses
                        .map { [$0.partOfSpeech, $0.gloss, $0.definition].compactMap { $0 }.joined(separator: ": ") }
                        .joined(separator: " • ")
                    return LampModuleSearchResult(
                        id: "dictionary:\(match.moduleID):\(match.entryID)",
                        kind: .dictionary,
                        moduleID: match.moduleID,
                        moduleName: match.moduleName,
                        title: match.lemma,
                        subtitle: match.transliteration,
                        snippet: searchSnippet(definition.isEmpty ? match.key : definition)
                    )
                }
            }
        }

        if wants(.commentary), results.count < resultLimit {
            let pattern = "%\(trimmedQuery)%"
            for module in installed where module.kind == .commentary && includesModule(module.id) {
                let queue = try openDatabase(moduleID: module.id)
                let remaining = resultLimit - results.count
                let matches = try queue.read { db -> [LampModuleSearchResult] in
                    guard try tableNames(in: db).contains("commentary_units") else { return [] }
                    let columns = try columnNames(in: db, table: "commentary_units")
                    var condition = "(COALESCE(title, '') LIKE ? COLLATE NOCASE OR COALESCE(introduction_json, '') LIKE ? COLLATE NOCASE OR COALESCE(translation_json, '') LIKE ? COLLATE NOCASE OR COALESCE(commentary_json, '') LIKE ? COLLATE NOCASE OR COALESCE(footnotes_json, '') LIKE ? COLLATE NOCASE)"
                    var arguments: StatementArguments = [pattern, pattern, pattern, pattern, pattern]
                    if columns.contains("module_id") {
                        condition = "module_id = ? AND " + condition
                        arguments = [module.id, pattern, pattern, pattern, pattern, pattern]
                    }
                    arguments += [remaining]
                    return try Row.fetchAll(db, sql: """
                        SELECT id, book, chapter, sv, ev, title,
                               introduction_json, translation_json, commentary_json, footnotes_json
                        FROM commentary_units
                        WHERE \(condition)
                        ORDER BY book, chapter, order_index
                        LIMIT ?
                        """, arguments: arguments).map { row in
                            let introduction: String? = row["introduction_json"]
                            let translation: String? = row["translation_json"]
                            let commentary: String? = row["commentary_json"]
                            let footnotes: String? = row["footnotes_json"]
                            let start: Int = row["sv"]
                            let end: Int? = row["ev"]
                            let body = [introduction, translation, commentary, footnotes]
                                .compactMap { plainText(fromJSONString: $0) }
                                .joined(separator: " ")
                            let title: String? = row["title"]
                            return LampModuleSearchResult(
                                id: "commentary:\(module.id):\(row["id"] as String)",
                                kind: .commentary,
                                moduleID: module.id,
                                moduleName: module.name,
                                title: title?.isEmpty == false
                                    ? title! : LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                                subtitle: LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                                snippet: searchSnippet(body),
                                startReference: start,
                                endReference: end
                            )
                        }
                }
                results += matches
                if results.count >= resultLimit { break }
            }
        }

        if wants(.book), results.count < resultLimit {
            let pattern = "%\(trimmedQuery)%"
            for module in installed where module.kind == .book && includesModule(module.id) {
                let queue = try openDatabase(moduleID: module.id)
                let remaining = resultLimit - results.count
                results += try queue.read { db in
                    guard try tableNames(in: db).contains("book_sections") else { return [] }
                    return try Row.fetchAll(db, sql: """
                        SELECT id, title, subtitle, key_scriptures_json,
                               content_json, search_text
                        FROM book_sections
                        WHERE module_id = ?
                          AND (title LIKE ? COLLATE NOCASE
                            OR COALESCE(subtitle, '') LIKE ? COLLATE NOCASE
                            OR search_text LIKE ? COLLATE NOCASE)
                        ORDER BY rowid
                        LIMIT ?
                        """, arguments: [module.id, pattern, pattern, pattern, remaining]).map { row in
                            let scripturesJSON: String? = row["key_scriptures_json"]
                            let scriptures = devotionalScriptureLinks(from: scripturesJSON)
                            let contentJSON: String = row["content_json"]
                            return LampModuleSearchResult(
                                id: "book:\(module.id):\(row["id"] as String)",
                                kind: .book,
                                moduleID: module.id,
                                moduleName: module.name,
                                title: row["title"],
                                subtitle: row["subtitle"],
                                snippet: searchSnippet(plainText(fromJSONString: contentJSON) ?? contentJSON),
                                startReference: scriptures.first?.startReference,
                                endReference: scriptures.first?.endReference
                            )
                        }
                }
                if results.count >= resultLimit { break }
            }
        }

        if wants(.notes), results.count < resultLimit {
            let pattern = "%\(trimmedQuery)%"
            if includesModule("personal-notes") {
                let queue = try openUserDatabase()
                let remaining = resultLimit - results.count
                results += try queue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT id, module_id, verse_id, title, content
                        FROM personal_notes
                        WHERE COALESCE(title, '') LIKE ? COLLATE NOCASE
                           OR content LIKE ? COLLATE NOCASE
                        ORDER BY last_modified DESC
                        LIMIT ?
                        """, arguments: [pattern, pattern, remaining]).map { row in
                            let reference: Int = row["verse_id"]
                            let title: String? = row["title"]
                            return LampModuleSearchResult(
                                id: "notes:personal-notes:\(row["id"] as String)",
                                kind: .notes,
                                moduleID: "personal-notes",
                                moduleName: "My Notes",
                                title: title?.isEmpty == false
                                    ? title! : LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                                subtitle: LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                                snippet: searchSnippet(row["content"] as String),
                                startReference: reference
                            )
                        }
                }
            }
            for module in installed where module.kind == .notes && includesModule(module.id) && results.count < resultLimit {
                let queue = try openDatabase(moduleID: module.id)
                let remaining = resultLimit - results.count
                results += try queue.read { db in
                    guard try tableNames(in: db).contains("note_entries") else { return [] }
                    let columns = try columnNames(in: db, table: "note_entries")
                    let titleColumn = columns.contains("title") ? "title" : "NULL AS title"
                    let searchCondition = columns.contains("title")
                        ? "COALESCE(title, '') LIKE ? COLLATE NOCASE OR content LIKE ? COLLATE NOCASE"
                        : "content LIKE ? COLLATE NOCASE"
                    var arguments: StatementArguments = columns.contains("title")
                        ? [pattern, pattern] : [pattern]
                    arguments += [remaining]
                    return try Row.fetchAll(db, sql: """
                        SELECT id, verse_id, \(titleColumn), content
                        FROM note_entries
                        WHERE \(searchCondition)
                        ORDER BY verse_id, id
                        LIMIT ?
                        """, arguments: arguments).map { row in
                            let reference: Int = row["verse_id"]
                            let title: String? = row["title"]
                            return LampModuleSearchResult(
                                id: "notes:\(module.id):\(row["id"] as String)",
                                kind: .notes,
                                moduleID: module.id,
                                moduleName: module.name,
                                title: title?.isEmpty == false
                                    ? title! : LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                                subtitle: LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                                snippet: searchSnippet(row["content"] as String),
                                startReference: reference
                            )
                        }
                }
            }
        }

        if wants(.devotional), results.count < resultLimit {
            let matches = try devotionals(moduleIDs: moduleIDs, query: trimmedQuery)
            results += matches.prefix(resultLimit - results.count).map { devotional in
                LampModuleSearchResult(
                    id: "devotional:\(devotional.moduleID):\(devotional.id)",
                    kind: .devotional,
                    moduleID: devotional.moduleID,
                    moduleName: devotional.moduleName,
                    title: devotional.title,
                    subtitle: devotional.subtitle ?? devotional.author,
                    snippet: searchSnippet(devotional.summary ?? devotional.content),
                    startReference: devotional.keyScriptures.first?.startReference,
                    endReference: devotional.keyScriptures.first?.endReference
                )
            }
        }

        if wants(.plan), results.count < resultLimit {
            results += try readingPlans().filter { plan in
                includesModule(plan.id) && [plan.name, plan.description, plan.fullDescription, plan.author]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            }
            .prefix(resultLimit - results.count)
            .map { plan in
                LampModuleSearchResult(
                    id: "plan:\(plan.id)",
                    kind: .plan,
                    moduleID: plan.id,
                    moduleName: plan.name,
                    title: plan.name,
                    subtitle: plan.author,
                    snippet: searchSnippet(plan.fullDescription ?? plan.description ?? "\(plan.duration) days")
                )
            }
        }

        if wants(.quiz), results.count < resultLimit {
            let pattern = "%\(trimmedQuery)%"
            for module in installed where module.kind == .quiz && includesModule(module.id) {
                let queue = try openDatabase(moduleID: module.id)
                let remaining = resultLimit - results.count
                results += try queue.read { db in
                    guard try tableNames(in: db).contains("quiz_questions") else { return [] }
                    return try Row.fetchAll(db, sql: """
                        SELECT id, day, sv, ev, age_group, question_json, answer_json, theme
                        FROM quiz_questions
                        WHERE quiz_module_id = ?
                          AND (question_json LIKE ? COLLATE NOCASE
                            OR answer_json LIKE ? COLLATE NOCASE
                            OR theme LIKE ? COLLATE NOCASE)
                        ORDER BY day, sv, age_group, question_index
                        LIMIT ?
                        """, arguments: [module.id, pattern, pattern, pattern, remaining]).map { row in
                            let start: Int = row["sv"]
                            let end: Int = row["ev"]
                            let questionJSON: String = row["question_json"]
                            let answerJSON: String = row["answer_json"]
                            return LampModuleSearchResult(
                                id: "quiz:\(module.id):\(row["id"] as Int64)",
                                kind: .quiz,
                                moduleID: module.id,
                                moduleName: module.name,
                                title: plainText(fromJSONString: questionJSON) ?? "Quiz Question",
                                subtitle: "Day \(row["day"] as Int) • \(row["age_group"] as String)",
                                snippet: searchSnippet(plainText(fromJSONString: answerJSON) ?? answerJSON),
                                startReference: start,
                                endReference: end
                            )
                        }
                }
                if results.count >= resultLimit { break }
            }
        }

        if wants(.highlights), results.count < resultLimit {
            let translationIDs = Set(installed.filter { $0.kind == .translation }.map(\.id))
            let verseMatches = try searchTranslations(
                query: trimmedQuery,
                moduleIDs: translationIDs,
                limit: min((resultLimit - results.count) * 4, 500)
            )
            for match in verseMatches where results.count < resultLimit {
                let personal = try verseHighlights(translationID: match.translationID, reference: match.reference)
                for highlight in personal where includesModule(highlight.setID) && results.count < resultLimit {
                    results.append(LampModuleSearchResult(
                        id: "highlights:\(highlight.setID):\(highlight.id)",
                        kind: .highlights,
                        moduleID: highlight.setID,
                        moduleName: "My Highlights",
                        title: "\(match.bookName) \(match.chapterNumber):\(match.verseNumber)",
                        subtitle: match.translationAbbreviation,
                        snippet: searchSnippet(match.text),
                        startReference: match.reference
                    ))
                }
                for module in installed where module.kind == .highlights && includesModule(module.id) {
                    let moduleHighlights = try moduleVerseHighlights(moduleID: module.id, reference: match.reference)
                    for highlight in moduleHighlights where highlight.translationID == match.translationID && results.count < resultLimit {
                        results.append(LampModuleSearchResult(
                            id: "highlights:\(module.id):\(highlight.id)",
                            kind: .highlights,
                            moduleID: module.id,
                            moduleName: module.name,
                            title: "\(match.bookName) \(match.chapterNumber):\(match.verseNumber)",
                            subtitle: match.translationAbbreviation,
                            snippet: searchSnippet(match.text),
                            startReference: match.reference
                        ))
                    }
                }
            }
        }

        return Array(results.prefix(resultLimit))
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
        content: String,
        verseReferences: [Int]? = nil,
        footnotes: [LampVerseFootnote]? = nil
    ) throws -> LampVerseNote? {
        let noteID = "personal-notes:\(reference)"
        let meaningfulTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if meaningfulTitle?.isEmpty != false
            && meaningfulContent.isEmpty
            && (footnotes ?? []).allSatisfy({ $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
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
            verseReferences: verseReferences ?? existing?.verseReferences ?? [],
            footnotes: footnotes ?? existing?.footnotes ?? []
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

    public func highlightSets(translationID: String? = nil) throws -> [LampHighlightSet] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            var sql = "SELECT * FROM highlight_sets"
            var arguments = StatementArguments()
            if let translationID {
                sql += " WHERE translation_id = ?"
                arguments = [translationID]
            }
            sql += " ORDER BY name COLLATE NOCASE, created"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let created: Int = row["created"]
                let lastModified: Int = row["last_modified"]
                return LampHighlightSet(
                    id: row["id"],
                    name: row["name"],
                    description: row["description"],
                    translationID: row["translation_id"],
                    created: Date(timeIntervalSince1970: TimeInterval(created)),
                    lastModified: Date(timeIntervalSince1970: TimeInterval(lastModified))
                )
            }
        }
    }

    @discardableResult
    public func saveHighlightSet(_ set: LampHighlightSet) throws -> LampHighlightSet {
        let name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LampLibraryError.invalidPersonalContent("A highlight set needs a name.")
        }
        try validateIdentifier(set.id)
        let now = Date(timeIntervalSince1970: TimeInterval(Int(Date().timeIntervalSince1970)))
        let created = Date(timeIntervalSince1970: TimeInterval(Int(set.created.timeIntervalSince1970)))
        let saved = LampHighlightSet(
            id: set.id,
            name: name,
            description: set.description?.nilIfBlank,
            translationID: set.translationID,
            created: created,
            lastModified: now
        )
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO highlight_sets (
                    id, name, description, translation_id, created, last_modified
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    description = excluded.description,
                    translation_id = excluded.translation_id,
                    last_modified = excluded.last_modified
                """, arguments: [
                    saved.id,
                    saved.name,
                    saved.description,
                    saved.translationID,
                    Int(saved.created.timeIntervalSince1970),
                    Int(saved.lastModified.timeIntervalSince1970),
                ])
        }
        return saved
    }

    public func deleteHighlightSet(id: String) throws {
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM highlights WHERE set_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM highlight_themes WHERE set_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM highlight_sets WHERE id = ?", arguments: [id])
        }
    }

    public func highlightThemes(setID: String) throws -> [LampHighlightTheme] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT set_id, color, style, name, description
                FROM highlight_themes WHERE set_id = ?
                ORDER BY name COLLATE NOCASE, color, style
                """, arguments: [setID]).compactMap(makeHighlightTheme)
        }
    }

    @discardableResult
    public func saveHighlightTheme(_ theme: LampHighlightTheme) throws -> LampHighlightTheme {
        let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LampLibraryError.invalidPersonalContent("A highlight theme needs a name.")
        }
        let saved = LampHighlightTheme(
            setID: theme.setID,
            color: theme.color,
            style: theme.style,
            name: name,
            description: theme.description?.nilIfBlank
        )
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO highlight_themes (set_id, color, style, name, description)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(set_id, color, style) DO UPDATE SET
                    name = excluded.name,
                    description = excluded.description
                """, arguments: [
                    saved.setID, saved.color, saved.style.rawValue, saved.name, saved.description,
                ])
        }
        return saved
    }

    public func deleteHighlightTheme(setID: String, color: String, style: LampHighlightStyle) throws {
        let normalizedColor = color.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let queue = try openUserDatabase()
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM highlight_themes WHERE set_id = ? AND color = ? AND style = ?
                """, arguments: [setID, normalizedColor, style.rawValue])
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
                    if let endReference = note.verseReferences.max(),
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
        name requestedName: String? = nil,
        setID requestedSetID: String? = nil
    ) throws -> LampPortableStudyDocument {
        let setID = requestedSetID ?? "personal-highlights:\(translationID)"
        let queue = try openUserDatabase()
        let export = try queue.read { db -> (name: String?, description: String?, created: Int?, modified: Int?, highlights: [LampVerseHighlight], themes: [LampHighlightTheme]) in
            let metadata = try Row.fetchOne(db, sql: """
                SELECT name, description, created, last_modified
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
            let themes = try Row.fetchAll(db, sql: """
                SELECT set_id, color, style, name, description
                FROM highlight_themes WHERE set_id = ?
                ORDER BY name, color, style
                """, arguments: [setID]).compactMap(makeHighlightTheme)
            let created: Int? = metadata?["created"]
            let modified: Int? = metadata?["last_modified"]
            let name: String? = metadata?["name"]
            let description: String? = metadata?["description"]
            return (name, description, created, modified, highlights, themes)
        }
        guard !export.highlights.isEmpty else {
            throw LampLibraryError.noPersonalHighlights(translationID: translationID)
        }

        let safeTranslationID = safeExportIdentifier(translationID)
        let moduleID = requestedModuleID ?? (requestedSetID == nil
            ? "personal-highlights-\(safeTranslationID)"
            : safeExportIdentifier(setID))
        let name = requestedName ?? export.name ?? "My Highlights — \(translationID)"
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": moduleID,
            "type": "highlights",
            "name": name,
            "translationId": translationID,
        ]
        if let created = export.created { meta["created"] = created }
        if let modified = export.modified { meta["lastModified"] = modified }
        if let description = export.description { meta["description"] = description }
        if !export.themes.isEmpty {
            meta["themes"] = export.themes.map { theme -> [String: Any] in
                var value: [String: Any] = [
                    "color": theme.color,
                    "style": theme.style.rawValue,
                    "name": theme.name,
                ]
                if let description = theme.description { value["description"] = description }
                return value
            }
        }
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

    @discardableResult
    public func exportPortableBackup(to destinationURL: URL) throws -> LampPortableBackupSummary {
        try prepareDirectories()
        let modulesDestination = destinationURL.appendingPathComponent(LampPortableBackupLayout.modulesDirectory, isDirectory: true)
        let notesDestination = destinationURL.appendingPathComponent(LampPortableBackupLayout.notesDirectory, isDirectory: true)
        let highlightsDestination = destinationURL.appendingPathComponent(LampPortableBackupLayout.highlightsDirectory, isDirectory: true)
        let devotionalsDestination = destinationURL.appendingPathComponent(LampPortableBackupLayout.devotionalsDirectory, isDirectory: true)
        for directory in [destinationURL, modulesDestination, notesDestination, highlightsDestination, devotionalsDestination] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var moduleCount = 0
        for sourceURL in try fileManager.contentsOfDirectory(
            at: modulesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where sourceURL.pathExtension.lowercased() == "lamp" {
            let destination = modulesDestination.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: sourceURL, to: destination)
            moduleCount += 1
        }

        let queue = try openUserDatabase()
        let noteBooks = try queue.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT book FROM personal_notes
                WHERE module_id = 'personal-notes' ORDER BY book
                """)
        }
        var noteDocumentCount = 0
        for book in noteBooks {
            let document = try personalNotesDocument(bookNumber: book)
            try document.jsonData.write(
                to: notesDestination.appendingPathComponent(document.suggestedJSONFilename),
                options: .atomic
            )
            noteDocumentCount += 1
        }

        let highlightSets = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT s.id, s.translation_id
                FROM highlight_sets s JOIN highlights h ON h.set_id = s.id
                ORDER BY s.translation_id, s.name, s.id
                """).map { row -> (id: String, translationID: String) in
                    (row["id"], row["translation_id"])
                }
        }
        var highlightDocumentCount = 0
        for set in highlightSets {
            let document = try personalHighlightsDocument(
                translationID: set.translationID,
                setID: set.id
            )
            try document.jsonData.write(
                to: highlightsDestination.appendingPathComponent(document.suggestedJSONFilename),
                options: .atomic
            )
            highlightDocumentCount += 1
        }

        let personalDevotionals = try personalDevotionals()
        for devotional in personalDevotionals {
            let document = try personalDevotionalDocument(id: devotional.id)
            try document.jsonData.write(
                to: devotionalsDestination.appendingPathComponent(document.suggestedJSONFilename),
                options: .atomic
            )
        }

        let mediaSource = rootURL.appendingPathComponent("Media", isDirectory: true)
        let mediaDestination = destinationURL.appendingPathComponent(LampPortableBackupLayout.mediaDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: mediaSource.path) {
            if fileManager.fileExists(atPath: mediaDestination.path) { try fileManager.removeItem(at: mediaDestination) }
            try fileManager.copyItem(at: mediaSource, to: mediaDestination)
        }

        let summary = LampPortableBackupSummary(
            moduleCount: moduleCount,
            noteDocumentCount: noteDocumentCount,
            highlightDocumentCount: highlightDocumentCount,
            devotionalDocumentCount: personalDevotionals.count
        )
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: summary.moduleCount,
                noteDocumentCount: summary.noteDocumentCount,
                highlightDocumentCount: summary.highlightDocumentCount,
                devotionalDocumentCount: summary.devotionalDocumentCount
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: destinationURL.appendingPathComponent(LampPortableBackupLayout.manifestPath),
            options: .atomic
        )
        return summary
    }

    @discardableResult
    public func importPortableBackup(from sourceURL: URL) async throws -> LampPortableBackupImportResult {
        if isStagingLibrary {
            return try importPortableBackupContents(from: sourceURL)
        }
        return try await withStagedChanges { stagedLibrary in
            try await stagedLibrary.importPortableBackup(from: sourceURL)
        }
    }

    /// Apply every part of an incoming sync to a sibling copy of the library.
    /// A thrown operation discards that copy; a successful one replaces the root
    /// only if the live library has not changed while the operation was running.
    @discardableResult
    public func withStagedChanges<Result>(
        _ operation: (LampLibrary) async throws -> Result
    ) async throws -> Result {
        precondition(!isStagingLibrary, "Nested staged library changes are unsupported")
        let parent = rootURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagedURL = parent.appendingPathComponent(
            ".lamp-backup-import-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagedURL) }
        let rootExisted = fileManager.fileExists(atPath: rootURL.path)
        if rootExisted {
            try fileManager.copyItem(at: rootURL, to: stagedURL)
        } else {
            try fileManager.createDirectory(at: stagedURL, withIntermediateDirectories: false)
        }
        let originalFiles = try libraryFileRevisions(at: stagedURL)

        let stagedLibrary = LampLibrary(
            stagingRootURL: stagedURL,
            bundledModulesArchiveURL: bundledModulesArchiveURL,
            fileManager: fileManager
        )
        let result = try await operation(stagedLibrary)
        await stagedLibrary.forgetOpenDatabases()

        // Another actor call may have changed the live library while this
        // actor was suspended for the staged import. Never replace that edit.
        let liveUnchanged: Bool
        if rootExisted, fileManager.fileExists(atPath: rootURL.path) {
            liveUnchanged = try libraryFileRevisions(at: rootURL) == originalFiles
        } else {
            liveUnchanged = !rootExisted && !fileManager.fileExists(atPath: rootURL.path)
        }
        guard liveUnchanged else {
            throw LampLibraryError.syncConflict("Local library changed during sync import.")
        }

        // The destination and stage are siblings on one volume. Replace the
        // directory only after all incoming content has been accepted.
        forgetOpenDatabases()
        cachedBundledDatabaseURL = nil
        cachedBundledModules = nil
        if fileManager.fileExists(atPath: rootURL.path) {
            let backupName = ".lamp-backup-previous-\(UUID().uuidString)"
            let previousURL = parent.appendingPathComponent(backupName, isDirectory: true)
            do {
                _ = try fileManager.replaceItemAt(
                    rootURL, withItemAt: stagedURL, backupItemName: backupName
                )
            } catch {
                if !fileManager.fileExists(atPath: rootURL.path),
                   fileManager.fileExists(atPath: previousURL.path) {
                    try? fileManager.moveItem(at: previousURL, to: rootURL)
                }
                throw error
            }
            try? fileManager.removeItem(at: previousURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: rootURL)
        }
        return result
    }

    private func importPortableBackupContents(
        from sourceURL: URL
    ) throws -> LampPortableBackupImportResult {
        let manifestURL = sourceURL.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LampLibraryError.invalidPersonalContent("The selected folder is not a Lamp Bible backup.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            LampPortableBackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try manifest.validate()
        var installedModules = 0
        var importedStudyEntries = 0
        var importedDevotionals = 0

        let modulesSource = sourceURL.appendingPathComponent(LampPortableBackupLayout.modulesDirectory, isDirectory: true)
        for url in backupFiles(in: modulesSource, extension: "lamp") {
            _ = try install(from: url)
            installedModules += 1
        }
        let studySource = sourceURL.appendingPathComponent(LampPortableBackupLayout.studyDirectory, isDirectory: true)
        for url in backupFiles(in: studySource, extension: "json") {
            let result = try importPersonalStudyData(from: url)
            importedStudyEntries += result.importedCount
        }
        let devotionalsSource = sourceURL.appendingPathComponent(LampPortableBackupLayout.devotionalsDirectory, isDirectory: true)
        for url in backupFiles(in: devotionalsSource, extension: "json") {
            importedDevotionals += try importPersonalDevotional(from: url).count
        }

        let mediaSource = sourceURL.appendingPathComponent(LampPortableBackupLayout.mediaDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: mediaSource.path) {
            let mediaDestination = rootURL.appendingPathComponent(LampPortableBackupLayout.mediaDirectory, isDirectory: true)
            try mergeDirectory(from: mediaSource, to: mediaDestination)
        }
        return LampPortableBackupImportResult(
            installedModules: installedModules,
            importedStudyEntries: importedStudyEntries,
            importedDevotionals: importedDevotionals
        )
    }

    private func libraryFileRevisions(at directory: URL) throws -> [String: String] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LampLibraryError.syncConflict("Could not inspect the local library.")
        }
        let pathPrefix = directory.standardizedFileURL.path + "/"
        var revisions: [String: String] = [:]
        for case let url as URL in enumerator {
            let itemPath = url.standardizedFileURL.path
            guard itemPath.hasPrefix(pathPrefix) else {
                throw LampLibraryError.syncConflict("Could not inspect the local library.")
            }
            let relativePath = String(itemPath.dropFirst(pathPrefix.count))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                revisions[relativePath] = "link:" + (try fileManager.destinationOfSymbolicLink(
                    atPath: url.path
                ))
            } else if values.isRegularFile == true {
                var digest = SHA256()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    digest.update(data: chunk)
                }
                revisions[relativePath] = digest.finalize()
                    .map { String(format: "%02x", $0) }.joined()
            }
        }
        if let enumerationError { throw enumerationError }
        return revisions
    }

    private var modulesURL: URL {
        rootURL.appendingPathComponent("Modules", isDirectory: true)
    }

    private func backupFiles(in directory: URL, extension fileExtension: String) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted { $0.path < $1.path }
    }

    private func mergeDirectory(from source: URL, to destination: URL) throws {
        if try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw LampLibraryError.syncConflict("Media backup contains a symbolic link.")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw LampLibraryError.syncConflict("Media backup contains a symbolic link.")
            }
            if values.isDirectory == true {
                try mergeDirectory(from: child, to: target)
            } else {
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: child, to: target)
            }
        }
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
            let metadataModuleID = tables.contains("module_meta")
                ? try String.fetchOne(db, sql: "SELECT id FROM module_meta LIMIT 1")
                : nil
            let moduleID = formatModuleID ?? metadataModuleID ?? fallbackModuleID

            if declaredKind == .notes || tables.contains("note_entries") {
                try LampPortableModuleInspector.validateOwnership(
                    databaseURL: databaseURL,
                    expectedID: moduleID,
                    kind: .notes,
                    verifyIntegrity: false
                )
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
                try LampPortableModuleInspector.validateOwnership(
                    databaseURL: databaseURL,
                    expectedID: moduleID,
                    kind: .highlights,
                    verifyIntegrity: false
                )
                let highlights = try readModuleHighlights(
                    in: db,
                    referenceRange: 1_000_000...66_999_999
                )
                let metadata = tables.contains("highlight_meta")
                    ? try Row.fetchOne(db, sql: "SELECT * FROM highlight_meta LIMIT 1")
                    : nil
                let name: String? = metadata?["name"]
                let description: String? = metadata?["description"]
                let created: Int? = metadata?["created"]
                let lastModified: Int? = metadata?["last_modified"]
                let setMetadata: [String: ImportedHighlightSetMetadata]
                if tables.contains("highlight_sets") {
                    setMetadata = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                        SELECT id, name, description, created, last_modified
                        FROM highlight_sets
                        """).map { row in
                            let id: String = row["id"]
                            return (id, ImportedHighlightSetMetadata(
                                name: row["name"],
                                description: row["description"],
                                created: row["created"],
                                lastModified: row["last_modified"]
                            ))
                        })
                } else {
                    setMetadata = [:]
                }
                let themes: [LampHighlightTheme]
                if tables.contains("highlight_themes") {
                    let themeColumns = try columnNames(in: db, table: "highlight_themes")
                    if themeColumns.contains("set_id") {
                        themes = try Row.fetchAll(db, sql: """
                            SELECT set_id, color, style, name, description
                            FROM highlight_themes ORDER BY set_id, name, color, style
                            """).compactMap(makeHighlightTheme)
                    } else {
                        themes = try Row.fetchAll(db, sql: """
                            SELECT ? AS set_id, color, style, name, description
                            FROM highlight_themes ORDER BY name, color, style
                            """, arguments: [moduleID]).compactMap(makeHighlightTheme)
                    }
                } else {
                    themes = []
                }
                return try mergeImportedHighlights(
                    highlights,
                    moduleID: moduleID,
                    name: name,
                    description: description,
                    created: created,
                    lastModified: lastModified,
                    themes: themes,
                    setMetadata: setMetadata
                )
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
                let referencesData = try JSONEncoder().encode(note.verseReferences)
                let referencesJSON = String(decoding: referencesData, as: UTF8.self)
                let footnotes = note.footnotes.map { footnote -> [String: String] in
                    var value = ["id": footnote.id, "content": footnote.content]
                    if let kind = footnote.kind { value["type"] = kind }
                    return value
                }
                let footnotesData = try JSONSerialization.data(
                    withJSONObject: footnotes,
                    options: [.sortedKeys]
                )
                let footnotesJSON = String(decoding: footnotesData, as: UTF8.self)
                let existing = try Row.fetchOne(db, sql: """
                    SELECT title, content, verse_refs_json, footnotes_json, last_modified
                    FROM personal_notes WHERE id = ?
                    """, arguments: [id])
                let existingTimestamp: Int? = existing?["last_modified"]
                if let existingTimestamp {
                    let existingTitle: String? = existing?["title"]
                    let existingContent: String? = existing?["content"]
                    let existingReferences: String? = existing?["verse_refs_json"]
                    let existingFootnotes: String? = existing?["footnotes_json"]
                    let decision = LampSyncMerge.decide(
                        localModified: existingTimestamp,
                        incomingModified: incomingTimestamp,
                        sameContent: existingTitle == note.title
                            && existingContent == note.content
                            && (existingReferences ?? "[]") == referencesJSON
                            && (existingFootnotes ?? "[]") == footnotesJSON
                    )
                    if decision == .conflict {
                        throw LampLibraryError.syncConflict("note \(note.reference)")
                    }
                    if decision != .incoming {
                        skippedCount += 1
                        continue
                    }
                }
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
                        referencesJSON,
                        footnotesJSON,
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
        moduleID: String,
        name: String? = nil,
        description: String? = nil,
        created: Int? = nil,
        lastModified: Int? = nil,
        themes: [LampHighlightTheme] = [],
        setMetadata: [String: ImportedHighlightSetMetadata] = [:]
    ) throws -> LampStudyImportResult {
        let queue = try openUserDatabase()
        let now = Int(Date().timeIntervalSince1970)
        var importedCount = 0
        var skippedCount = 0
        try queue.write { db in
            for setGroup in Dictionary(grouping: highlights, by: \.setID) {
                let setID = setGroup.key
                guard let translationID = setGroup.value.first?.translationID else { continue }
                let metadata = setMetadata[setID]
                try db.execute(sql: """
                    INSERT INTO highlight_sets (
                        id, name, description, translation_id, created, last_modified
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        description = excluded.description,
                        translation_id = excluded.translation_id,
                        last_modified = MAX(highlight_sets.last_modified, excluded.last_modified)
                    """, arguments: [
                        setID,
                        metadata?.name ?? name ?? "My Highlights",
                        metadata?.description ?? description,
                        translationID,
                        metadata?.created ?? created ?? now,
                        metadata?.lastModified ?? lastModified ?? now,
                    ])
                for highlight in setGroup.value {
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
                for theme in themes where theme.setID == setID {
                    try db.execute(sql: """
                        INSERT INTO highlight_themes (set_id, color, style, name, description)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(set_id, color, style) DO UPDATE SET
                            name = excluded.name,
                            description = excluded.description
                        """, arguments: [
                            setID,
                            theme.color,
                            theme.style.rawValue,
                            theme.name,
                            theme.description,
                        ])
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

    private struct ImportedHighlightSetMetadata {
        let name: String
        let description: String?
        let created: Int?
        let lastModified: Int?
    }

    private func normalizedHighlightColor(_ color: String?) -> String? {
        guard var color else { return nil }
        if color.hasPrefix("#") { color.removeFirst() }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let isHex = [6, 8].contains(color.count)
            && color.unicodeScalars.allSatisfy(hexDigits.contains)
        return isHex ? color.uppercased() : color
    }

    private func searchSnippet(_ text: String, limit: Int = 280) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func devotionalSort(_ lhs: LampDevotional, _ rhs: LampDevotional) -> Bool {
        let leftSeries = lhs.seriesName ?? ""
        let rightSeries = rhs.seriesName ?? ""
        if leftSeries != rightSeries {
            return leftSeries.localizedStandardCompare(rightSeries) == .orderedAscending
        }
        if lhs.seriesOrder != rhs.seriesOrder {
            return (lhs.seriesOrder ?? 0) < (rhs.seriesOrder ?? 0)
        }
        if lhs.date != rhs.date { return (lhs.date ?? "") < (rhs.date ?? "") }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private var databasesURL: URL {
        rootURL.appendingPathComponent("Databases", isDirectory: true)
    }

    private var bundledDatabasesURL: URL {
        rootURL.appendingPathComponent("Bundled", isDirectory: true)
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
        if fileManager.fileExists(atPath: url.path) {
            return try openReadOnlyDatabase(at: url)
        }
        if try bundledModules().contains(where: { $0.id == moduleID }),
           let bundledURL = try preparedBundledDatabaseURL() {
            return try openReadOnlyDatabase(at: bundledURL)
        }
        throw LampLibraryError.moduleNotFound(moduleID)
    }

    /// A read-only connection to `url`, reused across calls.
    ///
    /// Opening a connection is not free: it maps the file, reads the header and
    /// parses the schema. The library answers a great many small queries, so
    /// opening one per query meant that fixed cost dominated reads whose SQL takes
    /// well under a millisecond — measured at roughly 200 ms per lookup against a
    /// bundled database of a few hundred megabytes.
    ///
    /// `forgetOpenDatabases()` drops the cache whenever a database file is
    /// rewritten or removed, so nothing can read through a stale handle.
    private func openReadOnlyDatabase(at url: URL) throws -> DatabaseQueue {
        if let existing = openDatabases[url.path] { return existing }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        openDatabases[url.path] = queue
        return queue
    }

    /// Drops every cached connection. Called after any write that could replace a
    /// database file underneath one.
    private func forgetOpenDatabases() {
        openDatabases.removeAll()
    }

    private func preparedBundledDatabaseURL() throws -> URL? {
        if let cachedBundledDatabaseURL,
           fileManager.fileExists(atPath: cachedBundledDatabaseURL.path) {
            return cachedBundledDatabaseURL
        }
        guard let archiveURL = bundledModulesArchiveURL,
              fileManager.fileExists(atPath: archiveURL.path) else {
            return nil
        }

        try fileManager.createDirectory(at: bundledDatabasesURL, withIntermediateDirectories: true)
        let databaseURL = bundledDatabasesURL.appendingPathComponent("bundled_modules.sqlite")
        let markerURL = bundledDatabasesURL.appendingPathComponent("bundled_modules.version")
        let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let currentVersion = "\(archiveSize)"
        if fileManager.fileExists(atPath: databaseURL.path),
           (try? String(contentsOf: markerURL, encoding: .utf8)) == currentVersion {
            cachedBundledDatabaseURL = databaseURL
            return databaseURL
        }

        let hasSecurityScope = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { archiveURL.stopAccessingSecurityScopedResource() }
        }
        let sourceData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let databaseData: Data
        if archiveURL.pathExtension.lowercased() == "zlib" {
            guard let decompressed = try? (sourceData as NSData).decompressed(using: .zlib) as Data else {
                throw LampLibraryError.decompressionFailed
            }
            databaseData = decompressed
        } else {
            databaseData = sourceData
        }
        // The bundled database is being replaced on disk, so any connection still
        // held to the previous copy has to go before the new one is opened below.
        try databaseData.write(to: databaseURL, options: [.atomic])
        forgetOpenDatabases()

        // Verified here, once, rather than on every read of the bundled modules.
        // The version marker is written only after the check passes, so a corrupt
        // extraction is redone on the next launch instead of being trusted.
        let queue = try openReadOnlyDatabase(at: databaseURL)
        let integrityResults = try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        guard integrityResults == ["ok"] else {
            try? fileManager.removeItem(at: databaseURL)
            throw LampLibraryError.integrityCheckFailed(integrityResults.joined(separator: "; "))
        }

        try currentVersion.write(to: markerURL, atomically: true, encoding: .utf8)
        cachedBundledDatabaseURL = databaseURL
        cachedBundledModules = nil
        return databaseURL
    }

    private func bundledModules() throws -> [LampInstalledModule] {
        if let cachedBundledModules { return cachedBundledModules }
        guard let databaseURL = try preparedBundledDatabaseURL() else { return [] }
        let queue = try openReadOnlyDatabase(at: databaseURL)
        let modules = try queue.read { db -> [LampInstalledModule] in
            let tables = try tableNames(in: db)
            var modules: [LampInstalledModule] = []
            if tables.contains("translations") {
                modules += try Row.fetchAll(db, sql: """
                    SELECT id, name, abbreviation, language FROM translations
                    ORDER BY name
                    """).map { row in
                        LampInstalledModule(
                            id: row["id"], kind: .translation, name: row["name"],
                            abbreviation: row["abbreviation"], language: row["language"],
                            isBundled: true
                        )
                    }
            }
            if tables.contains("lexicons") {
                modules += try Row.fetchAll(db, sql: """
                    SELECT id, name, language FROM lexicons ORDER BY name
                    """).map { row in
                        LampInstalledModule(
                            id: row["id"], kind: .dictionary, name: row["name"],
                            language: row["language"], isBundled: true
                        )
                    }
            }
            if tables.contains("modules") {
                modules += try Row.fetchAll(db, sql: """
                    SELECT id, type, name, series_abbrev FROM modules
                    WHERE type IN ('commentary', 'devotional', 'notes', 'highlights')
                    ORDER BY type, name
                    """).compactMap { row in
                        let type: String = row["type"]
                        guard let kind = LampModuleKind(schemaValue: type) else { return nil }
                        return LampInstalledModule(
                            id: row["id"], kind: kind, name: row["name"],
                            abbreviation: row["series_abbrev"], isBundled: true
                        )
                    }
            }
            if tables.contains("book_modules") {
                modules += try Row.fetchAll(db, sql: """
                    SELECT id, title, language FROM book_modules ORDER BY title
                    """).map { row in
                        LampInstalledModule(
                            id: row["id"], kind: .book, name: row["title"],
                            language: row["language"], isBundled: true
                        )
                    }
            }
            if tables.contains("plans") {
                modules += try Row.fetchAll(db, sql: "SELECT id, name FROM plans ORDER BY name").map { row in
                    LampInstalledModule(id: row["id"], kind: .plan, name: row["name"], isBundled: true)
                }
            }
            if tables.contains("quiz_modules") {
                modules += try Row.fetchAll(db, sql: "SELECT id, name FROM quiz_modules ORDER BY name").map { row in
                    LampInstalledModule(id: row["id"], kind: .quiz, name: row["name"], isBundled: true)
                }
            }
            return modules
        }
        cachedBundledModules = modules
        return modules
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
                CREATE TABLE IF NOT EXISTS personal_devotionals (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    author TEXT,
                    devotional_date TEXT,
                    tags_json TEXT NOT NULL,
                    category TEXT,
                    series_name TEXT,
                    series_order INTEGER,
                    key_scriptures_json TEXT NOT NULL,
                    summary TEXT,
                    content TEXT NOT NULL,
                    content_json TEXT,
                    footnotes TEXT,
                    media_json TEXT,
                    created INTEGER NOT NULL,
                    last_modified INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_personal_devotionals_date
                    ON personal_devotionals(devotional_date, last_modified);
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
                CREATE TABLE IF NOT EXISTS highlight_themes (
                    set_id TEXT NOT NULL REFERENCES highlight_sets(id) ON DELETE CASCADE,
                    color TEXT NOT NULL,
                    style INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    PRIMARY KEY (set_id, color, style)
                );
                """)
            let personalNoteColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(personal_notes)")
                .compactMap { $0["name"] as String? }
            if !personalNoteColumns.contains("footnotes_json") {
                try db.execute(sql: "ALTER TABLE personal_notes ADD COLUMN footnotes_json TEXT")
            }
            let devotionalColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(personal_devotionals)")
                .compactMap { $0["name"] as String? }
            if !devotionalColumns.contains("media_json") {
                try db.execute(sql: "ALTER TABLE personal_devotionals ADD COLUMN media_json TEXT")
            }
            if !devotionalColumns.contains("content_json") {
                try db.execute(sql: "ALTER TABLE personal_devotionals ADD COLUMN content_json TEXT")
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

    private func makePersonalDevotional(_ row: Row) -> LampDevotional {
        let tagsJSON: String = row["tags_json"]
        let tags = tagsJSON.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } ?? []
        let scripturesJSON: String = row["key_scriptures_json"]
        let createdTimestamp: Int = row["created"]
        let modifiedTimestamp: Int = row["last_modified"]
        let storedTitle: String = row["title"]
        return LampDevotional(
            id: row["id"],
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: storedTitle == "Untitled Devotional"
                ? "Untitled"
                : storedTitle,
            subtitle: row["subtitle"],
            author: row["author"],
            date: row["devotional_date"],
            tags: tags,
            category: row["category"],
            seriesName: row["series_name"],
            seriesOrder: row["series_order"],
            keyScriptures: devotionalScriptureLinks(from: scripturesJSON),
            summary: row["summary"],
            content: row["content"],
            contentJSON: row["content_json"],
            footnotes: row["footnotes"],
            mediaJSON: row["media_json"],
            created: Date(timeIntervalSince1970: TimeInterval(createdTimestamp)),
            lastModified: Date(timeIntervalSince1970: TimeInterval(modifiedTimestamp)),
            isEditable: true
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

    private func makeHighlightTheme(_ row: Row) -> LampHighlightTheme? {
        let rawStyle: Int = row["style"]
        guard let style = LampHighlightStyle(rawValue: rawStyle) else { return nil }
        return LampHighlightTheme(
            setID: row["set_id"],
            color: row["color"],
            style: style,
            name: row["name"],
            description: row["description"]
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

    /// - Parameter verifyIntegrity: Whether to run `PRAGMA quick_check`, which
    ///   reads every page of the database. Worth it for a file arriving from
    ///   outside the library; ruinous for merely listing what is already
    ///   installed, where it costs seconds per gigabyte on every launch.
    private func inspectDatabase(
        at url: URL,
        fallbackID: String?,
        compressedByteCount: Int,
        verifyIntegrity: Bool = true
    ) throws -> LampInstalledModule {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            if verifyIntegrity {
                let integrityResults = try String.fetchAll(db, sql: "PRAGMA quick_check")
                guard integrityResults == ["ok"] else {
                    throw LampLibraryError.integrityCheckFailed(integrityResults.joined(separator: "; "))
                }
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
            if tables.contains("book_modules"),
               let row = try Row.fetchOne(db, sql: "SELECT id, title, language FROM book_modules LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .book,
                    name: row["title"],
                    language: row["language"],
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
            if tables.contains("devotional_entries") {
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
                    kind: declaredKind ?? .devotional,
                    name: metadataName ?? id,
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("quiz_modules"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name FROM quiz_modules LIMIT 1") {
                return LampInstalledModule(
                    id: formatID ?? row["id"],
                    kind: declaredKind ?? .quiz,
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
            let highlightModuleID = tables.contains("module_meta")
                ? try String.fetchOne(db, sql: "SELECT id FROM module_meta LIMIT 1")
                : nil
            if tables.contains("highlight_meta"),
               let row = try Row.fetchOne(db, sql: "SELECT id, name FROM highlight_meta LIMIT 1") {
                guard let id = formatID ?? highlightModuleID ?? fallbackID else {
                    throw LampLibraryError.missingModuleMetadata
                }
                return LampInstalledModule(
                    id: id,
                    kind: declaredKind ?? .highlights,
                    name: row["name"],
                    compressedByteCount: compressedByteCount
                )
            }
            if tables.contains("highlight_sets"),
               let row = try Row.fetchOne(db, sql: "SELECT * FROM highlight_sets LIMIT 1") {
                let metadataModuleID: String? = row.hasColumn("module_id") ? row["module_id"] : nil
                let name: String? = row["name"]
                guard let id = formatID ?? highlightModuleID ?? metadataModuleID ?? fallbackID else {
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

    private func installedModuleForExport(moduleID: String) throws -> LampInstalledModule {
        guard let module = try installedModules().first(where: { $0.id == moduleID }) else {
            throw LampLibraryError.moduleNotFound(moduleID)
        }
        guard !module.isBundled else {
            throw LampLibraryError.invalidPersonalContent(
                "Built-in modules are supplied with Lamp Bible and do not need to be exported."
            )
        }
        return module
    }

    private func markdownExport(for module: LampInstalledModule) throws -> String {
        let markdown: String
        switch module.kind {
        case .book:
            markdown = try bookMarkdown(module: module)
        case .devotional:
            markdown = try devotionalMarkdown(module: module)
        case .notes:
            markdown = try notesMarkdown(module: module)
        case .translation, .dictionary, .commentary, .plan, .highlights, .quiz:
            throw LampLibraryError.invalidPersonalContent(
                "\(module.name) cannot be represented as Markdown. Export it as a Lamp module instead."
            )
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func bookMarkdown(module: LampInstalledModule) throws -> String {
        guard let book = try bookModules(moduleIDs: [module.id]).first else {
            throw LampLibraryError.unsupportedModuleSchema
        }
        var blocks = ["# \(markdownHeading(book.title, fallback: module.name))"]
        if let subtitle = markdownValue(book.subtitle) {
            blocks.append("*\(subtitle)*")
        }

        var credits: [String] = []
        if let author = markdownValue(book.author) { credits.append("**Author:** \(author)") }
        if let editor = markdownValue(book.editor) { credits.append("**Editor:** \(editor)") }
        if let publisher = markdownValue(book.publisher) { credits.append("**Publisher:** \(publisher)") }
        if let year = book.year { credits.append("**Year:** \(year)") }
        if !credits.isEmpty { blocks.append(credits.joined(separator: " | ")) }
        if let description = markdownValue(book.description) { blocks.append(description) }

        for section in try bookSections(moduleID: module.id) {
            let level = min(max(section.depth + 2, 2), 6)
            var sectionBlocks = [
                "\(String(repeating: "#", count: level)) \(markdownHeading(section.title, fallback: section.sectionID))",
            ]
            if let subtitle = markdownValue(section.subtitle) {
                sectionBlocks.append("*\(subtitle)*")
            }
            if !section.keyScriptures.isEmpty {
                sectionBlocks.append(
                    "**Scripture:** " + section.keyScriptures.map(\.displayDescription).joined(separator: ", ")
                )
            }
            if let content = markdownValue(section.content) { sectionBlocks.append(content) }
            blocks.append(sectionBlocks.joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private func devotionalMarkdown(module: LampInstalledModule) throws -> String {
        let entries = try devotionals(moduleIDs: [module.id])
        return devotionalMarkdown(title: module.name, entries: entries)
    }

    private func devotionalMarkdown(title: String, entries: [LampDevotional]) -> String {
        var blocks = ["# \(markdownHeading(title, fallback: "Writing"))"]
        for devotional in entries {
            var entry = ["## \(markdownHeading(devotional.title, fallback: "Untitled"))"]
            if let subtitle = markdownValue(devotional.subtitle) { entry.append("*\(subtitle)*") }

            var metadata: [String] = []
            if let author = markdownValue(devotional.author) { metadata.append("**Author:** \(author)") }
            if let date = markdownValue(devotional.date) { metadata.append("**Date:** \(date)") }
            if !devotional.tags.isEmpty { metadata.append("**Tags:** \(devotional.tags.joined(separator: ", "))") }
            if let category = markdownValue(devotional.category) { metadata.append("**Category:** \(category)") }
            if let series = markdownValue(devotional.seriesName) { metadata.append("**Series:** \(series)") }
            if let order = devotional.seriesOrder { metadata.append("**Series Order:** \(order)") }
            if !metadata.isEmpty { entry.append(metadata.joined(separator: " | ")) }
            if !devotional.keyScriptures.isEmpty {
                entry.append(
                    "**Scripture:** " + devotional.keyScriptures.map(\.displayDescription).joined(separator: ", ")
                )
            }
            if let summary = markdownValue(devotional.summary) {
                entry.append("> **Summary:** \(summary.replacingOccurrences(of: "\n", with: "\n> "))")
            }
            if let content = markdownValue(devotional.content) { entry.append(content) }
            if let footnotes = markdownValue(devotional.footnotes) {
                entry.append("### Footnotes\n\n\(footnotes)")
            }
            blocks.append(entry.joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    private func notesMarkdown(module: LampInstalledModule) throws -> String {
        let queue = try openDatabase(moduleID: module.id)
        let notes = try queue.read { db -> [LampVerseNote] in
            guard try tableNames(in: db).contains("note_entries") else {
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
                SELECT id, verse_id, \(title), content,
                       \(references), \(footnotes), \(modified)
                FROM note_entries
                ORDER BY verse_id, last_modified, id
                """).map { row in
                    let referencesJSON: String? = row["verse_refs_json"]
                    let verseReferences = referencesJSON
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
                    let modifiedTimestamp: Int? = row["last_modified"]
                    let footnotesJSON: String? = row["footnotes_json"]
                    return LampVerseNote(
                        id: row["id"],
                        moduleID: module.id,
                        reference: row["verse_id"],
                        title: row["title"],
                        content: row["content"],
                        verseReferences: verseReferences,
                        footnotes: verseFootnotes(from: footnotesJSON),
                        lastModified: Date(timeIntervalSince1970: TimeInterval(modifiedTimestamp ?? 0))
                    )
                }
        }

        return notesMarkdown(title: module.name, notes: notes)
    }

    private func notesMarkdown(title: String, notes: [LampVerseNote]) -> String {
        var blocks = ["# \(markdownHeading(title, fallback: "Notes"))"]
        for note in notes {
            let endReference = note.verseReferences.filter { $0 >= note.reference }.max()
                ?? note.reference
            var entry = [
                "## \(LampBibleReferenceFormatter.describeRange(from: note.reference, to: endReference))",
            ]
            if let title = markdownValue(note.title) { entry.append("**Title:** \(title)") }
            if let content = markdownValue(note.content) { entry.append(content) }
            if !note.footnotes.isEmpty {
                entry.append("### Footnotes\n\n" + note.footnotes.map {
                    "- **\($0.id):** \($0.content)"
                }.joined(separator: "\n"))
            }
            blocks.append(entry.joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private func allPersonalNotes() throws -> [LampVerseNote] {
        let queue = try openUserDatabase()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, module_id, verse_id, title, content,
                       verse_refs_json, footnotes_json, last_modified
                FROM personal_notes
                WHERE module_id = 'personal-notes'
                ORDER BY book, chapter, verse, last_modified, id
                """).map(makeVerseNote)
        }
    }

    private func personalModuleArchive(for module: LampPersonalModule) throws -> Data {
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-personal-export-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(atPath: databaseURL.path + "-shm")
            try? fileManager.removeItem(atPath: databaseURL.path + "-wal")
        }

        switch module {
        case .writing:
            try createPersonalWritingDatabase(at: databaseURL)
        case .notes:
            try createPersonalNotesDatabase(at: databaseURL)
        case .highlights:
            try createPersonalHighlightsDatabase(at: databaseURL)
        }

        let databaseData = try Data(contentsOf: databaseURL, options: [.mappedIfSafe])
        guard let compressedData = try? (databaseData as NSData).compressed(using: .zlib) as Data,
              let verification = try? (compressedData as NSData).decompressed(using: .zlib) as Data,
              verification == databaseData else {
            throw LampLibraryError.invalidPersonalContent(
                "Lamp Bible could not create the portable \(module.name) archive."
            )
        }
        return compressedData
    }

    private func createPersonalWritingDatabase(at databaseURL: URL) throws {
        let entries = try personalDevotionals()
        try createPersonalExportDatabase(
            at: databaseURL,
            module: .writing,
            schema: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
                    author TEXT, version TEXT, is_editable INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE devotional_entries (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL,
                    title TEXT NOT NULL, subtitle TEXT, author TEXT, date TEXT,
                    tags TEXT, category TEXT, series_id TEXT, series_name TEXT,
                    series_order INTEGER, key_scriptures_json TEXT,
                    summary_json TEXT, content_json TEXT NOT NULL,
                    footnotes_json TEXT, related_ids TEXT, created INTEGER NOT NULL,
                    last_modified INTEGER, search_text TEXT, record_change_tag TEXT,
                    subscription_id TEXT, is_read_only INTEGER, media_json TEXT
                );
                CREATE INDEX idx_dev_module ON devotional_entries(module_id);
                CREATE INDEX idx_dev_date ON devotional_entries(date);
                CREATE INDEX idx_dev_series ON devotional_entries(series_id, series_order);
                """
        ) { db in
            try db.execute(sql: """
                INSERT INTO module_meta (id, name, version, is_editable)
                VALUES (?, ?, ?, 1)
                """, arguments: [
                    LampPersonalModule.writing.id,
                    LampPersonalModule.writing.name,
                    LampModuleCompiler.formatVersion,
                ])
            for devotional in entries {
                let scriptureValues = devotional.keyScriptures.map { scripture -> [String: Any] in
                    var value: [String: Any] = ["sv": scripture.startReference]
                    if let endReference = scripture.endReference { value["ev"] = endReference }
                    if let text = scripture.text { value["label"] = text }
                    return value
                }
                let contentJSON: String
                if let stored = devotional.contentJSON {
                    contentJSON = stored
                } else {
                    let blocks: [[String: Any]] = [[
                        "type": "paragraph", "content": ["text": devotional.content],
                    ]]
                    contentJSON = String(decoding: try JSONSerialization.data(
                        withJSONObject: blocks, options: [.sortedKeys]
                    ), as: UTF8.self)
                }
                let searchText = [
                    devotional.title,
                    devotional.subtitle,
                    devotional.summary,
                    devotional.content,
                    devotional.footnotes,
                ].compactMap { $0 }.joined(separator: " ")
                try db.execute(sql: """
                    INSERT INTO devotional_entries (
                        id, module_id, title, subtitle, author, date, tags, category,
                        series_id, series_name, series_order, key_scriptures_json,
                        summary_json, content_json, footnotes_json, related_ids,
                        created, last_modified, search_text, record_change_tag,
                        subscription_id, is_read_only, media_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL,
                              ?, ?, ?, NULL, NULL, 0, ?)
                    """, arguments: [
                        devotional.id,
                        LampPersonalModule.writing.id,
                        devotional.title,
                        devotional.subtitle,
                        devotional.author,
                        devotional.date,
                        devotional.tags.joined(separator: ","),
                        devotional.category,
                        devotional.seriesName,
                        devotional.seriesName,
                        devotional.seriesOrder,
                        try jsonFragmentString(scriptureValues),
                        try jsonFragmentString(devotional.summary),
                        contentJSON,
                        try jsonFragmentString(devotional.footnotes),
                        Int((devotional.created ?? Date()).timeIntervalSince1970),
                        Int((devotional.lastModified ?? Date()).timeIntervalSince1970),
                        searchText,
                        devotional.mediaJSON,
                    ])
            }
        }
    }

    private func createPersonalNotesDatabase(at databaseURL: URL) throws {
        let notes = try allPersonalNotes()
        try createPersonalExportDatabase(
            at: databaseURL,
            module: .notes,
            schema: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
                    author TEXT, version TEXT, is_editable INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE note_entries (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, verse_id INTEGER NOT NULL,
                    book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    title TEXT, content TEXT NOT NULL, verse_refs_json TEXT,
                    last_modified INTEGER, footnotes_json TEXT, search_text TEXT,
                    record_change_tag TEXT
                );
                CREATE INDEX idx_note_module ON note_entries(module_id);
                CREATE INDEX idx_note_verse ON note_entries(verse_id);
                CREATE INDEX idx_note_chapter ON note_entries(book, chapter, verse);
                """
        ) { db in
            try db.execute(sql: """
                INSERT INTO module_meta (id, name, version, is_editable)
                VALUES (?, ?, ?, 1)
                """, arguments: [
                    LampPersonalModule.notes.id,
                    LampPersonalModule.notes.name,
                    LampModuleCompiler.formatVersion,
                ])
            for note in notes {
                let components = LampBibleReferenceFormatter.components(of: note.reference)
                let footnotes = note.footnotes.map { footnote -> [String: String] in
                    var value = ["id": footnote.id, "content": footnote.content]
                    if let kind = footnote.kind { value["type"] = kind }
                    return value
                }
                try db.execute(sql: """
                    INSERT INTO note_entries (
                        id, module_id, verse_id, book, chapter, verse, title, content,
                        verse_refs_json, last_modified, footnotes_json, search_text,
                        record_change_tag
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """, arguments: [
                        note.id,
                        LampPersonalModule.notes.id,
                        note.reference,
                        components.book,
                        components.chapter,
                        components.verse,
                        note.title,
                        note.content,
                        try jsonFragmentString(note.verseReferences),
                        Int(note.lastModified.timeIntervalSince1970),
                        try jsonFragmentString(footnotes),
                        [note.title, note.content].compactMap { $0 }.joined(separator: " "),
                    ])
            }
        }
    }

    private func createPersonalHighlightsDatabase(at databaseURL: URL) throws {
        let sourceQueue = try openUserDatabase()
        let export = try sourceQueue.read { db -> (
            sets: [LampHighlightSet],
            highlights: [LampVerseHighlight],
            themes: [LampHighlightTheme]
        ) in
            let sets = try Row.fetchAll(db, sql: """
                SELECT * FROM highlight_sets ORDER BY name COLLATE NOCASE, created, id
                """).map { row in
                    let created: Int = row["created"]
                    let modified: Int = row["last_modified"]
                    return LampHighlightSet(
                        id: row["id"],
                        name: row["name"],
                        description: row["description"],
                        translationID: row["translation_id"],
                        created: Date(timeIntervalSince1970: TimeInterval(created)),
                        lastModified: Date(timeIntervalSince1970: TimeInterval(modified))
                    )
                }
            let highlights = try Row.fetchAll(db, sql: """
                SELECT h.id, h.set_id, s.translation_id, h.ref,
                       h.sc, h.ec, h.style, h.color
                FROM highlights h JOIN highlight_sets s ON s.id = h.set_id
                ORDER BY h.set_id, h.ref, h.sc, h.ec, h.id
                """).map(makeVerseHighlight)
            let themes = try Row.fetchAll(db, sql: """
                SELECT set_id, color, style, name, description
                FROM highlight_themes ORDER BY set_id, name, color, style
                """).compactMap(makeHighlightTheme)
            return (sets, highlights, themes)
        }

        try createPersonalExportDatabase(
            at: databaseURL,
            module: .highlights,
            schema: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
                    author TEXT, version TEXT, is_editable INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE highlight_sets (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
                    translation_id TEXT NOT NULL, created INTEGER NOT NULL,
                    last_modified INTEGER NOT NULL
                );
                CREATE TABLE highlights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    set_id TEXT NOT NULL REFERENCES highlight_sets(id) ON DELETE CASCADE,
                    ref INTEGER NOT NULL, sc INTEGER NOT NULL, ec INTEGER NOT NULL,
                    style INTEGER NOT NULL, color TEXT
                );
                CREATE INDEX idx_highlights_set_ref ON highlights(set_id, ref, sc);
                CREATE TABLE highlight_themes (
                    set_id TEXT NOT NULL REFERENCES highlight_sets(id) ON DELETE CASCADE,
                    color TEXT NOT NULL, style INTEGER NOT NULL, name TEXT NOT NULL,
                    description TEXT, PRIMARY KEY (set_id, color, style)
                );
                """
        ) { db in
            try db.execute(sql: """
                INSERT INTO module_meta (id, name, version, is_editable)
                VALUES (?, ?, ?, 1)
                """, arguments: [
                    LampPersonalModule.highlights.id,
                    LampPersonalModule.highlights.name,
                    LampModuleCompiler.formatVersion,
                ])
            for set in export.sets {
                try db.execute(sql: """
                    INSERT INTO highlight_sets (
                        id, name, description, translation_id, created, last_modified
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        set.id,
                        set.name,
                        set.description,
                        set.translationID,
                        Int(set.created.timeIntervalSince1970),
                        Int(set.lastModified.timeIntervalSince1970),
                    ])
            }
            for highlight in export.highlights {
                try db.execute(sql: """
                    INSERT INTO highlights (id, set_id, ref, sc, ec, style, color)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        highlight.id,
                        highlight.setID,
                        highlight.reference,
                        highlight.startOffset,
                        highlight.endOffset,
                        highlight.style.rawValue,
                        highlight.color,
                    ])
            }
            for theme in export.themes {
                try db.execute(sql: """
                    INSERT INTO highlight_themes (set_id, color, style, name, description)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        theme.setID,
                        theme.color,
                        theme.style.rawValue,
                        theme.name,
                        theme.description,
                    ])
            }
        }
    }

    private func createPersonalExportDatabase(
        at databaseURL: URL,
        module: LampPersonalModule,
        schema: String,
        populate: (Database) throws -> Void
    ) throws {
        var configuration = Configuration()
        configuration.label = "LampCore.PersonalModuleExport"
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE module_format (
                    format_version TEXT NOT NULL,
                    module_type TEXT NOT NULL,
                    module_id TEXT NOT NULL
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO module_format (format_version, module_type, module_id)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    LampModuleCompiler.formatVersion,
                    module.kind.rawValue,
                    module.id,
                ]
            )
            try db.execute(sql: schema)
            try populate(db)
            try db.execute(sql: "ANALYZE")
            try db.execute(sql: "VACUUM")
        }
        let integrityResults = try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        guard integrityResults == ["ok"] else {
            throw LampLibraryError.integrityCheckFailed(integrityResults.joined(separator: "; "))
        }
    }

    private func jsonFragmentString(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func markdownHeading(_ value: String, fallback: String) -> String {
        markdownValue(value)?.replacingOccurrences(of: "#", with: "\\#") ?? fallback
    }

    private func markdownValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
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
                derivation: plainText(from: object["derivation"]),
                usage: plainText(from: object["usage"]),
                scriptureLinks: dictionaryScriptureLinks(from: object),
                dictionaryLinks: dictionaryEntryLinks(from: object)
            )
        }
    }

    /// Dictionary senses can link scripture in two complementary ways: inline
    /// annotated text and an explicit `references` collection. Preserve both so
    /// clients can make inline labels interactive and append references that do
    /// not occur verbatim in the prose.
    private func dictionaryScriptureLinks(from sense: [String: Any]) -> [LampScriptureLink] {
        var links: [LampScriptureLink] = []
        collectScriptureLinks(from: sense, into: &links)

        if let references = sense["references"] as? [Any] {
            for value in references {
                guard let reference = value as? [String: Any],
                      let startReference = integerValue(reference["sv"]) else { continue }
                let endReference = integerValue(reference["ev"])
                guard !links.contains(where: {
                    $0.startReference == startReference && $0.endReference == endReference
                }) else { continue }
                links.append(LampScriptureLink(
                    text: stringValue(reference["label"] ?? reference["text"]),
                    startReference: startReference,
                    endReference: endReference
                ))
            }
        }

        var seen = Set<String>()
        return links.filter { seen.insert($0.id).inserted }
    }

    /// Extracts annotated links to other lexicon entries. Strong's source data
    /// places these primarily in annotated derivation fields, but walking the
    /// complete sense also supports links embedded in definitions and usage notes.
    private func dictionaryEntryLinks(from sense: [String: Any]) -> [LampDictionaryLink] {
        var links: [LampDictionaryLink] = []
        collectDictionaryEntryLinks(from: sense, into: &links)
        var seen = Set<String>()
        return links.filter { seen.insert($0.id).inserted }
    }

    private func collectDictionaryEntryLinks(
        from value: Any,
        into links: inout [LampDictionaryLink]
    ) {
        if let values = value as? [Any] {
            for value in values {
                collectDictionaryEntryLinks(from: value, into: &links)
            }
            return
        }
        guard let object = value as? [String: Any] else { return }

        let parentText = stringValue(object["text"])
        if let annotations = object["annotations"] as? [Any] {
            for annotationValue in annotations {
                guard let annotation = annotationValue as? [String: Any] else { continue }
                let annotationData = annotation["data"] as? [String: Any]
                guard let key = stringValue(
                    annotationData?["strongs"]
                        ?? annotationData?["key"]
                        ?? annotation["strongs"]
                        ?? annotation["key"]
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !key.isEmpty else { continue }
                let startOffset = integerValue(annotation["start"])
                let endOffset = integerValue(annotation["end"])
                let derivedText = startOffset.flatMap { start in
                    endOffset.flatMap { end in
                        parentText.flatMap { substring(of: $0, from: start, to: end) }
                    }
                }
                links.append(LampDictionaryLink(
                    text: stringValue(annotation["text"]) ?? derivedText,
                    key: key
                ))
            }
        }

        for (key, nestedValue) in object where key != "annotations" {
            collectDictionaryEntryLinks(from: nestedValue, into: &links)
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

    private func annotatedText(
        fromJSONString json: String
    ) -> (text: String, annotations: [LampVerseAnnotation]) {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (json, [])
        }
        let text = plainText(from: value) ?? json
        guard let object = value as? [String: Any],
              let annotations = object["annotations"] as? [Any],
              let annotationData = try? JSONSerialization.data(withJSONObject: annotations),
              let annotationJSON = String(data: annotationData, encoding: .utf8) else {
            return (text, [])
        }
        return (text, verseAnnotations(from: annotationJSON, verseText: text))
    }

    private func integerArray(fromJSONString json: String?) -> [Int] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    private func personalDevotional(fromJSONData data: Data) throws -> LampDevotional {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = root["meta"] as? [String: Any],
              let identifier = stringValue(meta["id"]),
              let title = stringValue(meta["title"]),
              let contentValue = root["content"] else {
            throw LampLibraryError.invalidPersonalContent("The devotional JSON needs meta.id, meta.title, and content.")
        }
        // Title-only outlines are valid authored drafts. Their canonical JSON
        // contains the content field, but its paragraph text is intentionally
        // empty and should round-trip without becoming an import error.
        let contentJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: contentValue, options: [.sortedKeys, .fragmentsAllowed]
        ), as: UTF8.self)
        let content = LampPortableDevotionalContent.plainText(from: contentJSON) ?? ""
        let tags = (meta["tags"] as? [Any])?.compactMap(stringValue) ?? []
        let series = meta["series"] as? [String: Any]
        let scripturesData = try JSONSerialization.data(
            withJSONObject: meta["keyScriptures"] as? [Any] ?? [],
            options: [.sortedKeys]
        )
        let scripturesJSON = String(decoding: scripturesData, as: UTF8.self)
        let mediaJSON: String?
        if let media = root["media"] {
            guard let values = media as? [Any] else {
                throw LampLibraryError.invalidPersonalContent("Invalid devotional media metadata.")
            }
            mediaJSON = String(decoding: try JSONSerialization.data(
                withJSONObject: values, options: [.sortedKeys]
            ), as: UTF8.self)
        } else {
            mediaJSON = nil
        }
        let created = integerValue(meta["created"]).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let modified = integerValue(meta["lastModified"]).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return LampDevotional(
            id: identifier,
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: title,
            subtitle: stringValue(meta["subtitle"]),
            author: stringValue(meta["author"]),
            date: stringValue(meta["date"]),
            tags: tags,
            category: stringValue(meta["category"]),
            seriesName: stringValue(series?["name"]),
            seriesOrder: integerValue(series?["order"]),
            keyScriptures: devotionalScriptureLinks(from: scripturesJSON),
            summary: plainText(from: root["summary"]),
            content: content,
            contentJSON: contentJSON,
            footnotes: plainText(from: root["footnotes"]),
            mediaJSON: mediaJSON,
            created: created,
            lastModified: modified,
            isEditable: true
        )
    }

    private func devotionalsFromDatabase(at databaseURL: URL) throws -> [LampDevotional] {
        let queue = try openReadOnlyDatabase(at: databaseURL)
        return try queue.read { db in
            guard try tableNames(in: db).contains("devotional_entries") else {
                throw LampLibraryError.unsupportedModuleSchema
            }
            let columns = try columnNames(in: db, table: "devotional_entries")
            let moduleName = try Row.fetchOne(db, sql: "SELECT name FROM module_meta LIMIT 1")
                .flatMap { $0["name"] as String? } ?? "Imported Devotionals"
            return try Row.fetchAll(db, sql: "SELECT * FROM devotional_entries ORDER BY title").map { row in
                let scripturesJSON: String? = row["key_scriptures_json"]
                let tags: String? = row["tags"]
                let createdTimestamp: Int? = row["created"]
                let modifiedTimestamp: Int? = row["last_modified"]
                let contentJSON: String = row["content_json"]
                let summaryJSON: String? = row["summary_json"]
                let footnotesJSON: String? = row["footnotes_json"]
                return LampDevotional(
                    id: row["id"],
                    moduleID: "personal-devotionals",
                    moduleName: moduleName,
                    title: row["title"],
                    subtitle: row["subtitle"],
                    author: row["author"],
                    date: row["date"],
                    tags: tags?.split(separator: ",").map {
                        String($0).trimmingCharacters(in: .whitespaces)
                    } ?? [],
                    category: row["category"],
                    seriesName: row["series_name"],
                    seriesOrder: row["series_order"],
                    keyScriptures: devotionalScriptureLinks(from: scripturesJSON),
                    summary: plainText(fromJSONString: summaryJSON),
                    content: LampPortableDevotionalContent.plainText(from: contentJSON)
                        ?? contentJSON,
                    contentJSON: contentJSON,
                    footnotes: plainText(fromJSONString: footnotesJSON),
                    mediaJSON: columns.contains("media_json") ? row["media_json"] : nil,
                    created: createdTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    lastModified: modifiedTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    isEditable: true
                )
            }
        }
    }

    private func devotionalScriptureLinks(from json: String?) -> [LampScriptureLink] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return values.compactMap { value in
            guard let start = integerValue(value["sv"]) else { return nil }
            return LampScriptureLink(
                text: stringValue(value["label"]),
                startReference: start,
                endReference: integerValue(value["ev"])
            )
        }
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
