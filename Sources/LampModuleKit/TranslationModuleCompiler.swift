import Foundation
import GRDB

extension LampModuleCompiler {
    func compileTranslation(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let books = try JSONSupport.requiredArray(root["books"], path: "/books")
        let queue = try makeDatabaseQueue(at: databaseURL)
        var verseCount = 0
        var headingCount = 0

        try queue.write { db in
            try createTranslationSchema(in: db)
            try createFormatMetadata(in: db, kind: .translation, moduleID: moduleID)

            try db.execute(
                sql: """
                    INSERT INTO translation_meta (
                        id, name, abbreviation, description, language, language_name,
                        text_direction, translation_philosophy, year, publisher,
                        copyright, copyright_year, license, source_texts_json,
                        features_json, versification
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    moduleID,
                    try JSONSupport.requiredString(meta["name"], path: "/meta/name"),
                    try JSONSupport.requiredString(meta["abbreviation"], path: "/meta/abbreviation"),
                    JSONSupport.string(meta["description"]),
                    try JSONSupport.requiredString(meta["language"], path: "/meta/language"),
                    JSONSupport.string(meta["languageName"]),
                    JSONSupport.string(meta["textDirection"]) ?? "ltr",
                    JSONSupport.string(meta["translationPhilosophy"]),
                    JSONSupport.integer(meta["year"]),
                    JSONSupport.string(meta["publisher"]),
                    JSONSupport.string(meta["copyright"]),
                    JSONSupport.integer(meta["copyrightYear"]),
                    JSONSupport.string(meta["license"]),
                    try JSONSupport.jsonString(meta["sourceTexts"]),
                    try JSONSupport.jsonString(meta["features"]),
                    JSONSupport.string(meta["versification"]) ?? "standard",
                ]
            )

            for (bookIndex, bookValue) in books.enumerated() {
                let bookPath = "/books/\(bookIndex)"
                let book = try JSONSupport.requiredObject(bookValue, path: bookPath)
                let bookNumber = try JSONSupport.requiredInteger(book["number"], path: "\(bookPath)/number")
                let chapters = try JSONSupport.requiredArray(book["chapters"], path: "\(bookPath)/chapters")

                try db.execute(
                    sql: "INSERT INTO books (id, book_id, name, testament, chapter_count) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        bookNumber,
                        try JSONSupport.requiredString(book["id"], path: "\(bookPath)/id"),
                        try JSONSupport.requiredString(book["name"], path: "\(bookPath)/name"),
                        try JSONSupport.requiredString(book["testament"], path: "\(bookPath)/testament"),
                        chapters.count,
                    ]
                )

                for (chapterIndex, chapterValue) in chapters.enumerated() {
                    let chapterPath = "\(bookPath)/chapters/\(chapterIndex)"
                    let chapter = try JSONSupport.requiredObject(chapterValue, path: chapterPath)
                    let chapterNumber = try JSONSupport.requiredInteger(chapter["chapter"], path: "\(chapterPath)/chapter")

                    for (headingIndex, headingValue) in (JSONSupport.array(chapter["headings"]) ?? []).enumerated() {
                        let headingPath = "\(chapterPath)/headings/\(headingIndex)"
                        let heading = try JSONSupport.requiredObject(headingValue, path: headingPath)
                        try db.execute(
                            sql: "INSERT INTO headings (book, chapter, before_verse, level, text) VALUES (?, ?, ?, ?, ?)",
                            arguments: [
                                bookNumber,
                                chapterNumber,
                                try JSONSupport.requiredInteger(heading["beforeVerse"], path: "\(headingPath)/beforeVerse"),
                                JSONSupport.integer(heading["level"]) ?? 1,
                                try JSONSupport.requiredString(heading["text"], path: "\(headingPath)/text"),
                            ]
                        )
                        headingCount += 1
                    }

                    let verses = try JSONSupport.requiredArray(chapter["verses"], path: "\(chapterPath)/verses")
                    for (verseIndex, verseValue) in verses.enumerated() {
                        let versePath = "\(chapterPath)/verses/\(verseIndex)"
                        let verse = try JSONSupport.requiredObject(verseValue, path: versePath)
                        let verseNumber = try JSONSupport.requiredInteger(verse["v"], path: "\(versePath)/v")
                        let reference = JSONSupport.integer(verse["ref"])
                            ?? bookNumber * 1_000_000 + chapterNumber * 1_000 + verseNumber

                        let content = verse["content"]
                        let text: String
                        let annotations: Any?
                        let footnoteReferences: Any?
                        if let contentObject = JSONSupport.object(content) {
                            text = try JSONSupport.requiredString(contentObject["text"], path: "\(versePath)/content/text")
                            annotations = contentObject["annotations"]
                            footnoteReferences = contentObject["footnoteRefs"] ?? contentObject["footnote_refs"]
                        } else {
                            text = try JSONSupport.requiredString(content, path: "\(versePath)/content")
                            annotations = nil
                            footnoteReferences = nil
                        }

                        try db.execute(
                            sql: """
                                INSERT INTO verses (
                                    ref, book, chapter, verse, text, annotations_json,
                                    footnotes_json, footnote_refs_json, paragraph, poetry_json
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                reference,
                                bookNumber,
                                chapterNumber,
                                verseNumber,
                                text,
                                try JSONSupport.jsonString(annotations),
                                try JSONSupport.jsonString(verse["footnotes"]),
                                try JSONSupport.jsonString(footnoteReferences),
                                JSONSupport.bool(verse["paragraph"]) == true ? 1 : 0,
                                try JSONSupport.jsonString(verse["poetry"]),
                            ]
                        )
                        verseCount += 1
                    }
                }
            }

            try db.execute(sql: "INSERT INTO verses_fts(verses_fts) VALUES('rebuild')")
        }

        try optimize(queue)
        return [
            "translation_meta": 1,
            "books": books.count,
            "verses": verseCount,
            "headings": headingCount,
        ]
    }

    private func createTranslationSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE translation_meta (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                abbreviation TEXT NOT NULL,
                description TEXT,
                language TEXT NOT NULL,
                language_name TEXT,
                text_direction TEXT NOT NULL DEFAULT 'ltr',
                translation_philosophy TEXT,
                year INTEGER,
                publisher TEXT,
                copyright TEXT,
                copyright_year INTEGER,
                license TEXT,
                source_texts_json TEXT,
                features_json TEXT,
                versification TEXT DEFAULT 'standard'
            )
            """)
        try db.execute(sql: """
            CREATE TABLE books (
                id INTEGER PRIMARY KEY,
                book_id TEXT NOT NULL,
                name TEXT NOT NULL,
                testament TEXT NOT NULL,
                chapter_count INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE verses (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ref INTEGER NOT NULL UNIQUE,
                book INTEGER NOT NULL,
                chapter INTEGER NOT NULL,
                verse INTEGER NOT NULL,
                text TEXT NOT NULL,
                annotations_json TEXT,
                footnotes_json TEXT,
                footnote_refs_json TEXT,
                paragraph INTEGER DEFAULT 0,
                poetry_json TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_verses_ref ON verses(ref)")
        try db.execute(sql: "CREATE INDEX idx_verses_book_chapter ON verses(book, chapter)")
        try db.execute(sql: """
            CREATE TABLE headings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book INTEGER NOT NULL,
                chapter INTEGER NOT NULL,
                before_verse INTEGER NOT NULL,
                level INTEGER NOT NULL DEFAULT 1,
                text TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_headings_chapter ON headings(book, chapter)")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE verses_fts USING fts5(
                text,
                content='verses',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER verses_fts_insert AFTER INSERT ON verses BEGIN
                INSERT INTO verses_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)
    }
}
