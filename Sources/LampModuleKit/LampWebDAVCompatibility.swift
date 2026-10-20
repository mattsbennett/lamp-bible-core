import Foundation
import SQLite3

public enum LampWebDAVPersonalArchiveKind: Sendable {
    case notes
    case devotionals

    fileprivate var entryTable: String {
        switch self {
        case .notes: "note_entries"
        case .devotionals: "devotional_entries"
        }
    }
}

public enum LampWebDAVPersonalArchiveAdapter {
    /// The two apps use different IDs for their default editable collections.
    /// Rewrite the Mac archive's module IDs before publishing it into the iOS
    /// folder layout so iOS merges the rows into its existing collection.
    public static func archive(
        _ compressedData: Data,
        replacingModuleIDWith moduleID: String,
        kind: LampWebDAVPersonalArchiveKind,
        mediaRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard !moduleID.isEmpty,
              !moduleID.contains("/"),
              !moduleID.contains("\0"),
              let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-ios-sync-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(atPath: databaseURL.path + "-journal")
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        do {
            try updateModuleID(in: database, table: "module_format", column: "module_id", to: moduleID)
            try updateModuleID(in: database, table: "module_meta", column: "id", to: moduleID)
            try updateModuleID(in: database, table: kind.entryTable, column: "module_id", to: moduleID)
            if case .devotionals = kind {
                try normalizeDevotionalMedia(
                    in: database, mediaRootURL: mediaRootURL, fileManager: fileManager
                )
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw LampWebDAVCompatibilityError.archiveConversionFailed
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }

        let rewrittenData = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        guard let compressed = try? (rewrittenData as NSData).compressed(using: .zlib) as Data else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        return compressed
    }

    public static func highlightSetID(
        in compressedData: Data,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-ios-highlight-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer { try? fileManager.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM highlight_meta LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private static func updateModuleID(
        in database: OpaquePointer,
        table: String,
        column: String,
        to moduleID: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE \(table) SET \(column) = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, moduleID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
    }

    private static func normalizeDevotionalMedia(
        in database: OpaquePointer,
        mediaRootURL: URL?,
        fileManager: FileManager
    ) throws {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT id, content_json, media_json FROM devotional_entries", -1, &query, nil
        ) == SQLITE_OK, let query else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        var rows: [(id: String, content: String, media: String?)] = []
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            guard let id = sqlite3_column_text(query, 0),
                  let content = sqlite3_column_text(query, 1) else {
                sqlite3_finalize(query)
                throw LampWebDAVCompatibilityError.archiveConversionFailed
            }
            rows.append((
                String(cString: id),
                String(cString: content),
                sqlite3_column_text(query, 2).map { String(cString: $0) }
            ))
            step = sqlite3_step(query)
        }
        sqlite3_finalize(query)
        guard step == SQLITE_DONE else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }

        var update: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE devotional_entries SET content_json = ?, media_json = ? WHERE id = ?",
            -1, &update, nil
        ) == SQLITE_OK, let update else {
            throw LampWebDAVCompatibilityError.archiveConversionFailed
        }
        defer { sqlite3_finalize(update) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            let markdown = LampPortableDevotionalMedia.plainMarkdown(from: row.content)
                ?? row.content
            let references = try LampPortableDevotionalMedia.references(
                in: markdown, devotionalID: row.id
            )
            if let mediaRootURL {
                for reference in references {
                    let url = mediaRootURL.appendingPathComponent(reference.archivePath)
                    guard fileManager.fileExists(atPath: url.path) else {
                        throw LampWebDAVCompatibilityError.missingDevotionalMedia(reference.archivePath)
                    }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw LampWebDAVCompatibilityError.missingDevotionalMedia(reference.archivePath)
                    }
                }
            }
            let generated: [[String: Any]] = references.map { reference in
                [
                    "id": reference.id,
                    "type": reference.kind.rawValue,
                    "filename": reference.filename,
                    "mimeType": reference.mimeType,
                ]
            }
            let existing: [[String: Any]]
            if let media = row.media {
                guard let data = media.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw LampWebDAVCompatibilityError.archiveConversionFailed
                }
                existing = decoded
            } else {
                existing = []
            }
            if let mediaRootURL {
                for media in existing {
                    guard let filename = media["filename"] as? String,
                          LampPortableDevotionalMedia.isSafePathComponent(row.id),
                          LampPortableDevotionalMedia.isSafePathComponent(filename) else {
                        throw LampWebDAVCompatibilityError.archiveConversionFailed
                    }
                    let path = "Media/Devotionals/\(row.id)/\(filename)"
                    let url = mediaRootURL.appendingPathComponent(path)
                    guard fileManager.fileExists(atPath: url.path) else {
                        throw LampWebDAVCompatibilityError.missingDevotionalMedia(path)
                    }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw LampWebDAVCompatibilityError.missingDevotionalMedia(path)
                    }
                }
            }
            let mediaJSON: String?
            if generated.isEmpty {
                mediaJSON = row.media
            } else {
                let existingIDs = Set(existing.compactMap { $0["id"] as? String })
                let combined = existing + generated.filter { !existingIDs.contains($0["id"] as? String ?? "") }
                let data = try JSONSerialization.data(withJSONObject: combined, options: [.sortedKeys])
                mediaJSON = String(decoding: data, as: UTF8.self)
            }
            guard sqlite3_bind_text(update, 1, markdown, -1, transient) == SQLITE_OK,
                  (mediaJSON.map { sqlite3_bind_text(update, 2, $0, -1, transient) }
                    ?? sqlite3_bind_null(update, 2)) == SQLITE_OK,
                  sqlite3_bind_text(update, 3, row.id, -1, transient) == SQLITE_OK,
                  sqlite3_step(update) == SQLITE_DONE else {
                throw LampWebDAVCompatibilityError.archiveConversionFailed
            }
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
        }
    }

}

public enum LampWebDAVCompatibilityError: Error, LocalizedError {
    case archiveConversionFailed
    case missingDevotionalMedia(String)
    case invalidModuleJSON

    public var errorDescription: String? {
        switch self {
        case .archiveConversionFailed:
            "Lamp Bible could not prepare personal content for cross-device sync."
        case .missingDevotionalMedia(let path):
            "Missing devotional media for sync: \(path)."
        case .invalidModuleJSON:
            "The WebDAV module JSON is not in a supported Lamp Bible format."
        }
    }
}
