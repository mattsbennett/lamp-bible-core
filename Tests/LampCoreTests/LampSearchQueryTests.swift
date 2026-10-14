import Foundation
import GRDB
import Testing
@testable import LampCore

struct LampSearchQueryTests {
    @Test func keepsQuotedPhrasesAndEscapesFTS5Operators() {
        let query = LampSearchQuery("\u{201C}living water\u{201D} hope")
        #expect(query.terms == [
            LampSearchTerm(text: "living water", isExact: true),
            LampSearchTerm(text: "hope", isExact: false),
        ])
        #expect(query.fts5Query == "\"living water\" \"hope\"*")
        #expect(LampSearchQuery("hope*").fts5Query == "\"hope\"*")
        #expect(query.matches("Jesus offers living water and hopefulness"))
        #expect(!query.matches("Jesus offers living waters and hopefulness"))
    }

    @Test func retainsIOSRankingAndUnclosedQuoteBehavior() {
        let query = LampSearchQuery("'faith hope")
        #expect(query.terms == [LampSearchTerm(text: "faith hope", isExact: true)])
        #expect(query.textRank(in: ["faith hope", "faith hope in God", "strong faith hope"])
            == 16)
        #expect(query.realmPrefilter == "faith hope")
    }

    /// Two words search as "both of these words, anywhere" — not as a phrase.
    /// Each platform used to escape its own queries, and three of iOS's search
    /// paths wrapped the whole query in one quoted phrase with a trailing star,
    /// so a verse search for "faith works" asked FTS5 for the two words
    /// adjacent and missed "faith without works" while every other kind of
    /// result matched it.
    @Test func separateWordsMatchIndependentlyRatherThanAsAPhrase() {
        #expect(LampSearchQuery("faith works").fts5Query == "\"faith\"* \"works\"*")
        #expect(LampSearchQuery("faith works").matches("faith without works is dead"))
    }

    /// Quoting is how a reader asks for the words together, so it has to
    /// survive into the FTS5 query as a phrase without the prefix star.
    @Test func quotingIsTheOnlyWayToAskForAPhrase() {
        let phrase = LampSearchQuery("\"faith works\"")
        #expect(phrase.fts5Query == "\"faith works\"")
        #expect(phrase.matches("faith works through love"))
        #expect(!phrase.matches("faith without works is dead"))
    }

    /// FTS5 reads these as operators. Any that reaches MATCH unescaped is a
    /// syntax error, and a search that errors returns nothing at all — so the
    /// check is that SQLite accepts the query, not that the string looks right.
    @Test(arguments: [
        "grace*", "grace^", "grace:", "(grace)", "grace-filled", "gra\"ce",
        "NOT grace", "grace OR peace", "grace AND peace", "grace NEAR peace",
    ])
    func everyQueryIsAcceptedByFTS5(typed: String) throws {
        let query = LampSearchQuery(typed).fts5Query
        try #require(!query.isEmpty)
        // Throws on a malformed MATCH argument.
        _ = try FTS5Probe().matches(query)
    }

    /// Punctuation on its own is not a search. Returning an empty query is what
    /// lets each caller skip the query rather than ask FTS5 for nothing.
    @Test(arguments: ["", "   ", "***", "()", "\"\""])
    func aQueryWithNoWordsInItIsEmpty(typed: String) {
        #expect(LampSearchQuery(typed).fts5Query.isEmpty)
    }

    /// A hyphen separates; it does not vanish. FTS5 stores "self-control" as
    /// two tokens, so deleting the hyphen asked for one token no verse has and
    /// a search for a hyphenated word came back empty.
    @Test(arguments: ["self-control", "grace-filled", "loving-kindness"])
    func aHyphenatedWordFindsTheHyphenatedText(typed: String) throws {
        let probe = try FTS5Probe(texts: [
            "temperance, self-control, and patience",
            "in grace-filled speech",
            "his loving-kindness endures",
        ])
        #expect(try probe.matches(LampSearchQuery(typed).fts5Query).count == 1)
    }

    @Test func likePredicateRequiresEveryTermAcrossFields() {
        let predicate = LampSearchQuery("hope grace").sqlLikePredicate(
            columns: ["title", "content"]
        )
        #expect(predicate.condition.contains(" AND "))
        #expect(predicate.arguments == ["%hope%", "%hope%", "%grace%", "%grace%"])
    }
}

/// A real FTS5 table, so the queries are judged by SQLite rather than by how
/// their strings look.
private struct FTS5Probe {
    private let queue: DatabaseQueue

    init(texts: [String] = ["grace and peace to you"]) throws {
        queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE v USING fts5(text)")
            for text in texts {
                try db.execute(sql: "INSERT INTO v(text) VALUES (?)", arguments: [text])
            }
        }
    }

    func matches(_ query: String) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM v WHERE v MATCH ?", arguments: [query])
        }
    }
}
