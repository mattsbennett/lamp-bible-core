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

    /// What a file's `search_text` holds, derived from the row rather than
    /// taken from whoever sent it.
    ///
    /// It is a **derived** column: each app rebuilds it for its own index
    /// on the way in, so what the sender put there is nobody's business but
    /// the file's. Taken from the sender it is the one column two apps can
    /// disagree about while holding identical content — which is enough to
    /// make each publish its own file in reply to the other for ever.
    ///
    /// It is not dead weight either. An installed module is searched
    /// through this column (`LampModuleSearch`), so a module one device
    /// publishes and another installs is findable only by what is written
    /// here. So: everything a reader would search for, joined, from the row.
    /// ios-56 asked for the rule; this is it.
    public static func searchText(_ parts: [String?]) -> String {
        parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The words inside a JSON value, in the order they are written.
    ///
    /// For a column that holds structured text — a note's footnotes, a
    /// writing's summary — where what a reader searches for is the text and
    /// not the shape around it. A value that is not JSON at all is itself
    /// the text, which is what a writing's content column holds once it has
    /// been unwrapped to Markdown.
    public static func searchableText(in value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              )
        else { return value }
        var words: [String] = []
        func walk(_ item: Any) {
            switch item {
            case let text as String: words.append(text)
            case let list as [Any]: list.forEach(walk)
            case let object as [String: Any]:
                // Sorted, so one device's dictionary order cannot reach the
                // bytes: Swift seeds that per process.
                for key in object.keys.sorted() { walk(object[key] as Any) }
            default: break
            }
        }
        walk(decoded)
        let joined = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
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
