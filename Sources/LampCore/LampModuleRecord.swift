import Foundation

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
