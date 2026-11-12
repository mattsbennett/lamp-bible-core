import Foundation
import GRDB
import LampModuleKit

/// The file the reader's own writings travel in, written from records alone.
///
/// The second of the three personal kinds to move here, on the same terms
/// as `LampPersonalNotesFile`: records in, rows out, nothing of a library
/// in between, so the Mac and the phone produce the same bytes from the
/// same writings.
///
/// Pinned by `LampPersonalExportShapeTests` against
/// `LampPersonalExportSchema.exportedTables(for: .writing)`.
public enum LampPersonalWritingFile {
    /// The table as this writes it. Column order is part of the file.
    public static let schema = """
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

    /// The whole published file, compressed, under the name it travels as.
    ///
    /// `moduleID` is the reader's collection on the server (`notes` /
    /// `devotionals`), the local backup's name (`personal-notes` /
    /// `personal-writing`), or a module of the reader's own making. Writing
    /// it in from the start is what lets a file be published without being
    /// decompressed, rewritten and compressed again afterwards.
    ///
    /// `description` goes with it, and travels for the same reason: a
    /// reader-made module's description was staying on the device that set
    /// it, because this wrote `module_meta` without the column.
    ///
    /// `name` goes with it, and defaults apart from it on purpose. A
    /// receiving app takes `module_meta.name` as what to call the module, so
    /// a file published under its own id and the collection's *name* would
    /// show the reader every module of their own making renamed "My Notes"
    /// on their other device. Caught by ios-56 while adopting this.
    public static func archive(
        _ writings: [LampDevotional],
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        normalizingMediaIn mediaRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        try LampPersonalFile.archive(
            kind: LampPersonalModule.writing.kind,
            moduleID: moduleID,
            schema: """
                \(LampPersonalFile.metaSchema)
                \(schema)
                """,
            fileManager: fileManager
        ) { db in
            try write(
                writings, moduleID: moduleID, name: name, description: description, author: author, version: version,
                normalizingMediaIn: mediaRootURL, fileManager: fileManager, into: db
            )
        }
    }

    /// The whole published file from rows, for an app whose writings this
    /// app's model cannot hold.
    ///
    /// The sequence is the point. Given only `LampPersonalFile.archive` and
    /// a row writer, a second app would have to compose the metadata row,
    /// the rows and the container itself in the right order — core's code,
    /// but that app's sequence, which drifts the first time a step is added
    /// here. One entry point, so both apps provably go through the same
    /// one. Asked for by ios-56.
    public static func archive(
        rows: [Row],
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        try LampPersonalFile.archive(
            kind: LampPersonalModule.writing.kind,
            moduleID: moduleID,
            schema: """
                \(LampPersonalFile.metaSchema)
                \(schema)
                """,
            fileManager: fileManager
        ) { db in
            try writeMetadata(moduleID: moduleID, name: name, description: description, author: author, version: version, into: db)
            for row in rows { try write(row, into: db) }
        }
    }

    public static func write(
        _ writings: [LampDevotional],
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        normalizingMediaIn mediaRootURL: URL? = nil,
        fileManager: FileManager = .default,
        into db: Database
    ) throws {
        try writeMetadata(moduleID: moduleID, name: name, description: description, author: author, version: version, into: db)
        for writing in writings {
            try write(
                writing, moduleID: moduleID,
                normalizingMediaIn: mediaRootURL, fileManager: fileManager, into: db
            )
        }
    }

    /// One row of the file, as stored values.
    ///
    /// The unit the two apps agree on is **the row**, not either app's
    /// model of a writing. `LampDevotional` cannot carry everything this
    /// file holds — it flattens the summary and footnotes to plain strings,
    /// has no series id of its own, and knows nothing of `related_ids`,
    /// `subscription_id` or `is_read_only`. Writing the phone's writings
    /// through it would lose all of that between the reader's own iPhone
    /// and iPad, which sync through this same file. ios-56 caught that
    /// before adopting it.
    ///
    /// So each app maps its own record to a row: the Mac from
    /// `LampDevotional`, exactly as it wrote before, and the phone from
    /// what it holds, losing nothing.
    public struct Row: Sendable {
        public var id: String
        public var moduleID: String
        public var title: String
        public var subtitle: String?
        public var author: String?
        public var date: String?
        /// Comma-separated, as the column has always held them.
        public var tags: String?
        public var category: String?
        public var seriesID: String?
        public var seriesName: String?
        public var seriesOrder: Int?
        /// JSON written as JSON, verbatim — this writes what it is given.
        public var keyScripturesJSON: String?
        public var summaryJSON: String?
        public var contentJSON: String
        public var footnotesJSON: String?
        public var relatedIDs: String?
        /// Seconds.
        public var created: Int
        public var lastModified: Int?
        public var recordChangeTag: String?
        public var subscriptionID: String?
        public var isReadOnly: Int?
        public var mediaJSON: String?

        public init(
            id: String,
            moduleID: String,
            title: String,
            subtitle: String? = nil,
            author: String? = nil,
            date: String? = nil,
            tags: String? = nil,
            category: String? = nil,
            seriesID: String? = nil,
            seriesName: String? = nil,
            seriesOrder: Int? = nil,
            keyScripturesJSON: String? = nil,
            summaryJSON: String? = nil,
            contentJSON: String,
            footnotesJSON: String? = nil,
            relatedIDs: String? = nil,
            created: Int,
            lastModified: Int? = nil,
            recordChangeTag: String? = nil,
            subscriptionID: String? = nil,
            isReadOnly: Int? = nil,
            mediaJSON: String? = nil
        ) {
            self.id = id
            self.moduleID = moduleID
            self.title = title
            self.subtitle = subtitle
            self.author = author
            self.date = date
            self.tags = tags
            self.category = category
            self.seriesID = seriesID
            self.seriesName = seriesName
            self.seriesOrder = seriesOrder
            self.keyScripturesJSON = keyScripturesJSON
            self.summaryJSON = summaryJSON
            self.contentJSON = contentJSON
            self.footnotesJSON = footnotesJSON
            self.relatedIDs = relatedIDs
            self.created = created
            self.lastModified = lastModified
            self.recordChangeTag = recordChangeTag
            self.subscriptionID = subscriptionID
            self.isReadOnly = isReadOnly
            self.mediaJSON = mediaJSON
        }
    }

    /// The one metadata row, which every way of writing this file shares.
    public static func writeMetadata(
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        into db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO module_meta (id, name, description, author, version, is_editable)
            VALUES (?, ?, ?, ?, ?, 1)
            """, arguments: [
                moduleID,
                name,
                description,
                author,
                // A module of the reader's own making carries the version
                // they gave it; the collection has none of its own and
                // takes the format's, as it always did.
                version ?? LampModuleCompiler.formatVersion,
            ])
    }

    /// Writes a row as given, except `search_text`, which is derived
     /// here so that no sender can disagree about it.
    public static func write(_ row: Row, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO devotional_entries (
                id, module_id, title, subtitle, author, date, tags, category,
                series_id, series_name, series_order, key_scriptures_json,
                summary_json, content_json, footnotes_json, related_ids,
                created, last_modified, search_text, record_change_tag,
                subscription_id, is_read_only, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                      ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                row.id, row.moduleID, row.title, row.subtitle, row.author,
                row.date, row.tags, row.category, row.seriesID, row.seriesName,
                row.seriesOrder, row.keyScripturesJSON, row.summaryJSON,
                row.contentJSON, row.footnotesJSON, row.relatedIDs,
                row.created, row.lastModified,
                // Derived here, never taken from the sender: it is the one
                // column two apps can spell differently while holding
                // identical content, and that alone would make each
                // publish its file in reply to the other for ever.
                LampPersonalFile.searchText([
                    row.title,
                    row.subtitle,
                    LampPersonalFile.searchableText(in: row.summaryJSON),
                    LampPersonalFile.searchableText(in: row.contentJSON),
                    LampPersonalFile.searchableText(in: row.footnotesJSON),
                ]),
                row.recordChangeTag, row.subscriptionID, row.isReadOnly,
                row.mediaJSON,
            ])
    }

    /// One writing's row, which is the unit the two apps have to agree on.
    ///
    /// `series_id` is given the series' *name*, because a writing of the
    /// reader's own has no separate id for its series — `LampDevotional`
    /// carries a name and an order and nothing else. It round-trips, which
    /// is what matters here, but a reader of this file should not take that
    /// column for an identifier it can resolve elsewhere.
    public static func write(
        _ writing: LampDevotional,
        moduleID: String = LampPersonalModule.writing.id,
        normalizingMediaIn mediaRootURL: URL? = nil,
        fileManager: FileManager = .default,
        into db: Database
    ) throws {
        try write(
            try row(
                for: writing, moduleID: moduleID,
                normalizingMediaIn: mediaRootURL, fileManager: fileManager
            ),
            into: db
        )
    }

    /// This app's writing as a row of the file.
    ///
    /// `series_id` is given the series' *name*, because a writing of the
    /// reader's own has no separate id for its series — `LampDevotional`
    /// carries a name and an order and nothing else. It round-trips, which
    /// is what matters here, but a reader of this file should not take that
    /// column for an identifier it can resolve elsewhere. The phone, whose
    /// writings do have one, maps its own row and keeps it.
    public static func row(
        for writing: LampDevotional,
        moduleID: String = LampPersonalModule.writing.id,
        normalizingMediaIn mediaRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Row {
        let scriptureValues = writing.keyScriptures.map { scripture -> [String: Any] in
            var value: [String: Any] = ["sv": scripture.startReference]
            if let endReference = scripture.endReference { value["ev"] = endReference }
            if let text = scripture.text { value["label"] = text }
            return value
        }
        let normalized = try normalized(
            writing, mediaRootURL: mediaRootURL, fileManager: fileManager
        )
        return Row(
            id: writing.id,
            moduleID: moduleID,
            title: writing.title,
            subtitle: writing.subtitle,
            author: writing.author,
            date: writing.date,
            tags: writing.tags.joined(separator: ","),
            category: writing.category,
            seriesID: writing.seriesName,
            seriesName: writing.seriesName,
            seriesOrder: writing.seriesOrder,
            keyScripturesJSON: try LampPersonalFile.jsonFragment(scriptureValues),
            summaryJSON: try LampPersonalFile.jsonFragment(writing.summary),
            contentJSON: normalized.content,
            footnotesJSON: try LampPersonalFile.jsonFragment(writing.footnotes),
            relatedIDs: nil,
            created: Int(stamp(writing.created).timeIntervalSince1970),
            lastModified: Int(stamp(writing.lastModified).timeIntervalSince1970),
            recordChangeTag: nil,
            subscriptionID: nil,
            isReadOnly: 0,
            mediaJSON: normalized.mediaJSON
        )
    }

    /// A writing's content and media as the file carries them.
    ///
    /// With no root given — a local backup — they are left as stored. With
    /// one, the writing is made ready to travel, which is what a receiving
    /// device needs and what used to be done afterwards by decompressing the
    /// published file and rewriting it in place:
    ///
    /// - A content wrapper that holds nothing but one paragraph of plain
    ///   text is **unwrapped**, so the column carries the Markdown the other
    ///   app reads rather than a JSON box around it. Anything richer is left
    ///   alone.
    /// - The pictures and recordings that Markdown refers to are **gathered
    ///   into `media_json`**, beside whatever the writing already listed,
    ///   first-listed winning for a repeated id.
    /// - Every file named, listed or referred to, must **be on this device**.
    ///   Publishing a writing whose picture is missing would send the other
    ///   device a reference to bytes nobody has, so it is refused outright.
    static func normalized(
        _ writing: LampDevotional,
        mediaRootURL: URL?,
        fileManager: FileManager
    ) throws -> (content: String, mediaJSON: String?) {
        let stored = try contentJSON(for: writing)
        guard let mediaRootURL else { return (stored, writing.mediaJSON) }
        let markdown = LampPortableDevotionalMedia.plainMarkdown(from: stored) ?? stored
        let references = try LampPortableDevotionalMedia.references(
            in: markdown, devotionalID: writing.id
        )
        for reference in references {
            try requireFile(at: mediaRootURL.appendingPathComponent(reference.archivePath),
                            named: reference.archivePath, fileManager: fileManager)
        }

        let existing: [[String: Any]]
        if let mediaJSON = writing.mediaJSON {
            guard let decoded = try JSONSerialization.jsonObject(
                with: Data(mediaJSON.utf8)
            ) as? [[String: Any]] else {
                throw LampWebDAVCompatibilityError.archiveConversionFailed
            }
            existing = decoded
        } else {
            existing = []
        }
        for entry in existing {
            guard let filename = entry["filename"] as? String,
                  LampPortableDevotionalMedia.isSafePathComponent(writing.id),
                  LampPortableDevotionalMedia.isSafePathComponent(filename) else {
                throw LampWebDAVCompatibilityError.archiveConversionFailed
            }
            let path = "Media/\(LampMediaScope.devotional.folder)/\(writing.id)/\(filename)"
            try requireFile(at: mediaRootURL.appendingPathComponent(path),
                            named: path, fileManager: fileManager)
        }

        guard !references.isEmpty else { return (markdown, writing.mediaJSON) }
        let generated: [[String: Any]] = references.map { reference in
            [
                "id": reference.id,
                "type": reference.kind.rawValue,
                "filename": reference.filename,
                "mimeType": reference.mimeType,
            ]
        }
        let known = Set(existing.compactMap { $0["id"] as? String })
        let combined = existing + generated.filter { !known.contains($0["id"] as? String ?? "") }
        let data = try JSONSerialization.data(withJSONObject: combined, options: [.sortedKeys])
        return (markdown, String(decoding: data, as: UTF8.self))
    }

    /// A regular file, present and not a symbolic link pointing elsewhere.
    private static func requireFile(
        at url: URL, named path: String, fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw LampWebDAVCompatibilityError.missingDevotionalMedia(path)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LampWebDAVCompatibilityError.missingDevotionalMedia(path)
        }
    }

    /// The blocks a writing is stored as, or one paragraph standing for its
    /// plain text where it has none.
    public static func contentJSON(for writing: LampDevotional) throws -> String {
        if let stored = writing.contentJSON { return stored }
        let blocks: [[String: Any]] = [[
            "type": "paragraph", "content": ["text": writing.content],
        ]]
        return String(decoding: try JSONSerialization.data(
            withJSONObject: blocks, options: [.sortedKeys]
        ), as: UTF8.self)
    }

    /// What a search of the file matches on.
    public static func searchText(for writing: LampDevotional) -> String {
        [
            writing.title,
            writing.subtitle,
            writing.summary,
            writing.content,
            writing.footnotes,
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// A writing with no date of its own.
    ///
    /// `personal_devotionals` declares both timestamps NOT NULL, so nothing
    /// a sync publishes reaches this: a writing the reader owns always has
    /// them. It matters anyway, because the fallback is **the clock**, and a
    /// row stamped with the time it was written out makes the whole file
    /// different on every pass — every device downloading every writing
    /// again, for ever, from a record that merely forgot to say when it was
    /// made. Kept as it was rather than quietly changed, since changing it
    /// would change the bytes of any file that did reach it; named here so
    /// that a future record type with optional dates is not handed a clock
    /// by accident.
    private static func stamp(_ date: Date?) -> Date {
        date ?? Date()
    }
}
