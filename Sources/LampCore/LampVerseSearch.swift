import Foundation
import GRDB

/// A verse a search found, as its translation reads it.
public struct LampVerseSearchHit: Equatable, Sendable {
    public let translationID: String
    public let reference: Int
    public let book: Int
    public let chapter: Int
    public let verse: Int
    /// The book's name in its translation, or the canonical one where the
    /// database names none.
    public let bookName: String
    public let text: String
    /// Whether the verse holds the query's words together.
    public let holdsPhrase: Bool
}

extension LampModuleSearch {
    /// Verses matching `query` in `db`, at most `limit` from each translation
    /// searched: the best ranked first where the verses have an index the
    /// query can ask, else in the Bible's order. Each translation answers for
    /// itself, so that one which repeats the words more often can't crowd out
    /// the rest, and a caller shares the room between them (`sharedEvenly`),
    /// in an order of its own rather than this one: grouped by translation
    /// here, by database there.
    ///
    /// A translation's module file keeps its verses in `verses`, and answers
    /// as `translations`' one; a database of several, as the bundled one and
    /// the phone's do, keeps them in `translation_verses` by translation, all
    /// of them searched where `translations` is nil.
    public static func verses(
        in db: Database,
        translations: [String]?,
        query: LampSearchQuery,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int
    ) throws -> [LampVerseSearchHit] {
        guard limit > 0, !query.isEmpty, !query.plainText.isEmpty, translations?.isEmpty != true else { return [] }
        let tables = try LampModuleText.tableNames(in: db)
        let shared = tables.contains("translation_verses")
        guard shared || tables.contains("verses") else { return [] }
        let table = shared ? "translation_verses" : "verses"
        let index = shared ? "translation_verses_fts" : "verses_fts"
        // A module file holds one translation, named by the caller or by its
        // own metadata.
        let ownID: String? = shared ? nil : try translations?.first
            ?? (tables.contains("translation_meta") ? String.fetchOne(db, sql: "SELECT id FROM translation_meta") : nil)
        guard shared || ownID != nil else { return [] }

        var arguments = StatementArguments()
        let translationColumn: String
        if let ownID {
            translationColumn = "?"
            arguments += [ownID]
        } else {
            translationColumn = "v.translation_id"
        }
        let books: String
        if shared {
            books = tables.contains("translation_books")
                ? "LEFT JOIN translation_books b ON b.translation_id = v.translation_id AND b.book_number = v.book" : ""
        } else {
            books = tables.contains("books") ? "LEFT JOIN books b ON b.id = v.book" : ""
        }
        let columns = """
            \(translationColumn) AS translation_id, v.ref, v.book, v.chapter, v.verse,
            \(books.isEmpty ? "NULL" : "b.name") AS book_name, v.text
            """
        var conditions: [String] = []
        var filters = StatementArguments()
        if shared, let translations {
            conditions.append("v.translation_id IN (\(translations.map { _ in "?" }.joined(separator: ", ")))")
            filters += StatementArguments(translations)
        }
        if let bookRange {
            conditions.append("v.book BETWEEN ? AND ?")
            filters += [bookRange.lowerBound, bookRange.upperBound]
        }

        func hit(_ row: Row) -> LampVerseSearchHit {
            let text: String = row["text"]
            let book: Int = row["book"]
            return LampVerseSearchHit(
                translationID: row["translation_id"], reference: row["ref"], book: book,
                chapter: row["chapter"], verse: row["verse"],
                bookName: row["book_name"] ?? LampBibleReferenceFormatter.bookName(book),
                text: text, holdsPhrase: query.holdsPhrase(text)
            )
        }

        let asked = tables.contains(index) ? try indexQuery(query, index: index, in: db) : nil
        if case .nothing = asked { return [] }
        if let match = asked?.match {
            // Every match is ranked either way; numbered within its
            // translation, each keeps its best.
            arguments += [match]
            arguments += filters
            arguments += [limit]
            return try Row.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT *, ROW_NUMBER() OVER (PARTITION BY translation_id ORDER BY rank, ref) AS place
                    FROM (
                        SELECT \(columns), bm25(\(index)) AS rank
                        FROM \(index) JOIN \(table) v ON v.id = \(index).rowid \(books)
                        WHERE \(([index + " MATCH ?"] + conditions).joined(separator: " AND "))
                    )
                )
                WHERE place <= ?
                ORDER BY translation_id, place
                """, arguments: arguments).map(hit)
        }

        // Without an index, or where it can't answer, found by LIKE in the
        // Bible's order and kept where the query's own rule finds the words.
        let like = query.sqlLikePredicate(columns: ["v.text"])
        arguments += StatementArguments(like.arguments)
        arguments += filters
        let rows = try Row.fetchCursor(db, sql: """
            SELECT \(columns)
            FROM \(table) v \(books)
            WHERE \(([like.condition] + conditions).joined(separator: " AND "))
            ORDER BY \(shared ? "v.translation_id, " : "")v.ref
            """, arguments: arguments)
        var kept: [LampVerseSearchHit] = []
        var counts: [String: Int] = [:]
        // Done once each translation asked for has its fill, rather than at
        // the end of every verse LIKE finds.
        let wanted = ownID.map { [$0] } ?? translations.map(Set.init).map(Array.init)
        while let row = try rows.next() {
            let translationID: String = row["translation_id"]
            guard counts[translationID, default: 0] < limit, query.matches(row["text"]) else { continue }
            counts[translationID, default: 0] += 1
            kept.append(hit(row))
            if let wanted, wanted.allSatisfy({ counts[$0, default: 0] >= limit }) { break }
        }
        return kept
    }

    /// A search's results from several modules, at most `limit` of them,
    /// shared as evenly as the modules allow: each module's best, in its own
    /// order, and room one module can't fill goes to the others. A search
    /// across several modules hears from each, however many it names and in
    /// whatever order, rather than filling from the first.
    public static func sharedEvenly<Hit>(_ found: [[Hit]], limit: Int) -> [Hit] {
        zip(found, shares(of: found.map(\.count), limit: limit)).flatMap { $0.prefix($1) }
    }

    /// How many of each of lists of `counts` `sharedEvenly` keeps.
    static func shares(of counts: [Int], limit: Int) -> [Int] {
        var shares = Array(repeating: 0, count: counts.count)
        var room = limit
        // Fewest first, so what a short list leaves is shared by the rest.
        let fewestFirst = counts.indices.sorted { counts[$0] < counts[$1] }
        for (position, index) in fewestFirst.enumerated() {
            shares[index] = min(counts[index], room / (counts.count - position))
            room -= shares[index]
        }
        return shares
    }
}
