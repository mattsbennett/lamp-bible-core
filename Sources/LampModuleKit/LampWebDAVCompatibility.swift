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

public struct LampWebDAVModuleJSONDocument: Equatable, Sendable {
    public let data: Data
    public let moduleID: String
    /// Identity of the original remote module. Legacy notes JSON expands one
    /// module into per-book documents, but competes with one .lamp successor.
    public let syncIdentity: String

    public init(data: Data, moduleID: String, syncIdentity: String? = nil) {
        self.data = data
        self.moduleID = moduleID
        self.syncIdentity = syncIdentity ?? moduleID
    }
}

/// Converts legacy iOS JSON envelopes into canonical module documents.
public enum LampWebDAVModuleJSONAdapter {
    public static func documents(
        from data: Data,
        kind: LampModuleKind,
        fallbackModuleID: String
    ) throws -> [LampWebDAVModuleJSONDocument] {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LampWebDAVCompatibilityError.invalidModuleJSON
        }
        let fallbackID = safeIdentifier(fallbackModuleID)

        switch kind {
        case .devotional:
            if let entries = root["entries"] as? [Any] {
                return try entries.enumerated().map { index, value in
                    guard let entry = value as? [String: Any] else {
                        throw LampWebDAVCompatibilityError.invalidModuleJSON
                    }
                    return try devotionalDocument(
                        entry,
                        fallbackModuleID: "\(fallbackID)-\(index + 1)"
                    )
                }
            }
            return [try devotionalDocument(root, fallbackModuleID: fallbackID)]

        case .notes:
            if root["meta"] == nil, let entries = root["entries"] as? [Any] {
                return try noteDocuments(
                    entries: entries,
                    metadata: root,
                    fallbackModuleID: fallbackID
                )
            }

        case .highlights:
            if root["meta"] == nil, let highlights = root["highlights"] as? [Any] {
                root = try canonicalHighlights(
                    root: root,
                    highlights: highlights,
                    fallbackModuleID: fallbackID
                )
            }

        case .translation, .dictionary, .commentary, .book, .plan, .quiz:
            break
        }

        root = canonicalRoot(root, kind: kind, fallbackModuleID: fallbackID)
        return [LampWebDAVModuleJSONDocument(
            data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            moduleID: moduleID(in: root) ?? fallbackID
        )]
    }

    private static func devotionalDocument(
        _ source: [String: Any],
        fallbackModuleID: String
    ) throws -> LampWebDAVModuleJSONDocument {
        var root = source
        var meta = root["meta"] as? [String: Any] ?? [:]
        if meta.isEmpty {
            for key in [
                "id", "title", "subtitle", "author", "date", "tags", "category",
                "series", "keyScriptures", "created", "lastModified",
            ] where root[key] != nil {
                meta[key] = root[key]
            }
        }
        let identifier = string(meta["id"]) ?? string(root["id"]) ?? fallbackModuleID
        meta["schemaVersion"] = string(meta["schemaVersion"]) ?? "1.0"
        meta["id"] = safeIdentifier(identifier)
        meta["type"] = "devotional"
        meta["title"] = string(meta["title"])
            ?? string(root["title"])
            ?? "Untitled"
        root["meta"] = meta
        // The iOS model treats markdownContent as the preferred representation
        // when both the legacy block tree and Markdown are present.
        if let markdown = string(root["markdownContent"]), !markdown.isEmpty {
            root["content"] = markdown
        }
        guard root.keys.contains("content") else {
            throw LampWebDAVCompatibilityError.invalidModuleJSON
        }
        return LampWebDAVModuleJSONDocument(
            data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            moduleID: safeIdentifier(identifier)
        )
    }

    private static func noteDocuments(
        entries: [Any],
        metadata: [String: Any],
        fallbackModuleID: String
    ) throws -> [LampWebDAVModuleJSONDocument] {
        var entriesByBook: [Int: [[String: Any]]] = [:]
        for value in entries {
            guard let entry = value as? [String: Any],
                  let reference = integer(entry["verseId"]),
                  reference > 0,
                  reference / 1_000_000 > 0 else { continue }
            entriesByBook[reference / 1_000_000, default: []].append(entry)
        }

        return try entriesByBook.keys.sorted().map { bookNumber in
            let identifier = safeIdentifier("\(fallbackModuleID)-\(bookNumber)")
            let bookEntries = entriesByBook[bookNumber] ?? []
            let chapters = Dictionary(grouping: bookEntries) { entry in
                (integer(entry["verseId"]) ?? 0) / 1_000 % 1_000
            }.keys.sorted().map { chapterNumber -> [String: Any] in
                let verses = (Dictionary(grouping: bookEntries) { entry in
                    (integer(entry["verseId"]) ?? 0) / 1_000 % 1_000
                }[chapterNumber] ?? []).compactMap { entry -> [String: Any]? in
                    guard let reference = integer(entry["verseId"]),
                          let content = entry["content"], isMeaningful(content) else { return nil }
                    var verse: [String: Any] = ["sv": reference, "commentary": content]
                    for key in ["title", "lastModified", "footnotes"] where entry[key] != nil {
                        verse[key] = entry[key]
                    }
                    if let verseReferences = entry["verseRefs"] as? [Any] {
                        let endReferences = verseReferences.compactMap { value -> Int? in
                            guard let object = value as? [String: Any] else { return nil }
                            return integer(object["ev"]) ?? integer(object["sv"])
                        }.filter { $0 >= reference }
                        if let endReference = endReferences.max(), endReference > reference {
                            verse["ev"] = endReference
                        }
                    }
                    return verse
                }
                return ["chapter": chapterNumber, "verses": verses]
            }
            var meta: [String: Any] = [
                "schemaVersion": "1.0",
                "id": identifier,
                "type": "notes",
                "name": string(metadata["name"]) ?? "Notes",
            ]
            for key in ["description", "author"] where metadata[key] != nil {
                meta[key] = metadata[key]
            }
            let root: [String: Any] = [
                "meta": meta,
                "book": bookName(bookNumber),
                "bookNumber": bookNumber,
                "chapters": chapters,
            ]
            return LampWebDAVModuleJSONDocument(
                data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                moduleID: identifier,
                syncIdentity: safeIdentifier(string(metadata["id"]) ?? fallbackModuleID)
            )
        }
    }

    private static func canonicalHighlights(
        root: [String: Any],
        highlights: [Any],
        fallbackModuleID: String
    ) throws -> [String: Any] {
        let grouped = Dictionary(grouping: highlights) { value -> Int in
            guard let entry = value as? [String: Any] else { return 0 }
            return integer(entry["ref"]) ?? 0
        }
        let verses: [[String: Any]] = grouped.keys.filter { $0 > 0 }.sorted().map { reference in
            let spans = (grouped[reference] ?? []).compactMap { value -> [String: Any]? in
                guard let entry = value as? [String: Any],
                      integer(entry["sc"]) != nil,
                      integer(entry["ec"]) != nil else { return nil }
                var span: [String: Any] = [
                    "sc": integer(entry["sc"])!,
                    "ec": integer(entry["ec"])!,
                    "style": integer(entry["style"]) ?? 0,
                ]
                if entry["color"] != nil { span["color"] = entry["color"] }
                return span
            }
            return ["ref": reference, "highlights": spans]
        }
        let identifier = safeIdentifier(string(root["id"]) ?? fallbackModuleID)
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": identifier,
            "type": "highlights",
            "translationId": string(root["translationId"]) ?? "unknown",
            "name": string(root["name"]) ?? "Highlights",
        ]
        for key in ["description", "created", "lastModified", "themes"] where root[key] != nil {
            meta[key] = root[key]
        }
        return ["meta": meta, "verses": verses]
    }

    private static func canonicalRoot(
        _ source: [String: Any],
        kind: LampModuleKind,
        fallbackModuleID: String
    ) -> [String: Any] {
        var root = source
        var meta = root["meta"] as? [String: Any] ?? root
        meta["schemaVersion"] = string(meta["schemaVersion"]) ?? "1.0"
        if kind != .commentary {
            meta["id"] = safeIdentifier(string(meta["id"]) ?? fallbackModuleID)
            meta["type"] = kind.rawValue
        }
        if kind == .dictionary, string(meta["name"]) == nil {
            meta["name"] = fallbackModuleID
        }
        root["meta"] = meta
        return root
    }

    private static func moduleID(in root: [String: Any]) -> String? {
        guard let meta = root["meta"] as? [String: Any] else { return nil }
        return string(meta["id"])
    }

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let identifier = String(value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        })
        return identifier.isEmpty ? "webdav-module" : identifier
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func isMeaningful(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let value = value as? String {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let value = value as? [Any] { return !value.isEmpty }
        if let value = value as? [String: Any] { return !value.isEmpty }
        return true
    }

    private static func bookName(_ number: Int) -> String {
        let names = [
            "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
            "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
            "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer", "Lam",
            "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic", "Nah",
            "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt", "Mark", "Luke", "John",
            "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess",
            "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas", "1Pet",
            "2Pet", "1John", "2John", "3John", "Jude", "Rev",
        ]
        guard names.indices.contains(number - 1) else { return "Book\(number)" }
        return names[number - 1]
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
