import Foundation
import GRDB

extension LampModuleCompiler {
    func compileDevotional(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let title = try JSONSupport.requiredString(meta["title"], path: "/meta/title")
        guard let content = root["content"], JSONSupport.isMeaningful(content) else {
            throw ModuleCompilationError.missingValue(path: "/content")
        }
        let queue = try makeDatabaseQueue(at: databaseURL)

        try queue.write { db in
            try createDevotionalSchema(in: db)
            try createFormatMetadata(in: db, kind: .devotional, moduleID: moduleID)

            try db.execute(sql: """
                INSERT INTO module_meta (
                    id, name, description, author, version, is_editable
                ) VALUES (?, ?, ?, ?, ?, 1)
                """, arguments: [
                    moduleID,
                    title,
                    JSONSupport.string(meta["subtitle"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["schemaVersion"]),
                ])

            let tags = JSONSupport.array(meta["tags"])?
                .compactMap(JSONSupport.string)
                .joined(separator: ",")
            let series = JSONSupport.object(meta["series"])
            let relatedIDs = JSONSupport.array(root["relatedDevotionals"])?
                .compactMap(JSONSupport.string)
                .joined(separator: ",")
            let summaryText = JSONSupport.plainText(root["summary"])
            let contentText = JSONSupport.plainText(content)
            let footnoteText = JSONSupport.plainText(root["footnotes"])
            let searchText = [title, JSONSupport.string(meta["subtitle"]), summaryText, contentText, footnoteText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            try db.execute(sql: """
                INSERT INTO devotional_entries (
                    id, module_id, title, subtitle, author, date, tags, category,
                    series_id, series_name, series_order, key_scriptures_json,
                    summary_json, content_json, footnotes_json, related_ids,
                    created, last_modified, search_text, record_change_tag,
                    subscription_id, is_read_only, media_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 0, ?)
                """, arguments: [
                    moduleID,
                    moduleID,
                    title,
                    JSONSupport.string(meta["subtitle"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["date"]),
                    tags,
                    JSONSupport.string(meta["category"]),
                    JSONSupport.string(series?["id"]),
                    JSONSupport.string(series?["name"]),
                    JSONSupport.integer(series?["order"]),
                    try JSONSupport.jsonString(meta["keyScriptures"]),
                    try JSONSupport.jsonFragmentString(root["summary"]),
                    try JSONSupport.jsonString(content) ?? "[]",
                    try JSONSupport.jsonString(root["footnotes"]),
                    relatedIDs,
                    JSONSupport.integer(meta["created"]) ?? 0,
                    JSONSupport.integer(meta["lastModified"]),
                    searchText,
                    try JSONSupport.jsonString(root["media"]),
                ])
        }

        try optimize(queue)
        return ["module_meta": 1, "devotional_entries": 1]
    }

    private func createDevotionalSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE module_meta (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                author TEXT,
                version TEXT,
                is_editable INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE devotional_entries (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL REFERENCES module_meta(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                subtitle TEXT,
                author TEXT,
                date TEXT,
                tags TEXT,
                category TEXT,
                series_id TEXT,
                series_name TEXT,
                series_order INTEGER,
                key_scriptures_json TEXT,
                summary_json TEXT,
                content_json TEXT NOT NULL,
                footnotes_json TEXT,
                related_ids TEXT,
                created INTEGER NOT NULL,
                last_modified INTEGER,
                search_text TEXT,
                record_change_tag TEXT,
                subscription_id TEXT,
                is_read_only INTEGER,
                media_json TEXT
            );
            CREATE INDEX idx_dev_module ON devotional_entries(module_id);
            CREATE INDEX idx_dev_date ON devotional_entries(date);
            CREATE INDEX idx_dev_series ON devotional_entries(series_id, series_order);
            """)
    }
}
