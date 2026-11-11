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

        // No senses: the one sense is made from the entry's own fields, and
        // this list stays a selection rather than becoming a pass-through —
        // an entry holds `key`, `lemma` and `transliteration` too, which are
        // the entry's and not the sense's. Every field the schema puts on a
        // sense is reachable through `senses`, which is where an author
        // writing one would put it.

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

    /// The spellings this format has accepted for one sense field over time.
    /// The first key present wins, and the value is stored under the first
    /// name, so a reader has one name to look for.
    private static let senseKeySpellings: [[String]] = [
        ["definition", "def"],
        ["shortDefinition", "short_definition"],
        ["partOfSpeech", "part_of_speech"],
        ["usage"],
        ["derivation"],
        ["gloss"],
        ["references"],
        ["translationUsages", "translation_usages"],
    ]

    /// A sense as the reader will see it: **the author's own object**, with
    /// those alternate spellings folded onto one name and `id` made a string.
    ///
    /// It used to be rebuilt from a list of eight keys, which dropped
    /// everything else the author wrote. `septuagintHebrew` — the Hebrew a
    /// Greek word renders, a published field of `sense` — was among them, so
    /// a compiled lexicon carried none of it while the bundled copy, written
    /// by a different tool, did; `LampStrongsAnalysisPresentation` reads it,
    /// so the two were not interchangeable. A whitelist here is a second,
    /// narrower contract than the published schema, declared nowhere and
    /// impossible to notice from either side. The schema decides what a sense
    /// may hold; this carries what it holds.
    ///
    /// Carrying unknown keys is safe to store: every value came from
    /// `JSONSerialization`, and `JSONSupport.jsonString` sorts keys, so the
    /// bytes stay the same for the same source (`LampModuleDeterminismTests`).
    private func normalizedSense(_ source: [String: Any]) -> [String: Any] {
        var sense = source
        for spellings in Self.senseKeySpellings {
            let value = JSONSupport.firstValue(in: source, keys: spellings)
            for spelling in spellings { sense.removeValue(forKey: spelling) }
            if let value { sense[spellings[0]] = value }
        }

        if let id = JSONSupport.string(source["id"]) {
            sense["id"] = id
        } else if let id = JSONSupport.integer(source["id"]) {
            sense["id"] = String(id)
        } else {
            // As before: an id of any other shape is no id.
            sense.removeValue(forKey: "id")
        }
        // A key explicitly null says nothing, and reaching the file would
        // make a sense that differs from one where it was left out.
        return sense.filter { !($0.value is NSNull) }
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
