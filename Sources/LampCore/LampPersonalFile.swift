import Foundation
import GRDB
import LampModuleKit

/// What every file the reader's own content travels in has in common.
///
/// Small, and worth having apart all the same: the way a value is spelled
/// is the contract between two apps. Two encoders that disagree about key
/// order or an escaped slash make each device decide the other's file is
/// new and upload its own in reply — a sync that never settles, from a
/// difference nobody would call a bug on either side.
public enum LampPersonalFile {
    /// The metadata table every personal file opens with, written here so
    /// that its text — which `sqlite_master` keeps verbatim, and which is
    /// therefore part of the bytes — is the same whoever writes the file.
    public static let metaSchema = """
        CREATE TABLE module_meta (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
            author TEXT, version TEXT, is_editable INTEGER NOT NULL DEFAULT 1
        );
        """

    /// The whole published file, compressed, from records alone.
    ///
    /// Core owns the container and not merely the rows, because the rows are
    /// not the only thing in the bytes: the journal mode, the `module_format`
    /// row, the text of every `CREATE`, what `ANALYZE` leaves in
    /// `sqlite_stat1`, `VACUUM`, and the zlib step all land in the file two
    /// devices are comparing. A second app that reproduced the rows and not
    /// those would publish a different file from the same notes, and the two
    /// would trade uploads for ever. ios-56 made this point about the first
    /// cut of the notes writer, which exposed the rows alone; it was right.
    ///
    /// `moduleID` is a parameter because the same records are published
    /// under different names: the reader's collection travels as `notes`
    /// while a local backup is `personal-notes`, and a notes module of the
    /// reader's own making travels under its own id. Writing the id in from
    /// the start is also what retires the rewrite-after-the-fact step, which
    /// decompressed the file, updated three tables and compressed it again.
    public static func archive(
        kind: LampModuleKind,
        moduleID: String,
        schema: String,
        fileManager: FileManager = .default,
        populate: (Database) throws -> Void
    ) throws -> Data {
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-personal-export-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(atPath: databaseURL.path + "-shm")
            try? fileManager.removeItem(atPath: databaseURL.path + "-wal")
        }

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
                arguments: [LampModuleCompiler.formatVersion, kind.rawValue, moduleID]
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

        let databaseData = try Data(contentsOf: databaseURL, options: [.mappedIfSafe])
        guard let compressed = try? (databaseData as NSData).compressed(using: .zlib) as Data,
              let verification = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              verification == databaseData else {
            throw LampLibraryError.invalidPersonalContent(
                "Lamp Bible could not create the portable archive."
            )
        }
        return compressed
    }

    /// JSON written the one way: keys sorted, slashes unescaped, a bare
    /// value allowed.
    public static func jsonFragment(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
