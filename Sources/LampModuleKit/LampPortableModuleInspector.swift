import Foundation
import GRDB

public struct LampPortableModuleDescriptor: Equatable, Sendable {
    public let id: String
    public let kind: LampModuleKind

    public init(id: String, kind: LampModuleKind) {
        self.id = id
        self.kind = kind
    }
}

/// Reads module identity from the SQLite payload. Archive filenames are storage
/// keys on Mac and must never be treated as module IDs by another client.
public enum LampPortableModuleInspector {
    /// Source tables used by the iOS archive installer for this module kind.
    /// The installer stages only these tables before its local transaction.
    public static func archiveImportSourceTables(for kind: LampModuleKind) -> [String] {
        switch kind {
        case .dictionary: ["dictionary_entries", "module_meta", "module_metadata"]
        case .commentary: ["series_meta", "commentary_books", "commentary_units"]
        case .book: ["book_modules", "book_sections"]
        case .plan: ["plan_meta", "days", "plans", "plan_days"]
        case .highlights: ["highlight_meta", "highlight_sets", "highlights", "highlight_themes"]
        case .quiz: ["quiz_modules", "quiz_questions"]
        case .translation: [
            "translations", "translation_books", "translation_verses",
            "translation_headings", "translation_meta", "books", "verses", "headings"
        ]
        case .notes, .devotional: []
        }
    }

    /// Columns copied verbatim by the iOS book importer. Keep inspection and
    /// installation tied to one schema contract.
    public static let bookModuleColumns = [
        "id", "title", "subtitle", "description", "author", "editor",
        "publisher", "year", "edition", "isbn", "language",
        "text_direction", "copyright", "license", "version",
        "schema_version", "tags_json", "cover_media_id", "is_editable",
        "created", "last_modified", "footnotes_json", "media_json"
    ]

    public static let bookSectionColumns = [
        "id", "module_id", "section_id", "parent_id", "section_type",
        "number", "title", "subtitle", "depth", "order_index",
        "key_scriptures_json", "content_json", "search_text"
    ]

    public enum InspectionError: Error, LocalizedError, Equatable {
        case invalidArchive
        case missingIdentity
        case wrongKind(expected: LampModuleKind, actual: LampModuleKind)
        case missingImportSchema(String)
        case foreignRows(String)

        public var errorDescription: String? {
            switch self {
            case .invalidArchive: "The portable module database is damaged."
            case .missingIdentity: "The portable module has no supported identity."
            case .wrongKind(let expected, let actual):
                "The portable module is \(actual.rawValue), not \(expected.rawValue)."
            case .missingImportSchema(let table):
                "The portable module is missing required import data: \(table)."
            case .foreignRows(let table): "The portable module contains rows for another module in \(table)."
            }
        }
    }

    /// Inspect a remote SQLite body using the same legacy filename policy on
    /// both clients. Only a missing identity may fall back: old .db files have
    /// no header, and old compact highlight .lamp files store a set ID only.
    /// The caller still checks a declared ID against its listed remote ID.
    public static func inspectRemote(
        data: Data,
        filename: String,
        fallbackID: String,
        expectedKind: LampModuleKind,
        fileManager: FileManager = .default
    ) throws -> LampPortableModuleDescriptor {
        let lowercased = filename.lowercased()
        let canonical = lowercased.hasSuffix(".lamp")
        let result: LampPortableModuleDescriptor
        do {
            result = try lowercased.hasSuffix(".db")
                ? inspect(databaseData: data, fileManager: fileManager)
                : inspect(compressedData: data, fileManager: fileManager)
        } catch InspectionError.missingIdentity where !canonical || expectedKind == .highlights {
            try validateLegacyFallback(
                data: data,
                uncompressed: lowercased.hasSuffix(".db"),
                expectedID: fallbackID,
                kind: expectedKind,
                fileManager: fileManager
            )
            return try descriptor(id: fallbackID, kind: expectedKind)
        }
        guard result.kind == expectedKind else {
            throw InspectionError.wrongKind(expected: expectedKind, actual: result.kind)
        }
        return result
    }

    private static func validateLegacyFallback(
        data: Data,
        uncompressed: Bool,
        expectedID: String,
        kind: LampModuleKind,
        fileManager: FileManager
    ) throws {
        let databaseData: Data
        if uncompressed {
            databaseData = data
        } else {
            guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
                throw InspectionError.invalidArchive
            }
            databaseData = decompressed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-legacy-module-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer { try? fileManager.removeItem(at: databaseURL) }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.read { db in
            let tables = Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
            try validateImportSchema(in: db, tables: tables, kind: kind)
            try validateOwnership(in: db, tables: tables, expectedID: expectedID, kind: kind)
        }
    }

    /// `requireImportSchema` checks columns read by the iOS archive importer.
    /// Identity-only callers can still inspect older files.
    public static func inspect(
        compressedData: Data,
        requireImportSchema: Bool = false,
        fileManager: FileManager = .default
    ) throws -> LampPortableModuleDescriptor {
        guard let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw InspectionError.invalidArchive
        }
        return try inspect(
            databaseData: databaseData,
            requireImportSchema: requireImportSchema,
            fileManager: fileManager
        )
    }

    /// Inspect a legacy uncompressed .db body using the same identity rules.
    public static func inspect(
        databaseData: Data,
        requireImportSchema: Bool = false,
        fileManager: FileManager = .default
    ) throws -> LampPortableModuleDescriptor {
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-module-inspect-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer { try? fileManager.removeItem(at: databaseURL) }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try queue.read { db in
            guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"] else {
                throw InspectionError.invalidArchive
            }
            let tables = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
            func checked(_ id: String, _ kind: LampModuleKind) throws -> LampPortableModuleDescriptor {
                try verifiedDescriptor(
                    id: id, kind: kind, in: db, tables: tables,
                    requireImportSchema: requireImportSchema
                )
            }
            if tables.contains("module_format"),
               let row = try Row.fetchOne(
                db,
                sql: "SELECT module_id, module_type FROM module_format LIMIT 1"
               ),
               let id: String = row["module_id"],
               let type: String = row["module_type"],
               let kind = LampModuleKind(schemaValue: type) {
                return try checked(id, kind)
            }

            func firstID(_ table: String, column: String = "id") throws -> String? {
                guard tables.contains(table) else { return nil }
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? })
                guard columns.contains(column) else { return nil }
                return try String.fetchOne(db, sql: "SELECT \(column) FROM \(table) LIMIT 1")
            }

            if let id = try firstID("translation_meta") ?? firstID("translations") {
                return try checked(id, .translation)
            }
            if let id = try firstID("module_metadata") {
                return try checked(id, .dictionary)
            }
            if let id = try firstID("commentary_books", column: "module_id") {
                return try checked(id, .commentary)
            }
            if let id = try firstID("book_modules") {
                return try checked(id, .book)
            }
            if let id = try firstID("plans") {
                return try checked(id, .plan)
            }
            if tables.contains("devotional_entries"), let id = try firstID("module_meta") {
                return try checked(id, .devotional)
            }
            if let id = try firstID("quiz_modules") {
                return try checked(id, .quiz)
            }
            if tables.contains("note_entries"), let id = try firstID("module_meta") {
                return try checked(id, .notes)
            }
            if tables.contains("highlights"), let id = try firstID("module_meta") {
                return try checked(id, .highlights)
            }
            // Compact highlight_meta.id is the set ID, not the module ID.
            // A canonical compact file needs module_format; older files can
            // still be imported by a caller that explicitly knows the path.
            if let id = try firstID("highlight_sets", column: "module_id") {
                return try checked(id, .highlights)
            }
            throw InspectionError.missingIdentity
        }
    }

    /// Check every source row that carries a module owner before an importer
    /// retires local rows. Missing owner columns are valid in compact formats,
    /// where the parent metadata supplies the owner during import. Pass
    /// `verifyIntegrity: false` only after checking this same database body.
    public static func validateOwnership(
        databaseURL: URL,
        expectedID: String,
        kind: LampModuleKind,
        verifyIntegrity: Bool = true
    ) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.read { db in
            if verifyIntegrity {
                guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"] else {
                    throw InspectionError.invalidArchive
                }
            }
            let tables = Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
            try validateOwnership(in: db, tables: tables, expectedID: expectedID, kind: kind)
        }
    }

    private static func verifiedDescriptor(
        id: String, kind: LampModuleKind, in db: Database, tables: Set<String>,
        requireImportSchema: Bool
    ) throws -> LampPortableModuleDescriptor {
        let result = try descriptor(id: id, kind: kind)
        try validateOwnership(in: db, tables: tables, expectedID: id, kind: kind)
        if requireImportSchema {
            try validateImportSchema(in: db, tables: tables, kind: kind)
        }
        return result
    }

    private static func validateImportSchema(
        in db: Database, tables: Set<String>, kind: LampModuleKind
    ) throws {
        // The variants match the branches in iOS copySQLiteModuleRows. Only
        // columns read by the chosen branch are required; legacy optional
        // tables and columns remain optional.
        func require(_ table: String, _ columns: [String]) throws {
            guard tables.contains(table) else {
                throw InspectionError.missingImportSchema(table)
            }
            let present = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? })
            guard Set(columns).isSubset(of: present) else {
                throw InspectionError.missingImportSchema(table)
            }
        }
        func requireIfPresent(_ table: String, _ columns: [String]) throws {
            if tables.contains(table) { try require(table, columns) }
        }

        switch kind {
        case .dictionary:
            try require("dictionary_entries", [
                "id", "module_id", "key", "lemma", "transliteration",
                "pronunciation", "senses_json", "metadata_json"
            ])

        case .commentary:
            if tables.contains("series_meta") {
                try require("series_meta", [
                    "id", "name", "abbreviation", "description", "editor",
                    "publisher", "testament", "language", "website",
                    "editor_preface_json", "introduction_json", "abbreviations_json",
                    "bibliography_json", "volumes_json"
                ])
                try require("commentary_books", [
                    "book_number", "title", "author", "editor", "publisher",
                    "year", "abbreviations_json", "front_matter_json", "indices_json"
                ])
                try require("commentary_units", [
                    "id", "book", "chapter", "sv", "ev", "unit_type",
                    "level", "parent_id", "title", "suffix",
                    "introduction_json", "translation_json", "commentary_json",
                    "footnotes_json", "search_text", "order_index"
                ])
            } else {
                try require("commentary_books", [
                    "id", "module_id", "book_number", "series_full",
                    "series_abbrev", "title", "author", "editor", "publisher",
                    "year", "abbreviations_json", "front_matter_json", "indices_json"
                ])
                try require("commentary_units", [
                    "id", "module_id", "book", "chapter", "sv", "ev",
                    "unit_type", "level", "parent_id", "title", "suffix",
                    "introduction_json", "translation_json", "commentary_json",
                    "footnotes_json", "search_text", "order_index"
                ])
            }

        case .book:
            try require("book_modules", bookModuleColumns)
            try require("book_sections", bookSectionColumns)

        case .devotional:
            // Archive imports reconcile through DevotionalEntry.fetchAll,
            // whose nonoptional fields need these source columns. The old
            // month_day/content copy branch is not used by that path.
            try require("devotional_entries", [
                "id", "module_id", "title", "content_json", "created"
            ])

        case .notes:
            // Archive imports likewise decode NoteEntry before merging.
            try require("note_entries", [
                "id", "module_id", "verse_id", "book", "chapter", "verse", "content"
            ])

        case .plan:
            if tables.contains("plan_meta") && tables.contains("days") {
                try require("plan_meta", [
                    "id", "name", "description", "author", "full_description",
                    "duration", "readings_per_day"
                ])
                try require("days", ["day", "readings_json"])
            } else {
                try require("plans", [
                    "id", "name", "description", "author", "full_description",
                    "duration", "readings_per_day"
                ])
                try require("plan_days", ["plan_id", "day", "readings_json"])
            }

        case .highlights:
            if tables.contains("highlight_meta") && tables.contains("highlights") {
                try require("highlight_meta", ["id", "name", "translation_id"])
                try require("highlights", ["ref", "sc", "ec", "style", "color"])
            } else {
                try require("highlight_sets", [
                    "id", "module_id", "name", "description", "translation_id",
                    "created", "last_modified"
                ])
                try require("highlights", ["id", "set_id", "ref", "sc", "ec", "style", "color"])
            }

        case .quiz:
            try require("quiz_modules", [
                "id", "plan_id", "name", "description", "questions_per_reading",
                "age_groups_json"
            ])
            try require("quiz_questions", [
                "quiz_module_id", "day", "sv", "ev", "age_group",
                "question_index", "question_json", "answer_json", "theme",
                "christ_focused", "references_json", "cross_references_json"
            ])

        case .translation:
            if tables.contains("translations") {
                try require("translations", [
                    "id", "name", "abbreviation", "description", "language",
                    "language_name", "text_direction", "translation_philosophy",
                    "year", "publisher", "copyright", "copyright_year",
                    "license", "source_texts_json", "features_json", "versification",
                    "file_path", "file_hash"
                ])
                try requireIfPresent("translation_books", [
                    "id", "translation_id", "book_number", "book_id", "name",
                    "testament", "chapter_count"
                ])
                try requireIfPresent("translation_verses", [
                    "translation_id", "ref", "book", "chapter", "verse", "text",
                    "annotations_json", "footnotes_json", "footnote_refs_json",
                    "paragraph", "poetry_json"
                ])
                try requireIfPresent("translation_headings", [
                    "translation_id", "book", "chapter", "before_verse",
                    "level", "text"
                ])
            } else {
                try require("translation_meta", [
                    "id", "name", "abbreviation", "description", "language",
                    "language_name", "text_direction", "translation_philosophy",
                    "year", "publisher", "copyright", "copyright_year",
                    "license", "source_texts_json", "features_json", "versification"
                ])
                try require("verses", [
                    "ref", "book", "chapter", "verse", "text", "annotations_json",
                    "footnotes_json", "paragraph"
                ])
                try requireIfPresent("books", [
                    "id", "book_id", "name", "testament", "chapter_count"
                ])
                try requireIfPresent("headings", [
                    "book", "chapter", "before_verse", "level", "text"
                ])
            }
        }
    }

    private static func validateOwnership(
        in db: Database, tables: Set<String>, expectedID: String, kind: LampModuleKind
    ) throws {
        // All identifiers below are fixed schema names, never payload strings.
        let owners: [(String, String)] = [("module_format", "module_id")] + {
            switch kind {
            case .translation:
                return [("translation_meta", "id"), ("translations", "id"),
                        ("translation_books", "translation_id"),
                        ("translation_verses", "translation_id"),
                        ("translation_headings", "translation_id")]
            case .dictionary:
                return [("module_metadata", "id"), ("dictionary_entries", "module_id")]
            case .commentary:
                return [("commentary_books", "module_id"), ("commentary_units", "module_id")]
            case .book:
                return [("book_modules", "id"), ("book_sections", "module_id")]
            case .devotional:
                return [("module_meta", "id"), ("devotional_entries", "module_id")]
            case .notes:
                return [("module_meta", "id"), ("note_entries", "module_id")]
            case .plan:
                return [("plan_meta", "id"), ("plans", "id"), ("plan_days", "plan_id")]
            case .highlights:
                return [("module_meta", "id"), ("highlight_sets", "module_id")]
            case .quiz:
                return [("quiz_modules", "id"), ("quiz_questions", "quiz_module_id")]
            }
        }()

        for (table, column) in owners where tables.contains(table) {
            let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? })
            guard columns.contains(column) else { continue }
            let aliases = kind == .notes
                && LampSyncModuleFiles.canonicalIdentity(expectedID, isNotes: true) == "notes"
                ? ["notes", "bible-notes"] : [expectedID]
            let placeholders = aliases.map { _ in "?" }.joined(separator: ", ")
            let foreign = try Row.fetchOne(db, sql: """
                SELECT 1 FROM \(table)
                WHERE \(column) IS NULL OR \(column) NOT IN (\(placeholders)) LIMIT 1
                """, arguments: StatementArguments(aliases))
            if foreign != nil { throw InspectionError.foreignRows(table) }
        }

        if tables.contains("module_format") {
            let types = try String.fetchAll(db, sql: "SELECT DISTINCT module_type FROM module_format")
            if types.contains(where: { LampModuleKind(schemaValue: $0) != kind }) {
                throw InspectionError.foreignRows("module_format")
            }
        }

        // Full highlight databases copy child set IDs directly. Reject an
        // orphaned child that could otherwise attach to a local foreign set.
        if kind == .highlights, tables.contains("highlight_sets") {
            for table in ["highlights", "highlight_themes"] where tables.contains(table) {
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? })
                guard columns.contains("set_id") else { continue }
                let orphan = try Row.fetchOne(db, sql: """
                    SELECT 1 FROM \(table) AS child
                    WHERE child.set_id IS NULL OR NOT EXISTS (
                        SELECT 1 FROM highlight_sets AS parent WHERE parent.id = child.set_id
                    ) LIMIT 1
                    """)
                if orphan != nil { throw InspectionError.foreignRows(table) }
            }
        }
    }

    private static func descriptor(
        id: String,
        kind: LampModuleKind
    ) throws -> LampPortableModuleDescriptor {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), !id.contains("\0") else {
            throw InspectionError.missingIdentity
        }
        return LampPortableModuleDescriptor(id: id, kind: kind)
    }
}
