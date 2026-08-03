import Foundation
import GRDB

extension LampModuleCompiler {
    func compileDictionary(
        root: [String: Any],
        databaseURL: URL,
        moduleID: String
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(root["meta"], path: "/meta")
        let entries = try JSONSupport.requiredArray(root["entries"], path: "/entries")
        let queue = try makeDatabaseQueue(at: databaseURL)

        try queue.write { db in
            try createDictionarySchema(in: db)
            try createFormatMetadata(in: db, kind: .dictionary, moduleID: moduleID)
            try db.execute(
                sql: """
                    INSERT INTO module_metadata (
                        id, name, description, author, version, key_type,
                        schema_version, type, series_abbrev, series_full,
                        editor, publisher, year, isbn, language
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    moduleID,
                    try JSONSupport.requiredString(meta["name"], path: "/meta/name"),
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["author"]),
                    JSONSupport.string(root["version"]) ?? JSONSupport.string(meta["version"]),
                    JSONSupport.string(meta["keyType"]),
                    JSONSupport.string(meta["schemaVersion"]),
                    JSONSupport.string(meta["type"]),
                    JSONSupport.string(meta["seriesAbbrev"]),
                    JSONSupport.string(meta["seriesFull"]),
                    JSONSupport.string(meta["editor"]),
                    JSONSupport.string(meta["publisher"]),
                    JSONSupport.integer(meta["year"]),
                    JSONSupport.string(meta["isbn"]),
                    JSONSupport.string(meta["language"]),
                ]
            )

            for (index, entryValue) in entries.enumerated() {
                let path = "/entries/\(index)"
                let entry = try JSONSupport.requiredObject(entryValue, path: path)
                let key = try JSONSupport.requiredString(entry["key"], path: "\(path)/key")
                let senses = normalizedSenses(for: entry)
                let metadata = dictionaryMetadata(for: entry)
                let searchText = senses
                    .flatMap { sense -> [String] in
                        var parts = [
                            JSONSupport.plainText(sense["definition"]),
                            JSONSupport.plainText(sense["shortDefinition"]),
                        ]
                        if let gloss = JSONSupport.string(sense["gloss"]) { parts.append(gloss) }
                        return parts
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                try db.execute(
                    sql: """
                        INSERT INTO dictionary_entries (
                            id, module_id, key, lemma, transliteration, pronunciation,
                            senses_json, metadata_json, search_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "\(moduleID):\(key)",
                        moduleID,
                        key,
                        JSONSupport.string(entry["lemma"]) ?? "",
                        JSONSupport.string(entry["transliteration"]),
                        JSONSupport.string(entry["pronunciation"]),
                        try JSONSupport.jsonString(senses),
                        try JSONSupport.jsonString(metadata),
                        searchText,
                    ]
                )
            }
        }

        try optimize(queue)
        return ["module_metadata": 1, "dictionary_entries": entries.count]
    }

    private func createDictionarySchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE module_metadata (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                author TEXT,
                version TEXT,
                key_type TEXT,
                schema_version TEXT,
                type TEXT,
                series_abbrev TEXT,
                series_full TEXT,
                editor TEXT,
                publisher TEXT,
                year INTEGER,
                isbn TEXT,
                language TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE dictionary_entries (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL,
                key TEXT NOT NULL,
                lemma TEXT NOT NULL,
                transliteration TEXT,
                pronunciation TEXT,
                senses_json TEXT,
                metadata_json TEXT,
                search_text TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_dict_module ON dictionary_entries(module_id)")
        try db.execute(sql: "CREATE INDEX idx_dict_key ON dictionary_entries(key)")
        try db.execute(sql: "CREATE INDEX idx_dict_lemma ON dictionary_entries(lemma)")
    }

    private func normalizedSenses(for entry: [String: Any]) -> [[String: Any]] {
        if let sourceSenses = JSONSupport.array(entry["senses"]), !sourceSenses.isEmpty {
            return sourceSenses.compactMap(JSONSupport.object).map(normalizedSense)
        }

        var sense: [String: Any] = [:]
        copyFirstValue(from: entry, keys: ["definition", "def"], to: "definition", in: &sense)
        copyFirstValue(from: entry, keys: ["shortDefinition", "short_definition"], to: "shortDefinition", in: &sense)
        copyFirstValue(from: entry, keys: ["partOfSpeech", "part_of_speech"], to: "partOfSpeech", in: &sense)
        copyFirstValue(from: entry, keys: ["usage"], to: "usage", in: &sense)
        copyFirstValue(from: entry, keys: ["derivation"], to: "derivation", in: &sense)
        copyFirstValue(from: entry, keys: ["gloss"], to: "gloss", in: &sense)
        copyFirstValue(from: entry, keys: ["references"], to: "references", in: &sense)
        copyFirstValue(from: entry, keys: ["translationUsages", "translation_usages"], to: "translationUsages", in: &sense)

        guard sense["definition"] != nil || sense["shortDefinition"] != nil else { return [] }
        return [sense]
    }

    private func normalizedSense(_ source: [String: Any]) -> [String: Any] {
        var sense: [String: Any] = [:]
        copyFirstValue(from: source, keys: ["definition", "def"], to: "definition", in: &sense)
        copyFirstValue(from: source, keys: ["shortDefinition", "short_definition"], to: "shortDefinition", in: &sense)
        copyFirstValue(from: source, keys: ["partOfSpeech", "part_of_speech"], to: "partOfSpeech", in: &sense)
        copyFirstValue(from: source, keys: ["usage"], to: "usage", in: &sense)
        copyFirstValue(from: source, keys: ["derivation"], to: "derivation", in: &sense)
        copyFirstValue(from: source, keys: ["gloss"], to: "gloss", in: &sense)
        copyFirstValue(from: source, keys: ["references"], to: "references", in: &sense)
        copyFirstValue(from: source, keys: ["translationUsages", "translation_usages"], to: "translationUsages", in: &sense)

        if let id = JSONSupport.string(source["id"]) {
            sense["id"] = id
        } else if let id = JSONSupport.integer(source["id"]) {
            sense["id"] = String(id)
        }
        return sense
    }

    private func copyFirstValue(
        from source: [String: Any],
        keys: [String],
        to destinationKey: String,
        in destination: inout [String: Any]
    ) {
        if let value = JSONSupport.firstValue(in: source, keys: keys) {
            destination[destinationKey] = value
        }
    }

    private func dictionaryMetadata(for entry: [String: Any]) -> [String: Any] {
        let standardFields: Set<String> = [
            "key", "lemma", "transliteration", "pronunciation", "senses",
            "definition", "def", "shortDefinition", "short_definition",
            "partOfSpeech", "part_of_speech", "usage", "derivation", "gloss",
            "references", "translationUsages", "translation_usages",
        ]
        return entry.filter { !standardFields.contains($0.key) }
    }
}
