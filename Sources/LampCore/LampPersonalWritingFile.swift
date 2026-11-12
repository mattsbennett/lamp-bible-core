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
    /// `name` goes with it, and defaults apart from it on purpose. A
    /// receiving app takes `module_meta.name` as what to call the module, so
    /// a file published under its own id and the collection's *name* would
    /// show the reader every module of their own making renamed "My Notes"
    /// on their other device. Caught by ios-56 while adopting this.
    public static func archive(
        _ writings: [LampDevotional],
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
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
            try write(writings, moduleID: moduleID, name: name, into: db)
        }
    }

    public static func write(
        _ writings: [LampDevotional],
        moduleID: String = LampPersonalModule.writing.id,
        name: String = LampPersonalModule.writing.name,
        into db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO module_meta (id, name, version, is_editable)
            VALUES (?, ?, ?, 1)
            """, arguments: [
                moduleID,
                name,
                LampModuleCompiler.formatVersion,
            ])
        for writing in writings {
            try write(writing, moduleID: moduleID, into: db)
        }
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
        into db: Database
    ) throws {
        let scriptureValues = writing.keyScriptures.map { scripture -> [String: Any] in
            var value: [String: Any] = ["sv": scripture.startReference]
            if let endReference = scripture.endReference { value["ev"] = endReference }
            if let text = scripture.text { value["label"] = text }
            return value
        }
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
                writing.id,
                moduleID,
                writing.title,
                writing.subtitle,
                writing.author,
                writing.date,
                writing.tags.joined(separator: ","),
                writing.category,
                writing.seriesName,
                writing.seriesName,
                writing.seriesOrder,
                try LampPersonalFile.jsonFragment(scriptureValues),
                try LampPersonalFile.jsonFragment(writing.summary),
                contentJSON(for: writing),
                try LampPersonalFile.jsonFragment(writing.footnotes),
                Int(stamp(writing.created).timeIntervalSince1970),
                Int(stamp(writing.lastModified).timeIntervalSince1970),
                searchText(for: writing),
                writing.mediaJSON,
            ])
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
