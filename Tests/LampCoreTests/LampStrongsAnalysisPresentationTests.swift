import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// Narrowing an analysis to the occurrences behind one of its figures.
///
/// These are the sums the pane does for itself. Core counts; the pane decides
/// which occurrences a reader meant when they clicked a number, and getting
/// that wrong shows them a list that disagrees with the figure they clicked.
struct StrongsAnalysisSupportTests {
    private static func reference(book: Int, chapter: Int, verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    private static func occurrence(
        book: Int = 43,
        chapter: Int = 1,
        verse: Int = 1,
        renderingID: String = "word",
        form: String? = "λόγος",
        morphology: String? = nil
    ) -> LampStrongsAnalysis.Occurrence {
        LampStrongsAnalysis.Occurrence(
            reference: reference(book: book, chapter: chapter, verse: verse),
            startOffset: 0,
            endOffset: 4,
            text: "Word",
            renderingID: renderingID,
            form: form,
            morphology: morphology
        )
    }

    private static func analysis(
        key: String = "G3056",
        translationID: String,
        occurrences: [LampStrongsAnalysis.Occurrence] = [],
        books: [LampStrongsAnalysis.Division] = []
    ) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: key,
            translationID: translationID,
            translationName: translationID,
            translationAbbreviation: translationID,
            wordCount: 1_000,
            taggedVerseCount: 10,
            occurrences: occurrences,
            references: occurrences.map(\.reference),
            renderings: [],
            forms: [],
            parsings: [],
            grammar: [],
            books: books,
            sections: [],
            companions: []
        )
    }

    private static func division(
        id: Int,
        name: String,
        occurrenceCount: Int,
        wordCount: Int,
        keyness: Double = 0
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id,
            name: name,
            bookRange: id...id,
            occurrenceCount: occurrenceCount,
            verseCount: occurrenceCount,
            wordCount: wordCount,
            expectedCount: 0,
            keyness: keyness,
            chapters: []
        )
    }

    // MARK: - Is the key there at all

    /// The case that sent this rule here: every translation answers, and the
    /// answer is a card of noughts.
    @Test func aKeyNoTranslationTagsIsAbsent() {
        // wordCount is the module's tagged words, not the key's, so it is a
        // thousand for a key that is nowhere. That is what made the pane
        // believe it had something to draw.
        let answers = [
            Self.analysis(key: "H0", translationID: "esv"),
            Self.analysis(key: "H0", translationID: "kjv"),
        ]
        #expect(answers.allSatisfy { $0.wordCount > 0 })
        #expect(LampStrongsPresence.absent(from: answers))
    }

    /// One occurrence anywhere is a finding, however many modules answered
    /// with none.
    @Test func oneOccurrenceInAnyTranslationIsPresent() {
        #expect(!LampStrongsPresence.absent(from: [
            Self.analysis(translationID: "esv"),
            Self.analysis(translationID: "kjv", occurrences: [Self.occurrence()]),
        ]))
    }

    /// No analyses at all — no tagged translation installed — is absent too,
    /// so the caller has one question to ask rather than two.
    @Test func nothingAskedIsAbsent() {
        #expect(LampStrongsPresence.absent(from: []))
    }

    /// Why it found nothing is a different sentence when the search was
    /// narrowed: the key may be tagged all through the Bible and reach none
    /// of the books chosen, and the unnarrowed wording would be false there.
    @Test func theReasonNamesTheBooksOnlyWhenNarrowed() {
        #expect(LampStrongsPresence.reason(narrowed: true).contains("chosen books"))
        #expect(!LampStrongsPresence.reason(narrowed: false).contains("chosen books"))
        #expect(LampStrongsPresence.title(key: "H0") == "No Tags for H0")
    }

    /// Books the key is in, out of the books in range that tag its language —
    /// a zero is a book that could have had it and does not.
    @Test func booksWithOccurrencesCountsOnlyBooksTheKeyIsIn() {
        let analysis = Self.analysis(translationID: "BSBs", books: [
            Self.division(id: 43, name: "John", occurrenceCount: 7, wordCount: 100),
            Self.division(id: 44, name: "Acts", occurrenceCount: 0, wordCount: 100),
            Self.division(id: 45, name: "Romans", occurrenceCount: 9, wordCount: 100),
        ])
        #expect(analysis.booksWithOccurrences == 2)
        #expect(analysis.books.count == 3)
    }

    // MARK: - Filtering

    @Test func arenderingKeepsOnlyItsOwnOccurrences() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(renderingID: "word"),
                Self.occurrence(verse: 2, renderingID: "saying"),
                Self.occurrence(verse: 3, renderingID: "word"),
            ]
        )

        let kept = analysis.occurrences(
            matching: .rendering(id: "word", text: "Word")
        )
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.renderingID == "word" })
    }

    @Test func nofilterKeepsEverything() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [Self.occurrence(), Self.occurrence(verse: 2)]
        )
        #expect(analysis.occurrences(matching: nil).count == 2)
    }

    /// A book takes all of its chapters; a chapter takes only its own. Both
    /// read the book out of the verse reference, so a filter that compared the
    /// wrong digits would pass one of these and fail the other.
    @Test func abookTakesItsChaptersAndAChapterTakesOnlyItsOwn() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(book: 43, chapter: 1, verse: 1),
                Self.occurrence(book: 43, chapter: 3, verse: 16),
                Self.occurrence(book: 41, chapter: 1, verse: 1),
            ]
        )

        #expect(analysis.occurrences(matching: .book(number: 43)).count == 2)
        #expect(analysis.occurrences(matching: .book(number: 41)).count == 1)
        #expect(
            analysis.occurrences(matching: .chapter(book: 43, number: 1)).count == 1,
            "John 1 must not collect Mark 1"
        )
        #expect(analysis.occurrences(matching: .chapter(book: 41, number: 1)).count == 1)
        #expect(analysis.occurrences(matching: .chapter(book: 43, number: 2)).isEmpty)
    }

    /// Grammar is read through core's own parser, because the counts this
    /// filter narrows were produced by that parser. The filter must compare
    /// the feature as well as the value, and a word with no parsing belongs to
    /// no grammatical value at all.
    @Test func grammarMatchesThroughCoresParserAndNeedsBothHalves() throws {
        let aorist = try #require(
            LampGreekMorphology.features(of: "V-AAI-3S").first { $0.feature == .tense }
        )
        let analysis = Self.analysis(
            translationID: "KJVs",
            occurrences: [
                Self.occurrence(verse: 1, morphology: "V-AAI-3S"),
                Self.occurrence(verse: 2, morphology: "V-PAI-3S"),
                Self.occurrence(verse: 3, morphology: nil),
            ]
        )

        let kept = analysis.occurrences(
            matching: .grammar(feature: aorist.feature, value: aorist.value)
        )
        #expect(kept.count == 1, "only the aorist occurrence")
        #expect(kept.first?.morphology == "V-AAI-3S")

        #expect(
            analysis.occurrences(
                matching: .grammar(feature: .gender, value: aorist.value)
            ).isEmpty,
            "the same value under another feature must not match"
        )
    }

    /// A Hebrew word's grammar is read by the Hebrew parser, for the morpheme
    /// its Strong's number names, as the analysis counted it. Read as Greek,
    /// "Noun 36" in TAHOT's ʼahăbâh (H160) narrowed to nothing.
    @Test func hebrewGrammarMatchesTheWordsOwnMorpheme() throws {
        let noun = try #require(
            LampMorphology.features(of: "HR/Ncfsc/Sp3ms", strongsKey: "H160")
                .first { $0.feature == .partOfSpeech }
        )
        let qal = try #require(
            LampMorphology.features(of: "HR/Vqcc", strongsKey: "H160").first { $0.feature == .stem }
        )
        let analysis = Self.analysis(
            key: "H160",
            translationID: "TAHOT",
            occurrences: [
                Self.occurrence(book: 1, chapter: 29, verse: 20, form: nil, morphology: "HR/Ncfsc/Sp3ms"),
                Self.occurrence(book: 22, chapter: 2, verse: 4, form: nil, morphology: "HNcfsa"),
                Self.occurrence(book: 5, chapter: 10, verse: 15, form: nil, morphology: "HR/Vqcc"),
            ]
        )

        #expect(analysis.occurrences(matching: .grammar(feature: noun.feature, value: noun.value)).count == 2)
        #expect(analysis.occurrences(matching: .grammar(feature: qal.feature, value: qal.value)).count == 1)
    }

    @Test func aformMatchesTheTaggedWordAndNeverAnUntaggedOne() {
        let analysis = Self.analysis(
            translationID: "BSBs",
            occurrences: [
                Self.occurrence(verse: 1, form: "λόγος"),
                Self.occurrence(verse: 2, form: "λόγου"),
                Self.occurrence(verse: 3, form: nil),
            ]
        )

        #expect(analysis.occurrences(matching: .form("λόγος")).count == 1)
        #expect(analysis.occurrences(matching: .form("λόγου")).count == 1)
    }

    // MARK: - The chip

    /// The chip is the only thing telling a reader what the list has been
    /// narrowed to, so every case has to name itself in words — a rendering by
    /// its text and never its id.
    @Test func everyfilterNamesItselfForTheChip() {
        #expect(LampStrongsFilter.rendering(id: "word-1", text: "Word").label == "“Word”")
        #expect(LampStrongsFilter.form("λόγος").label == "λόγος")
        #expect(LampStrongsFilter.grammar(feature: .tense, value: "Aorist").label
            == "Tense: Aorist")
        #expect(LampStrongsFilter.book(number: 43).label == "John")
        #expect(LampStrongsFilter.chapter(book: 43, number: 3).label == "John 3")
    }

    /// The chip sits in the occurrence list's heading, after the count, so
    /// it has to finish that sentence: "1 of 113 occurrences rendered
    /// “beloved”".
    @Test func everyFilterFinishesTheListsHeading() {
        #expect(LampStrongsFilter.rendering(id: "word-1", text: "beloved").narrowing
            == "translated “beloved”")
        #expect(LampStrongsFilter.form("λόγον").narrowing == "as λόγον")
        #expect(LampStrongsFilter.grammar(feature: .tense, value: "Aorist").narrowing
            == "Tense: Aorist")
        #expect(LampStrongsFilter.book(number: 43).narrowing == "in John")
        #expect(LampStrongsFilter.chapter(book: 43, number: 3).narrowing == "in John 3")
    }

    /// Unfiltered, the heading says the list is whole rather than leaving a
    /// bare count that could be a page of a longer list.
    @Test func theListsHeadingSaysWhetherItIsWhole() {
        #expect(LampStrongsFilter.heading(shown: 113, total: 113, narrowed: false)
            == "All 113 occurrences")
        #expect(LampStrongsFilter.heading(shown: 1, total: 113, narrowed: true)
            == "1 of 113 occurrences")
        #expect(LampStrongsFilter.heading(shown: 1, total: 1, narrowed: false)
            == "1 occurrence")
        #expect(LampStrongsFilter.heading(shown: 1, total: 1, narrowed: true)
            == "1 of 1 occurrence")
    }

    // MARK: - The definition

    /// A menu choice outranks the default, and the default outranks order —
    /// but a dictionary without an entry for the key is never the one shown.
    @Test func theDefinitionComesFromADictionaryThatHasTheWord() {
        let withEntries = ["strongs_greek", "dodson_greek", "wsd_greek"]
        #expect(LampStrongsDefinitionChoice.shown(
            among: withEntries, chosen: "wsd_greek", preferred: "dodson_greek"
        ) == "wsd_greek")
        #expect(LampStrongsDefinitionChoice.shown(
            among: withEntries, chosen: nil, preferred: "dodson_greek"
        ) == "dodson_greek")
        #expect(LampStrongsDefinitionChoice.shown(
            among: withEntries, chosen: "bdb", preferred: "abbott_smith"
        ) == "strongs_greek")
        #expect(LampStrongsDefinitionChoice.shown(
            among: [], chosen: "wsd_greek", preferred: "dodson_greek"
        ) == nil)
    }

    /// What the panes actually compose: the candidates are ordered by the
    /// language's preference before `shown` takes the first with an entry, so a
    /// reader who has chosen nothing gets Strong's — not Dodson, which merely
    /// sorts first by name, and not TBESG, whose entries assume Greek.
    @Test func theGreekDefaultIsStrongsEvenThoughDodsonSortsFirst() {
        let byName = ["dodson_greek", "strongs_greek", "tbesg"]
        let ordered = LampModuleSelection.ordered(
            byName, preferredIDs: LampModuleSelection.preferredGreekDictionaryIDs, id: { $0 }
        )
        #expect(LampStrongsDefinitionChoice.shown(
            among: ordered, chosen: nil, preferred: nil
        ) == "strongs_greek")
        // An explicit choice still outranks the preference.
        #expect(LampStrongsDefinitionChoice.shown(
            among: ordered, chosen: "dodson_greek", preferred: nil
        ) == "dodson_greek")
        // Strong's absent from the key's entries: TBESG, then the rest by name.
        #expect(LampStrongsDefinitionChoice.shown(
            among: ordered.filter { $0 != "strongs_greek" }, chosen: nil, preferred: nil
        ) == "tbesg")
    }

    // MARK: - The Septuagint section

    /// The same Hebrew word named by two senses is one word to a reader, and
    /// the lexicon's order is the order it is printed in.
    @Test func theHebrewIsListedOnceInTheOrderTheLexiconPrintsIt() {
        let senses = [
            LampDictionarySense(septuagintHebrew: [
                LampSeptuagintHebrew(text: "דָּבָר", strongs: "H1697"),
                LampSeptuagintHebrew(text: "מִלָּה", strongs: "H4405"),
            ]),
            LampDictionarySense(septuagintHebrew: [
                LampSeptuagintHebrew(text: "דָּבָר", strongs: "H1697"),
                LampSeptuagintHebrew(text: "אֵמֶר", strongs: "H561"),
            ]),
        ]
        #expect(LampSeptuagintSection.words(in: senses).map(\.strongs)
            == ["H1697", "H4405", "H561"])
        #expect(LampSeptuagintSection.words(in: []).isEmpty)
        #expect(LampSeptuagintSection.words(in: [LampDictionarySense(definition: "x")])
            .isEmpty)
    }

    /// Two words that share a number are still two words: folding them would
    /// lose one of the forms the lexicon prints.
    @Test func wordsSharingANumberAreNotFoldedTogether() {
        let senses = [LampDictionarySense(septuagintHebrew: [
            LampSeptuagintHebrew(text: "גיל", strongs: "H1523"),
            LampSeptuagintHebrew(text: "גילה", strongs: "H1523"),
        ])]
        #expect(LampSeptuagintSection.words(in: senses).count == 2)
    }

    @Test func aStemIsPrintedWithItsWord() {
        #expect(LampSeptuagintSection.word(
            LampSeptuagintHebrew(text: "רנן", stem: "pi.")
        ) == "רנן pi.")
        #expect(LampSeptuagintSection.word(
            LampSeptuagintHebrew(text: "גיל", strongs: "H1523")
        ) == "גיל")
    }

    /// The heading has one job beyond counting: saying whose verses these are.
    /// The Septuagint doesn't always use this Greek word where that Hebrew
    /// stands, so a bare "40 verses" beside a Greek word would be a wrong
    /// claim about the Greek word.
    @Test func theHeadingSaysTheVersesAreTheHebrewWords() {
        let hebrew = LampSeptuagintHebrew(text: "אַהֲבָה", strongs: "H160")
        #expect(LampSeptuagintSection.heading(hebrew, verses: 40)
            == "Hebrew אַהֲבָה (H160) · 40 verses")
        #expect(LampSeptuagintSection.heading(hebrew, verses: 1)
            == "Hebrew אַהֲבָה (H160) · 1 verse")
        // No number to show, and nothing to follow: the word still names itself.
        #expect(LampSeptuagintSection.heading(
            LampSeptuagintHebrew(text: "רנן", stem: "pi."), verses: 0
        ) == "Hebrew רנן pi. · 0 verses")
    }

    /// A missing verse names the text that is missing it. Brenton prints
    /// Codex Vaticanus, which leaves out 1 Samuel 18:1–5 among others, and
    /// other witnesses have them — so the absence is that edition's, not the
    /// Septuagint tradition's.
    @Test func aMissingVerseNamesTheTextRatherThanTheWholeTradition() {
        #expect(LampSeptuagintSection.missingVerse(in: "Brenton Greek Septuagint")
            == "This verse isn’t in Brenton Greek Septuagint.")
        #expect(LampSeptuagintSection.missingVerse(in: nil)
            == "This verse isn’t in the Greek text installed.")
        #expect(LampSeptuagintSection.missingVerse(in: "")
            == "This verse isn’t in the Greek text installed.")
    }

    /// With no Septuagint installed there is one thing to say, and it is about
    /// the library. Saying it against each verse instead would make
    /// twenty-five claims about verses nothing has looked at.
    @Test func noSeptuagintIsOneFactAboutTheLibraryNotOneAboutEachVerse() {
        #expect(LampSeptuagintSection.withoutSeptuagint
            == "No Septuagint is installed, so there’s no Greek to put beside these verses.")
        #expect(!LampSeptuagintSection.withoutSeptuagint.contains("This verse"))
    }

    /// A read that failed says so. It must not borrow the missing-verse
    /// wording, which claims the text does not have the verse — a failed read
    /// has not established that, and the next attempt may well find it.
    @Test func afailedReadIsNotAMissingVerse() {
        #expect(LampSeptuagintSection.unreadable("Brenton Greek Septuagint")
            == "Brenton Greek Septuagint couldn’t be read.")
        #expect(LampSeptuagintSection.unreadable(nil) == "The Greek text couldn’t be read.")
        #expect(LampSeptuagintSection.unreadable("") == "The Greek text couldn’t be read.")
        #expect(!LampSeptuagintSection.unreadable("Brenton").contains("isn’t in"))
    }

    // MARK: - The spread chart

    @Test func barsAreScaledAgainstTheLongestOne() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(id: 41, name: "Mark", occurrenceCount: 5, wordCount: 1_000),
                Self.division(id: 43, name: "John", occurrenceCount: 20, wordCount: 1_000),
            ],
            measure: .occurrences
        )

        #expect(bars.map(\.name) == ["Mark", "John"], "the order given is kept")
        #expect(bars[1].share == 1)
        #expect(bars[0].share == 0.25)
    }

    /// Each bar carries its part of the whole, the same under either measure,
    /// so a count can say "80%" without a ring beside it.
    @Test func eachBarCarriesItsPartOfEveryOccurrence() {
        let divisions = [
            Self.division(id: 41, name: "Mark", occurrenceCount: 5, wordCount: 1_000),
            Self.division(id: 43, name: "John", occurrenceCount: 20, wordCount: 100_000),
            Self.division(id: 42, name: "Luke", occurrenceCount: 0, wordCount: 1_000),
        ]
        for measure in LampStrongsSpreadMeasure.allCases {
            let bars = LampStrongsSpread.bars(divisions, measure: measure)
            #expect(bars.map(\.fractionOfOccurrences) == [0.2, 0.8, 0])
        }
        let nowhere = LampStrongsSpread.bars(
            [Self.division(id: 41, name: "Mark", occurrenceCount: 0, wordCount: 1_000)],
            measure: .occurrences
        )
        #expect(nowhere[0].fractionOfOccurrences == 0)
    }

    /// A book that holds the word never reads "0%".
    @Test func aPercentTooSmallToRoundIsLessThanOne() {
        #expect(LampStrongsSpread.percent(0.16) == "16%")
        #expect(LampStrongsSpread.percent(1) == "100%")
        #expect(LampStrongsSpread.percent(0.004) == "<1%")
        #expect(LampStrongsSpread.percent(0) == "0%")
    }

    /// Where the word occurs is the spread's one question: books and sections
    /// are bars with a rate to offer, and chapters are the grid, without one.
    @Test func theSpreadIsGroupedOnlyByWhere() {
        #expect(LampStrongsSpreadGrouping.allCases.map(\.title) == ["Books", "Sections", "Chapters"])
        #expect(LampStrongsSpreadGrouping.books.bars == .books)
        #expect(LampStrongsSpreadGrouping.sections.bars == .sections)
        #expect(LampStrongsSpreadGrouping.chapters.bars == nil)
        #expect(LampStrongsSpreadGrouping.books.usesMeasure)
        #expect(!LampStrongsSpreadGrouping.chapters.usesMeasure)
    }

    /// Per 1,000 words is a different ranking, not a rescaling: a short book
    /// with few occurrences can outrank a long one with many.
    @Test func therateCanRankABookAboveOneWithMoreOccurrences() {
        let divisions = [
            Self.division(id: 43, name: "John", occurrenceCount: 20, wordCount: 100_000),
            Self.division(id: 65, name: "Jude", occurrenceCount: 2, wordCount: 1_000),
        ]

        let byCount = LampStrongsSpread.bars(divisions, measure: .occurrences)
        #expect(byCount[0].share == 1, "John has the most occurrences")

        let byRate = LampStrongsSpread.bars(divisions, measure: .perThousandWords)
        #expect(byRate[1].share == 1, "but Jude uses it far more densely")
        #expect(byRate[0].value == 0.2)
        #expect(byRate[1].value == 2)
    }

    /// A key that occurs nowhere in range. Every bar is zero, and the longest
    /// of them is zero, so the share has to be decided rather than divided.
    @Test func akeyThatOccursNowhereDrawsNoBarsRatherThanFullOnes() {
        for measure in LampStrongsSpreadMeasure.allCases {
            let bars = LampStrongsSpread.bars(
                [
                    Self.division(id: 41, name: "Mark", occurrenceCount: 0, wordCount: 1_000),
                    Self.division(id: 43, name: "John", occurrenceCount: 0, wordCount: 0),
                ],
                measure: measure
            )
            #expect(bars.allSatisfy { $0.share == 0 }, "\(measure.title) must draw nothing")
            #expect(bars.allSatisfy { $0.value.isFinite }, "\(measure.title) must not be NaN")
        }
    }

    @Test func divisionsWithNoWordsDoNotDivideByZero() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(id: 43, name: "John", occurrenceCount: 4, wordCount: 0),
                Self.division(id: 41, name: "Mark", occurrenceCount: 2, wordCount: 1_000),
            ],
            measure: .perThousandWords
        )
        #expect(bars[0].value == 0, "no tagged words means no rate, not infinity")
        #expect(bars.allSatisfy { $0.value.isFinite })
        #expect(bars[1].share == 1)
    }

    @Test func anotableDivisionCarriesItsStanding() {
        let bars = LampStrongsSpread.bars(
            [
                Self.division(
                    id: 43, name: "John", occurrenceCount: 40, wordCount: 1_000,
                    keyness: LampStrongsAnalysis.notableKeyness + 1
                ),
                Self.division(
                    id: 41, name: "Mark", occurrenceCount: 1, wordCount: 1_000,
                    keyness: -(LampStrongsAnalysis.notableKeyness + 1)
                ),
                Self.division(id: 42, name: "Luke", occurrenceCount: 10, wordCount: 1_000),
            ],
            measure: .occurrences
        )

        #expect(bars[0].expectation == .more)
        #expect(bars[1].expectation == .fewer)
        #expect(bars[2].expectation == .asExpected, "below the threshold is not news")
    }

    // MARK: - Which translation leads

    /// The pane shows the translation being read before the others have been
    /// worked out, so the settled order has to begin with that same one.
    @Test func thetranslationBeingReadComesFirst() {
        let analyses = ["BSBs", "KJVs", "WEBs"].map { Self.analysis(translationID: $0) }

        let ordered = LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: "WEBs")
        #expect(ordered.map(\.translationID) == ["WEBs", "BSBs", "KJVs"])
        #expect(
            LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: "BSBs")
                .map(\.translationID) == ["BSBs", "KJVs", "WEBs"],
            "one already in front stays there, and the rest keep installed order"
        )
    }

    /// Reading a translation that tags nothing for this key: it has no
    /// analysis, and the rest must not be reshuffled on its account.
    @Test func atranslationWithNoAnalysisLeavesTheOrderAlone() {
        let analyses = ["BSBs", "KJVs"].map { Self.analysis(translationID: $0) }

        for active in ["ESVs", nil] {
            #expect(
                LampStrongsAnalysisOrder.ordered(analyses, activeTranslationID: active)
                    .map(\.translationID) == ["BSBs", "KJVs"]
            )
        }
        #expect(LampStrongsAnalysisOrder.ordered([], activeTranslationID: "BSBs").isEmpty)
    }
}

/// Showing a verse around the word that carries the key.
struct StrongsContextTests {
    @Test func theverseIsSplitAroundTheTaggedWord() {
        let snippet = LampStrongsContext.snippet(
            of: "In the beginning was the Word, and the Word was with God.",
            from: 25,
            to: 29
        )

        #expect(snippet.before == "In the beginning was the ")
        #expect(snippet.word == "Word")
        #expect(snippet.after == ", and the Word was with God.")
        #expect(!snippet.isTrimmedAtStart)
        #expect(!snippet.isTrimmedAtEnd)
    }

    /// A pointed Hebrew word, as TAHOT actually writes it: the unit the
    /// offsets count is the one that gets the whole word.
    ///
    /// The fixture above proves the rule on a made-up verse. This proves it
    /// on the shape of the real thing, which is where it bit: a Hebrew word
    /// with points is far more code points than Characters, so the two units
    /// disagree about where it ends by several places.
    @Test func aPointedHebrewWordIsCountedInCodePoints() {
        let word = "\u{05D0}\u{05B7}\u{05D4}\u{05B2}\u{05D1}\u{05B8}\u{05D4}"   // אַהֲבָה
        let verse = "\(word) \u{05D5}"
        #expect(word.unicodeScalars.count == 7)
        #expect(Array(word).count == 4, "the two units disagree by three")

        // Sliced by the unit the tags count, the whole word comes back.
        let whole = LampStrongsContext.snippet(of: verse, from: 0, to: word.unicodeScalars.count)
        #expect(whole.word == word)
        // Sliced by Characters, as the old note said, it is cut short.
        let cut = LampStrongsContext.snippet(of: verse, from: 0, to: Array(word).count)
        #expect(cut.word != word, "four of seven code points is not the word")
    }

    /// Offsets count code points, not Characters. A decomposed accent
    /// earlier in the verse makes the two disagree, and slicing by Character
    /// moves the highlight off the word.
    ///
    /// This test asserted the opposite, on a fixture that counted its own
    /// offsets in Characters, and so agreed with itself and with nothing
    /// else. Measured over the bundled texts, in verses where the units
    /// differ, every tag lands by code point and none by grapheme — TAHOT
    /// 54,198 of them, TAGNT 11,252.
    @Test func adecomposedAccentEarlierInTheVerseDoesNotMoveTheWord() {
        // "Café" with a combining acute: five scalars, four characters.
        let verse = "Cafe\u{301} and love abide"
        #expect(verse.unicodeScalars.count != Array(verse).count, "the two must disagree here")

        let scalars = Array(verse.unicodeScalars)
        let start = 10
        let end = 14
        #expect(String(String.UnicodeScalarView(scalars[start..<end])) == "love",
            "the offsets a tagger writes")
        // The Character offsets the old note recommended, which land a place
        // early and would cut "e love" out of the middle of the verse.
        #expect(String(Array(verse)[9..<13]) == "love", "and why the two were confused")

        let snippet = LampStrongsContext.snippet(of: verse, from: start, to: end)
        #expect(snippet.word == "love")
        #expect(snippet.after == " abide")
    }

    /// An offset past the end of the verse. Clamped, because a tag that
    /// disagrees with its verse must not take a row down — and must not
    /// silently highlight the wrong words either.
    @Test func offsetsPastTheEndAreClampedRatherThanTrusted() {
        let verse = "Short verse."

        let past = LampStrongsContext.snippet(of: verse, from: 400, to: 500)
        #expect(past.before == verse)
        #expect(past.word.isEmpty)
        #expect(past.after.isEmpty)

        let straddling = LampStrongsContext.snippet(of: verse, from: 6, to: 900)
        #expect(straddling.before == "Short ")
        #expect(straddling.word == "verse.")
        #expect(straddling.after.isEmpty)
    }

    @Test func negativeAndReversedOffsetsGiveNoWordRatherThanACrash() {
        let verse = "In the beginning"

        let negative = LampStrongsContext.snippet(of: verse, from: -5, to: 2)
        #expect(negative.before.isEmpty)
        #expect(negative.word == "In")

        let reversed = LampStrongsContext.snippet(of: verse, from: 9, to: 3)
        #expect(reversed.word.isEmpty, "an end before its start describes nothing")
        #expect(reversed.before == "In the be")
    }

    @Test func alongVerseIsTrimmedEitherSideAndSaysSo() {
        let filler = String(repeating: "word ", count: 60)
        let snippet = LampStrongsContext.snippet(
            of: filler + "LOVE " + filler,
            from: filler.count,
            to: filler.count + 4,
            window: 20
        )

        #expect(snippet.word == "LOVE")
        #expect(snippet.isTrimmedAtStart)
        #expect(snippet.isTrimmedAtEnd)
        #expect(snippet.before.count <= 20)
        #expect(snippet.after.count <= 20)
    }

    /// Trimming stops at a space, so a row never opens or closes on half a
    /// word.
    @Test func trimmingDoesNotCutAWordInHalf() {
        let snippet = LampStrongsContext.snippet(
            of: "Jerusalem Jerusalem Jerusalem LOVE Jerusalem Jerusalem",
            from: 30,
            to: 34,
            window: 15
        )

        #expect(snippet.word == "LOVE")
        #expect(!snippet.before.hasPrefix("salem"), "it must not start mid-word")
        #expect(!snippet.after.hasSuffix("Jerus"), "nor end mid-word")
    }

    /// A verse that was never asked for. The pane only requests verses for the
    /// translation being read, so the rest have none and must simply show no
    /// snippet.
    @Test func atranslationWithNoVersesKeptHasNoSnippets() {
        let analysis = LampStrongsAnalysis(
            key: "G3056", translationID: "KJVs", translationName: "KJV",
            translationAbbreviation: "KJV", wordCount: 10, taggedVerseCount: 1,
            occurrences: [], references: [], renderings: [], forms: [],
            parsings: [], grammar: [], books: [], sections: [], companions: []
        )
        #expect(analysis.verseTexts.isEmpty)
    }
}

/// The other readings of one set of numbers.
struct StrongsChartStyleTests {
    private static func division(
        id: Int, name: String, occurrences: Int, chapters: [(Int, Int)] = []
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id, name: name, bookRange: id...id,
            occurrenceCount: occurrences, verseCount: occurrences, wordCount: 1_000,
            expectedCount: 0, keyness: 0,
            chapters: chapters.map {
                LampStrongsAnalysis.Chapter(
                    number: $0.0, occurrenceCount: $0.1, wordCount: 500
                )
            }
        )
    }

    // MARK: - Putting the gaps back




    // MARK: - Share

    @Test func sharesAreProportionsOfTheWhole() {
        let slices = LampStrongsShare.slices(
            from: [
                Self.division(id: 1, name: "Gospels", occurrences: 25),
                Self.division(id: 2, name: "Paul", occurrences: 75),
            ]
        )
        #expect(slices.map(\.name) == ["Paul", "Gospels"], "largest first")
        #expect(slices[0].fraction == 0.75)
        #expect(slices[1].fraction == 0.25)
        #expect(abs(slices.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001)
    }

    /// A ring of twenty-seven slivers answers nothing, so the tail is
    /// gathered — and the gathered slice still has to carry its real count.
    @Test func thetailIsGatheredIntoOther() {
        let divisions = (1...10).map {
            Self.division(id: $0, name: "Book \($0)", occurrences: 11 - $0)
        }

        let slices = LampStrongsShare.slices(from: divisions, limit: 3)
        #expect(slices.count == 4)
        #expect(slices.last?.isOther == true)
        #expect(slices.last?.name == "Other")
        // 10+9+8 named, the remaining 7...1 gathered.
        #expect(slices.last?.value == 28)
        #expect(abs(slices.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001)
    }

    @Test func nothingToShareDrawsNoSlices() {
        #expect(LampStrongsShare.slices(from: []).isEmpty)
        #expect(
            LampStrongsShare.slices(
                from: [Self.division(id: 1, name: "Gospels", occurrences: 0)]
            ).isEmpty,
            "a slice of nothing is invisible but still takes a label"
        )
    }

    @Test func anexactFitAddsNoOtherSlice() {
        let slices = LampStrongsShare.slices(
            from: [
                Self.division(id: 1, name: "A", occurrences: 2),
                Self.division(id: 2, name: "B", occurrences: 1),
            ],
            limit: 6
        )
        #expect(slices.count == 2)
        #expect(slices.contains { $0.isOther } == false)
    }

    // MARK: - Grid

    /// Shaded against the busiest chapter anywhere, not the busiest in each
    /// row. Per-row shading would paint a book with one occurrence as darkly
    /// as the book with twenty.
    @Test func thegridIsShadedAgainstTheBusiestChapterAnywhere() {
        let rows = LampStrongsGrid.rows(from: [
            Self.division(id: 43, name: "John", occurrences: 2, chapters: [(1, 1), (2, 1)]),
            Self.division(id: 62, name: "1 John", occurrences: 21, chapters: [(1, 1), (4, 20)]),
        ])

        #expect(rows.count == 2)
        let john = try! #require(rows.first { $0.name == "John" })
        let first = try! #require(rows.first { $0.name == "1 John" })
        #expect(first.cells.last?.intensity == 1, "the busiest chapter anchors the ramp")
        #expect(john.cells.first?.intensity == 0.05, "one against twenty, not one against one")
    }

    @Test func booksWithNoChaptersOrNoOccurrencesAreLeftOut() {
        let rows = LampStrongsGrid.rows(from: [
            Self.division(id: 43, name: "John", occurrences: 2, chapters: [(1, 2)]),
            Self.division(id: 41, name: "Mark", occurrences: 0, chapters: [(1, 0)]),
            Self.division(id: 40, name: "Matthew", occurrences: 5),
        ])
        #expect(rows.map(\.name) == ["John"])
    }

    @Test func anemptyGridDoesNotDivideByZero() {
        let rows = LampStrongsGrid.rows(
            from: [Self.division(id: 43, name: "John", occurrences: 0, chapters: [(1, 0)])],
            includingEmptyBooks: true
        )
        #expect(rows.first?.cells.allSatisfy { $0.intensity == 0 } == true)
    }
}

/// Charting renderings and forms, not only books and sections.
struct StrongsGroupingTests {
    private static func analysis() -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: "G3056", translationID: "ASVs", translationName: "ASV",
            translationAbbreviation: "ASV", wordCount: 1_000, taggedVerseCount: 10,
            occurrences: [], references: [],
            renderings: [
                .init(id: "word", text: "word", count: 180, variants: []),
                .init(id: "bare", text: "", count: 3, variants: []),
            ],
            forms: [.init(id: "f1", text: "λόγος", count: 120)],
            parsings: [], grammar: [],
            books: [
                LampStrongsAnalysis.Division(
                    id: 43, name: "John", bookRange: 43...43, occurrenceCount: 37,
                    verseCount: 30, wordCount: 1_000, expectedCount: 0, keyness: 0,
                    chapters: []
                ),
            ],
            sections: [
                LampStrongsAnalysis.Division(
                    id: 40, name: "Gospels", bookRange: 40...43, occurrenceCount: 90,
                    verseCount: 80, wordCount: 5_000, expectedCount: 0, keyness: 0,
                    chapters: []
                ),
            ],
            companions: []
        )
    }

    /// Choosing a bar has to mean what the bar stands for. A rendering bar
    /// looks like a book bar, and narrowing by book there would show the
    /// wrong occurrences while appearing to work.
    @Test func arenderingBarFiltersByItsRendering() throws {
        let entries = LampStrongsGrouping.renderings.divisions(of: Self.analysis())

        #expect(entries.map(\.division.name) == ["word", "(no English of its own)"])
        #expect(entries.map(\.division.occurrenceCount) == [180, 3])
        #expect(entries.first?.filter == .rendering(id: "word", text: "word"))
        #expect(
            entries.last?.filter == .rendering(id: "bare", text: ""),
            "the filter keeps the real text even where the label stands in for it"
        )
    }

    @Test func aformBarFiltersByItsForm() throws {
        let entries = LampStrongsGrouping.forms.divisions(of: Self.analysis())
        #expect(entries.map(\.division.name) == ["λόγος"])
        #expect(entries.first?.filter == .form("λόγος"))
    }

    @Test func abookBarFiltersByItsBookAndASectionByNothing() {
        #expect(
            LampStrongsGrouping.books.divisions(of: Self.analysis()).first?.filter
                == .book(number: 43)
        )
        #expect(
            LampStrongsGrouping.sections.divisions(of: Self.analysis()).first?.filter == nil,
            "a section spans books, and no filter says \"these books\""
        )
    }

    /// A rendering is a choice translators made, not a frequency against
    /// chance, so nothing here may be marked "more" or "fewer".
    @Test func renderingsAndFormsAreNeverMarkedAgainstChance() {
        for grouping in [LampStrongsGrouping.renderings, .forms] {
            let entries = grouping.divisions(of: Self.analysis())
            #expect(entries.allSatisfy { $0.division.expectation == .asExpected })
            #expect(entries.allSatisfy { $0.division.ratePerThousandWords == 0 })
        }
    }

    /// There is no population a rendering could be a rate of, so the measure
    /// picker is hidden rather than offering a number with no question.
    @Test func onlyBooksAndSectionsHaveARate() {
        #expect(LampStrongsGrouping.books.usesMeasure)
        #expect(LampStrongsGrouping.sections.usesMeasure)
        #expect(!LampStrongsGrouping.renderings.usesMeasure)
        #expect(!LampStrongsGrouping.forms.usesMeasure)
        #expect(LampStrongsGrouping.books.hasChapters)
        #expect(!LampStrongsGrouping.sections.hasChapters)
    }
}

/// Choosing the same thing twice.
struct StrongsFilterWideningTests {
    /// A chapter falls back to its book, not to nothing: the book's chapter
    /// strip is still open underneath, so clearing everything leaves the
    /// reader looking at one book's chapters beside a list of the whole
    /// Bible.
    @Test func achapterFallsBackToItsOwnBook() {
        #expect(
            LampStrongsFilter.chapter(book: 43, number: 3).widened
                == .book(number: 43)
        )
        #expect(
            LampStrongsFilter.chapter(book: 62, number: 4).widened
                == .book(number: 62),
            "its own book, not the one that happened to be open before"
        )
    }

    /// Everything else has nothing wider to fall back to, so choosing it
    /// again shows all the occurrences.
    @Test func everythingElseClears() {
        #expect(LampStrongsFilter.book(number: 43).widened == nil)
        #expect(LampStrongsFilter.rendering(id: "word", text: "Word").widened == nil)
        #expect(LampStrongsFilter.form("λόγος").widened == nil)
        #expect(LampStrongsFilter.grammar(feature: .tense, value: "Aorist").widened == nil)
    }
}

/// Which wedge a point is in.
struct StrongsShareHitTests {
    private let size = CGSize(width: 164, height: 164)
    private let centre = 82.0

    private func point(atClock hours: Double, radius: Double) -> CGPoint {
        // Twelve o'clock is straight up, and the angle grows clockwise.
        let turn = hours / 12
        let radians = turn * 2 * .pi - .pi / 2
        return CGPoint(x: centre + radius * cos(radians), y: centre + radius * sin(radians))
    }

    /// The first wedge starts at twelve o'clock and they run clockwise, as
    /// they are drawn.
    @Test func quartersAreFoundByTheClock() {
        let quarters = [0.25, 0.25, 0.25, 0.25]
        let expected = [(1.5, 0), (4.5, 1), (7.5, 2), (10.5, 3)]
        for (hours, slice) in expected {
            #expect(
                LampStrongsShareHit.index(
                    at: point(atClock: hours, radius: 70),
                    in: size, fractions: quarters, thickness: 0.38
                ) == slice,
                "\(hours) o'clock should be wedge \(slice)"
            )
        }
    }

    /// The bug the user saw: the last wedge is "Other", and it answered for
    /// the whole square. Twelve o'clock must be the first wedge, never the
    /// last, whatever the pointer is nearest to.
    @Test func thelastWedgeDoesNotAnswerForTheWholeRing() {
        let uneven = [0.5, 0.3, 0.2]
        #expect(
            LampStrongsShareHit.index(
                at: point(atClock: 1, radius: 70), in: size,
                fractions: uneven, thickness: 0.38
            ) == 0
        )
        #expect(
            LampStrongsShareHit.index(
                at: point(atClock: 7, radius: 70), in: size,
                fractions: uneven, thickness: 0.38
            ) == 1
        )
        #expect(
            LampStrongsShareHit.index(
                at: point(atClock: 11, radius: 70), in: size,
                fractions: uneven, thickness: 0.38
            ) == 2,
            "the last wedge answers only for its own arc"
        )
    }

    /// The hole is not part of a ring, and nothing outside the circle is.
    @Test func theholeAndTheOutsideAreNotWedges() {
        let halves = [0.5, 0.5]
        #expect(
            LampStrongsShareHit.index(
                at: CGPoint(x: centre, y: centre), in: size,
                fractions: halves, thickness: 0.38
            ) == nil,
            "the middle of a ring holds the total, not a wedge"
        )
        #expect(
            LampStrongsShareHit.index(
                at: CGPoint(x: 4, y: 4), in: size,
                fractions: halves, thickness: 0.38
            ) == nil,
            "a corner is outside the circle"
        )
    }

    /// A pie has no hole, so the middle belongs to a wedge.
    @Test func apieIsFilledToTheMiddle() {
        #expect(
            LampStrongsShareHit.index(
                at: point(atClock: 1, radius: 8), in: size,
                fractions: [0.5, 0.5], thickness: 1
            ) == 0,
            "close to the middle of a pie is still the wedge it is under"
        )
    }

    /// Nothing to point at.
    @Test func noSlicesIsNoWedge() {
        #expect(
            LampStrongsShareHit.index(
                at: CGPoint(x: 40, y: 40), in: size, fractions: [], thickness: 0.38
            ) == nil
        )
    }
}

/// One rule for what a key is called, shared by the apps and the agent tool.
struct StrongsHeadwordTests {
    private func result(
        _ key: String, module: String, lemma: String, transliteration: String? = nil,
        senses: [LampDictionarySense]
    ) -> LampDictionaryResult {
        LampDictionaryResult(
            entryID: key, moduleID: module, moduleName: module,
            key: key, lemma: lemma, transliteration: transliteration, senses: senses
        )
    }

    /// G26 as the bundled lexicons give it, in the library's order by name.
    private var agape: [LampDictionaryResult] {
        [
            result("G26", module: "dodson_greek", lemma: "ἀγάπη, ης, ἡ", senses: [
                LampDictionarySense(shortDefinition: "love, benevolence, good will, esteem"),
            ]),
            result("G0026", module: "strongs_greek", lemma: "ἀγάπη", transliteration: "agápē", senses: [
                LampDictionarySense(shortDefinition: "(feast of) charity(-ably), dear, love",
                                    definition: "love, i.e. affection or benevolence"),
            ]),
            result("G26", module: "tbesg", lemma: "ἀγάπη", senses: [LampDictionarySense(gloss: "love")]),
        ]
    }

    /// Strong's names the word, bare, wherever it falls in the order given;
    /// a lexicon's own gloss is the gloss, before anyone's short definition.
    @Test func strongsNamesTheWordAndAGlossIsTheGloss() {
        let headword = LampStrongsHeadword.merging(agape)["G26"]
        #expect(headword?.lemma == "ἀγάπη")
        #expect(headword?.transliteration == "agápē")
        #expect(headword?.shortGloss == "love")
        #expect(headword?.gloss == "love")
    }

    /// With no gloss anywhere, the first short definition stands in as the
    /// gloss, and the short gloss stays empty for a heading to leave out.
    @Test func withNoGlossAShortDefinitionStandsIn() {
        let headword = LampStrongsHeadword.merging(Array(agape.prefix(2)))["G26"]
        #expect(headword?.shortGloss == nil)
        #expect(headword?.gloss == "(feast of) charity(-ably), dear, love")
    }

    /// Entries read later — another translation's companions — fill gaps and
    /// never overwrite, though a gloss still displaces a short definition.
    @Test func entriesReadLaterOnlyFillGaps() {
        let known = ["G26": LampStrongsHeadword(lemma: "ἀγάπη", shortDefinition: "charity")]
        let headwords = LampStrongsHeadword.merging(
            [result("G26", module: "other", lemma: "other", senses: [LampDictionarySense(gloss: "love")])],
            into: known
        )
        #expect(headwords["G26"]?.lemma == "ἀγάπη")
        #expect(headwords["G26"]?.gloss == "love")
    }

    /// TBESG writes a gloss as senses under one head; the heading shows the
    /// head, and a gloss naming different things is left whole. All from
    /// TBESG as bundled.
    @Test func sensesUnderOneHeadReadAsTheHead() {
        #expect(LampStrongsHeadword.headGloss("faith; faith: faithfulness") == "faith")
        #expect(LampStrongsHeadword.headGloss("to see: see; to see: appear") == "to see")
        #expect(LampStrongsHeadword.headGloss("love") == "love")
        #expect(LampStrongsHeadword.headGloss("John; Jonah") == "John; Jonah")
        #expect(LampStrongsHeadword.headGloss("seed: offspring; seed(s)") == "seed: offspring; seed(s)")
        #expect(LampStrongsHeadword.headGloss("hell: Hades") == "hell: Hades")
        #expect(LampStrongsHeadword.headGloss("reckoning: accounts") == "reckoning: accounts")
        let headwords = LampStrongsHeadword.merging([
            result("G4102", module: "tbesg", lemma: "πίστις",
                   senses: [LampDictionarySense(gloss: "faith; faith: faithfulness")]),
        ])
        #expect(headwords["G4102"]?.shortGloss == "faith")
    }

    /// A blank gloss is no gloss: the heading falls through to the next
    /// sense's gloss, or shows the short definition where a gloss is wanted.
    @Test func aBlankGlossIsNoGloss() {
        #expect(LampStrongsHeadword.headGloss("") == nil)
        #expect(LampStrongsHeadword.headGloss(" ; ") == nil)
        let headwords = LampStrongsHeadword.merging([
            result("G26", module: "tbesg", lemma: "ἀγάπη", senses: [
                LampDictionarySense(gloss: " "),
                LampDictionarySense(gloss: "love"),
            ]),
            result("G25", module: "tbesg", lemma: "ἀγαπάω", senses: [
                LampDictionarySense(gloss: ";", shortDefinition: "to love"),
            ]),
        ])
        #expect(headwords["G26"]?.shortGloss == "love")
        #expect(headwords["G25"]?.shortGloss == nil)
        #expect(headwords["G25"]?.gloss == "to love")
    }
}

/// The Septuagint's Greek beside the Hebrew word's verses, found through the
/// Septuagint's own numbering.
/// The Septuagint section read by someone with no Hebrew: each Hebrew word
/// named in English, and each verse in English with the word marked.
struct SeptuagintEnglishTests {
    private static func analysis(
        occurrences: [LampStrongsAnalysis.Occurrence],
        verseTexts: [Int: String],
        renderings: [LampStrongsAnalysis.Rendering] = []
    ) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: "H160", translationID: "BSBs", translationName: "Berean Standard Bible",
            translationAbbreviation: "BSBs", wordCount: 1_000, taggedVerseCount: 2,
            occurrences: occurrences, references: verseTexts.keys.sorted(),
            renderings: renderings, forms: [], parsings: [], grammar: [],
            books: [], sections: [], companions: [], verseTexts: verseTexts
        )
    }

    private static func occurrence(_ reference: Int, _ start: Int, _ end: Int) -> LampStrongsAnalysis.Occurrence {
        .init(reference: reference, startOffset: start, endOffset: end, text: "love",
              renderingID: "love", form: nil, morphology: nil)
    }

    /// The Hebrew text numbers this verse Psalm 51:7, the English 51:5: the
    /// English is read at its own number and marked where its tag says.
    @Test func theEnglishIsReadAtItsOwnNumberAndMarkedByItsTag() throws {
        let hebrew = LampVersification.standard(.original)
        let english = LampVersification.standard(.english)
        let hebrewReference = 19_051_007
        let englishReference = try #require(hebrew.opens(hebrewReference, in: english))
        #expect(englishReference != hebrewReference, "the psalm's title shifts the verse")
        let verse = "Surely I was brought forth in iniquity; I was sinful when my mother conceived me."
        let found = LampSeptuagintSection.english(
            for: [hebrewReference],
            hebrewNumbering: hebrew,
            englishNumbering: english,
            analysis: Self.analysis(
                occurrences: [Self.occurrence(englishReference, 30, 38)],
                verseTexts: [englishReference: verse]
            )
        )
        let line = try #require(found[hebrewReference])
        #expect(line.reference == englishReference)
        #expect(line.text == verse, "the verse whole, not cut around the word")
        #expect(line.marks.map(\.start) == [30])
        #expect(marked(verse, line.marks) == ["iniquity"])
    }

    /// A verse the English does not tag with this word is never marked at a
    /// likely word.
    @Test func aVerseTheTranslationDoesNotTagIsLeftOut() throws {
        let numbering = LampVersification.standard(.english)
        let found = LampSeptuagintSection.english(
            for: [1_029_020, 1_029_021],
            hebrewNumbering: numbering,
            englishNumbering: numbering,
            analysis: Self.analysis(
                occurrences: [Self.occurrence(1_029_020, 4, 8)],
                verseTexts: [1_029_020: "his love for her", 1_029_021: "love unmarked"]
            )
        )
        let tagged = try #require(found[1_029_020])
        #expect(marked("his love for her", tagged.marks) == ["love"])
        #expect(found[1_029_021]?.reference == 1_029_021)
        #expect(found[1_029_021]?.text == nil, "not marked at a likely word")
        #expect(found[1_029_021]?.marks.isEmpty == true)
    }

    /// A word with no analysis — no Strong's number to ask by — still has its
    /// verses' English numbers, so they open where a reader of the English
    /// looks them up, and none is marked.
    @Test func withNoAnalysisEveryVerseHasItsEnglishNumber() throws {
        let hebrew = LampVersification.standard(.original)
        let english = LampVersification.standard(.english)
        let found = LampSeptuagintSection.english(
            for: [19_051_007, 1_029_020],
            hebrewNumbering: hebrew,
            englishNumbering: english,
            analysis: nil
        )
        let psalm = try #require(found[19_051_007])
        #expect(psalm.reference == hebrew.opens(19_051_007, in: english))
        #expect(psalm.reference != 19_051_007)
        #expect(psalm.text == nil)
        #expect(psalm.marks.isEmpty)
        #expect(found[1_029_020]?.reference == 1_029_020)
    }

    /// A verse the English does not tag still has its English number, so one
    /// list never shows the Hebrew numbering beside the English: in the
    /// Psalms the two differ by the title.
    @Test func anUnmarkedVerseKeepsItsEnglishNumber() throws {
        let hebrew = LampVersification.standard(.original)
        let english = LampVersification.standard(.english)
        let hebrewReference = 19_051_007
        let found = LampSeptuagintSection.english(
            for: [hebrewReference],
            hebrewNumbering: hebrew,
            englishNumbering: english,
            analysis: Self.analysis(occurrences: [], verseTexts: [:])
        )
        let line = try #require(found[hebrewReference])
        #expect(line.reference == hebrew.opens(hebrewReference, in: english))
        #expect(line.reference != hebrewReference)
        #expect(line.text == nil)
    }

    /// The English marks every place it renders the word, because the Greek
    /// line beside it does. Marking one of two said the two texts disagreed
    /// where they agreed.
    @Test func everyRenderingInAVerseIsMarked() throws {
        let numbering = LampVersification.standard(.english)
        // ABP Genesis 1:3, the verse the owner found.
        let verse = "And God said, Let there be light! And there was light."
        let first = try #require(verse.range(of: "light"))
        let second = try #require(verse.range(of: "light", options: .backwards))
        func offset(_ index: String.Index) -> Int {
            verse.unicodeScalars.distance(from: verse.unicodeScalars.startIndex, to: index)
        }
        let found = LampSeptuagintSection.english(
            for: [1_001_003],
            hebrewNumbering: numbering,
            englishNumbering: numbering,
            analysis: Self.analysis(
                // Given out of order, as an analysis may list them.
                occurrences: [
                    Self.occurrence(1_001_003, offset(second.lowerBound), offset(second.upperBound)),
                    Self.occurrence(1_001_003, offset(first.lowerBound), offset(first.upperBound)),
                ],
                verseTexts: [1_001_003: verse]
            )
        )
        let line = try #require(found[1_001_003])
        #expect(line.text == verse)
        #expect(marked(verse, line.marks) == ["light", "light"])
        #expect(line.marks.map(\.start) == line.marks.map(\.start).sorted(), "in reading order")
    }

    /// The text each mark names, for asserting on what a row would draw.
    private func marked(_ text: String, _ marks: [LampSeptuagintSection.Span]) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return marks.compactMap { span in
            guard span.start >= 0, span.end > span.start, span.end <= scalars.count else { return nil }
            return String(String.UnicodeScalarView(scalars[span.start..<span.end]))
        }
    }

    @Test func aHebrewWordIsNamedForSomeoneWithNoHebrew() {
        let word = LampSeptuagintHebrew(text: "אַהֲבָה", strongs: "H160")
        #expect(LampSeptuagintSection.heading(
            word, transliteration: "ʼahăbâh", rendering: "love", verses: 40
        ) == "ʼahăbâh “love” (H160) · in 40 Hebrew verses")
        #expect(LampSeptuagintSection.heading(word, rendering: "love", verses: 1)
            == "אַהֲבָה “love” (H160) · in 1 Hebrew verse")
        #expect(LampSeptuagintSection.heading(word, verses: 40)
            == "Hebrew אַהֲבָה (H160) · 40 verses", "unchanged without English")
        // Narrowed, the heading says from how many: the list holds the
        // verses that use the Greek word, not all the Hebrew word's.
        #expect(LampSeptuagintSection.heading(
            word, transliteration: "ʼahăbâh", rendering: "love", verses: 14, of: 35, usingGreek: "ἀγάπη"
        ) == "ʼahăbâh “love” (H160) · 14 of 35 verses using ἀγάπη")
        #expect(LampSeptuagintSection.heading(word, verses: 1, of: 3, usingGreek: "ἀγάπη")
            == "Hebrew אַהֲבָה (H160) · 1 of 3 verses using ἀγάπη")
        // Never "35 of 35", and never a total without the Greek word.
        #expect(LampSeptuagintSection.heading(
            word, rendering: "love", verses: 35, of: 35, usingGreek: "ἀγάπη"
        ) == "אַהֲבָה “love” (H160) · 35 verses using ἀγάπη")
        #expect(LampSeptuagintSection.heading(word, rendering: "love", verses: 1, of: nil, usingGreek: "ἀγάπη")
            == "אַהֲבָה “love” (H160) · 1 verse using ἀγάπη")
        #expect(LampSeptuagintSection.heading(word, rendering: "love", verses: 14, of: 35)
            == "אַהֲבָה “love” (H160) · in 14 Hebrew verses")
        let analysis = Self.analysis(occurrences: [], verseTexts: [:], renderings: [
            .init(id: "", text: "", count: 9, variants: []),
            .init(id: "love", text: "love", count: 8, variants: []),
        ])
        #expect(LampSeptuagintSection.rendering(in: analysis) == "love")
    }

    /// The note says whose verses these are: the Hebrew word's, not the
    /// Greek word's, whatever the installed Septuagint can show.
    @Test func theNoteSaysTheVersesAreTheHebrewWords() {
        let note = LampSeptuagintSection.note(greek: "ἀγάπη", septuagint: .untagged("Brenton Greek Septuagint"))
        #expect(note.contains("not ἀγάπη’s"))
        #expect(note.contains("Brenton Greek Septuagint isn’t tagged word by word"))
        #expect(LampSeptuagintSection.note(greek: nil, septuagint: .untagged("Brenton"))
            .contains("not this word’s"))
        // Unnamed, it still says there is nothing to count the Greek word by.
        #expect(LampSeptuagintSection.note(greek: "λόγος", septuagint: .untagged(" "))
            .contains("the Septuagint installed isn’t tagged word by word"))
    }

    /// Looked up and tagged, the note must not say the text cannot count the
    /// Greek word: it can, and the note says where those verses are.
    @Test func aTaggedSeptuagintIsNotSaidToBeUntagged() {
        let note = LampSeptuagintSection.note(
            greek: "λόγος", septuagint: .tagged("Brenton Greek Septuagint")
        )
        #expect(!note.contains("tagged word by word"))
        // Nothing at all: the headings under it say whose verses they are,
        // and how many of how many.
        #expect(note.isEmpty)
        #expect(LampSeptuagintSection.note(greek: "λόγος", septuagint: .tagged("")).isEmpty)
    }

    /// A Hebrew word's verses can now be narrowed to the ones the Septuagint
    /// renders with the Greek word being studied, through its own numbering.
    @Test func aHebrewWordsVersesNarrowToTheOnesUsingTheGreekWord() {
        let hebrew = LampVersification.standard(.original)
        let septuagint = LampVersification.standard(.septuagint)
        // Psalm 51:5 in the Hebrew is the Septuagint's 50:7, so a list that
        // matched raw numbers would drop it.
        let psalm = 19_051_005
        let mapped = try! #require(hebrew.opens(psalm, in: septuagint))
        let genesis = 1_001_001
        let found = LampSeptuagintSection.versesRenderedByGreek(
            hebrew: [genesis, psalm],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint,
            septuagintReferences: [mapped]
        )
        #expect(found == [psalm], "the psalm is in, by the Septuagint's own number")
        // Nothing known of the Greek: nothing claimed, rather than everything.
        #expect(LampSeptuagintSection.versesRenderedByGreek(
            hebrew: [genesis, psalm],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint,
            septuagintReferences: []
        ).isEmpty)
    }

    /// A word standing in a psalm's title is in the list, whichever half of
    /// the title it stands in.
    ///
    /// TAHOT holds a whole title as one verse, numbered 0; the Septuagint
    /// numbers it as two. Crossing on a single converted number found only
    /// the first half, so a word in "when Nathan the prophet came to him"
    /// was tested against "To the choirmaster, a psalm of David" and fell
    /// out of a list that claims to be that word's verses. Words like
    /// מִזְמוֹר and לַמְנַצֵּחַ live almost entirely in titles.
    @Test func aWordInEitherHalfOfAPsalmTitleIsInTheList() {
        let hebrew = LampVersification.standard(.english)
        let septuagint = LampVersification.standard(.septuagint)
        let title = 19_051_000
        #expect(hebrew.counterparts(of: title, in: septuagint) == [19_050_001, 19_050_002])
        // The first half: found before this change, and still found.
        #expect(LampSeptuagintSection.versesRenderedByGreek(
            hebrew: [title],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint,
            septuagintReferences: [19_050_001]
        ) == [title])
        // The second half: the half that used to be lost.
        #expect(LampSeptuagintSection.versesRenderedByGreek(
            hebrew: [title],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint,
            septuagintReferences: [19_050_002]
        ) == [title])
        // A Septuagint verse belonging to neither half still excludes it.
        #expect(LampSeptuagintSection.versesRenderedByGreek(
            hebrew: [title],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint,
            septuagintReferences: [19_050_003]
        ).isEmpty)
    }

    /// What a narrowed list says, and what it does not.
    @Test func theNarrowedListSaysWhatTheRestAre() {
        #expect(LampSeptuagintSection.renderedHeading(greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}", shown: 575, of: 1_289)
            == "Narrowed to the 575 of 1289 where the Septuagint uses \u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}; "
            + "in the rest it translates the Hebrew another way.")
        #expect(LampSeptuagintSection.renderedHeading(greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}", shown: 8, of: 8)
            == "The Septuagint uses \u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2} in all 8 of them.")
        #expect(LampSeptuagintSection.renderedHeading(greek: nil, shown: 1, of: 2)
            .hasPrefix("Narrowed to the 1 of 2 where the Septuagint uses this word"))
        #expect(LampSeptuagintSection.renderedHeading(greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}", shown: 0, of: 0).isEmpty)
    }

    /// A narrowed count says what it counts, so it is not read as the whole.
    @Test func aNarrowedCountNamesTheGreekWord() {
        let hebrew = LampSeptuagintHebrew(text: "\u{05D3}\u{05B8}\u{05D1}\u{05B8}\u{05E8}", strongs: "H1697")
        #expect(LampSeptuagintSection.heading(
            hebrew, transliteration: "d\u{0101}\u{1E07}\u{0101}r", rendering: "words",
            verses: 735, usingGreek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}"
        ) == "d\u{0101}\u{1E07}\u{0101}r \u{201C}words\u{201D} (H1697) \u{00B7} 735 verses using \u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}")
        // Not narrowed, it is every verse of the Hebrew word, as before.
        #expect(LampSeptuagintSection.heading(
            hebrew, transliteration: "d\u{0101}\u{1E07}\u{0101}r", rendering: "words", verses: 1_289
        ) == "d\u{0101}\u{1E07}\u{0101}r \u{201C}words\u{201D} (H1697) \u{00B7} in 1289 Hebrew verses")
    }

    /// The section reads the same with a Septuagint in English installed and
    /// without one, and marks a different word in each case.
    @Test func theEnglishComesFromWhicheverSeptuagintIsInstalled() {
        func analysis(_ id: String, key: String, books: [(Int, Int)]) -> LampStrongsAnalysis {
            LampStrongsAnalysis(
                key: key, translationID: id, translationName: id, translationAbbreviation: id,
                wordCount: 1_000, taggedVerseCount: 10,
                occurrences: [], references: [], renderings: [], forms: [],
                parsings: [], grammar: [],
                books: books.map {
                    LampStrongsAnalysis.Division(
                        id: $0.0, name: "Book \($0.0)", bookRange: $0.0...$0.0,
                        occurrenceCount: $0.1, verseCount: $0.1, wordCount: 100,
                        expectedCount: 0, keyness: 0, chapters: []
                    )
                },
                sections: [], companions: []
            )
        }
        // Without one: the reader's own Bible, on the Hebrew word.
        #expect(LampSeptuagintSection.englishSource(
            hebrewKey: "H160", greekKey: "G26",
            readersTranslationID: "BSBs", septuagintInEnglish: nil
        ) == .readersBible(moduleID: "BSBs", key: "H160"))
        // With one: that text, on the Greek word, which is what the section
        // is about — the reader's Bible translates the Hebrew, not this.
        #expect(LampSeptuagintSection.englishSource(
            hebrewKey: "H160", greekKey: "G26",
            readersTranslationID: "BSBs", septuagintInEnglish: "ABPs"
        ) == .septuagintInEnglish(moduleID: "ABPs", key: "G26"))
        // A Hebrew word with no number of its own, and no Septuagint in
        // English: nothing to mark, so no English is claimed.
        #expect(LampSeptuagintSection.englishSource(
            hebrewKey: nil, greekKey: "G26",
            readersTranslationID: "BSBs", septuagintInEnglish: nil
        ) == nil)
        // ... but with one there is still the Greek word to mark.
        #expect(LampSeptuagintSection.englishSource(
            hebrewKey: nil, greekKey: "G26",
            readersTranslationID: "BSBs", septuagintInEnglish: "ABPs"
        ) == .septuagintInEnglish(moduleID: "ABPs", key: "G26"))

        // Recognised by what it tags: a Greek key standing in Old Testament
        // books, in a text that is not itself Greek.
        #expect(LampSeptuagintSection.rendersTheGreekOldTestament(
            analysis("ABPs", key: "G26", books: [(22, 11), (21, 2)]), isOriginalLanguage: false
        ))
        // An English Bible translated from the Hebrew holds no Greek key
        // in those books, so a Greek key finds it only in the New Testament.
        #expect(!LampSeptuagintSection.rendersTheGreekOldTestament(
            analysis("BSBs", key: "G26", books: [(43, 8), (45, 12)]), isOriginalLanguage: false
        ))
        // The Greek text itself is an original-language text, not a rendering
        // of one.
        #expect(!LampSeptuagintSection.rendersTheGreekOldTestament(
            analysis("LXX", key: "G26", books: [(22, 11)]), isOriginalLanguage: true
        ))
        // A Hebrew key says nothing about the Greek Old Testament.
        #expect(!LampSeptuagintSection.rendersTheGreekOldTestament(
            analysis("ABPs", key: "H160", books: [(22, 11)]), isOriginalLanguage: false
        ))
    }

    /// Where the words stand settles some verses and not others, and it is
    /// only ever allowed to take a warning away.
    @Test func positionSettlesAPairingOnlyWhenItIsClear() {
        // One each: settled without needing a position at all.
        #expect(LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.4], greekAt: [0.9]))
        // One Hebrew, two Greek, and only one of them is anywhere near it.
        #expect(LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.2], greekAt: [0.24, 0.8]))
        // Near enough, but the runner-up is near too: nothing is settled, and
        // this is the case the measurement says costs accuracy.
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.2], greekAt: [0.24, 0.33]))
        // Nothing within reach of where the Hebrew word stands.
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.2], greekAt: [0.5, 0.9]))
        // Two of each, each clearly its own.
        #expect(LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.1, 0.7], greekAt: [0.12, 0.72]))
        // Two Hebrew words with one Greek between them: one of them must be
        // answering to nothing, so the doubt stands.
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.1, 0.7], greekAt: [0.12]))
        // Two Hebrew words whose nearest is the same Greek word: that Greek
        // word cannot be both of them.
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.30, 0.34], greekAt: [0.32, 0.9]))
        // Nothing said about a verse with nothing in it.
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [], greekAt: [0.3]))
        #expect(!LampSeptuagintSection.pairingIsSettled(hebrewAt: [0.3], greekAt: []))
    }

    /// One of each and nothing competing is the strong case, and says
    /// nothing; each other case says which doubt it is.
    @Test func aVersePairingSaysWhichDoubtItHas() {
        func doubt(_ hebrew: Int, _ greek: Int, also: [String] = []) -> String? {
            LampSeptuagintSection.pairingDoubt(
                greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}", hebrew: "\u{05D3}\u{05B8}\u{05D1}\u{05B8}\u{05E8}",
                hebrewOccurrences: hebrew, greekOccurrences: greek, alsoRendered: also
            )
        }
        // Hebrew set into an English sentence is isolated, and the sentence
        // itself opens left to right; without that the full stop jumped to
        // the front and the Hebrew was stranded at the end.
        func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }
        let dabar = isolated("\u{05D3}\u{05B8}\u{05D1}\u{05B8}\u{05E8}")
        let millah = isolated("\u{05DE}\u{05B4}\u{05DC}\u{05B8}\u{05BC}\u{05D4}")
        let emer = isolated("\u{05D0}\u{05B5}\u{05DE}\u{05B6}\u{05E8}")
        #expect(doubt(1, 1) == nil, "one of each, nothing competing")
        #expect(doubt(2, 1) == "\u{200E}\(dabar) stands twice in this verse.")
        #expect(doubt(1, 3) == "\u{200E}\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2} stands three times in the Greek.")
        #expect(doubt(1, 1, also: ["\u{05DE}\u{05B4}\u{05DC}\u{05B8}\u{05BC}\u{05D4}"])
            == "\u{200E}\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2} also renders \(millah), which stands here too.")
        // Every doubt there is, in one line.
        let all = doubt(2, 2, also: ["\u{05DE}\u{05B4}\u{05DC}\u{05B8}\u{05BC}\u{05D4}", "\u{05D0}\u{05B5}\u{05DE}\u{05B6}\u{05E8}"])
        #expect(all?.hasPrefix("\u{200E}") == true, "an English sentence, whatever it opens with")
        #expect(all?.contains("twice in this verse; ") == true)
        #expect(all?.contains("twice in the Greek; ") == true)
        #expect(all?.hasSuffix("and \(emer), which stands here too.") == true)
        // The stop is the last character, not the first.
        #expect(all?.hasSuffix(".") == true)
        #expect(all?.hasPrefix("\u{200E}.") == false)
    }

    /// The narrowed list says what it cannot show, not only what it shows.
    @Test func theNarrowedListOwnsUpToBeingVerseDeep() {
        let caveat = LampSeptuagintSection.renderedCaveat(greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}")
        #expect(caveat.contains("both stand in it"))
        #expect(caveat.contains("may be translating another word of it"))
        // Without a lemma it still reads as a sentence about the Greek word.
        #expect(LampSeptuagintSection.renderedCaveat(greek: nil)
            .contains("the Greek word in the Greek"))
    }

    /// The headline counts verses in both Testaments, and never adds them.
    @Test func theHeadlineCountsVersesInBothTestaments() {
        func analysis(_ id: String, references: [Int]) -> LampStrongsAnalysis {
            LampStrongsAnalysis(
                key: "G3056", translationID: id, translationName: id,
                translationAbbreviation: id, wordCount: 1_000, taggedVerseCount: 10,
                occurrences: [], references: references, renderings: [], forms: [],
                parsings: [], grammar: [], books: [], sections: [], companions: []
            )
        }
        let septuagint = analysis("LXX", references: Array(1...1_238))
        let newTestament = analysis("TAGNT", references: Array(1...330))
        let line = LampSeptuagintSection.ownUseHeadline(
            greek: "λόγος", septuagint: septuagint, newTestament: newTestament
        )
        #expect(line == "λόγος stands in 1238 verses of the Greek Old Testament, "
            + "and in 330 verses of the New Testament.")
        // No Greek New Testament analysed: the half that is known is said,
        // and the other is not given as a count of nothing.
        let alone = LampSeptuagintSection.ownUseHeadline(
            greek: "λόγος", septuagint: septuagint, newTestament: nil
        )
        #expect(alone == "λόγος stands in 1238 verses of the Greek Old Testament.")
        #expect(LampSeptuagintSection.ownUseHeadline(
            greek: "λόγος", septuagint: septuagint, newTestament: analysis("TAGNT", references: [])
        ) == alone, "an analysis with no verses is no count to give")
        // One verse is a verse.
        #expect(LampSeptuagintSection.ownUseHeadline(
            greek: nil, septuagint: analysis("LXX", references: [1]), newTestament: nil
        ) == "This word stands in 1 verse of the Greek Old Testament.")
    }

    /// The contrast needs both sides, draws each bar against the larger, and
    /// gives the rate the counts alone would mislead about.
    @Test func theTestamentContrastIsTwoTextsNotTwoHalves() {
        func analysis(
            _ id: String, verses: Int, occurrences: Int, words: Int
        ) -> LampStrongsAnalysis {
            LampStrongsAnalysis(
                key: "G3056", translationID: id, translationName: id,
                translationAbbreviation: id, wordCount: words, taggedVerseCount: verses,
                occurrences: (0..<occurrences).map {
                    LampStrongsAnalysis.Occurrence(
                        reference: $0 + 1, startOffset: 0, endOffset: 1, text: "λ",
                        renderingID: "", form: nil, morphology: nil
                    )
                },
                references: Array(1...max(verses, 1)).prefix(verses).map { $0 },
                renderings: [], forms: [], parsings: [], grammar: [],
                books: [], sections: [], companions: []
            )
        }
        let newTestament = analysis("TAGNT", verses: 330, occurrences: 330, words: 138_000)
        let septuagint = analysis("LXX", verses: 1_238, occurrences: 1_400, words: 465_550)
        let contrast = try! #require(LampSeptuagintSection.contrast(
            newTestament: newTestament, septuagint: septuagint
        ))
        #expect(contrast.septuagint.source == "LXX")
        #expect(contrast.newTestament.label == "New Testament")
        // Against the larger side, never against the sum: the longer bar is
        // full, and nothing reads as a share of one whole.
        #expect(contrast.share(of: contrast.septuagint) == 1)
        #expect(abs(contrast.share(of: contrast.newTestament) - 330.0 / 1_238.0) < 0.000_1)
        // The rate is the part the bars cannot carry.
        let caption = LampSeptuagintSection.contrastCaption(contrast)
        #expect(caption == "Per 1,000 tagged words: 2.4 in the New Testament, 3.0 in the Septuagint.")
        #expect(caption.contains("2.4 in the New Testament"))
        #expect(caption.contains("3.0 in the Septuagint"))
        // One side alone is not a contrast; the headline covers that case.
        #expect(LampSeptuagintSection.contrast(newTestament: nil, septuagint: septuagint) == nil)
        #expect(LampSeptuagintSection.contrast(
            newTestament: analysis("TAGNT", verses: 0, occurrences: 0, words: 138_000),
            septuagint: septuagint
        ) == nil)
        // Nothing tagged on a side: no rate is given rather than a rate of
        // none.
        let untagged = try! #require(LampSeptuagintSection.contrast(
            newTestament: analysis("TAGNT", verses: 330, occurrences: 330, words: 0),
            septuagint: septuagint
        ))
        #expect(untagged.newTestament.perThousandWords == 0)
        // Nothing to say without words to count against.
        #expect(LampSeptuagintSection.contrastCaption(untagged).isEmpty)
        // A rate under a tenth is said, not rounded to nothing: ἀγάπη stands
        // 14 times in the Septuagint's 476,000 tagged words, and "0.0" beside
        // a count of 14 reads as a contradiction.
        let rare = try! #require(LampSeptuagintSection.contrast(
            newTestament: analysis("TAGNT", verses: 106, occurrences: 116, words: 138_000),
            septuagint: analysis("LXX", verses: 14, occurrences: 14, words: 476_000)
        ))
        let rareCaption = LampSeptuagintSection.contrastCaption(rare)
        #expect(rareCaption.contains("0.03 in the Septuagint"))
        #expect(!rareCaption.contains("0.0 in the Septuagint"))
    }

    /// A reader is sent to the verse their own Bible numbers, and told when
    /// the verse is the Septuagint's own.
    @Test func versesAreNumberedTheReadersWay() {
        let septuagint = LampVersification.standard(.septuagint)
        let reader = LampVersification.standard(.english)
        let psalm = 19_050_007
        let numbered = LampSeptuagintSection.readerNumbering(
            of: [psalm], septuagintNumbering: septuagint, readerNumbering: reader
        )
        let found = try! #require(numbered[psalm])
        #expect(!found.isTheSeptuagintsOwn)
        #expect((found.reference / 1_000) % 1_000 == 51, "the reader’s Bible numbers this psalm 51")
        // Its own numbering either way, when the two agree.
        let same = LampSeptuagintSection.readerNumbering(
            of: [1_001_001], septuagintNumbering: reader, readerNumbering: reader
        )
        #expect(same[1_001_001] == .init(reference: 1_001_001, isTheSeptuagintsOwn: false))
    }

    /// Before the lookup, and with nothing installed, the note says nothing
    /// about tagging at all — the trap an optional name would have set.
    @Test func theNoteClaimsNothingItHasNotLookedUp() {
        for septuagint in [LampSeptuagintSection.Tagging.unknown, .notInstalled] {
            let note = LampSeptuagintSection.note(greek: "λόγος", septuagint: septuagint)
            #expect(note.contains("not λόγος’s"))
            #expect(!note.contains("tagged"))
            #expect(!note.contains("counted in"))
            #expect(!note.contains("may use another word"))
        }
        // The default is the state that claims nothing.
        #expect(LampSeptuagintSection.note(greek: "λόγος")
            == LampSeptuagintSection.note(greek: "λόγος", septuagint: .unknown))
    }
}

struct SeptuagintGreekTests {
    /// The Hebrew text numbers this psalm 51 and the Septuagint 50, so the
    /// Greek is read from the Septuagint's chapter, at the verse its own
    /// numbering gives — and that chapter once, for both verses.
    @Test func versesAreReadThroughTheSeptuagintsNumbering() async throws {
        let hebrew = LampVersification.standard(.original)
        let septuagint = LampVersification.standard(.septuagint)
        let first = 19_051_007
        let second = 19_051_008
        let mappedFirst = try #require(hebrew.opens(first, in: septuagint))
        let mappedSecond = try #require(hebrew.opens(second, in: septuagint))
        #expect((mappedFirst / 1_000) % 1_000 == 50, "the Septuagint numbers this psalm 50")

        var reads: [String] = []
        let greek = try await LampSeptuagintSection.greek(
            for: [first, second],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint
        ) { book, chapter in
            reads.append("\(book):\(chapter)")
            return [mappedFirst % 1_000: "ἰδοὺ γὰρ ἐν ἀνομίαις συνελήμφθην",
                    mappedSecond % 1_000: "ἰδοὺ γὰρ ἀλήθειαν ἠγάπησας"]
        }
        #expect(reads == ["19:50"])
        #expect(greek[first] == "ἰδοὺ γὰρ ἐν ἀνομίαις συνελήμφθην")
        #expect(greek[second] == "ἰδοὺ γὰρ ἀλήθειαν ἠγάπησας")
    }

    /// A chapter that cannot be read leaves its verses out, not the rest.
    @Test func achapterThatCannotBeReadCostsOnlyItsVerses() async throws {
        struct Unreadable: Error {}
        let english = LampVersification.standard(.english)
        let greek = try await LampSeptuagintSection.greek(
            for: [1_001_001, 1_002_001],
            hebrewNumbering: english,
            septuagintNumbering: english
        ) { _, chapter in
            if chapter == 1 { throw Unreadable() }
            return [1: "οὕτως"]
        }
        #expect(greek == [1_002_001: "οὕτως"])
    }

    /// Cancelled part way, it says nothing rather than something partial:
    /// a verse it did not reach would otherwise read as one the text lacks.
    @Test func cancelledPartWayItReturnsNothing() async {
        let english = LampVersification.standard(.english)
        let task = Task {
            try await LampSeptuagintSection.greek(
                for: [1_001_001, 1_002_001],
                hebrewNumbering: english,
                septuagintNumbering: english
            ) { _, chapter in
                if chapter == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return [1: "ἐν ἀρχῇ"]
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}

struct StrongsFormReadingTests {
    @Test func greekReadsInLatinLettersAsItIsSaid() {
        let cases = [
            ("ἀγάπην", "agapēn"), ("ἀγάπῃ", "agapēi"), ("τῷ", "tōi"), ("ἁγίων", "hagiōn"),
            ("εὐαγγέλιον", "euangelion"), ("υἱός", "huios"), ("ῥῆμα", "rhēma"),
            ("Ἰησοῦς", "Iēsous"), ("οὐρανοῦ", "ouranou"), ("ἠγάπησεν", "ēgapēsen"),
            ("πνεῦμα", "pneuma"), ("ἐκκλησία", "ekklēsia"), ("ἄγγελος", "angelos"),
            ("Χριστός", "Christos"), ("ψυχή", "psychē"), ("ὁ λόγος", "ho logos"),
        ]
        for (greek, latin) in cases {
            #expect(LampGreekTransliteration.latin(greek) == latin, "\(greek)")
        }
    }

    @Test func aParsingIsSaidByItsJobInTheSentence() {
        func role(_ code: String, _ key: String = "G26") -> String? {
            LampStrongsFormReading.role(of: LampMorphology.features(of: code, strongsKey: key))
        }
        #expect(role("N-NSF") == "the subject")
        #expect(role("N-GSF") == "“of …”")
        #expect(role("N-APF") == "the object · more than one")
        #expect(role("V-AAI-3S", "G25") == "he, she or it · did it, as a whole")
        #expect(role("V-PAN", "G25") == "“to …”")
        #expect(role("V-PAP-NSM", "G25") == "“…ing”, “the one who …”")
        #expect(role("V-APM-2P", "G25") == "a command to more than one · done to, not doing")
    }

    /// ἀγάπη in three spellings: two nominatives, one rendered "Love" and
    /// one "love"; a genitive "of love"; one form with a grave accent.
    private var analysis: LampStrongsAnalysis {
        var analyzer = LampStrongsAnalyzer(key: "G26", translationID: "T", translationName: "Test")
        let rows: [(String, String, String)] = [
            ("Love", "ἀγάπη", "N-NSF"), ("love", "ἀγάπη", "N-NSF"),
            ("of love", "ἀγάπης", "N-GSF"), ("love", "ἀγὰπη", "N-NSF"),
        ]
        for (index, row) in rows.enumerated() {
            let text = row.0 + " word"
            let json = #"[{"start":0,"end":\#(row.0.count),"data":{"strongs":"G26","lemma":"\#(row.1)","morphology":"\#(row.2)"}},"#
                + #"{"start":\#(row.0.count + 1),"end":\#(text.count),"data":{"strongs":"G1"}}]"#
            analyzer.add(reference: 46_013_001 + index, text: text, annotationsJSON: json)
        }
        return analyzer.analysis()
    }

    @Test func eachFormSaysWhatItBecameInEnglish() {
        let readings = LampStrongsFormReading.readings(of: analysis)
        #expect(readings.map(\.form.text) == ["ἀγάπη", "ἀγάπης"])
        #expect(readings[0].form.count == 3)
        #expect(readings[0].transliteration == "agapē")
        #expect(readings[0].role == "the subject")
        #expect(readings[0].renderedAs == ["love"])
        #expect(readings[1].renderedAs == ["of love"])
        #expect(readings[1].parsing == "Noun · Genitive · Singular · Feminine")
    }

    /// As the BSB tags it: each Greek spelling, no parsing, and three tags
    /// with no spelling at all.
    private var bare: LampStrongsAnalysis {
        var bare = LampStrongsAnalyzer(key: "G26", translationID: "B", translationName: "Bare", translationAbbreviation: "BSB")
        let rows: [(String, String?)] = [
            ("of love", "ἀγάπης"), ("And love", "ἀγάπη"), ("Love", "ἀγάπη"), ("love", "ἀγάπη"), ("love", nil),
        ]
        for (index, row) in rows.enumerated() {
            let text = row.0 + " word"
            let lemma = row.1.map { #","lemma":"\#($0)""# } ?? ""
            let json = #"[{"start":0,"end":\#(row.0.count),"data":{"strongs":"G26"\#(lemma)}},"#
                + #"{"start":\#(row.0.count + 1),"end":\#(text.count),"data":{"strongs":"G1"}}]"#
            bare.add(reference: 46_013_001 + index, text: text, annotationsJSON: json)
        }
        return bare.analysis()
    }

    @Test func aFormWithoutItsOwnParsingSaysNoneAndTheSectionSaysWhy() {
        let readings = LampStrongsFormReading.readings(of: bare)
        // Nothing borrowed from another text, however well it would match.
        #expect(readings.allSatisfy { $0.role == nil && $0.parsing == nil })
        // "And" came from a neighbouring word; "Love" starts a sentence.
        #expect(readings[0].renderedAs == ["love"])
        #expect(LampStrongsFormReading.gaps(of: bare, readings: readings) == [
            "BSB tags each Greek spelling but not its grammar, so what each one does is not said here.",
            "1 of 5 occurrences is tagged in BSB without a Greek spelling.",
        ])
        #expect(LampStrongsFormReading.note(for: bare, readings: readings).hasSuffix(
            "Each spelling is shown with how to say it and the English it became here."
        ))
        #expect(LampStrongsFormReading.gaps(of: analysis, readings: LampStrongsFormReading.readings(of: analysis)).isEmpty)
    }

    @Test func aTranslationWithoutSpellingsSaysItCannotCountForms() {
        var esv = LampStrongsAnalyzer(key: "G26", translationID: "E", translationName: "English", translationAbbreviation: "ESV")
        esv.add(
            reference: 46_013_001, text: "love word",
            annotationsJSON: #"[{"start":0,"end":4,"data":{"strongs":"G26"}},{"start":5,"end":9,"data":{"strongs":"G1"}}]"#
        )
        let analysis = esv.analysis()
        #expect(LampStrongsFormReading.gaps(of: analysis, readings: []) == [
            "ESV tags the word by its number but not by its Greek spelling, so its forms cannot be counted here.",
        ])
    }

    @Test func aGreekTextsFormIsTheWordAsPrinted() {
        // As TAGNT tags it: the word itself as the text, the dictionary form
        // as `lemma`.
        var greek = LampStrongsAnalyzer(key: "G26", translationID: "TAGNT", translationName: "TAGNT", language: "grc")
        for (index, word) in ["ἀγάπην", "ἀγάπη", "ἀγάπῃ,"].enumerated() {
            let text = word + " λόγος"
            let json = #"[{"start":0,"end":\#(word.count),"data":{"strongs":"G26","lemma":"ἀγάπη","morphology":"N-ASF"}},"#
                + #"{"start":\#(word.count + 1),"end":\#(text.count),"data":{"strongs":"G3056","lemma":"λόγος"}}]"#
            greek.add(reference: 62_004_016 + index, text: text, annotationsJSON: json)
        }
        #expect(Set(greek.analysis().forms.map(\.text)) == ["ἀγάπην", "ἀγάπη", "ἀγάπῃ"])
    }

    /// πνεῦμα is a subject in some verses and an object in others: one
    /// spelling, two jobs. Stating the commonest alone was wrong for 62 of
    /// its 145 New Testament occurrences.
    @Test func aSpellingWithTwoJobsNamesBoth() {
        var analyzer = LampStrongsAnalyzer(key: "G4151", translationID: "T", translationName: "Test")
        for (index, code) in ["N-NSN", "N-NSN", "N-ASN", "N-GSN"].enumerated() {
            let word = code == "N-GSN" ? "πνεύματος" : "πνεῦμα"
            let text = "Spirit word"
            let json = #"[{"start":0,"end":6,"data":{"strongs":"G4151","lemma":"\#(word)","morphology":"\#(code)"}},"#
                + #"{"start":7,"end":11,"data":{"strongs":"G1"}}]"#
            analyzer.add(reference: 43_003_005 + index, text: text, annotationsJSON: json)
        }
        let readings = LampStrongsFormReading.readings(of: analyzer.analysis())
        let pneuma = readings.first { $0.form.text == "πνεῦμα" }
        #expect(pneuma?.role == "either the subject or the object, one spelling for both")
        #expect(pneuma?.parsing == "Noun · Nominative · Singular · Neuter, or Noun · Accusative · Singular · Neuter")
        #expect(readings.first { $0.form.text == "πνεύματος" }?.role == "“of …”")
        #expect(LampStrongsFormReading.either(["a": 3, "b": 2, "c": 1, "d": 1])
            == "either a or b or c or more, one spelling for each")
        // What the jobs share is said once.
        #expect(LampStrongsFormReading.either(["the object · more than one": 2, "the subject · more than one": 1])
            == "either the object or the subject, one spelling for both · more than one")
        #expect(LampStrongsFormReading.either(["he · did it": 2, "he · “has …”": 1])
            == "he · either did it or “has …”, one spelling for both")
        #expect(LampStrongsFormReading.either(["x · y": 2, "x": 1]) == "either x · y or x, one spelling for both")

        // A chart of its forms says the same, so a slide cannot state less.
        let chart = LampPresentationChart(source: .init(strongs: "G4151", translationID: "T"), by: .form)
        #expect(chart.values(from: analyzer.analysis()).first?.detail
            == "pneuma · either the subject or the object, one spelling for both")
    }

    @Test func aSecondEnglishIsShownOnlyWhenItIsCommon() {
        #expect(LampStrongsFormReading.englishOfForm("And God, ") == "God")
        #expect(LampStrongsFormReading.englishOfForm("and") == "and")
    }

    @Test func choosingAFormListsEverySpellingItCounts() {
        let analysis = analysis
        let form = analysis.forms[0]
        #expect(analysis.occurrences(matching: .form(form.text)).count == form.count)
    }

    /// A verse as an original-language text tags it: the word itself as the
    /// text, its dictionary form as `lemma`.
    private func original(
        _ key: String, language: String, words: [(word: String, code: String)]
    ) -> LampStrongsAnalysis {
        var analyzer = LampStrongsAnalyzer(key: key, translationID: "O", translationName: "Original", language: language)
        for (index, row) in words.enumerated() {
            let text = row.word + " x"
            // Code points, as a real tagger writes them: a pointed Hebrew
            // word is seven of them and four Characters, and counting the
            // wrong one here made the fixture agree with a bug.
            let json = #"[{"start":0,"end":\#(row.word.unicodeScalars.count),"data":{"strongs":"\#(key)","lemma":"lemma","morphology":"\#(row.code)"}}]"#
            analyzer.add(reference: 19_001_001 + index, text: text, annotationsJSON: json)
        }
        return analyzer.analysis()
    }

    @Test func aGreekTextHasNoEnglishOfItsOwn() {
        let tagnt = original("G26", language: "grc", words: [("ἀγάπης", "N-GSF"), ("ἀγάπης", "N-GSF")])
        let readings = LampStrongsFormReading.readings(of: tagnt)
        #expect(readings[0].renderedAs.isEmpty)
        #expect(readings[0].role == "“of …”")
        #expect(LampStrongsFormReading.note(for: tagnt, readings: readings).hasSuffix(
            "Each spelling is shown with how to say it and what it does."
        ))
    }

    @Test func hebrewAccentsAreNotADifferentSpelling() {
        let tahot = original("H160", language: "hbo", words: [("אַהֲבָ֑ה", "HNcfsa"), ("אַהֲבָ֥ה", "HNcfsa"), ("אַֽהֲבָה", "HNcfsa")])
        #expect(tahot.forms.map(\.text) == ["אַהֲבָה"])
        #expect(tahot.forms.first?.count == 3)
    }

    @Test func aHebrewFormSaysTheSmallWordsItCarries() {
        func role(_ word: String, _ code: String, _ key: String = "H160") -> String? {
            LampStrongsFormReading.readings(of: original(key, language: "hbo", words: [(word, code)]))[0].role
        }
        #expect(role("בְּאַהֲבָתוֹ", "HR/Ncfsc/Sp3ms") == "“in his …”")
        #expect(role("וְאַהֲבָה", "HC/Ncfsa") == "“and …”")
        #expect(role("אַהֲבַת", "HNcfsc") == "“… of”, bound to the word after it")
        #expect(role("אַהֲבָה", "HNcfsa") == nil)
        #expect(role("לָאַהֲבָה", "HRd/Ncfsa") == "“to the …”")
        #expect(role("וַיֶּאֱהַב", "Hc/Vqw3ms", "H157") == "he · “and … did”, the next thing that happened")
        #expect(role("אֲהֵבוֹ", "HVqp3ms/Sp3ms", "H157") == "“… him” · he · “did”, “has done”")
    }

    @Test func aParsingWithNoJobIsAChoiceOfItsOwn() {
        var analyzer = LampStrongsAnalyzer(key: "G4139", translationID: "T", translationName: "T")
        for (index, code) in (Array(repeating: "ADV", count: 16) + ["N-NSF"]).enumerated() {
            let json = #"[{"start":0,"end":9,"data":{"strongs":"G4139","lemma":"πλησίον","morphology":"\#(code)"}}]"#
            analyzer.add(reference: 40_022_039 + index, text: "neighbour", annotationsJSON: json)
        }
        #expect(LampStrongsFormReading.readings(of: analyzer.analysis())[0].role
            == "either an adverb or the subject, one spelling for both")
    }
}

struct TranslationSourceTests {
    @Test func aModuleSaysWhereItsTaggingCameFrom() {
        let json = #"""
            [ { "part": "forms", "source": "an earlier BSB module", "method": "matched by each verse's Strong's numbers when the module was built" },
              { "part": "strongs", "source": "the WEB USFM's machine alignment" },
              { "part": "morphology", "source": "ignored" },
              "NA28", { "part": "forms", "source": " " } ]
            """#
        let sources = LampTranslationSource.parsed(json)
        #expect(sources == [
            .init(part: .forms, source: "an earlier BSB module",
                  method: "matched by each verse's Strong's numbers when the module was built"),
            .init(part: .strongs, source: "the WEB USFM's machine alignment"),
        ])
        #expect(sources[0].disclosure(translationName: "BSBs", strongsKey: "G26")
            == "Greek spellings in BSBs come from an earlier BSB module, matched by each verse's Strong's numbers when the module was built.")
        #expect(sources[1].disclosure(translationName: "WEBs", strongsKey: "H160")
            == "Strong’s numbers in WEBs come from the WEB USFM's machine alignment.")
        #expect(LampTranslationSource.parsed(nil).isEmpty)
        #expect(LampTranslationSource.parsed(#"{"part": "forms"}"#).isEmpty)
    }

    /// The tagged Septuagint's two sources for its numbers, which read as one
    /// sentence begun twice when each was its own paragraph: one lead, then
    /// each source. A part with one source keeps its sentence.
    @Test func severalSourcesForOnePartAreSaidOnce() {
        let sources: [LampTranslationSource] = [
            .init(part: .strongs, source: "STEPBible’s TAGNT", method: "matched to each word by machine"),
            .init(part: .forms, source: "an earlier module"),
            .init(part: .strongs, source: "STEPBible’s TAHOT", method: "for names the New Testament does not use"),
        ]
        #expect(LampTranslationSource.disclosures(sources, translationName: "LXX", strongsKey: "G26") == [
            "Strong’s numbers in LXX come from two sources:\n"
                + "• STEPBible’s TAGNT, matched to each word by machine.\n"
                + "• STEPBible’s TAHOT, for names the New Testament does not use.",
            "Greek spellings in LXX come from an earlier module.",
        ])
        #expect(LampTranslationSource.disclosures([], translationName: "LXX", strongsKey: "G26").isEmpty)
    }

    @Test func theLibraryReadsAnInstalledModulesSources() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        let moduleURL = fixture.appendingPathComponent("T.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {"meta": {"schemaVersion": "1.0", "id": "T", "type": "translation", "name": "Test", "abbreviation": "T", "language": "en",
                      "sourceTexts": [{"part": "forms", "source": "an earlier module", "method": "matched by Strong's numbers"}]},
             "books": [{"id": "John", "name": "John", "number": 43, "testament": "NT", "chapters": [{"chapter": 1, "verses": [{"v": 1, "content": {"text": "In the beginning"}}]}]}]}
            """#.utf8),
            sourceFilename: "T.json",
            destinationURL: moduleURL
        )
        _ = try await library.install(from: moduleURL)
        #expect(try await library.translationSources(moduleID: "T")
            == [.init(part: .forms, source: "an earlier module", method: "matched by Strong's numbers")])
    }

    @Test func aChartSaysWhatItRestsOnThatWasMatchedAtBuild() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        let moduleURL = fixture.appendingPathComponent("T.lamp")
        let annotations = #"[{"start":0,"end":4,"data":{"strongs":"G26","lemma":"ἀγάπη"}},{"start":5,"end":9,"data":{"strongs":"G1"}}]"#
        let meta = #"{"schemaVersion": "1.0", "id": "T", "type": "translation", "name": "Test", "abbreviation": "T", "language": "en", "sourceTexts": [{"part": "forms", "source": "an earlier module"}, {"part": "strongs", "source": "a machine alignment"}]}"#
        let verse: String = #"{"v": 1, "content": {"text": "love word", "annotations": \#(annotations)}}"#
        let books: String = #"[{"id": "John", "name": "John", "number": 43, "testament": "NT", "chapters": [{"chapter": 1, "verses": [\#(verse)]}]}]"#
        let document: String = #"{"meta": \#(meta), "books": \#(books)}"#
        _ = try LampModuleCompiler().compile(
            data: Data(document.utf8),
            sourceFilename: "T.json",
            destinationURL: moduleURL
        )
        _ = try await library.install(from: moduleURL)
        let numbers = "Strong’s numbers in T come from a machine alignment."
        let spellings = "Greek spellings in T come from an earlier module."
        let byBook = LampPresentationChart(source: .init(strongs: "G26", translationID: "T"), by: .book)
        #expect(try await library.workedOut(byBook)?.sources == [numbers])
        let forms = LampPresentationChart(source: .init(strongs: "G26", translationID: "T"), by: .form)
        #expect(Set(try await library.workedOut(forms)?.sources ?? []) == [numbers, spellings])
    }
}
