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

    @Test func likePredicateRequiresEveryTermAcrossFields() {
        let predicate = LampSearchQuery("hope grace").sqlLikePredicate(
            columns: ["title", "content"]
        )
        #expect(predicate.condition.contains(" AND "))
        #expect(predicate.arguments == ["%hope%", "%hope%", "%grace%", "%grace%"])
    }
}
