import Foundation
import GRDB

extension LampModuleCompiler {
    func compileNotes(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let book = try JSONSupport.requiredString(root["book"], path: "/book")
        let bookNumber = try JSONSupport.requiredInteger(root["bookNumber"], path: "/bookNumber")
        let chapters = try JSONSupport.requiredArray(root["chapters"], path: "/chapters")
        let queue = try makeDatabaseQueue(at: databaseURL)
        var entryCount = 0

        try queue.write { db in
            try createNotesSchema(in: db)
            try createFormatMetadata(in: db, kind: .notes, moduleID: moduleID)

            try db.execute(sql: """
                INSERT INTO module_meta (
                    id, name, description, author, version, is_editable
                ) VALUES (?, ?, ?, ?, ?, 1)
                """, arguments: [
                    moduleID,
                    JSONSupport.string(meta["name"]) ?? "Notes",
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(meta["schemaVersion"]),
                ])
            try db.execute(sql: """
                INSERT INTO note_book_meta (module_id, book, book_number, media_json)
                VALUES (?, ?, ?, ?)
                """, arguments: [
                    moduleID,
                    book,
                    bookNumber,
                    try JSONSupport.jsonString(root["media"]),
                ])

            for (chapterIndex, chapterValue) in chapters.enumerated() {
                let chapterPath = "/chapters/\(chapterIndex)"
                let chapter = try JSONSupport.requiredObject(chapterValue, path: chapterPath)
                let chapterNumber = try JSONSupport.requiredInteger(
                    chapter["chapter"],
                    path: "\(chapterPath)/chapter"
                )

                if let introduction = chapter["introduction"],
                   JSONSupport.isMeaningful(introduction) {
                    let reference = bookNumber * 1_000_000 + chapterNumber * 1_000
                    let footnotes = JSONSupport.array(chapter["footnotes"])
                    try insertNoteEntry(
                        in: db,
                        id: "\(moduleID):\(reference)",
                        moduleID: moduleID,
                        reference: reference,
                        title: "Introduction",
                        contentValue: introduction,
                        endReference: nil,
                        lastModified: JSONSupport.integer(chapter["lastModified"]),
                        footnotes: footnotes
                    )
                    entryCount += 1
                }

                let verses = JSONSupport.array(chapter["verses"]) ?? []
                for (verseIndex, verseValue) in verses.enumerated() {
                    let versePath = "\(chapterPath)/verses/\(verseIndex)"
                    let verse = try JSONSupport.requiredObject(verseValue, path: versePath)
                    let startReference = try JSONSupport.requiredInteger(
                        verse["sv"],
                        path: "\(versePath)/sv"
                    )
                    let commentary = verse["commentary"]
                    guard let commentary, JSONSupport.isMeaningful(commentary) else {
                        throw ModuleCompilationError.missingValue(path: "\(versePath)/commentary")
                    }
                    try insertNoteEntry(
                        in: db,
                        id: "\(moduleID):\(startReference)",
                        moduleID: moduleID,
                        reference: startReference,
                        title: JSONSupport.string(verse["title"]),
                        contentValue: commentary,
                        endReference: JSONSupport.integer(verse["ev"]),
                        lastModified: JSONSupport.integer(verse["lastModified"]),
                        footnotes: JSONSupport.array(verse["footnotes"])
                    )
                    entryCount += 1
                }
            }

            try db.execute(sql: "INSERT INTO note_fts(note_fts) VALUES('rebuild')")
        }

        try optimize(queue)
        return [
            "module_meta": 1,
            "note_book_meta": 1,
            "note_entries": entryCount,
        ]
    }

    private func insertNoteEntry(
        in db: Database,
        id: String,
        moduleID: String,
        reference: Int,
        title: String?,
        contentValue: Any,
        endReference: Int?,
        lastModified: Int?,
        footnotes: [Any]?
    ) throws {
        let content = JSONSupport.plainText(contentValue)
        let verseReferences = endReference.map { [$0] }
        let footnoteText = (footnotes ?? [])
            .compactMap(JSONSupport.object)
            .map { JSONSupport.plainText($0["content"]) }
            .filter { !$0.isEmpty }
        let searchText = ([content] + footnoteText).joined(separator: " ")

        try db.execute(sql: """
            INSERT INTO note_entries (
                id, module_id, verse_id, book, chapter, verse,
                title, content, verse_refs_json, last_modified,
                footnotes_json, search_text, record_change_tag
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """, arguments: [
                id,
                moduleID,
                reference,
                reference / 1_000_000,
                (reference / 1_000) % 1_000,
                reference % 1_000,
                title,
                content,
                try JSONSupport.jsonString(verseReferences),
                lastModified,
                try JSONSupport.jsonString(footnotes),
                searchText,
            ])
    }

    private func createNotesSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE module_meta (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                author TEXT,
                version TEXT,
                is_editable INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE note_book_meta (
                module_id TEXT PRIMARY KEY REFERENCES module_meta(id) ON DELETE CASCADE,
                book TEXT NOT NULL,
                book_number INTEGER NOT NULL,
                media_json TEXT
            );
            CREATE TABLE note_entries (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL,
                verse_id INTEGER NOT NULL,
                book INTEGER NOT NULL,
                chapter INTEGER NOT NULL,
                verse INTEGER NOT NULL,
                title TEXT,
                content TEXT NOT NULL,
                verse_refs_json TEXT,
                last_modified INTEGER,
                footnotes_json TEXT,
                search_text TEXT,
                record_change_tag TEXT
            );
            CREATE INDEX idx_note_module ON note_entries(module_id);
            CREATE INDEX idx_note_verse ON note_entries(verse_id);
            CREATE INDEX idx_note_chapter ON note_entries(book, chapter, verse);
            CREATE VIRTUAL TABLE note_fts USING fts5(
                title, search_text,
                content='note_entries', content_rowid='rowid'
            );
            """)
    }
}
