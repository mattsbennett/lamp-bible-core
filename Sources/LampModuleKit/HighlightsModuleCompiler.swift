import Foundation
import GRDB

extension LampModuleCompiler {
    func compileHighlights(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let verses = try JSONSupport.requiredArray(root["verses"], path: "/verses")
        let translationID = try JSONSupport.requiredString(
            meta["translationId"],
            path: "/meta/translationId"
        )
        let themes = JSONSupport.array(meta["themes"]) ?? []
        let queue = try makeDatabaseQueue(at: databaseURL)
        var highlightCount = 0

        try queue.write { db in
            try createHighlightsSchema(in: db)
            try createFormatMetadata(in: db, kind: .highlights, moduleID: moduleID)

            try db.execute(sql: """
                INSERT INTO highlight_meta (
                    id, name, description, translation_id, created, last_modified
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    moduleID,
                    JSONSupport.string(meta["name"]) ?? "Highlights",
                    JSONSupport.string(meta["description"]),
                    translationID,
                    JSONSupport.integer(meta["created"]),
                    JSONSupport.integer(meta["lastModified"]),
                ])

            for (verseIndex, verseValue) in verses.enumerated() {
                let versePath = "/verses/\(verseIndex)"
                let verse = try JSONSupport.requiredObject(verseValue, path: versePath)
                let reference = try JSONSupport.requiredInteger(
                    verse["ref"],
                    path: "\(versePath)/ref"
                )
                let highlights = try JSONSupport.requiredArray(
                    verse["highlights"],
                    path: "\(versePath)/highlights"
                )
                for (highlightIndex, highlightValue) in highlights.enumerated() {
                    let path = "\(versePath)/highlights/\(highlightIndex)"
                    let highlight = try JSONSupport.requiredObject(highlightValue, path: path)
                    try db.execute(sql: """
                        INSERT INTO highlights (ref, sc, ec, style, color)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [
                            reference,
                            try JSONSupport.requiredInteger(highlight["sc"], path: "\(path)/sc"),
                            try JSONSupport.requiredInteger(highlight["ec"], path: "\(path)/ec"),
                            try JSONSupport.requiredInteger(highlight["style"], path: "\(path)/style"),
                            normalizedHighlightColor(JSONSupport.string(highlight["color"])),
                        ])
                    highlightCount += 1
                }
            }

            for (themeIndex, themeValue) in themes.enumerated() {
                let path = "/meta/themes/\(themeIndex)"
                let theme = try JSONSupport.requiredObject(themeValue, path: path)
                try db.execute(sql: """
                    INSERT INTO highlight_themes (color, style, name, description)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [
                        normalizedHighlightColor(try JSONSupport.requiredString(
                            theme["color"],
                            path: "\(path)/color"
                        )),
                        try JSONSupport.requiredInteger(theme["style"], path: "\(path)/style"),
                        try JSONSupport.requiredString(theme["name"], path: "\(path)/name"),
                        JSONSupport.string(theme["description"]),
                    ])
            }
        }

        try optimize(queue)
        return [
            "highlight_meta": 1,
            "highlights": highlightCount,
            "highlight_themes": themes.count,
        ]
    }

    private func normalizedHighlightColor(_ color: String?) -> String? {
        guard var color else { return nil }
        if color.hasPrefix("#") { color.removeFirst() }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let isHex = [6, 8].contains(color.count)
            && color.unicodeScalars.allSatisfy(hexDigits.contains)
        return isHex ? color.uppercased() : color
    }

    private func createHighlightsSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE highlight_meta (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                translation_id TEXT NOT NULL,
                created INTEGER,
                last_modified INTEGER
            );
            CREATE TABLE highlights (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ref INTEGER NOT NULL,
                sc INTEGER NOT NULL,
                ec INTEGER NOT NULL,
                style INTEGER NOT NULL DEFAULT 0,
                color TEXT
            );
            CREATE INDEX idx_highlights_ref ON highlights(ref, sc);
            CREATE TABLE highlight_themes (
                color TEXT NOT NULL,
                style INTEGER NOT NULL,
                name TEXT NOT NULL,
                description TEXT,
                PRIMARY KEY (color, style)
            );
            """)
    }
}
