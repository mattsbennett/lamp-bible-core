import Foundation
import GRDB

extension LampModuleCompiler {
    func compileBook(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let sections = try JSONSupport.requiredArray(root["sections"], path: "/sections")
        let title = try JSONSupport.requiredString(meta["title"], path: "/meta/title")
        let language = try JSONSupport.requiredString(meta["language"], path: "/meta/language")
        let queue = try makeDatabaseQueue(at: databaseURL)
        var sectionCount = 0

        try queue.write { db in
            try createBookSchema(in: db)
            try createFormatMetadata(in: db, kind: .book, moduleID: moduleID)

            try db.execute(sql: """
                INSERT INTO book_modules (
                    id, title, subtitle, description, author, editor, publisher,
                    year, edition, isbn, language, text_direction, copyright,
                    license, version, schema_version, tags_json, cover_media_id,
                    is_editable, created, last_modified, footnotes_json, media_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    moduleID,
                    title,
                    JSONSupport.string(meta["subtitle"]),
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["editor"]),
                    JSONSupport.string(meta["publisher"]),
                    JSONSupport.integer(meta["year"]),
                    JSONSupport.string(meta["edition"]),
                    JSONSupport.string(meta["isbn"]),
                    language,
                    JSONSupport.string(meta["textDirection"]) ?? "ltr",
                    JSONSupport.string(meta["copyright"]),
                    JSONSupport.string(meta["license"]),
                    JSONSupport.string(meta["version"]),
                    JSONSupport.string(meta["schemaVersion"]) ?? "1.0",
                    try JSONSupport.jsonString(meta["tags"]),
                    JSONSupport.string(meta["coverMediaId"]),
                    JSONSupport.bool(meta["isEditable"]) == true ? 1 : 0,
                    JSONSupport.integer(meta["created"]),
                    JSONSupport.integer(meta["lastModified"]),
                    try JSONSupport.jsonString(root["footnotes"]),
                    try JSONSupport.jsonString(root["media"]),
                ])

            var seenIDs = Set<String>()
            func insertSections(
                _ values: [Any],
                parentID: String?,
                depth: Int,
                basePath: String
            ) throws {
                for (arrayIndex, value) in values.enumerated() {
                    let path = "\(basePath)/\(arrayIndex)"
                    let section = try JSONSupport.requiredObject(value, path: path)
                    let sectionID = try JSONSupport.requiredString(section["id"], path: "\(path)/id")
                    guard seenIDs.insert(sectionID).inserted else {
                        throw ModuleCompilationError.invalidValue(
                            path: "\(path)/id",
                            expected: "an ID unique within the book"
                        )
                    }
                    let sectionType = try JSONSupport.requiredString(section["type"], path: "\(path)/type")
                    let sectionTitle = try JSONSupport.requiredString(section["title"], path: "\(path)/title")
                    let content = JSONSupport.array(section["content"]) ?? []
                    let children = JSONSupport.array(section["sections"]) ?? []
                    let storageID = "\(moduleID):\(sectionID)"
                    let number = JSONSupport.string(section["number"])
                        ?? JSONSupport.integer(section["number"]).map(String.init)
                    let subtitle = JSONSupport.string(section["subtitle"])
                    let searchText = [sectionTitle, subtitle, JSONSupport.plainText(content)]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")

                    try db.execute(sql: """
                        INSERT INTO book_sections (
                            id, module_id, section_id, parent_id, section_type,
                            number, title, subtitle, depth, order_index,
                            key_scriptures_json, content_json, search_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            storageID,
                            moduleID,
                            sectionID,
                            parentID,
                            sectionType,
                            number,
                            sectionTitle,
                            subtitle,
                            depth,
                            JSONSupport.integer(section["order"]) ?? arrayIndex,
                            try JSONSupport.jsonString(section["keyScriptures"]),
                            try JSONSupport.jsonString(content) ?? "[]",
                            searchText,
                        ])
                    sectionCount += 1

                    try insertSections(
                        children,
                        parentID: storageID,
                        depth: depth + 1,
                        basePath: "\(path)/sections"
                    )
                }
            }

            try insertSections(sections, parentID: nil, depth: 0, basePath: "/sections")
            try db.execute(sql: "INSERT INTO book_sections_fts(book_sections_fts) VALUES('rebuild')")
        }

        try optimize(queue)
        return ["book_modules": 1, "book_sections": sectionCount]
    }

    private func createBookSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE book_modules (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                subtitle TEXT,
                description TEXT,
                author TEXT,
                editor TEXT,
                publisher TEXT,
                year INTEGER,
                edition TEXT,
                isbn TEXT,
                language TEXT NOT NULL,
                text_direction TEXT NOT NULL DEFAULT 'ltr',
                copyright TEXT,
                license TEXT,
                version TEXT,
                schema_version TEXT NOT NULL,
                tags_json TEXT,
                cover_media_id TEXT,
                is_editable INTEGER NOT NULL DEFAULT 0,
                created INTEGER,
                last_modified INTEGER,
                footnotes_json TEXT,
                media_json TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE book_sections (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL REFERENCES book_modules(id) ON DELETE CASCADE,
                section_id TEXT NOT NULL,
                parent_id TEXT REFERENCES book_sections(id) ON DELETE CASCADE,
                section_type TEXT NOT NULL,
                number TEXT,
                title TEXT NOT NULL,
                subtitle TEXT,
                depth INTEGER NOT NULL,
                order_index INTEGER NOT NULL,
                key_scriptures_json TEXT,
                content_json TEXT NOT NULL,
                search_text TEXT NOT NULL DEFAULT '',
                UNIQUE(module_id, section_id)
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_book_sections_module ON book_sections(module_id)")
        try db.execute(sql: "CREATE INDEX idx_book_sections_parent ON book_sections(parent_id, order_index)")
        try db.execute(sql: "CREATE INDEX idx_book_sections_type ON book_sections(module_id, section_type)")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE book_sections_fts USING fts5(
                title,
                search_text,
                content='book_sections',
                content_rowid='rowid'
            )
            """)
    }
}
