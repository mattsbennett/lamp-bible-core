import Foundation
import GRDB

/// A module a search covers: its ID, as a database holding several modules
/// keeps it in `module_id`, and the name its results show.
public struct LampSearchedModule: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Searches over module databases, whichever app holds them and however. The
/// Mac's library keeps each module in a file of its own, and the bundled ones
/// together; the phone keeps every module it installs in one database, with a
/// `module_id` on each row. Each app chooses the databases and the modules in
/// them; what matches, which rows come first and how a result reads are
/// decided here, once for both.
public enum LampModuleSearch {
    /// How much a match counts toward a commentary unit's rank by the column
    /// it falls in: a unit named for the words before one whose text uses
    /// them, and that before one whose footnotes do, since a unit's text is
    /// what its result shows first. A column not named here counts as text.
    static let commentaryColumnWeights: [String: Double] = [
        "title": 5,
        "search_text": 1,
        "footnotes_text": 0.5,
    ]

    /// Commentary units matching `query` in `db`, at most `limit` of them.
    ///
    /// With an index of title, text and footnotes, the best-ranked units are
    /// the ones taken. An older module's index, without its footnotes, or a
    /// module without an index, gives its units in reading order: a match
    /// found by `LIKE` has no rank.
    ///
    /// Without `snippets`, each result's snippet is left empty, for
    /// `commentarySnippets` to cut once a merge has chosen the results kept:
    /// cutting one for every unit each database offers, most of them then
    /// dropped, was most of a search's time.
    public static func commentary(
        in db: Database,
        modules: [LampSearchedModule],
        query: LampSearchQuery,
        limit: Int,
        snippets: Bool = true
    ) throws -> [LampModuleSearchResult] {
        guard limit > 0, !modules.isEmpty, !query.isEmpty, !query.plainText.isEmpty else { return [] }
        let tables = try LampModuleText.tableNames(in: db)
        guard tables.contains("commentary_units") else { return [] }
        let columns = try LampModuleText.columnNames(in: db, table: "commentary_units")
        let hasSearchText = columns.contains("search_text")
        let hasFootnotesText = columns.contains("footnotes_text")
        let hasFTS = tables.contains("commentary_units_fts") && !query.fts5Query.isEmpty
        let ftsColumns = hasFTS ? try LampModuleText.orderedColumnNames(in: db, table: "commentary_units_fts") : []
        let fullFTS = hasFootnotesText && ftsColumns.contains("footnotes_text")
        // A database holding several modules answers for the ones asked
        // about. A module's own file holds only it.
        let sharesDatabase = columns.contains("module_id")
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if fullFTS {
            conditions.append("commentary_units_fts MATCH ?")
            arguments += [query.fts5Query]
        }
        if sharesDatabase {
            conditions.append("u.module_id IN (\(modules.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(modules.map(\.id))
        }
        if fullFTS {
            // Matched above, in the same query as the modules and before the
            // limit, so a database of several loses none of their units.
        } else if hasFTS {
            // Old indexes omit footnotes. Each term can occur in either the
            // indexed body or the notes, including mixed queries with terms
            // split between the two.
            for term in query.terms {
                let single = LampSearchQuery(term.isExact ? "\"" + term.text + "\"" : term.text)
                let notes = single.sqlLikePredicate(columns: [], jsonColumns: ["u.footnotes_json"])
                if single.fts5Query.isEmpty {
                    conditions.append(notes.condition)
                    arguments += StatementArguments(notes.arguments)
                } else {
                    conditions.append("(u.rowid IN (SELECT rowid FROM commentary_units_fts WHERE commentary_units_fts MATCH ?) OR \(notes.condition))")
                    arguments += [single.fts5Query]
                    arguments += StatementArguments(notes.arguments)
                }
            }
        } else {
            let like = hasSearchText
                ? query.sqlLikePredicate(columns: ["u.title", "u.search_text"], jsonColumns: ["u.footnotes_json"])
                : query.sqlLikePredicate(columns: ["u.title"], jsonColumns: [
                    "u.introduction_json", "u.translation_json", "u.commentary_json", "u.footnotes_json",
                ])
            conditions.append(like.condition)
            arguments += StatementArguments(like.arguments)
        }

        let module = sharesDatabase ? "u.module_id" : "NULL AS module_id"
        // The units' text, where it is needed now: to check a match found
        // without the index, or to cut snippets.
        let readsText = snippets || !fullFTS
        let text = readsText
            ? ", " + commentaryTextColumns(hasSearchText: hasSearchText, hasFootnotesText: hasFootnotesText)
            : ""
        let source: String
        let order: String
        var limitClause = ""
        if fullFTS {
            let weights = ftsColumns
                .map { LampModuleText.number(commentaryColumnWeights[$0] ?? 1) }
                .joined(separator: ", ")
            source = "commentary_units_fts JOIN commentary_units u ON u.rowid = commentary_units_fts.rowid"
            order = "bm25(commentary_units_fts, \(weights)), u.rowid"
            // Every condition is in the SQL, so the limit can be too.
            limitClause = "LIMIT ?"
            arguments += [limit]
        } else {
            source = "commentary_units u"
            order = "u.book, u.chapter, u.order_index, u.rowid"
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT u.id, \(module), u.sv, u.ev, u.title\(text)
            FROM \(source)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            \(limitClause)
            """, arguments: arguments)

        var found: [LampModuleSearchResult] = []
        while found.count < limit, let row = try rows.next() {
            var snippet = ""
            if readsText {
                let texts = commentaryTexts(
                    of: row, hasSearchText: hasSearchText, hasFootnotesText: hasFootnotesText, query: query
                )
                if !fullFTS {
                    let title: String = row["title"] ?? ""
                    guard query.matchesWordPrefixes(title + " " + texts.searched) else { continue }
                }
                if snippets { snippet = query.markedSnippet(texts.shown) }
            }
            let moduleID: String = sharesDatabase ? row["module_id"] : modules[0].id
            let start: Int = row["sv"]
            let end: Int? = row["ev"]
            let title: String? = row["title"]
            found.append(LampModuleSearchResult(
                id: "commentary:\(moduleID):\(row["id"] as String)",
                kind: .commentary, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                title: title?.isEmpty == false ? title! : LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                subtitle: LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                snippet: snippet, startReference: start, endReference: end
            ))
        }
        return found
    }

    /// The snippets of commentary results found without them, read again
    /// from the database they were found in.
    public static func commentarySnippets(
        for results: [LampModuleSearchResult],
        in db: Database,
        query: LampSearchQuery
    ) throws -> [LampModuleSearchResult] {
        guard !results.isEmpty else { return results }
        let columns = try LampModuleText.columnNames(in: db, table: "commentary_units")
        let hasSearchText = columns.contains("search_text")
        let hasFootnotesText = columns.contains("footnotes_text")
        let byModule = columns.contains("module_id") ? " AND u.module_id = ?" : ""
        let sql = """
            SELECT \(commentaryTextColumns(hasSearchText: hasSearchText, hasFootnotesText: hasFootnotesText))
            FROM commentary_units u
            WHERE u.id = ?\(byModule)
            """
        return try results.map { result in
            let unit = String(result.id.dropFirst("commentary:\(result.moduleID):".count))
            let arguments: StatementArguments = byModule.isEmpty ? [unit] : [unit, result.moduleID]
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return result }
            let texts = commentaryTexts(
                of: row, hasSearchText: hasSearchText, hasFootnotesText: hasFootnotesText, query: query
            )
            return result.withSnippet(query.markedSnippet(texts.shown))
        }
    }

    /// The columns a unit's text is read from: its search projection where it
    /// has one, else its JSON.
    private static func commentaryTextColumns(hasSearchText: Bool, hasFootnotesText: Bool) -> String {
        let body = hasSearchText ? "u.search_text" : "NULL AS search_text"
        let notes = hasFootnotesText ? "u.footnotes_text" : "NULL AS footnotes_text"
        let legacyBody = hasSearchText ? "" : ", u.introduction_json, u.translation_json, u.commentary_json"
        let legacyNotes = hasFootnotesText ? "" : ", u.footnotes_json"
        // The projection keeps legacy-font source spellings. Only
        // return/decode body JSON when Unicode replacement spans
        // are actually present; ordinary previews stay text-only.
        let encodedBody = hasSearchText ? """
            , CASE WHEN instr(u.introduction_json, '"sourceEncoding"') > 0
                     OR instr(u.translation_json, '"sourceEncoding"') > 0
                     OR instr(u.commentary_json, '"sourceEncoding"') > 0
              THEN '[' || COALESCE(u.introduction_json, 'null') || ','
                       || COALESCE(u.translation_json, 'null') || ','
                       || COALESCE(u.commentary_json, 'null') || ']'
              END AS encoded_body_json
            """ : ", NULL AS encoded_body_json"
        let encodedNotes = hasFootnotesText ? """
            , CASE WHEN instr(u.footnotes_json, '"sourceEncoding"') > 0
              THEN u.footnotes_json END AS encoded_footnotes_json
            """ : ", NULL AS encoded_footnotes_json"
        return "\(body), \(notes)\(legacyBody)\(legacyNotes)\(encodedBody)\(encodedNotes)"
    }

    /// A unit's text as searched, and as shown with its Greek and Hebrew
    /// read: its body, and its notes too where the body lacks the words.
    private static func commentaryTexts(
        of row: Row,
        hasSearchText: Bool,
        hasFootnotesText: Bool,
        query: LampSearchQuery
    ) -> (searched: String, shown: String) {
        var text: String
        if hasSearchText {
            text = row["search_text"] ?? ""
        } else {
            text = ["introduction_json", "translation_json", "commentary_json"]
                .compactMap { LampModuleText.plainText(fromJSONString: row[$0], decodingEncodedSpans: true) }
                .joined(separator: " ")
        }
        var displayText = LampModuleText.plainText(
            fromJSONString: row["encoded_body_json"], decodingEncodedSpans: true
        ) ?? text
        // No JSON decode on the normal indexed-body path.
        if !query.matchesWordPrefixes(text) {
            let footnotes: String = hasFootnotesText
                ? row["footnotes_text"] ?? ""
                : LampModuleText.plainText(fromJSONString: row["footnotes_json"], decodingEncodedSpans: true) ?? ""
            text += "\n\n" + footnotes
            displayText += "\n\n" + (LampModuleText.plainText(
                fromJSONString: row["encoded_footnotes_json"], decodingEncodedSpans: true
            ) ?? footnotes)
        }
        return (text, displayText)
    }

    /// How much a match counts toward a book section's rank by the column it
    /// falls in: a section named for the words before one whose text uses
    /// them.
    static let bookColumnWeights: [String: Double] = [
        "title": 5,
        "search_text": 1,
    ]

    /// Book sections matching `query` in `db`, at most `limit` of them: the
    /// best-ranked where the books have an index, else in reading order.
    /// Without `snippets`, as `commentary`, for `bookSnippets` to cut later.
    public static func books(
        in db: Database,
        modules: [LampSearchedModule],
        query: LampSearchQuery,
        limit: Int,
        snippets: Bool = true
    ) throws -> [LampModuleSearchResult] {
        guard limit > 0, !modules.isEmpty, !query.isEmpty, !query.plainText.isEmpty else { return [] }
        let tables = try LampModuleText.tableNames(in: db)
        guard tables.contains("book_sections") else { return [] }
        let hasFTS = tables.contains("book_sections_fts") && !query.fts5Query.isEmpty
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if hasFTS {
            conditions.append("book_sections_fts MATCH ?")
            arguments += [query.fts5Query]
        }
        // Every book's sections carry their book, in its own file or not.
        conditions.append("s.module_id IN (\(modules.map { _ in "?" }.joined(separator: ", ")))")
        arguments += StatementArguments(modules.map(\.id))
        let source: String
        let order: String
        var limitClause = ""
        if hasFTS {
            let weights = try LampModuleText.orderedColumnNames(in: db, table: "book_sections_fts")
                .map { LampModuleText.number(bookColumnWeights[$0] ?? 1) }
                .joined(separator: ", ")
            source = "book_sections_fts JOIN book_sections s ON s.rowid = book_sections_fts.rowid"
            order = "bm25(book_sections_fts, \(weights)), s.rowid"
            limitClause = "LIMIT ?"
            arguments += [limit]
        } else {
            let like = query.sqlLikePredicate(columns: ["s.title", "s.subtitle", "s.search_text"])
            conditions.append(like.condition)
            arguments += StatementArguments(like.arguments)
            source = "book_sections s"
            order = "s.rowid"
        }
        // A section's text, where it is needed now, as for commentary.
        let readsText = snippets || !hasFTS
        let rows = try Row.fetchCursor(db, sql: """
            SELECT s.id, s.module_id, s.title, s.subtitle, s.key_scriptures_json\(readsText ? ", s.search_text" : "")
            FROM \(source)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            \(limitClause)
            """, arguments: arguments)

        var found: [LampModuleSearchResult] = []
        while found.count < limit, let row = try rows.next() {
            var snippet = ""
            if readsText {
                let text: String = row["search_text"]
                if !hasFTS, !query.matchesWordPrefixes(text) { continue }
                if snippets { snippet = query.markedSnippet(text) }
            }
            let moduleID: String = row["module_id"]
            let scriptures = LampModuleText.scriptureLinks(fromJSONString: row["key_scriptures_json"])
            found.append(LampModuleSearchResult(
                id: "book:\(moduleID):\(row["id"] as String)",
                kind: .book, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                title: row["title"], subtitle: row["subtitle"],
                snippet: snippet,
                startReference: scriptures.first?.startReference,
                endReference: scriptures.first?.endReference
            ))
        }
        return found
    }

    /// The snippets of book results found without them, read again from the
    /// database they were found in.
    public static func bookSnippets(
        for results: [LampModuleSearchResult],
        in db: Database,
        query: LampSearchQuery
    ) throws -> [LampModuleSearchResult] {
        try results.map { result in
            let section = String(result.id.dropFirst("book:\(result.moduleID):".count))
            guard let text = try String.fetchOne(db, sql: """
                SELECT search_text FROM book_sections WHERE id = ? AND module_id = ?
                """, arguments: [section, result.moduleID]) else { return result }
            return result.withSnippet(query.markedSnippet(text))
        }
    }

    /// Results from every kind and database as one list, the ones named for
    /// the words first, by their title and subtitle: a rank that means the
    /// same whichever database a result came from, as an index's own does
    /// not. Not by snippet, which nearly every result's holds the words of,
    /// so that results can be ranked before their snippets are cut.
    ///
    /// Most results tie on it. Among equals the kinds keep the order they were
    /// found in, and within a kind the modules take turns, each in its own
    /// order, best first where it ranks its rows: taking them a database at a
    /// time gave every place in a common word's results to whichever was
    /// searched first.
    public static func ranked(
        _ results: [LampModuleSearchResult],
        by query: LampSearchQuery,
        limit: Int
    ) -> [LampModuleSearchResult] {
        ranked(
            results, by: query, limit: limit,
            showing: { [$0.title, $0.subtitle ?? ""] },
            from: { ($0.kind.rawValue, $0.moduleID) }
        )
    }

    /// The same merge for an app's own kind of result, by the texts that name
    /// it and the kind and module it came from.
    public static func ranked<Result>(
        _ results: [Result],
        by query: LampSearchQuery,
        limit: Int,
        showing texts: (Result) -> [String],
        from source: (Result) -> (kind: String, module: String)
    ) -> [Result] {
        var kinds: [String: Int] = [:]
        var taken: [String: [String: Int]] = [:]
        let keys = results.map { result -> (rank: Double, kind: Int, turn: Int) in
            let (kind, module) = source(result)
            let kindOrder = kinds[kind] ?? kinds.count
            kinds[kind] = kindOrder
            let turn = taken[kind, default: [:]][module, default: 0]
            taken[kind, default: [:]][module] = turn + 1
            return (query.textRank(in: texts(result)), kindOrder, turn)
        }
        return results.indices
            .sorted { lhs, rhs in
                let left = keys[lhs], right = keys[rhs]
                if left.rank != right.rank { return left.rank > right.rank }
                if left.kind != right.kind { return left.kind < right.kind }
                if left.turn != right.turn { return left.turn < right.turn }
                return lhs < rhs
            }
            .prefix(max(limit, 0))
            .map { results[$0] }
    }
}

/// What a module's JSON says as plain text, and what its schema holds, for the
/// library and the searches alike.
enum LampModuleText {
    static func tableNames(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
        ))
    }

    static func columnNames(in db: Database, table: String) throws -> Set<String> {
        Set(try orderedColumnNames(in: db, table: table))
    }

    static func orderedColumnNames(in db: Database, table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            .compactMap { $0["name"] as String? }
    }

    /// A weight as SQL takes it, without a locale's decimal comma.
    static func number(_ value: Double) -> String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// The passages a section or writing is keyed to, as its
    /// `key_scriptures_json` lists them.
    static func scriptureLinks(fromJSONString json: String?) -> [LampScriptureLink] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return values.compactMap { value in
            guard let start = integerValue(value["sv"]) else { return nil }
            return LampScriptureLink(
                text: stringValue(value["label"]),
                startReference: start,
                endReference: integerValue(value["ev"])
            )
        }
    }

    static func plainText(fromJSONString json: String?, decodingEncodedSpans: Bool = false) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return plainText(from: value, decodingEncodedSpans: decodingEncodedSpans)
    }

    /// A module keeps text set in a legacy font encoding as its source has it
    /// ("oJ lo/gos" for ὁ λόγος) and gives each such span its Unicode reading,
    /// as `data.unicode` beside a `data.sourceEncoding`. The span reads as that
    /// Unicode. Offsets count Unicode scalars, and a span whose offsets do not
    /// land on its own `text` is left as written.
    static func decodingEncodedSpans(in text: String, annotations: [Any]) -> String {
        let spans = annotations.compactMap { value -> (start: Int, end: Int, source: String, unicode: String)? in
            guard let annotation = value as? [String: Any],
                  let data = annotation["data"] as? [String: Any],
                  data["sourceEncoding"] != nil,
                  let unicode = stringValue(data["unicode"]), !unicode.isEmpty,
                  let source = stringValue(annotation["text"]),
                  let start = integerValue(annotation["start"]),
                  let end = integerValue(annotation["end"]),
                  start >= 0, end > start else { return nil }
            return (start, end, source, unicode)
        }
        guard !spans.isEmpty else { return text }
        var scalars = Array(text.unicodeScalars)
        // From the end, so the spans before each one keep their offsets.
        for span in spans.sorted(by: { $0.start > $1.start }) where span.end <= scalars.count {
            var written = String.UnicodeScalarView()
            written.append(contentsOf: scalars[span.start..<span.end])
            guard String(written) == span.source else { continue }
            scalars.replaceSubrange(span.start..<span.end, with: span.unicode.unicodeScalars)
        }
        var decoded = String.UnicodeScalarView()
        decoded.append(contentsOf: scalars)
        return String(decoded)
    }

    static func plainText(from value: Any?, decodingEncodedSpans: Bool = false) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let values = value as? [Any] {
            let text = values
                .compactMap { plainText(from: $0, decodingEncodedSpans: decodingEncodedSpans) }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            if decodingEncodedSpans,
               let text = object["text"] as? String,
               let annotations = object["annotations"] as? [Any],
               let decoded = plainText(from: Self.decodingEncodedSpans(in: text, annotations: annotations)) {
                return decoded
            }
            for key in ["text", "content", "value", "note", "body"] {
                if let text = plainText(from: object[key], decodingEncodedSpans: decodingEncodedSpans) {
                    return text
                }
            }
            let ignoredKeys: Set<String> = ["id", "type", "style", "level", "annotations"]
            let text = object
                .filter { !ignoredKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
                .compactMap { plainText(from: $0.value, decodingEncodedSpans: decodingEncodedSpans) }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

extension LampModuleSearchResult {
    /// The same result with its snippet cut.
    func withSnippet(_ snippet: String) -> LampModuleSearchResult {
        LampModuleSearchResult(
            id: id, kind: kind, moduleID: moduleID, moduleName: moduleName,
            title: title, subtitle: subtitle, snippet: snippet,
            startReference: startReference, endReference: endReference,
            highlightColor: highlightColor
        )
    }
}
