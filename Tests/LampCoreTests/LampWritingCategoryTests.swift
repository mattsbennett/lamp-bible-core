import Testing
@testable import LampCore

struct LampWritingCategoryTests {
    /// The vocabulary the editors offer. Pinned because it is a decision about
    /// the writing, not an implementation detail: the owner chose these five
    /// and dropped `testimony` and `other`, neither of which had ever been
    /// applied to a writing.
    @Test func theOfferedKindsAreTheFiveChosen() {
        #expect(LampWritingCategory.suggestions == [
            "devotional", "exhortation", "reflection", "study", "prayer",
        ])
    }

    /// A suggestion that is not stored as it is offered would be saved as
    /// something other than what was shown, and would never match itself.
    @Test func everySuggestionIsStoredAsItIsOffered() {
        for suggestion in LampWritingCategory.suggestions {
            #expect(LampWritingCategory.canonical(suggestion) == suggestion)
        }
    }

    /// The kinds with one right spelling are snapped to it; every other kind
    /// keeps the capitals the writer gave it, because folding on the way in
    /// cannot be undone.
    @Test(arguments: [
        ("exhortation", "exhortation"),
        ("Exhortation", "exhortation"),
        ("  EXHORTATION  ", "exhortation"),
        ("sermon", "exhortation"),
        ("Sermon", "exhortation"),
        ("Q&A", "Q&A"),
        ("ClassDiscussion_1", "ClassDiscussion_1"),
        ("Man of Sin handout", "Man of Sin handout"),
        ("class  discussion", "class discussion"),
        ("  Handout\n", "Handout"),
    ])
    func akindIsStoredAsItWasWritten(written: String, stored: String) {
        #expect(LampWritingCategory.canonical(written) == stored)
    }

    /// Folding is for telling kinds apart, and only for that.
    @Test func onekindTypedTwoWaysIsOneKind() {
        #expect(LampWritingCategory.foldedKey("Handout") == LampWritingCategory.foldedKey("handout"))
        #expect(LampWritingCategory.foldedKey("Sermon") == LampWritingCategory.foldedKey("exhortation"))
        #expect(LampWritingCategory.foldedKey("study") != LampWritingCategory.foldedKey("study questions"))
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func nothingWrittenIsNoKindAtAll(written: String) {
        #expect(LampWritingCategory.canonical(written) == nil)
        #expect(LampWritingCategory.foldedKey(written) == nil)
        #expect(LampWritingCategory.displayName(written) == nil)
    }

    @Test func noKindSurvivesAsNoKind() {
        #expect(LampWritingCategory.canonical(nil) == nil)
        #expect(LampWritingCategory.foldedKey(nil) == nil)
        #expect(LampWritingCategory.displayName(nil) == nil)
    }

    /// The first letter is raised and the rest is left alone, so a kind the
    /// writer capitalised on purpose is shown the way they wrote it.
    @Test(arguments: [
        ("study", "Study"),
        ("sermon", "Exhortation"),
        ("handout", "Handout"),
        ("class discussion", "Class discussion"),
        ("Q&A", "Q&A"),
        ("ClassDiscussion_1", "ClassDiscussion_1"),
        ("Man of Sin handout", "Man of Sin handout"),
    ])
    func akindIsShownAsItWasWritten(stored: String, shown: String) {
        #expect(LampWritingCategory.displayName(stored) == shown)
    }

    /// A filter lists what a library holds and nothing else — a suggestion
    /// nobody has written is not a filter worth offering.
    @Test func thekindsHeldAreTheOnesWritten() {
        let held = LampWritingCategory.kindsHeld([
            "study", "Handout", "handout", nil, "", "Sermon", "STUDY",
        ])
        #expect(held == ["Handout", "exhortation", "study"])
        #expect(LampWritingCategory.kindsHeld([]).isEmpty)
        #expect(LampWritingCategory.kindsHeld([nil, "", "  "]).isEmpty)
    }

    /// What the editor offers grows with the writing: the suggestions first,
    /// in their own order, then whatever else the writer has used.
    @Test func thekindsOfferedIncludeTheOnesAlreadyWritten() {
        let offered = LampWritingCategory.offered(forLibraryHolding: [
            "study", "Handout", "class discussion", nil, "", "sermon",
        ])
        #expect(offered == LampWritingCategory.suggestions + ["Handout", "class discussion"])
    }

    /// A kind the writer has used that is also suggested is offered once, in
    /// the suggestion's own place.
    @Test func akindBothSuggestedAndUsedIsOfferedOnce() {
        let offered = LampWritingCategory.offered(forLibraryHolding: ["study", "STUDY", "Sermon"])
        #expect(offered == LampWritingCategory.suggestions)
    }

    /// Two spellings of one bespoke kind are one entry, and which one is shown
    /// does not depend on the order they came out of the library.
    @Test(arguments: [["Handout", "handout"], ["handout", "Handout"]])
    func twoSpellingsOfAkindAreOfferedOnce(held: [String]) {
        #expect(LampWritingCategory.offered(forLibraryHolding: held)
            == LampWritingCategory.suggestions + ["Handout"])
    }

    /// The bug this fixes: every surface shows a kind capitalised, so a reader
    /// typing what they saw found nothing, because the comparison was exact.
    @Test func akindIsFoundWhateverTheCaseItIsAskedIn() {
        let criteria = LampDevotionalSearchCriteria(categories: ["Exhortation"])
        #expect(criteria.matches(date: nil, tags: [], category: "exhortation"))
        let sql = criteria.sqlConditions(tableAlias: "")
        #expect(sql.clauses == ["category COLLATE NOCASE IN (?, ?)"])
        #expect(sql.arguments == ["exhortation", "sermon"])
    }

    /// A library an older build wrote still holds `sermon`, so asking for an
    /// exhortation has to ask for both names.
    @Test func askingForAnexhortationFindsAnOlderSermon() {
        let criteria = LampDevotionalSearchCriteria(categories: ["exhortation"])
        #expect(criteria.matches(date: nil, tags: [], category: "sermon"))
        #expect(criteria.matches(date: nil, tags: [], category: "exhortation"))
        #expect(!criteria.matches(date: nil, tags: [], category: "study"))
    }

    @Test func akindTheVocabularyNeverKnewIsStillSearchable() {
        let criteria = LampDevotionalSearchCriteria(categories: ["Study Questions"])
        #expect(criteria.matches(date: nil, tags: [], category: "study questions"))
        #expect(!criteria.matches(date: nil, tags: [], category: "study"))
        #expect(criteria.sqlConditions(tableAlias: "").arguments == ["Study Questions"])
    }

    @Test func writingOfNoKindIsNotOfEveryKind() {
        let criteria = LampDevotionalSearchCriteria(categories: ["study"])
        #expect(!criteria.matches(date: nil, tags: [], category: nil))
        #expect(!criteria.matches(date: nil, tags: [], category: ""))
    }

    /// A request that named no kind at all asked for one and named none, so it
    /// matches nothing rather than quietly widening to everything — including
    /// writing that has no kind, which a blank must not be read as naming.
    @Test func arequestOfNothingButBlanksMatchesNothing() {
        let criteria = LampDevotionalSearchCriteria(categories: ["", "   "])
        #expect(!criteria.matches(date: nil, tags: [], category: "study"))
        #expect(!criteria.matches(date: nil, tags: [], category: nil))
        let sql = criteria.sqlConditions(tableAlias: "")
        #expect(sql.clauses == ["1 = 0"])
        #expect(sql.arguments.isEmpty)
    }
}
