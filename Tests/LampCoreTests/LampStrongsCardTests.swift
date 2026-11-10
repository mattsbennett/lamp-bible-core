import Foundation
import Testing
@testable import LampCore

/// The Analyse card's slots: which figures a reader can put in them, what
/// happens to a figure the word cannot answer, and what a card carries into a
/// deck.
///
/// The card is where a word study begins, so a wrong number here is a wrong
/// number quoted onward — into a slide, and out of a listener's description
/// where nobody can see it was wrong.
struct StrongsCardFigureTests {
    private static func analysis(
        occurrences: Int = 3,
        wordCount: Int = 1_000,
        renderings: [(String, Int)] = [("love", 2), ("charity", 1)],
        forms: [(String, Int)] = [("ἀγάπη", 2), ("ἀγάπης", 1)],
        books: [(name: String, occurrences: Int, chapters: [Int])] = [
            (name: "Romans", occurrences: 2, chapters: [1, 0, 1]),
            (name: "Titus", occurrences: 1, chapters: [1, 0]),
            (name: "Jude", occurrences: 0, chapters: [0]),
        ],
        sections: [(String, Int)] = [("Paul's Letters", 3), ("General Letters", 0)]
    ) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: "G26",
            translationID: "esv",
            translationName: "English Standard Version",
            translationAbbreviation: "ESV",
            wordCount: wordCount,
            taggedVerseCount: 50,
            occurrences: (0 ..< occurrences).map { index in
                LampStrongsAnalysis.Occurrence(
                    reference: 45_000_001 + index,
                    startOffset: 0,
                    endOffset: 4,
                    text: "love",
                    renderingID: "love",
                    form: "ἀγάπη",
                    morphology: nil
                )
            },
            references: (0 ..< occurrences).map { 45_000_001 + $0 },
            renderings: renderings.map {
                .init(id: $0.0, text: $0.0, count: $0.1, variants: [])
            },
            forms: forms.map { .init(id: $0.0, text: $0.0, count: $0.1) },
            parsings: [],
            grammar: [],
            books: books.enumerated().map { index, book in
                .init(
                    id: 45 + index,
                    name: book.name,
                    bookRange: (45 + index)...(45 + index),
                    occurrenceCount: book.occurrences,
                    verseCount: book.occurrences,
                    wordCount: 400,
                    expectedCount: 1,
                    keyness: 0,
                    chapters: book.chapters.enumerated().map { number, hits in
                        .init(number: number + 1, occurrenceCount: hits, wordCount: 100)
                    }
                )
            },
            sections: sections.enumerated().map { index, section in
                .init(
                    id: 45 + index,
                    name: section.0,
                    bookRange: 45...66,
                    occurrenceCount: section.1,
                    verseCount: section.1,
                    wordCount: 600,
                    expectedCount: 1,
                    keyness: 0,
                    chapters: []
                )
            },
            companions: []
        )
    }

    @Test func everyFigureCountsWhatItsLabelSays() {
        let analysis = Self.analysis()
        func reading(_ figure: LampStrongsCardFigure) -> String {
            let reading = figure.reading(of: analysis)
            return [reading?.value, reading?.of].compactMap { $0 }.joined(separator: " ")
        }
        #expect(reading(.occurrences) == "3")
        #expect(reading(.verses) == "3")
        // Two of the three books in range hold it; the third is counted in
        // the denominator, which is the point of "of".
        #expect(reading(.books) == "2 of 3")
        // Every chapter of every book in range, zeros included.
        #expect(reading(.chapters) == "3 of 6")
        #expect(reading(.sections) == "1 of 2")
        #expect(reading(.perThousandWords) == "3")
        // "(no English of its own)" is not a word the translation uses.
        #expect(reading(.differentWords) == "2")
        #expect(reading(.forms) == "2")
        #expect(reading(.commonest) == "67% “love”")
    }

    @Test func aFigureTheWordCannotAnswerIsLeftOutRatherThanSubstituted() {
        let bare = Self.analysis(renderings: [], forms: [])
        #expect(LampStrongsCardFigure.forms.reading(of: bare) == nil)
        #expect(LampStrongsCardFigure.differentWords.reading(of: bare) == nil)
        #expect(LampStrongsCardFigure.commonest.reading(of: bare) == nil)

        let choice = LampStrongsCardChoice(figures: [.forms, .occurrences, .commonest], chart: nil)
        // Two slots drop out and the third keeps its own figure: a slot
        // filled with a substitute would label one thing and count another.
        #expect(choice.readings(of: bare).map(\.figure) == [.occurrences])
        #expect(choice.spoken(of: bare) == "3 times")
    }

    @Test func aRateNeedsWordsToHaveBeenCounted() {
        // Zero is not a small rate here, it is a missing denominator.
        #expect(LampStrongsCardFigure.perThousandWords.reading(of: Self.analysis(wordCount: 0)) == nil)
    }

    @Test func theCommonestWordIsTheCommonestWordAndNotTheCommonestTagging() {
        // More occurrences get no English of their own than are translated
        // "love", so the untranslated group sorts first. It is not a word, so
        // it cannot be what the card calls the commonest.
        let analysis = Self.analysis(occurrences: 10, renderings: [("", 7), ("love", 3)])
        let reading = LampStrongsCardFigure.commonest.reading(of: analysis)
        #expect(reading?.of == "“love”")
        #expect(reading?.value == "30%")
        #expect(LampStrongsCardFigure.differentWords.reading(of: analysis)?.value == "1")
    }

    @Test func aStoredChoiceIsReadForgivinglyInBothHalves() {
        func read(figures: String, chart: String = "books") -> LampStrongsCardChoice {
            LampStrongsCardChoice(storedFigures: figures, storedChart: chart)
        }
        // Nothing stored is the card's own three, not a card with no figures.
        #expect(read(figures: "").figures == LampStrongsCardChoice.standard.figures)
        // A figure from a newer Lamp is dropped, not refused.
        #expect(read(figures: "occurrences,wingspan,verses").figures == [.occurrences, .verses])
        // Two slots counting one thing is a setting no chooser can make.
        #expect(read(figures: "verses,verses,books").figures == [.verses, .books])
        #expect(read(figures: " verses , books ").figures == [.verses, .books])
        // A fourth figure would shrink every number on the card.
        #expect(read(figures: "verses,books,forms,commonest").figures.count == LampStrongsCardChoice.slots)

        #expect(read(figures: "", chart: "off").chart == nil)
        #expect(read(figures: "", chart: "renderings").chart == .renderings)
        // A chart named by a newer Lamp falls back to the card's own strip:
        // an empty band under the figures reads as a card that failed.
        #expect(read(figures: "", chart: "constellations").chart == .books)
        #expect(read(figures: "", chart: "").chart == .books)
    }

    @Test func aChoiceSurvivesBeingStoredAndReadBack() {
        for chart in LampStrongsGrouping.allCases.map({ Optional($0) }) + [nil] {
            let choice = LampStrongsCardChoice(figures: [.commonest, .chapters, .forms], chart: chart)
            #expect(
                LampStrongsCardChoice(
                    storedFigures: choice.storedFigures, storedChart: choice.storedChart
                ) == choice
            )
        }
    }

    @Test func oneDivisionIsNotAChart() {
        // A strip of a single column, or a ring that is one whole circle,
        // draws a shape that says nothing the figures above it did not.
        let alone = Self.analysis(
            renderings: [("love", 3)],
            forms: [("ἀγάπη", 3)],
            books: [(name: "Romans", occurrences: 3, chapters: [3])],
            sections: [("Paul's Letters", 3)]
        )
        for grouping in LampStrongsGrouping.allCases {
            #expect(!grouping.canDraw(alone), "\(grouping) drew one division")
            #expect(LampStrongsCardChoice(figures: [], chart: grouping).chart(for: alone) == nil)
        }
        let several = Self.analysis()
        #expect(LampStrongsGrouping.allCases.allSatisfy { $0.canDraw(several) })
    }

    @Test func onlyWhatThisWordCanAnswerIsOfferedForASlot() {
        #expect(LampStrongsCardChoice.available(for: Self.analysis()) == LampStrongsCardFigure.allCases)
        let bare = Self.analysis(renderings: [], forms: [], sections: [])
        let offered = LampStrongsCardChoice.available(for: bare)
        #expect(!offered.contains(.forms))
        #expect(!offered.contains(.differentWords))
        #expect(!offered.contains(.commonest))
        #expect(!offered.contains(.sections))
        #expect(offered.contains(.occurrences))
    }
}

/// What a chosen card carries into a deck.
///
/// A slide outlives the pane it was added from, and nothing re-asks the
/// reader what their card looked like, so whatever is written here is what a
/// room full of people will be shown.
struct StrongsCardInADeckTests {
    private static func analysis(forms: [(String, Int)] = [("ἀγάπη", 2), ("ἀγάπης", 1)]) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: "G26",
            translationID: "esv",
            translationName: "English Standard Version",
            translationAbbreviation: "ESV",
            wordCount: 1_000,
            taggedVerseCount: 50,
            occurrences: [],
            references: [45_000_001, 45_000_002, 45_000_003],
            renderings: [.init(id: "love", text: "love", count: 3, variants: [])],
            forms: forms.map { .init(id: $0.0, text: $0.0, count: $0.1) },
            parsings: [],
            grammar: [],
            books: [
                .init(
                    id: 45, name: "Romans", bookRange: 45...45, occurrenceCount: 3,
                    verseCount: 3, wordCount: 400, expectedCount: 1, keyness: 0, chapters: []
                ),
                .init(
                    id: 46, name: "1 Corinthians", bookRange: 46...46, occurrenceCount: 0,
                    verseCount: 0, wordCount: 400, expectedCount: 1, keyness: 0, chapters: []
                ),
            ],
            sections: [],
            companions: []
        )
    }

    private static func card(figures: [String]?) -> LampPresentationChart {
        LampPresentationChart(
            source: .init(strongs: "G26", translationID: "esv"),
            by: .book,
            style: .card,
            figures: figures
        )
    }

    @Test func aCardPrintingItsStandardThreeIsWrittenAsItAlwaysWas() {
        // An ordinary card must encode exactly as it did before slots could
        // be chosen, or every deck in the library looks changed.
        for figures in [nil, ["occurrences", "verses", "books"]] as [[String]?] {
            let worked = Self.card(figures: figures).headword(from: Self.analysis(), headword: nil)
            #expect(worked.figures == nil)
            #expect(worked.occurrences == 0)
            #expect(worked.verses == 3)
            #expect(worked.books == 1)
            #expect(worked.bookCount == 2)
        }
    }

    @Test func aCardCarriesTheFiguresItPrinted() {
        let worked = Self.card(figures: ["verses", "forms", "books"])
            .headword(from: Self.analysis(), headword: nil)
        #expect(worked.figures?.map(\.label) == ["Verses", "Forms", "Books"])
        #expect(worked.figures?.map(\.value) == ["3", "2", "1"])
        #expect(worked.figures?.map(\.of) == [nil, nil, "of 2"])
        // The fields an older Lamp reads are still written, so a deck opened
        // there draws the card it has always drawn.
        #expect(worked.verses == 3)
    }

    @Test func aFigureTheWordCannotAnswerIsNotWrittenIntoTheSlide() {
        let worked = Self.card(figures: ["verses", "forms"])
            .headword(from: Self.analysis(forms: []), headword: nil)
        #expect(worked.figures?.map(\.label) == ["Verses"])
    }

    @Test func aDeckNamingAFigureThisVersionDoesNotKnowStillOpens() throws {
        let json = """
        {"source":{"strongs":"G26","translationID":"esv"},"by":"book","style":"card",
         "figures":["occurrences","wingspan","forms"]}
        """
        let chart = try JSONDecoder().decode(LampPresentationChart.self, from: Data(json.utf8))
        // Dropped when read, not refused when decoded.
        #expect(chart.cardFigures == [.occurrences, .forms])
        // And kept in the file, so the Lamp that knows the figure still has
        // it after this one has saved the deck.
        let again = try JSONDecoder().decode(
            LampPresentationChart.self, from: JSONEncoder().encode(chart)
        )
        #expect(again.figures == ["occurrences", "wingspan", "forms"])
    }

    @Test func aListenerHearsTheFiguresTheCardPrinted() {
        var chart = Self.card(figures: ["verses", "forms"])
        chart.headword = chart.headword(from: Self.analysis(), headword: nil)
        chart.values = chart.values(from: [Self.analysis()])
        #expect(chart.spokenDescription.contains("Verses 3, Forms 2"))

        var standard = Self.card(figures: nil)
        standard.headword = standard.headword(from: Self.analysis(), headword: nil)
        standard.values = standard.values(from: [Self.analysis()])
        #expect(standard.spokenDescription.contains("3 verses, in 1 of 2 books"))
    }

    @Test func aDeckIsToldWhatItNamedWrongly() {
        func warnings(_ chart: LampPresentationChart) -> [String] {
            LampPresentationDeckValidator.validate(
                LampPresentationDeck(title: "Card", slides: [
                    .init(layout: .image, blocks: [.init(kind: .chart, chart: chart)]),
                ]),
                assetExists: { _ in true }
            )
            // The path is the block's: `slides[0].blocks[0].chart.figures`.
            .filter { $0.path.hasSuffix("chart.figures") }
            .map(\.message)
        }
        #expect(warnings(Self.card(figures: ["verses"])).isEmpty)
        #expect(warnings(Self.card(figures: nil)).isEmpty)

        let unknown = warnings(Self.card(figures: ["verses", "wingspan"]))
        #expect(unknown.count == 1)
        #expect(unknown.first?.contains("“wingspan” is not a figure a card prints") == true)

        let tooMany = warnings(Self.card(figures: ["verses", "books", "forms", "commonest"]))
        #expect(tooMany == ["A card prints 3 figures, so the rest are not drawn."])

        // Figures without a card, as a headword without a card is.
        var bars = Self.card(figures: ["verses"])
        bars.style = .bars
        #expect(warnings(bars) == ["Only a card prints figures."])
    }
}
