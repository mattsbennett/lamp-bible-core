import Foundation
import GRDB
import LampModuleKit

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

/// A reading plan a search covers, as each app keeps its plans its own way.
public struct LampSearchedPlan: Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let fullDescription: String?
    public let author: String?
    public let duration: Int?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        fullDescription: String? = nil,
        author: String? = nil,
        duration: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.fullDescription = fullDescription
        self.author = author
        self.duration = duration
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
    /// Without `snippets`, each result carries a stand-in for its snippet
    /// (`rankingSnippet`), for `commentarySnippets` to replace once a merge
    /// has chosen the results kept: cutting one for every unit each database
    /// offers, most of them then dropped, was most of a search's time.
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
        let indexed = tables.contains("commentary_units_fts")
        let ftsColumns = indexed ? try LampModuleText.orderedColumnNames(in: db, table: "commentary_units_fts") : []
        // An index of every unit's footnotes too answers the query; an older
        // one, without them, each term it can find in the body, the notes
        // read for it as well.
        let asked = hasFootnotesText && ftsColumns.contains("footnotes_text")
            ? try indexQuery(query, index: "commentary_units_fts", in: db) : nil
        if case .nothing = asked { return [] }
        let fullFTS = asked?.match != nil
        let hasFTS = fullFTS || indexed && !query.fts5Query.isEmpty
        // A database holding several modules answers for the ones asked
        // about. A module's own file holds only it.
        let sharesDatabase = columns.contains("module_id")
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match = asked?.match {
            conditions.append("commentary_units_fts MATCH ?")
            arguments += [match]
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
        let standIn = snippets ? "" : rankingSnippet(for: query)
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
            SELECT u.rowid AS unit_rowid, u.id, \(module), u.sv, u.ev, u.title\(text)
            FROM \(source)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            \(limitClause)
            """, arguments: arguments)

        // Snippets are cut once it is known which units hold the words
        // together, so that the rest aren't read again looking for them.
        var found: [(rowid: Int64, result: LampModuleSearchResult, shown: String?)] = []
        while found.count < limit, let row = try rows.next() {
            var holdsPhrase = false
            var shown: String?
            let title: String? = row["title"]
            if readsText {
                let texts = commentaryTexts(
                    of: row, hasSearchText: hasSearchText, hasFootnotesText: hasFootnotesText, query: query
                )
                if !fullFTS {
                    guard query.matchesWordPrefixes((title ?? "") + " " + texts.searched) else { continue }
                    holdsPhrase = query.holdsPhrase((title ?? "") + " " + texts.searched)
                }
                if snippets { shown = texts.shown }
            }
            let moduleID: String = sharesDatabase ? row["module_id"] : modules[0].id
            let start: Int = row["sv"]
            let end: Int? = row["ev"]
            found.append((row["unit_rowid"], LampModuleSearchResult(
                id: "commentary:\(moduleID):\(row["id"] as String)",
                kind: .commentary, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                title: title?.isEmpty == false ? title! : LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                subtitle: LampBibleReferenceFormatter.describeRange(from: start, to: end ?? start),
                snippet: standIn, startReference: start, endReference: end, holdsPhrase: holdsPhrase
            ), shown))
        }
        // The index answers whether a unit holds the words together, its
        // notes included, without reading its text.
        let together = fullFTS
            ? try rowidsHoldingPhrase(found.map(\.rowid), index: "commentary_units_fts", query: query, in: db)
            : []
        return found.map { item in
            let result = together.contains(item.rowid) ? item.result.withPhrase() : item.result
            guard let shown = item.shown else { return result }
            return result.withSnippet(query.markedSnippet(shown, findingPhrase: result.holdsPhrase))
        }
    }

    /// How an index is asked a query: by its MATCH argument, or not at all,
    /// where no word of the index holds a term found within words, so that
    /// nothing it covers can match.
    public enum IndexQuery: Equatable, Sendable {
        case match(String)
        case nothing

        public var match: String? {
            if case .match(let match) = self { match } else { nil }
        }
    }

    /// How `index` is asked `query`, each term found within words (`*faith`)
    /// as the words of the index holding it, from its list of them
    /// (`LampSearchWords`); nil where it can't answer, as where it has no
    /// list of its words as it is now or too many hold the term, or the query
    /// has nothing it can search by, so that the text is read instead.
    public static func indexQuery(_ query: LampSearchQuery, index: String, in db: Database) throws -> IndexQuery? {
        guard query.hasWithinWordTerms else {
            let match = query.fts5Query
            return match.isEmpty ? nil : .match(match)
        }
        var words: [String: [String]] = [:]
        for term in query.terms where term.isWithinWord && words[term.text] == nil {
            guard let holding = try LampSearchWords.words(holding: term.text, index: index, in: db) else { return nil }
            guard !holding.isEmpty else { return .nothing }
            words[term.text] = holding
        }
        return .match(query.fts5Query { words[$0.text] ?? [] })
    }

    /// Which of `rowids` an index finds the query's words in together.
    private static func rowidsHoldingPhrase(
        _ rowids: [Int64],
        index: String,
        query: LampSearchQuery,
        in db: Database
    ) throws -> Set<Int64> {
        guard let phrase = query.phraseFTS5Query, !rowids.isEmpty else { return [] }
        var arguments: StatementArguments = [phrase]
        arguments += StatementArguments(rowids)
        return Set(try Int64.fetchAll(db, sql: """
            SELECT rowid FROM \(index)
            WHERE \(index) MATCH ? AND rowid IN (\(rowids.map { _ in "?" }.joined(separator: ", ")))
            """, arguments: arguments))
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
            return result.withSnippet(query.markedSnippet(texts.shown, findingPhrase: result.holdsPhrase))
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
    /// Without `snippets`, as `commentary`, for `bookSnippets` to replace.
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
        let asked = tables.contains("book_sections_fts")
            ? try indexQuery(query, index: "book_sections_fts", in: db) : nil
        if case .nothing = asked { return [] }
        let hasFTS = asked?.match != nil
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match = asked?.match {
            conditions.append("book_sections_fts MATCH ?")
            arguments += [match]
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
        let standIn = snippets ? "" : rankingSnippet(for: query)
        let rows = try Row.fetchCursor(db, sql: """
            SELECT s.rowid AS section_rowid, s.id, s.module_id, s.title, s.subtitle, s.key_scriptures_json\(readsText ? ", s.search_text" : "")
            FROM \(source)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            \(limitClause)
            """, arguments: arguments)

        // Snippets are cut once it is known which sections hold the words
        // together, as for commentary.
        var found: [(rowid: Int64, result: LampModuleSearchResult, shown: String?)] = []
        while found.count < limit, let row = try rows.next() {
            var holdsPhrase = false
            var shown: String?
            let title: String = row["title"]
            let subtitle: String? = row["subtitle"]
            if readsText {
                let text: String = row["search_text"]
                if !hasFTS {
                    guard query.matchesWordPrefixes(text) else { continue }
                    holdsPhrase = query.holdsPhrase([title, subtitle ?? "", text].joined(separator: " "))
                }
                if snippets { shown = text }
            }
            let moduleID: String = row["module_id"]
            let scriptures = LampModuleText.scriptureLinks(fromJSONString: row["key_scriptures_json"])
            found.append((row["section_rowid"], LampModuleSearchResult(
                id: "book:\(moduleID):\(row["id"] as String)",
                kind: .book, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                title: title, subtitle: subtitle,
                snippet: standIn,
                startReference: scriptures.first?.startReference,
                endReference: scriptures.first?.endReference,
                holdsPhrase: holdsPhrase
            ), shown))
        }
        let together = hasFTS
            ? try rowidsHoldingPhrase(found.map(\.rowid), index: "book_sections_fts", query: query, in: db)
            : []
        return found.map { item in
            let result = together.contains(item.rowid) ? item.result.withPhrase() : item.result
            guard let shown = item.shown else { return result }
            return result.withSnippet(query.markedSnippet(shown, findingPhrase: result.holdsPhrase))
        }
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
            return result.withSnippet(query.markedSnippet(text, findingPhrase: result.holdsPhrase))
        }
    }

    /// How much a match counts toward a note's rank by the column it falls
    /// in: a note titled with the words before one whose text uses them.
    static let noteColumnWeights: [String: Double] = [
        "title": 5,
        "search_text": 1,
    ]

    /// Notes matching `query` in `db`, at most `limit` of them: the
    /// best-ranked where the notes have an index of title and text with its
    /// footnotes, else in the order of the verses they're on. Without
    /// `snippets`, as `commentary`, for `noteSnippets` to replace.
    ///
    /// Without the index, a note is matched in its title, its text and, where
    /// it has one, the text it is searched by, its footnotes included, as the
    /// index matches it; once only its title and text were.
    public static func notes(
        in db: Database,
        modules: [LampSearchedModule],
        query: LampSearchQuery,
        limit: Int,
        snippets: Bool = true
    ) throws -> [LampModuleSearchResult] {
        guard limit > 0, !modules.isEmpty, !query.isEmpty, !query.plainText.isEmpty else { return [] }
        let tables = try LampModuleText.tableNames(in: db)
        guard tables.contains("note_entries") else { return [] }
        let columns = try LampModuleText.columnNames(in: db, table: "note_entries")
        let hasTitle = columns.contains("title")
        let hasSearchText = columns.contains("search_text")
        let ftsColumns = tables.contains("note_fts")
            ? try LampModuleText.orderedColumnNames(in: db, table: "note_fts") : []
        let asked = hasTitle && hasSearchText && ftsColumns.contains("title") && ftsColumns.contains("search_text")
            ? try indexQuery(query, index: "note_fts", in: db) : nil
        if case .nothing = asked { return [] }
        let hasFTS = asked?.match != nil
        // A database holding several modules answers for the ones asked
        // about. A module's own file holds only it.
        let sharesDatabase = columns.contains("module_id")
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match = asked?.match {
            conditions.append("note_fts MATCH ?")
            arguments += [match]
        }
        if sharesDatabase {
            conditions.append("n.module_id IN (\(modules.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(modules.map(\.id))
        }
        let source: String
        let order: String
        var limitClause = ""
        if hasFTS {
            let weights = ftsColumns
                .map { LampModuleText.number(noteColumnWeights[$0] ?? 1) }
                .joined(separator: ", ")
            source = "note_fts JOIN note_entries n ON n.rowid = note_fts.rowid"
            order = "bm25(note_fts, \(weights)), n.rowid"
            limitClause = "LIMIT ?"
            arguments += [limit]
        } else {
            // A note's search text holds its text and footnotes both, so
            // where it has one the text isn't read twice.
            let like = query.sqlLikePredicate(
                columns: (hasTitle ? ["n.title"] : []) + [hasSearchText ? "COALESCE(NULLIF(n.search_text, ''), n.content)" : "n.content"]
            )
            conditions.append(like.condition)
            arguments += StatementArguments(like.arguments)
            source = "note_entries n"
            order = "n.verse_id, n.id"
        }
        // A note's text, where it is needed now: to tell whether one found
        // without the index holds the words together, or to cut snippets.
        let readsText = snippets || !hasFTS
        let standIn = snippets ? "" : rankingSnippet(for: query)
        let text = readsText ? ", n.content" + (hasSearchText ? ", n.search_text" : ", NULL AS search_text") : ""
        let rows = try Row.fetchCursor(db, sql: """
            SELECT n.rowid AS note_rowid, n.id, \(sharesDatabase ? "n.module_id" : "NULL AS module_id"),
                   n.verse_id, \(hasTitle ? "n.title" : "NULL AS title")\(text)
            FROM \(source)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order)
            \(limitClause)
            """, arguments: arguments)

        // Snippets are cut once it is known which notes hold the words
        // together, as for commentary.
        var found: [(rowid: Int64, result: LampModuleSearchResult, shown: String?)] = []
        while found.count < limit, let row = try rows.next() {
            let title: String? = row["title"]
            var holdsPhrase = false
            var shown: String?
            if readsText {
                let texts = noteTexts(of: row, query: query, shown: snippets)
                if !hasFTS {
                    // Found anywhere by LIKE; kept where the query's own rule
                    // finds it, as the index would.
                    guard query.matchesWordPrefixes(texts.searched) else { continue }
                    holdsPhrase = query.holdsPhrase(texts.searched)
                }
                if snippets { shown = texts.shown }
            }
            let moduleID: String = sharesDatabase ? row["module_id"] : modules[0].id
            let reference: Int = row["verse_id"]
            found.append((row["note_rowid"], LampModuleSearchResult(
                id: "notes:\(moduleID):\(row["id"] as String)",
                kind: .notes, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                title: title?.isEmpty == false
                    ? title! : LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                subtitle: LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                snippet: standIn, startReference: reference, holdsPhrase: holdsPhrase
            ), shown))
        }
        let together = hasFTS
            ? try rowidsHoldingPhrase(found.map(\.rowid), index: "note_fts", query: query, in: db)
            : []
        return found.map { item in
            let result = together.contains(item.rowid) ? item.result.withPhrase() : item.result
            guard let shown = item.shown else { return result }
            return result.withSnippet(query.markedSnippet(shown, findingPhrase: result.holdsPhrase))
        }
    }

    /// The snippets of note results found without them, read again from the
    /// database they were found in.
    public static func noteSnippets(
        for results: [LampModuleSearchResult],
        in db: Database,
        query: LampSearchQuery
    ) throws -> [LampModuleSearchResult] {
        guard !results.isEmpty else { return results }
        let columns = try LampModuleText.columnNames(in: db, table: "note_entries")
        let sql = """
            SELECT \(columns.contains("title") ? "title" : "NULL AS title"), content,
                   \(columns.contains("search_text") ? "search_text" : "NULL AS search_text")
            FROM note_entries
            WHERE id = ?\(columns.contains("module_id") ? " AND module_id = ?" : "")
            """
        return try results.map { result in
            let note = String(result.id.dropFirst("notes:\(result.moduleID):".count))
            let arguments: StatementArguments = columns.contains("module_id") ? [note, result.moduleID] : [note]
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return result }
            return result.withSnippet(
                query.markedSnippet(noteTexts(of: row, query: query).shown ?? "", findingPhrase: result.holdsPhrase)
            )
        }
    }

    /// A note's text as searched, its title and the text and footnotes it is
    /// searched by, and, where `shown`, the text a snippet is cut from: its
    /// text, or the text it is searched by where only that holds the words,
    /// a footnote's. Choosing that reads the note again, so a search whose
    /// snippets wait for the merge doesn't.
    private static func noteTexts(
        of row: Row,
        query: LampSearchQuery,
        shown: Bool = true
    ) -> (searched: String, shown: String?) {
        let title: String = row["title"] ?? ""
        let content: String = row["content"] ?? ""
        let searchText = (row["search_text"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        // The search text holds the note's text and footnotes both.
        let searched = title + " " + (searchText ?? content)
        guard shown else { return (searched, nil) }
        return (searched, !query.matchesWordPrefixes(content) && searchText.map(query.matchesWordPrefixes) == true
            ? searchText! : content)
    }

    /// How much a match counts toward a writing's rank by the column it falls
    /// in: a writing titled with the words before one whose text uses them.
    static let devotionalColumnWeights: [String: Double] = [
        "title": 5,
        "search_text": 1,
    ]

    /// Devotionals matching `query` and `criteria` in `db`, at most `limit`
    /// of them: the best-ranked where a text query has an index of title and
    /// text to ask, else in the order of their series, place in it, date and
    /// title. A search by date, tag or kind alone needs no words. Without
    /// `snippets`, as `commentary`, for `devotionalSnippets` to replace.
    ///
    /// The date narrows the rows in SQL, where it compares as it does in
    /// Swift; tags and kinds fold case and accents as only Swift folds them
    /// (`LampDevotionalSearchCriteria.matches`), and are checked there.
    /// Without the index a writing's words are matched in its title,
    /// subtitle, author, tags and search text, which holds its footnotes as
    /// well as its summary and text; once its footnotes weren't.
    public static func devotionals(
        in db: Database,
        modules: [LampSearchedModule],
        query: LampSearchQuery,
        criteria: LampDevotionalSearchCriteria = .init(),
        limit: Int,
        snippets: Bool = true
    ) throws -> [LampModuleSearchResult] {
        let hasTextQuery = !query.isEmpty && !query.plainText.isEmpty
        guard limit > 0, !modules.isEmpty, hasTextQuery || !criteria.isEmpty else { return [] }
        let tables = try LampModuleText.tableNames(in: db)
        guard tables.contains("devotional_entries") else { return [] }
        let columns = try LampModuleText.columnNames(in: db, table: "devotional_entries")
        let hasSearchText = columns.contains("search_text")
        let ftsColumns = hasTextQuery && hasSearchText && tables.contains("devotional_entries_fts")
            ? try LampModuleText.orderedColumnNames(in: db, table: "devotional_entries_fts") : []
        let asked = ftsColumns.contains("title") && ftsColumns.contains("search_text")
            ? try indexQuery(query, index: "devotional_entries_fts", in: db) : nil
        if case .nothing = asked { return [] }
        let usesIndex = asked?.match != nil
        let sharesDatabase = columns.contains("module_id")
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var conditions: [String] = []
        var arguments = StatementArguments()
        if let match = asked?.match {
            conditions.append("devotional_entries_fts MATCH ?")
            arguments += [match]
        }
        if sharesDatabase {
            conditions.append("d.module_id IN (\(modules.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(modules.map(\.id))
        }
        if let date = criteria.date {
            conditions.append("d.date = ?")
            arguments += [date]
        }
        if let monthDay = criteria.monthDay {
            let suffix = "-" + monthDay
            conditions.append("substr(d.date, -\(suffix.count)) = ?")
            arguments += [suffix]
        }
        let source: String
        let order: String
        if usesIndex {
            // The phone's index keeps its own copy, keyed by id; an index
            // over the table's content is keyed by rowid.
            let key = ftsColumns.contains("id") ? "devotional_entries_fts.id = d.id" : "devotional_entries_fts.rowid = d.rowid"
            // Its id isn't text to rank by.
            let weights = ftsColumns
                .map { $0 == "id" ? "0" : LampModuleText.number(devotionalColumnWeights[$0] ?? 1) }
                .joined(separator: ", ")
            source = "devotional_entries_fts JOIN devotional_entries d ON \(key)"
            order = "ORDER BY bm25(devotional_entries_fts, \(weights)), d.rowid"
        } else {
            source = "devotional_entries d"
            order = ""
        }
        // A writing's words, where they're matched here; its summary and
        // text, from its JSON, only where it has no search text.
        let words = hasTextQuery && !usesIndex
            ? (hasSearchText ? ", d.search_text" : ", NULL AS search_text") + """
                , CASE WHEN \(hasSearchText ? "COALESCE(d.search_text, '') = ''" : "1") THEN d.summary_json END AS summary_json,
                  CASE WHEN \(hasSearchText ? "COALESCE(d.search_text, '') = ''" : "1") THEN d.content_json END AS content_json
                """
            : ""
        let rows = try Row.fetchCursor(db, sql: """
            SELECT d.rowid AS devotional_rowid, d.id, \(sharesDatabase ? "d.module_id" : "NULL AS module_id"),
                   d.title, d.subtitle, d.author, d.date, d.tags, d.category, d.series_name, d.series_order,
                   d.key_scriptures_json\(words)
            FROM \(source)
            \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
            \(order)
            """, arguments: arguments)

        struct Found {
            let rowid: Int64
            let entryID: String
            let result: LampModuleSearchResult
            let seriesName: String
            let seriesOrder: Int
            let date: String
        }
        var found: [Found] = []
        while !(usesIndex && found.count >= limit), let row = try rows.next() {
            let tags = (row["tags"] as String?)?.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            guard criteria.matches(date: row["date"], tags: tags, category: row["category"]) else { continue }
            let title: String = row["title"]
            let subtitle: String? = row["subtitle"]
            let author: String? = row["author"]
            var holdsPhrase = false
            if hasTextQuery && !usesIndex {
                let text = (row["search_text"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? [
                        LampModuleText.plainText(fromJSONString: row["summary_json"]),
                        (row["content_json"] as String?).map { LampPortableDevotionalContent.plainText(from: $0) ?? $0 },
                    ].compactMap { $0 }.joined(separator: " ")
                guard query.matches(([title, subtitle, author, text] + tags).compactMap { $0 }.joined(separator: " "))
                else { continue }
                holdsPhrase = query.holdsPhrase(text)
            }
            let moduleID: String = sharesDatabase ? row["module_id"] : modules[0].id
            let scriptures = LampModuleText.scriptureLinks(fromJSONString: row["key_scriptures_json"])
            found.append(Found(
                rowid: row["devotional_rowid"],
                entryID: row["id"],
                result: LampModuleSearchResult(
                    id: "devotional:\(moduleID):\(row["id"] as String)",
                    kind: .devotional, moduleID: moduleID, moduleName: names[moduleID] ?? moduleID,
                    title: title, subtitle: subtitle ?? author,
                    snippet: rankingSnippet(for: query),
                    startReference: scriptures.first?.startReference,
                    endReference: scriptures.first?.endReference,
                    holdsPhrase: holdsPhrase
                ),
                seriesName: row["series_name"] ?? "", seriesOrder: row["series_order"] ?? 0, date: row["date"] ?? ""
            ))
        }
        if !usesIndex {
            // In series, then place in it, then date and title, as the
            // library lists them: every match is read before any is kept.
            found.sort { lhs, rhs in
                if lhs.seriesName != rhs.seriesName {
                    return lhs.seriesName.localizedStandardCompare(rhs.seriesName) == .orderedAscending
                }
                if lhs.seriesOrder != rhs.seriesOrder { return lhs.seriesOrder < rhs.seriesOrder }
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                let order = lhs.result.title.localizedStandardCompare(rhs.result.title)
                return order == .orderedSame ? lhs.result.id < rhs.result.id : order == .orderedAscending
            }
        }
        let kept = Array(found.prefix(limit))
        var together: Set<Int64> = []
        if usesIndex, ftsColumns.contains("id"), let phrase = query.phraseFTS5Query, !kept.isEmpty {
            // The phone's index numbers its own rows: ask it by id.
            let rowids = Dictionary(kept.map { ($0.entryID, $0.rowid) }, uniquingKeysWith: { first, _ in first })
            var phraseArguments: StatementArguments = [phrase]
            phraseArguments += StatementArguments(kept.map(\.entryID))
            together = Set(try String.fetchAll(db, sql: """
                SELECT id FROM devotional_entries_fts
                WHERE devotional_entries_fts MATCH ? AND id IN (\(kept.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: phraseArguments).compactMap { rowids[$0] })
        } else if usesIndex {
            together = try rowidsHoldingPhrase(kept.map(\.rowid), index: "devotional_entries_fts", query: query, in: db)
        }
        let results = kept.map { together.contains($0.rowid) ? $0.result.withPhrase() : $0.result }
        return snippets ? try devotionalSnippets(for: results, in: db, query: query) : results
    }

    /// The snippets of devotional results found without them, read again
    /// from the database they were found in: the summary where it holds the
    /// words, else the text; a search by its facets alone, the opening.
    public static func devotionalSnippets(
        for results: [LampModuleSearchResult],
        in db: Database,
        query: LampSearchQuery
    ) throws -> [LampModuleSearchResult] {
        guard !results.isEmpty else { return results }
        let byModule = try LampModuleText.columnNames(in: db, table: "devotional_entries").contains("module_id")
        let sql = """
            SELECT summary_json, content_json FROM devotional_entries
            WHERE id = ?\(byModule ? " AND module_id = ?" : "")
            """
        let hasTextQuery = !query.isEmpty && !query.plainText.isEmpty
        return try results.map { result in
            let entry = String(result.id.dropFirst("devotional:\(result.moduleID):".count))
            let arguments: StatementArguments = byModule ? [entry, result.moduleID] : [entry]
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return result }
            let contentJSON: String = row["content_json"]
            let summary = LampModuleText.plainText(fromJSONString: row["summary_json"])
            let content = LampPortableDevotionalContent.plainText(from: contentJSON) ?? contentJSON
            let text = summary.flatMap { query.matches($0) ? $0 : nil } ?? content
            return result.withSnippet(
                hasTextQuery
                    ? query.markedSnippet(text, findingPhrase: result.holdsPhrase)
                    : LampModuleText.openingSnippet(text)
            )
        }
    }

    /// Quiz questions matching `query` in `db`, at most `limit` of them, in
    /// reading order: by day, passage, age group and place. Matched in their
    /// theme and the words of their question and answer, never their JSON's
    /// field names. A database may hold several quizzes, as the phone's
    /// bundled one does.
    public static func quizzes(
        in db: Database,
        modules: [LampSearchedModule],
        query: LampSearchQuery,
        limit: Int
    ) throws -> [LampModuleSearchResult] {
        guard limit > 0, !modules.isEmpty, !query.isEmpty, !query.plainText.isEmpty,
              try LampModuleText.tableNames(in: db).contains("quiz_questions") else { return [] }
        let names = Dictionary(modules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let like = query.sqlLikePredicate(columns: ["theme"], jsonColumns: ["question_json", "answer_json"])
        var arguments = StatementArguments(modules.map(\.id))
        arguments += StatementArguments(like.arguments)
        // Sorted, so the questions kept are the first in reading order: a
        // quiz isn't always stored in it. Found anywhere by LIKE, and kept
        // where the query's own rule finds the words.
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, quiz_module_id, day, sv, ev, age_group, theme, question_json, answer_json
            FROM quiz_questions
            WHERE quiz_module_id IN (\(modules.map { _ in "?" }.joined(separator: ", "))) AND \(like.condition)
            ORDER BY day, sv, age_group, question_index
            """, arguments: arguments)
        var found: [LampModuleSearchResult] = []
        while found.count < limit, let row = try rows.next() {
            let moduleID: String = row["quiz_module_id"]
            let answerJSON: String = row["answer_json"]
            let question = LampModuleText.plainText(fromJSONString: row["question_json"])
            let answer = LampModuleText.plainText(fromJSONString: answerJSON)
            guard query.matches([row["theme"] as String?, question, answer].compactMap { $0 }.joined(separator: " "))
            else { continue }
            found.append(LampModuleSearchResult(
                id: "quiz:\(moduleID):\(row["id"] as Int64)",
                kind: .quiz,
                moduleID: moduleID,
                moduleName: names[moduleID] ?? moduleID,
                title: question ?? "Quiz Question",
                subtitle: "Day \(row["day"] as Int) • \(row["age_group"] as String)",
                snippet: query.markedSnippet(answer ?? answerJSON),
                startReference: row["sv"],
                endReference: row["ev"],
                holdsPhrase: query.holdsPhrase([question, answer].compactMap { $0 }.joined(separator: " "))
            ))
        }
        return found
    }

    /// Reading plans matching `query` by their name, descriptions and
    /// author, at most `limit` of them, in the order given.
    public static func plans(
        _ plans: [LampSearchedPlan],
        query: LampSearchQuery,
        limit: Int
    ) -> [LampModuleSearchResult] {
        guard limit > 0, !query.isEmpty, !query.plainText.isEmpty else { return [] }
        return plans
            .filter { plan in
                query.matches(
                    [plan.name, plan.description, plan.fullDescription, plan.author]
                        .compactMap { $0 }.joined(separator: " ")
                )
            }
            .prefix(limit)
            .map { plan in
                LampModuleSearchResult(
                    id: "plan:\(plan.id)",
                    kind: .plan,
                    moduleID: plan.id,
                    moduleName: plan.name,
                    title: plan.name,
                    subtitle: plan.author,
                    snippet: query.markedSnippet(
                        plan.fullDescription ?? plan.description ?? plan.duration.map { "\($0) days" } ?? ""
                    ),
                    holdsPhrase: query.holdsPhrase(
                        [plan.description, plan.fullDescription].compactMap { $0 }.joined(separator: " ")
                    )
                )
            }
    }

    /// What a result found without its snippet carries in its place: the
    /// query's own words, marked as a snippet cut around them would mark
    /// them, so that it ranks in a merge as its snippet will. One word scores
    /// as a snippet holding it does; words a snippet marks one by one score
    /// as they do there, apart.
    public static func rankingSnippet(for query: LampSearchQuery) -> String {
        query.markedSnippet(query.realmPrefilter)
    }

    /// Results from every kind and database as one list, best first by a
    /// rank that means the same whichever database a result came from, as an
    /// index's own does not (`mergeRank`).
    ///
    /// Many results tie on it. Among equals the kinds keep the order they
    /// were found in, and within a kind the modules take turns, each in its
    /// own order, best first where it ranks its rows: taking them a database
    /// at a time gave every place in a common word's results to whichever was
    /// searched first.
    public static func ranked(
        _ results: [LampModuleSearchResult],
        by query: LampSearchQuery,
        limit: Int
    ) -> [LampModuleSearchResult] {
        ranked(
            results, by: query, limit: limit,
            // A quiz result's title is its question, a sentence rather than a
            // name: it counts as what the result shows.
            named: { $0.kind == .quiz ? [$0.subtitle ?? ""] : [$0.title, $0.subtitle ?? ""] },
            shown: { $0.kind == .quiz ? [$0.title, $0.snippet] : [$0.snippet] },
            holdingPhrase: \.holdsPhrase,
            from: { ($0.kind.rawValue, $0.moduleID) }
        )
    }

    /// How well a result answers the query. Named for it outright, or
    /// starting with it, first, and shown with it, as `textRank` has it over
    /// the texts that name and show the result; then, for a query of several
    /// words, named with every one of them, in any order, a heading's words
    /// rather than a sentence's; then holding them together somewhere in its
    /// text. "The Kingdom of God" comes before "Kingdoms and the God of
    /// Daniel", and both before a section with "kingdom" on one page and
    /// "God" on another.
    public static func mergeRank(
        names: [String],
        shown: [String],
        holdsPhrase: Bool,
        query: LampSearchQuery
    ) -> Double {
        var rank = query.textRank(in: names + shown)
        if query.terms.count > 1, query.matchesWordPrefixes(names.joined(separator: " ")) { rank += 0.5 }
        if holdsPhrase { rank += 0.25 }
        return rank
    }

    /// The same merge for an app's own kind of result, by the texts that name
    /// it, the texts that show it, whether its text holds the query's words
    /// together, and the kind and module it came from.
    public static func ranked<Result>(
        _ results: [Result],
        by query: LampSearchQuery,
        limit: Int,
        named names: (Result) -> [String],
        shown: (Result) -> [String],
        holdingPhrase holdsPhrase: (Result) -> Bool = { _ in false },
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
            let rank = mergeRank(
                names: names(result), shown: shown(result), holdsPhrase: holdsPhrase(result), query: query
            )
            return (rank, kindOrder, turn)
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

    /// A text's opening, its whitespace collapsed: a result's snippet when
    /// no words were asked for.
    static func openingSnippet(_ text: String, limit: Int = 280) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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
            highlightColor: highlightColor, holdsPhrase: holdsPhrase, entryKey: entryKey
        )
    }

    /// The same result, found to hold the query's words together.
    func withPhrase() -> LampModuleSearchResult {
        LampModuleSearchResult(
            id: id, kind: kind, moduleID: moduleID, moduleName: moduleName,
            title: title, subtitle: subtitle, snippet: snippet,
            startReference: startReference, endReference: endReference,
            highlightColor: highlightColor, holdsPhrase: true, entryKey: entryKey
        )
    }
}
