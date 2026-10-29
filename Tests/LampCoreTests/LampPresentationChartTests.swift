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
            == "Chart of G26 in T: Gospels 0, fewer than expected; Paul’s Letters 10, more than expected")
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

        // Eleven renderings: the largest and the next six alphabetically keep
        // their slices, and the last four are gathered into one.
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
        #expect(slices.last == .init(label: "Others", value: 4))
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
}
