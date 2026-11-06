import Foundation
import GRDB

/// A dictionary entry a search found, as its database keeps it.
public struct LampDictionarySearchHit: Equatable, Sendable {
    public let entryID: String
    public let moduleID: String
    public let key: String
    public let lemma: String
    public let transliteration: String?
    public let pronunciation: String?
    public let sensesJSON: String?
    /// Its definitions as text, where its database keeps them so.
    public let searchText: String?
}

extension LampModuleSearch {
    /// Dictionary entries matching `query` in `db`, at most `limit` from each
    /// dictionary searched: the one whose key, then whose headword, is what
    /// was typed first, then by key. Matched in the key, headword,
    /// transliteration and definitions, never the senses' field names, and
    /// kept by the query's own rule; a query in Greek or Hebrew also against
    /// each headword with accents and points set aside, which SQLite can't
    /// do. A dictionary's module file holds it alone, and answers as
    /// `dictionaries`' one; a database of several, as the bundle's and the
    /// phone's do, answers for each named, or every one in it.
    public static func dictionaryEntries(
        in db: Database,
        dictionaries: [String]?,
        query: LampSearchQuery,
        limit: Int
    ) throws -> [LampDictionarySearchHit] {
        guard limit > 0, !query.isEmpty, !query.plainText.isEmpty, dictionaries?.isEmpty != true,
              try LampModuleText.tableNames(in: db).contains("dictionary_entries") else { return [] }
        let columns = try LampModuleText.columnNames(in: db, table: "dictionary_entries")
        guard columns.contains("senses_json") else { return [] }
        let shared = columns.contains("module_id")
        let modules: [String?]
        if shared {
            modules = try dictionaries ?? String.fetchAll(db, sql: "SELECT DISTINCT module_id FROM dictionary_entries ORDER BY module_id")
        } else {
            // One dictionary, whatever it's called.
            modules = [dictionaries?.first]
        }
        let searchColumns = ["key", "lemma", "transliteration", "search_text"].filter(columns.contains)
        let like = query.sqlLikePredicate(columns: searchColumns, jsonColumns: ["senses_json"])
        let typed = query.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let inOriginalLanguage = typed.unicodeScalars.contains(where: isGreekOrHebrew)
        let pronunciation = columns.contains("pronunciation") ? "pronunciation" : "NULL AS pronunciation"
        let searchText = columns.contains("search_text") ? "search_text" : "NULL AS search_text"

        var hits: [LampDictionarySearchHit] = []
        for module in modules {
            let moduleCondition = shared ? "module_id = ? AND" : ""
            let moduleArguments: StatementArguments = shared ? [module] : []
            var condition = "(\(like.condition))"
            var arguments = moduleArguments
            arguments += StatementArguments(like.arguments)
            if inOriginalLanguage {
                let ids = try headwordMatches(for: query, in: db, condition: moduleCondition, arguments: moduleArguments)
                if !ids.isEmpty {
                    condition = "(\(condition) OR id IN (\(ids.map { _ in "?" }.joined(separator: ", "))))"
                    arguments += StatementArguments(ids)
                }
            }
            arguments += [typed, typed]
            // Found anywhere by LIKE, and kept where the query's own rule
            // finds the words, as every other search keeps them.
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, \(shared ? "module_id" : "NULL AS module_id"), key, lemma, transliteration,
                       \(pronunciation), senses_json, \(searchText)
                FROM dictionary_entries
                WHERE \(moduleCondition) \(condition)
                ORDER BY
                    CASE
                        WHEN key = ? COLLATE NOCASE THEN 0
                        WHEN lemma = ? COLLATE NOCASE THEN 1
                        ELSE 2
                    END,
                    key, lemma
                """, arguments: arguments)
            var kept = 0
            while kept < limit, let row = try rows.next() {
                let key: String = row["key"] ?? ""
                let lemma: String = row["lemma"] ?? ""
                let transliteration: String? = row["transliteration"]
                let definitions: String? = row["search_text"]
                let sensesJSON: String? = row["senses_json"]
                // The senses' words too, as LIKE found them: a derivation, say,
                // which the definitions' text leaves out.
                let text = [key, lemma, transliteration, definitions, LampModuleText.plainText(fromJSONString: sensesJSON)]
                    .compactMap { $0 }.joined(separator: " ")
                guard query.matches(text) else { continue }
                let idValue: DatabaseValue = row["id"]
                let moduleID: String = row["module_id"] ?? module ?? ""
                hits.append(LampDictionarySearchHit(
                    entryID: String.fromDatabaseValue(idValue)
                        ?? Int64.fromDatabaseValue(idValue).map(String.init)
                        ?? "\(moduleID):\(key)",
                    moduleID: moduleID, key: key, lemma: lemma, transliteration: transliteration,
                    pronunciation: row["pronunciation"], sensesJSON: sensesJSON, searchText: definitions
                ))
                kept += 1
            }
        }
        return hits
    }

    /// The entries whose headword matches, among those holding every word of
    /// the query once its accents, points, case and apostrophes are folded
    /// away, which the query's own rule then confirms: run over every
    /// headword, it was too slow.
    private static func headwordMatches(
        for query: LampSearchQuery,
        in db: Database,
        condition: String,
        arguments: StatementArguments
    ) throws -> [DatabaseValue] {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { !"'’‘ʼ".contains($0) }
        }
        let words = query.plainText.split(whereSeparator: \.isWhitespace).map { folded(String($0)) }.filter { !$0.isEmpty }
        var headwordArguments = arguments
        headwordArguments += [""]
        return try Row.fetchAll(db, sql: """
            SELECT id, key, lemma, transliteration FROM dictionary_entries
            WHERE \(condition) COALESCE(lemma, '') <> ?
            """, arguments: headwordArguments).compactMap { row in
                let text = [row["key"], row["lemma"], row["transliteration"]]
                    .compactMap { $0 as String? }.joined(separator: " ")
                let headword = folded(text)
                guard words.allSatisfy({ headword.contains($0) }), query.matches(text) else { return nil }
                return row["id"]
            }
    }

    /// Greek, including its extended accented letters, or Hebrew.
    static func isGreekOrHebrew(_ scalar: Unicode.Scalar) -> Bool {
        (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
            || (0x0590...0x05FF).contains(scalar.value)
    }
}
