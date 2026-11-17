import Foundation
import GRDB
import LampModuleKit

/// Everything the library holds about one module, for a window that shows
/// it: the module as every list shows it, where it is kept, and each of its
/// kind's metadata tables with every column.
///
/// A column a table has is applicable to the module, and one empty in it
/// (`.null`) is missing for this module; a column the table doesn't have, or
/// a table the kind doesn't keep, is not applicable. So a translation has no
/// ISBN to be missing, and a book with no versification is not missing one.
public struct LampModuleRecord: Equatable, Sendable {
    public let module: LampInstalledModule
    public let storage: Storage
    /// The kind's metadata tables, in the order they are read, each with its
    /// rows for this module and every column in the table's own order.
    public let tables: [Table]

    public init(module: LampInstalledModule, storage: Storage, tables: [Table]) {
        self.module = module
        self.storage = storage
        self.tables = tables
    }

    public enum Storage: Equatable, Sendable {
        /// Installed from a `.lamp` file: that file, kept for sync, where
        /// there is one, and the database it was unpacked to.
        case installed(moduleFile: File?, database: File)
        /// Shipped inside the app, read from the bundle's database. Where the
        /// bundle records them, its rows' own `file_path` and `file_hash` say
        /// what the module was built from.
        case bundled(database: File)
        /// Installed into a database the app keeps for every module it
        /// holds, in the bundle's layout, as the phone keeps them: no `.lamp`
        /// file of its own.
        case shared(database: File)
    }

    public struct File: Equatable, Sendable {
        public let url: URL
        public let byteCount: Int?
        public let modifiedAt: Date?
        /// The SHA-256 of the file's bytes in hex, as sync records it. Only
        /// for a module's own `.lamp` file: a database is large and changes
        /// as it is read, so its hash would say nothing.
        public let sha256: String?

        public init(url: URL, byteCount: Int?, modifiedAt: Date?, sha256: String?) {
            self.url = url
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
            self.sha256 = sha256
        }
    }

    public struct Table: Equatable, Sendable {
        public let name: String
        public let rows: [[Field]]

        public init(name: String, rows: [[Field]]) {
            self.name = name
            self.rows = rows
        }
    }

    public struct Field: Equatable, Sendable {
        public let name: String
        public let value: Value

        public init(name: String, value: Value) {
            self.name = name
            self.value = value
        }
    }

    /// A column's value as SQLite holds it. A blob is given by its size.
    public enum Value: Equatable, Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(byteCount: Int)
    }

    /// The first value of a column across the tables, for a caller after one
    /// field by name; nil where no table has the column, `.null` where one
    /// has it empty.
    public func value(of column: String) -> Value? {
        for table in tables {
            for row in table.rows {
                if let field = row.first(where: { $0.name == column }) { return field.value }
            }
        }
        return nil
    }
}

extension LampModuleRecord {
    /// The metadata tables of a database holding one module, as a `.lamp`
    /// file unpacks to: every row of each, a record showing at most 100.
    /// Content tables (verses, entries, highlights) are not metadata.
    public static func tables(moduleDatabase db: Database) throws -> [Table] {
        try tables(in: db, moduleDatabaseTables.map { .init(table: $0, condition: "1 = 1", needs: [], arguments: []) })
    }

    /// One module's tables in a database holding many in the bundle's
    /// layout: the bundle's own, or an app's database of installed modules.
    /// Its row by ID — in the shared `modules` table, the row of its own
    /// type, since two kinds may share an ID — a commentary's series and
    /// books, and a highlight module's sets.
    public static func tables(sharedLayoutIn db: Database, kind: LampModuleKind, id: String) throws -> [Table] {
        try tables(in: db, sharedLayoutTables(for: kind).map {
            .init(
                table: $0.table, condition: $0.condition, needs: $0.needs,
                arguments: Array(repeating: id, count: $0.condition.filter { $0 == "?" }.count)
            )
        })
    }

    private static let moduleDatabaseTables = [
        "module_format", "translation_meta", "translations", "module_metadata", "series_meta",
        "module_meta", "note_book_meta", "highlight_meta", "highlight_sets", "highlight_themes",
        "commentary_books", "book_modules", "plans", "quiz_modules",
    ]

    /// Where a module of each kind is kept in the bundle's layout: each table
    /// with the columns its condition reads, which a layout without them is
    /// skipped for.
    private static func sharedLayoutTables(
        for kind: LampModuleKind
    ) -> [(table: String, condition: String, needs: [(table: String, column: String)])] {
        let types = switch kind {
        case .dictionary: "'dictionary', 'lexicon'"
        case .notes: "'notes', 'note'"
        default: "'\(kind.rawValue)'"
        }
        let registry = ("modules", "id = ? AND type IN (\(types))", [("modules", "type")])
        switch kind {
        case .translation: return [("translations", "id = ?", [("translations", "id")])]
        case .dictionary: return [("lexicons", "id = ?", [("lexicons", "id")]), registry]
        case .commentary:
            return [
                registry,
                ("commentary_series", "id = (SELECT series_id FROM modules WHERE id = ? AND type IN (\(types)))",
                 [("commentary_series", "id"), ("modules", "series_id"), ("modules", "type")]),
                ("commentary_books", "module_id = ?", [("commentary_books", "module_id")]),
            ]
        case .book: return [("book_modules", "id = ?", [("book_modules", "id")])]
        case .plan: return [("plans", "id = ?", [("plans", "id")])]
        case .quiz: return [("quiz_modules", "id = ?", [("quiz_modules", "id")])]
        case .highlights: return [registry, ("highlight_sets", "module_id = ?", [("highlight_sets", "module_id")])]
        case .devotional, .notes: return [registry]
        }
    }

    private struct Query {
        let table: String
        let condition: String
        /// The columns the condition reads: a layout without them is not
        /// this one, and the table is skipped rather than failing the read.
        let needs: [(table: String, column: String)]
        let arguments: [String]
    }

    /// Each of `queries`' tables the database has, with its matching rows and
    /// every column. A table with no matching row is left out.
    private static func tables(in db: Database, _ queries: [Query]) throws -> [Table] {
        try queries.compactMap { query in
            guard try db.tableExists(query.table) else { return nil }
            for need in query.needs {
                guard try db.tableExists(need.table),
                      try db.columns(in: need.table).contains(where: { $0.name == need.column }) else { return nil }
            }
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM \(query.table) WHERE \(query.condition) LIMIT 100",
                arguments: StatementArguments(query.arguments)
            )
            guard !rows.isEmpty else { return nil }
            return Table(name: query.table, rows: rows.map { row in
                zip(row.columnNames, row.databaseValues).map { name, value in
                    let recorded: Value = switch value.storage {
                    case .null: .null
                    case .int64(let integer): .integer(integer)
                    case .double(let real): .real(real)
                    case .string(let text): .text(text)
                    case .blob(let data): .blob(byteCount: data.count)
                    }
                    return Field(name: name, value: recorded)
                }
            })
        }
    }
}
