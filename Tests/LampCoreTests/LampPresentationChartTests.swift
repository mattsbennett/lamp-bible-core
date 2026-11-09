import Foundation
import LampModuleKit
import Testing
@testable import LampCore

struct LampPresentationChartTests {
    private func tagged(_ words: [(String, String)]) -> (text: String, json: String) {
        var text = ""
        var annotations: [String] = []
        for (word, key) in words {
            if !text.isEmpty { text += " " }
            let start = text.count
            text += word
            annotations.append(#"{"type":"strongs","start":\#(start),"end":\#(text.count),"data":{"strongs":"\#(key)"}}"#)
        }
        return (text, "[" + annotations.joined(separator: ",") + "]")
    }

    /// Love tagged ten times in twenty verses of 1 Corinthians, and nowhere in
    /// the two hundred of Matthew or the five of Romans.
    private var verses: [(Int, (text: String, json: String))] {
        let filler = Array(repeating: ("word", "G1"), count: 10)
        let matthew = (1...200).map { (40_001_000 + $0, tagged(filler)) }
        let romans = (1...5).map { (45_001_000 + $0, tagged(filler)) }
        let corinthians = (1...20).map { number in
            (46_013_000 + number, tagged(number <= 10 ? [("love", "G26")] + filler.dropFirst() : filler))
        }
        return matthew + romans + corinthians
    }

    private var analysis: LampStrongsAnalysis {
        var analyzer = LampStrongsAnalyzer(key: "G26", translationID: "T", translationName: "Test")
        for (reference, verse) in verses {
            analyzer.add(reference: reference, text: verse.text, annotationsJSON: verse.json)
        }
        return analyzer.analysis()
    }

    private func chart(
        by grouping: LampPresentationChart.Grouping,
        measure: LampPresentationChart.Measure = .occurrences
    ) -> LampPresentationChart {
        .init(source: .init(strongs: "G26", translationID: "T"), by: grouping, measure: measure)
    }

    @Test func aChartBlockReadsAsTheDeckFormatWritesIt() throws {
        let json = #"""
            { "id": "c1", "kind": "chart", "text": "Where ἀγάπη is found",
              "chart": {
                "source": { "strongs": "G26", "translationID": "ESVs", "range": "NT" },
                "by": "section", "measure": "occurrences",
                "values": [ { "label": "Gospels", "value": 9, "standing": "fewer" },
                            { "label": "Paul’s Letters", "value": 71, "standing": "more" } ] } }
            """#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(block.kind == .chart)
        #expect(block.chart?.source == .init(strongs: "G26", translationID: "ESVs", range: "NT"))
        #expect(block.chart?.by == .section)
        #expect(block.chart?.values?.map(\.standing) == [.fewer, .more])
        let again = try JSONDecoder().decode(LampPresentationBlock.self, from: JSONEncoder().encode(block))
        #expect(again == block)
    }

    @Test func aChartsBarsComeFromTheAnalysis() {
        let books = chart(by: .book).values(from: analysis)
        #expect(books.map(\.label) == ["Matthew", "1 Corinthians"])
        #expect(books.map(\.value) == [0, 10])
        #expect(books.map(\.standing) == [.fewer, .more])

        let sections = chart(by: .section).values(from: analysis)
        #expect(sections.map(\.label) == ["Gospels", "Paul’s Letters"])
        #expect(sections.map(\.standing) == [.fewer, .more])

        let rates = chart(by: .book, measure: .perThousandWords)
        #expect(rates.values(from: analysis).last?.value == 50)
        #expect(rates.formatted(2.5) == (2.5).formatted(.number.precision(.fractionLength(0...2))))
        #expect(chart(by: .book).formatted(10) == "10")

        #expect(chart(by: .rendering).values(from: analysis).map(\.label) == ["love"])
        #expect(chart(by: .form).values(from: analysis).isEmpty)

        var spoken = chart(by: .section)
        spoken.values = sections
        #expect(spoken.spokenDescription
            == "Chart of G26 in T: Gospels 0, fewer than expected; Paul’s Letters 10, 100 percent, more than expected")
    }

    @Test func aStyleTheAppDoesNotKnowReadsAsBars() throws {
        func decoded(_ style: String?) throws -> LampPresentationChart {
            let field = style.map { #", "style": "\#($0)""# } ?? ""
            let json = #"{"source": {"strongs": "G26", "translationID": "T"}, "by": "book", "measure": "occurrences"\#(field)}"#
            return try JSONDecoder().decode(LampPresentationChart.self, from: Data(json.utf8))
        }
        #expect(try decoded(nil).drawnStyle == .bars)
        #expect(try decoded("grid").drawnStyle == .grid)
        #expect(try decoded("spiral").drawnStyle == .bars)
    }

    @Test func eachStyleTakesTheValuesItDraws() {
        var columns = chart(by: .book)
        columns.style = .columns
        #expect(columns.values(from: analysis).map(\.label) == ["Matthew", "Romans", "1 Corinthians"])

        var grid = chart(by: .book)
        grid.style = .grid
        let rows = grid.values(from: analysis)
        #expect(rows.map(\.label) == ["Matthew", "Romans", "1 Corinthians"])
        #expect(rows.map { $0.chapters?.count } == [1, 1, 13])
        #expect(rows.last?.chapters?.last == 10)
        #expect(rows.last?.chapters?.dropLast().allSatisfy { $0 == 0 } == true)

        var share = chart(by: .section, measure: .perThousandWords)
        share.style = .share
        let ring = share.values(from: analysis)
        #expect(ring == [.init(label: "Paul’s Letters", value: 10)])
        #expect(share.formatted(10) == "10")
        share.values = ring
        #expect(share.spokenDescription.hasSuffix("Paul’s Letters 10, 100 percent"))

        // Eleven renderings: the largest and the next five alphabetically keep
        // their slices, and the last five are gathered into one, as the
        // analysis's ring gathers them.
        var analyzer = LampStrongsAnalyzer(key: "G26", translationID: "T", translationName: "Test")
        let words = Array(repeating: "love", count: 5) + (1...10).map { "word\($0)" }
        for (index, word) in words.enumerated() {
            let verse = tagged([(word, "G26"), ("filler", "G1")])
            analyzer.add(reference: 46_013_001 + index, text: verse.text, annotationsJSON: verse.json)
        }
        var renderings = chart(by: .rendering)
        renderings.style = .share
        let slices = renderings.values(from: analyzer.analysis())
        #expect(slices.count == LampPresentationChart.shareSlices)
        #expect(slices.first == .init(label: "love", value: 5))
        #expect(slices.last == .init(label: "Other", value: 5))
        #expect(slices.reduce(0) { $0 + $1.value } == 15)
    }

    @Test func theValidatorHoldsEachStyleToWhatItCanDraw() {
        func messages(_ chart: LampPresentationChart) -> [String] {
            var deck = LampPresentationDeck.starter(title: "Charts")
            deck.slides = [LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: chart)])]
            return LampPresentationDeckValidator.validate(deck).map(\.message)
        }
        let many = (1...30).map { LampPresentationChart.Value(label: "Book \($0)", value: 1) }
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T"), by: .book, style: .columns, values: many)).isEmpty)
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T"), by: .book, values: many))
            == ["30 bars are hard to read from the back of a room. Chart by section, or narrow the range."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T"), by: .section, style: .grid, values: []))
            == ["A grid shades each book's chapters, so it charts by book."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T"), by: .book, style: .grid, values: many))
            == ["This grid has no chapters yet. Lamp works them out when the deck is built."])
        let nine = Array(many.prefix(9))
        #expect(messages(.init(
            source: .init(strongs: "G26", translationID: "T"), by: .book, measure: .perThousandWords,
            style: .share, values: nine
        )) == [
            "A share is of occurrences: rates per thousand words do not add up to a whole, so the ring counts occurrences.",
            "A share of 9 slices cannot be told apart. Build the deck again to gather the smallest.",
        ])
    }

    @Test func aChartTakesTheSlotAPictureWould() {
        let chartBlock = LampPresentationBlock(kind: .chart, chart: chart(by: .book))
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Love in Corinth"),
            .init(kind: .body, text: "Paul names it ten times here."),
            chartBlock,
            .init(kind: .caption, text: "ESVs, New Testament"),
        ])
        #expect(slide.plan.image == chartBlock)
        #expect(slide.plan.caption?.text == "ESVs, New Testament")
        #expect(slide.plan.ignored.isEmpty)
        #expect(slide.displayTitle == "Love in Corinth")
        #expect(LampPresentationSlide(layout: .image, blocks: [chartBlock]).plan.image == chartBlock)
        #expect(LampPresentationSlide(layout: .image, blocks: [chartBlock]).displayTitle == "Chart of G26")

        var deck = LampPresentationDeck.starter(title: "Love")
        deck.slides = [
            LampPresentationSlide(layout: .scripture, blocks: [
                .init(kind: .scripture, text: "Love is patient"),
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A field"),
                chartBlock,
            ]),
            LampPresentationSlide(layout: .twoColumn, blocks: [
                .init(kind: .body, text: "One"), .init(kind: .body, text: "Two"), chartBlock,
            ]),
        ]
        let messages = LampPresentationDeckValidator.validate(deck).map(\.message)
        #expect(messages.contains { $0.contains("does not draw chart content — a slide draws one picture or chart") })
        #expect(messages.contains { $0.contains("two-column slides draw no picture or chart") })
    }

    @Test func theValidatorHoldsAChartToWhatItCanDraw() {
        func issues(_ blocks: [LampPresentationBlock]) -> [LampPresentationDeckIssue] {
            var deck = LampPresentationDeck.starter(title: "Charts")
            deck.slides = [LampPresentationSlide(layout: .image, blocks: blocks)]
            return LampPresentationDeckValidator.validate(deck)
        }
        var complete = chart(by: .section)
        complete.values = [.init(label: "Gospels", value: 9)]
        #expect(issues([.init(kind: .chart, chart: complete)]).isEmpty)

        #expect(issues([.init(kind: .chart)]).contains {
            $0.severity == .error && $0.path == "slides[0].blocks[0].chart"
        })
        #expect(issues([.init(kind: .body, text: "Words", chart: complete)]).contains {
            $0.severity == .error && $0.message == "A chart is supported on chart content."
        })

        var bare = complete
        bare.source.strongs = "26"
        #expect(issues([.init(kind: .chart, chart: bare)]).map(\.severity) == [.warning])
        var nameless = complete
        nameless.source.translationID = " "
        #expect(issues([.init(kind: .chart, chart: nameless)]).map(\.path)
            == ["slides[0].blocks[0].chart.source.translationID"])
        var nowhere = complete
        nowhere.source.range = "Nowhere"
        #expect(issues([.init(kind: .chart, chart: nowhere)]).map(\.path)
            == ["slides[0].blocks[0].chart.source.range"])
        #expect(issues([.init(kind: .chart, chart: chart(by: .book))]).map(\.message)
            == ["No values yet. Lamp works them out from the library when the deck is built."])
        var crowded = complete
        crowded.values = (1...30).map { .init(label: "Book \($0)", value: Double($0)) }
        #expect(issues([.init(kind: .chart, chart: crowded)]).map(\.path)
            == ["slides[0].blocks[0].chart.values"])
    }

    @Test func theLibraryWorksOutChartsAndNamesStaleOnes() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-chart-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))

        let books = Dictionary(grouping: verses) { LampBibleReferenceFormatter.components(of: $0.0).book }
            .sorted { $0.key < $1.key }
            .map { book, verses in
                let chapter = LampBibleReferenceFormatter.components(of: verses[0].0).chapter
                let rows = verses.map { reference, verse in
                    #"{"v": \#(reference % 1_000), "content": {"text": "\#(verse.text)", "annotations": \#(verse.json)}}"#
                }
                let name = LampBibleReferenceFormatter.bookName(book)
                return #"{"id": "\#(name)", "name": "\#(name)", "number": \#(book), "testament": "NT", "chapters": [{"chapter": \#(chapter), "verses": [\#(rows.joined(separator: ","))]}]}"#
            }
        let moduleURL = fixture.appendingPathComponent("T.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {"meta": {"schemaVersion": "1.0", "id": "T", "type": "translation", "name": "Test", "abbreviation": "T", "language": "en"},
             "books": [\#(books.joined(separator: ","))]}
            """#.utf8),
            sourceFilename: "T.json",
            destinationURL: moduleURL
        )
        _ = try await library.install(from: moduleURL)

        var deck = LampPresentationDeck.starter(title: "Love")
        var elsewhere = chart(by: .book)
        elsewhere.source.translationID = "MISSING"
        elsewhere.values = [.init(label: "John", value: 3)]
        deck.slides = [
            LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: chart(by: .section))]),
            LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: elsewhere)]),
        ]

        let built = await library.workingOutCharts(in: deck)
        #expect(built.changed)
        #expect(built.deck.slides[0].blocks[0].chart?.values?.map(\.label) == ["Gospels", "Paul’s Letters"])
        #expect(built.deck.slides[1].blocks[0].chart?.values == elsewhere.values)
        #expect(built.issues.map(\.path) == ["slides[1].blocks[0].chart.source"])

        let again = await library.workingOutCharts(in: built.deck)
        #expect(!again.changed)

        var stale = built.deck
        stale.slides[0].blocks[0].chart?.values?[1].value = 99
        let checked = await library.workingOutCharts(in: stale)
        #expect(checked.changed)
        #expect(checked.issues.contains {
            $0.path == "slides[0].blocks[0].chart.values" && $0.message.contains("no longer match T")
        })
        #expect(checked.deck == built.deck)

        var ranged = chart(by: .book)
        ranged.source.range = "Romans-1 Corinthians"
        #expect(try await library.chartValues(ranged)?.map(\.label) == ["1 Corinthians"])

        // An agent charts only what its policy lets it read, and is not told
        // whether a withheld translation is installed.
        let agent = LampAgentLibrary(library: library)
        #expect(try await agent.workingOutCharts(in: deck).deck == built.deck)
        let narrowed = LampAgentLibrary(library: library, policy: .init(allowedModuleIDs: ["OTHER"]))
        let withheld = try await narrowed.workingOutCharts(in: deck)
        #expect(withheld.deck == deck)
        #expect(!withheld.changed)
        #expect(withheld.issues.map(\.message) == [
            "T is not available to agents, so the chart keeps the values it carries.",
            "MISSING is not available to agents, so the chart keeps the values it carries.",
        ])
        await #expect(throws: LampAgentError.disabled) {
            try await LampAgentLibrary(library: library, policy: .disabled).workingOutCharts(in: deck)
        }
    }

    // MARK: - Figures from the analysis

    /// A verse of words, each with its key and optionally its form and parsing.
    private func parsed(_ words: [(String, String, String?, String?)]) -> (text: String, json: String) {
        var text = ""
        var annotations: [String] = []
        for (word, key, lemma, morphology) in words {
            if !text.isEmpty { text += " " }
            let start = text.count
            text += word
            var data = #""strongs":"\#(key)""#
            if let lemma { data += #","lemma":"\#(lemma)""# }
            if let morphology { data += #","morphology":"\#(morphology)""# }
            annotations.append(#"{"type":"strongs","start":\#(start),"end":\#(text.count),"data":{\#(data)}}"#)
        }
        return (text, "[" + annotations.joined(separator: ",") + "]")
    }

    /// ἀγάπη rendered "love" in three verses of John, as nominatives, and
    /// "charity" in two of 1 Corinthians, as genitives.
    private func narrowed(
        _ filter: LampPresentationChart.Filter?,
        translation: String = "T"
    ) -> LampStrongsAnalysis {
        var analyzer = LampStrongsAnalyzer(
            key: "G26", translationID: translation, translationName: "Test \(translation)",
            translationAbbreviation: translation, keeping: filter?.keeping(key: "G26")
        )
        let filler = ("word", "G1", String?.none, String?.none)
        for verse in 1...3 {
            let row = parsed([("love", "G26", "ἀγάπη", "N-NSF"), filler, filler])
            analyzer.add(reference: 43_001_000 + verse, text: row.text, annotationsJSON: row.json)
        }
        for verse in 1...2 {
            let row = parsed([("of charity", "G26", "ἀγάπης", "N-GSF"), filler])
            analyzer.add(reference: 46_013_000 + verse, text: row.text, annotationsJSON: row.json)
        }
        return analyzer.analysis()
    }

    @Test func aFilterNarrowsEveryFigureToTheOccurrencesItKeeps() {
        let all = narrowed(nil)
        #expect(all.occurrenceCount == 5)

        let love = narrowed(.init(rendering: "Love"))
        #expect(love.occurrenceCount == 3)
        #expect(love.books.map(\.occurrenceCount) == [3, 0])
        // Still weighed against every tagged word in range.
        #expect(love.wordCount == all.wordCount)

        #expect(narrowed(.init(form: "ἀγὰπης")).occurrenceCount == 2)
        #expect(narrowed(.init(grammar: .init(feature: .grammaticalCase, value: "genitive"))).occurrenceCount == 2)
        #expect(narrowed(.init(rendering: "love", grammar: .init(feature: .grammaticalCase, value: "Genitive")))
            .occurrenceCount == 0)
        #expect(narrowed(.init(rendering: " ")).occurrenceCount == 5)
        #expect(LampPresentationChart.Filter(rendering: " ").isEmpty)

        #expect(LampPresentationChart.Filter(
            rendering: "love", form: "ἀγάπη", grammar: .init(feature: .grammaticalCase, value: "Nominative")
        ).narrowing == "rendered “love”, as ἀγάπη, Case: Nominative")
    }

    @Test func aChartNamesItsFilterAndFeatureAsADeckWritesThem() throws {
        let json = #"""
            { "source": { "strongs": "G26", "translationID": "T",
                          "filter": { "rendering": "love", "grammar": { "feature": "case", "value": "Genitive" } } },
              "by": "grammar", "feature": "case" }
            """#
        let chart = try JSONDecoder().decode(LampPresentationChart.self, from: Data(json.utf8))
        #expect(chart.feature == .grammaticalCase)
        #expect(chart.measure == .occurrences)
        #expect(chart.source.filter?.grammar == .init(feature: .grammaticalCase, value: "Genitive"))
        #expect(chart.subject == "G26 in T, rendered “love”, Case: Genitive, by case")
        let again = try JSONDecoder().decode(LampPresentationChart.self, from: JSONEncoder().encode(chart))
        #expect(again == chart)
        #expect(LampGrammarFeature.named("Part of speech") == .partOfSpeech)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LampGrammarFeature.self, from: Data(#""aspect""#.utf8))
        }
    }

    @Test func barsOfAWholePrintTheirShare() {
        let books = chart(by: .book).values(from: analysis)
        #expect(books.map(\.share) == [0, 1])
        #expect(chart(by: .book).printed(books[1]) == "10 · 100%")
        #expect(chart(by: .book).printed(books[0]) == "0")
        // A rate is not a part of anything, and columns print no figure.
        #expect(chart(by: .book, measure: .perThousandWords).values(from: analysis).allSatisfy { $0.share == nil })
        var columns = chart(by: .book)
        columns.style = .columns
        #expect(columns.values(from: analysis).allSatisfy { $0.share == nil })

        var spoken = chart(by: .book)
        spoken.values = books
        #expect(spoken.spokenDescription.hasSuffix("1 Corinthians 10, 100 percent, more than expected"))
    }

    @Test func grammarIsChartedOneFeatureAtATime() {
        var grammar = LampPresentationChart(source: .init(strongs: "G26", translationID: "T"), by: .grammar)
        #expect(grammar.values(from: narrowed(nil)).isEmpty)
        grammar.feature = .grammaticalCase
        let values = grammar.values(from: narrowed(nil))
        #expect(values.map(\.label) == ["Nominative", "Genitive"])
        #expect(values.map(\.share) == [0.6, 0.4])
        grammar.style = .share
        #expect(grammar.values(from: narrowed(nil)) == [
            .init(label: "Nominative", value: 3), .init(label: "Genitive", value: 2),
        ])
    }

    @Test func translationsAreComparedSideBySide() {
        let compare = LampPresentationChart(source: .init(strongs: "G26", translationID: ""), by: .translation)
        let values = compare.values(from: [narrowed(.init(form: "ἀγάπης"), translation: "U"), narrowed(nil)])
        #expect(values.map(\.label) == ["T", "U"])
        #expect(values.map(\.value) == [5, 2])
        #expect(values.first?.detail == "love (3), charity (2)")
        #expect(values.allSatisfy { $0.share == nil })
        #expect(compare.subject == "G26 across translations")
    }

    @Test func companionsAreNamedByTheirWordAndMeasuredAgainstChance() {
        let base = analysis
        let withCompanions = LampStrongsAnalysis(
            key: base.key, translationID: base.translationID, translationName: base.translationName,
            translationAbbreviation: nil, wordCount: base.wordCount, taggedVerseCount: base.taggedVerseCount,
            occurrences: base.occurrences, references: base.references, renderings: base.renderings,
            forms: base.forms, parsings: base.parsings, grammar: base.grammar, books: base.books,
            sections: base.sections,
            companions: [
                .init(key: "G4102", sharedVerseCount: 22, verseCount: 243, lift: 9.06, keyness: 40),
                .init(key: "G1680", sharedVerseCount: 1, verseCount: 50, lift: 3.04, keyness: 11),
            ]
        )
        var companions = chart(by: .companion, measure: .perThousandWords)
        #expect(companions.headwordKeys(in: [withCompanions]) == ["G4102", "G1680"])
        let values = companions.values(
            from: withCompanions,
            headwords: ["G4102": .init(lemma: "πίστις", shortGloss: "faith")]
        )
        #expect(values == [
            .init(label: "πίστις", value: 9.1, detail: "G4102 · faith · 22 shared verses"),
            .init(label: "G1680", value: 3, detail: "1 shared verse"),
        ])
        #expect(companions.formatted(9.1) == (9.1).formatted(.number.precision(.fractionLength(1))) + "×")
        companions.values = values
        #expect(companions.spokenDescription.contains("πίστις 9.1× chance"))
    }

    @Test func aCardCarriesTheHeadwordOverEveryBook() {
        var card = chart(by: .book)
        card.style = .card
        #expect(card.headwordKeys(in: [analysis]) == ["G26"])
        #expect(card.values(from: analysis).map(\.label) == ["Matthew", "Romans", "1 Corinthians"])
        let headword = card.headword(
            from: analysis,
            headword: .init(lemma: "ἀγάπη", transliteration: "agapē", shortGloss: "love", shortDefinition: "a long definition")
        )
        #expect(headword == .init(
            lemma: "ἀγάπη", transliteration: "agapē", gloss: "love",
            occurrences: 10, verses: 10, books: 1, bookCount: 3, perThousandWords: 4.44, translation: "Test"
        ))
        card.headword = headword
        #expect(card.spokenDescription.hasPrefix("Chart of G26 in T: ἀγάπη, love: 10 times in 10 verses, in 1 of 3 books"))
    }

    @Test func theValidatorHoldsTheNewChartsToWhatTheyCanDraw() {
        func messages(_ chart: LampPresentationChart) -> [String] {
            var complete = chart
            complete.values = complete.values ?? [.init(label: "One", value: 1)]
            var deck = LampPresentationDeck.starter(title: "Charts")
            deck.slides = [LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: complete)])]
            return LampPresentationDeckValidator.validate(deck).map(\.message)
        }
        let source = LampPresentationChart.Source(strongs: "G26", translationID: "T")
        #expect(messages(.init(source: source, by: .grammar))
            == ["A chart by grammar names its feature, such as grammaticalCase or tense."])
        #expect(messages(.init(source: source, by: .grammar, feature: .tense)).isEmpty)
        #expect(messages(.init(source: source, by: .book, feature: .tense))
            == ["A feature is read only by a chart by grammar."])
        #expect(messages(.init(source: source, by: .section, style: .card))
            == ["A card draws a column for each book under the word, so it charts by book."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: ""), by: .translation)).isEmpty)
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "", translations: [" "]), by: .translation))
            == ["Name the translations to compare, or leave the list out to compare every tagged one."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T", translations: ["U"]), by: .book))
            == ["Only a chart by translation compares translations; this one counts translationID."])
        #expect(messages(.init(source: source, by: .translation, style: .share))
            == ["Each translation counts the whole again, so they are not slices of one ring."])
        #expect(messages(.init(source: source, by: .companion, measure: .perThousandWords)) == [
            "A companion is measured by how many times chance it shares the key's verses, so the measure is not read.",
        ])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T", filter: .init()), by: .book))
            == ["This filter names nothing, so every occurrence is counted."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T", filter: .init(rendering: "love")), by: .rendering))
            == ["The filter keeps one rendering, so a chart by rendering draws a single value."])
        #expect(messages(.init(source: .init(strongs: "G26", translationID: "T", filter: .init(rendering: "love")), by: .book))
            .isEmpty)
    }

    @Test func theLibraryWorksOutTheNewCharts() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-chart-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        for id in ["T", "U"] {
            let rows = (1...3).map { verse -> String in
                let row = verse <= 2 || id == "T"
                    ? parsed([("love", "G26", "ἀγάπη", "N-NSF"), ("word", "G1", nil, nil)])
                    : parsed([("charity", "G26", "ἀγάπης", "N-GSF"), ("word", "G1", nil, nil)])
                return #"{"v": \#(verse), "content": {"text": "\#(row.text)", "annotations": \#(row.json)}}"#
            }
            let moduleURL = fixture.appendingPathComponent("\(id).lamp")
            _ = try LampModuleCompiler().compile(
                data: Data(#"""
                {"meta": {"schemaVersion": "1.0", "id": "\#(id)", "type": "translation", "name": "Test \#(id)", "abbreviation": "\#(id)", "language": "en"},
                 "books": [{"id": "John", "name": "John", "number": 43, "testament": "NT", "chapters": [{"chapter": 1, "verses": [\#(rows.joined(separator: ","))]}]}]}
                """#.utf8),
                sourceFilename: "\(id).json",
                destinationURL: moduleURL
            )
            _ = try await library.install(from: moduleURL)
        }

        var compare = LampPresentationChart(source: .init(strongs: "G26", translationID: ""), by: .translation)
        #expect(try await library.workedOut(compare)?.values?.map(\.label) == ["T", "U"])
        compare.source.translations = ["U"]
        #expect(try await library.workedOut(compare)?.values?.map(\.label) == ["U"])
        compare.source.filter = .init(rendering: "charity")
        #expect(try await library.workedOut(compare)?.values?.map(\.value) == [1])

        var card = LampPresentationChart(source: .init(strongs: "G26", translationID: "T"), by: .book, style: .card)
        let worked = try await library.workedOut(card)
        #expect(worked?.headword?.occurrences == 3)
        #expect(worked?.headword?.lemma == nil)
        card.source.filter = .init(grammar: .init(feature: .grammaticalCase, value: "Genitive"))
        #expect(try await library.workedOut(card)?.headword?.occurrences == 0)

        // An agent compares only the translations its policy lets it read.
        var deck = LampPresentationDeck.starter(title: "Love")
        let everyOne = LampPresentationChart(source: .init(strongs: "G26", translationID: ""), by: .translation)
        let named = LampPresentationChart(
            source: .init(strongs: "G26", translationID: "", translations: ["T", "U"]), by: .translation
        )
        deck.slides = [
            LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: everyOne)]),
            LampPresentationSlide(layout: .image, blocks: [.init(kind: .chart, chart: named)]),
        ]
        let agent = LampAgentLibrary(library: library, policy: .init(allowedModuleIDs: ["T"]))
        let report = try await agent.workingOutCharts(in: deck)
        #expect(report.deck.slides[0].blocks[0].chart?.values?.map(\.label) == ["T"])
        #expect(report.deck.slides[1].blocks[0].chart == named)
        #expect(report.issues.map(\.message)
            == ["U is not available to agents, so the chart keeps the values it carries."])
    }

    @Test func aFormChartSaysEachFormForARoomWithoutGreek() {
        let values = chart(by: .form).values(from: narrowed(nil))
        #expect(values.map(\.label) == ["ἀγάπη", "ἀγάπης"])
        #expect(values.map(\.detail) == ["agapē · the subject", "agapēs · “of …”"])
        var ring = chart(by: .form)
        ring.style = .share
        #expect(ring.values(from: narrowed(nil)).map(\.detail) == values.map(\.detail))
    }
}
