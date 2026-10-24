import CoreGraphics
import Foundation
import Testing
@testable import LampCore

/// Words a deck emphasises are named, not counted by position, and drawn bold
/// in the accent or a named highlight, while the stored text stays the words
/// alone.
struct LampPresentationEmphasisTests {
    private typealias Run = LampPresentationTextRun

    private let theme = LampPresentationTheme(
        id: "lamp-dark",
        backgroundColor: "#111827",
        foregroundColor: "#F9FAFB",
        accentColor: "#F59E0B",
        highlights: ["grace": "#60A5FA", "law": "#F87171"]
    )

    private func block(
        _ kind: LampPresentationBlockKind = .body,
        _ text: String,
        _ emphasis: [LampPresentationEmphasis],
        listStyle: LampPresentationListStyle? = nil
    ) -> LampPresentationBlock {
        .init(kind: kind, text: text, listStyle: listStyle, emphasis: emphasis)
    }

    private func warnings(
        _ block: LampPresentationBlock,
        layout: LampPresentationSlideLayout = .titleAndBody,
        theme: LampPresentationTheme? = nil
    ) -> [String] {
        let deck = LampPresentationDeck(
            title: "Deck",
            theme: theme ?? self.theme,
            slides: [.init(layout: layout, blocks: [.init(kind: .title, text: "Heading"), block])]
        )
        return LampPresentationDeckValidator.validate(deck)
            .filter { $0.path.contains("emphasis") }
            .map(\.path)
    }

    // MARK: What is drawn

    @Test("A key detail takes the accent, and a named one its highlight")
    func marksFollowTheEntry() {
        let runs = block(.body, "Grace and law met on the third day.", [
            .init(text: "third day"),
            .init(text: "law", highlight: "law"),
        ]).drawnRuns(on: .titleAndBody)
        #expect(runs == [
            Run(text: "Grace and "),
            Run(text: "law", mark: .highlight("law")),
            Run(text: " met on the "),
            Run(text: "third day", mark: .accent),
            Run(text: "."),
        ])
    }

    @Test("Words match whole, so a word inside another is left alone")
    func wholeWordsOnly() {
        let runs = block(.body, "The lawless and the law.", [.init(text: "law")])
            .drawnRuns(on: .titleAndBody)
        #expect(runs == [Run(text: "The lawless and the "), Run(text: "law", mark: .accent), Run(text: ".")])

        // Punctuation at the edge is not a word, so a possessive still matches.
        let possessive = block(.body, "Cain's offering", [.init(text: "Cain")])
            .drawnRuns(on: .titleAndBody)
        #expect(possessive.first == Run(text: "Cain", mark: .accent))
    }

    @Test("Every appearance is emphasised unless an occurrence, counted from 1, names one")
    func occurrences() {
        let text = "Holy, holy, holy is the LORD"
        let every = block(.body, text, [.init(text: "holy")]).drawnRuns(on: .titleAndBody)
        #expect(every.filter { $0.mark != nil }.map(\.text) == ["holy", "holy"])

        let second = block(.body, text, [.init(text: "holy", occurrence: 2)]).drawnRuns(on: .titleAndBody)
        #expect(second == [
            Run(text: "Holy, holy, "),
            Run(text: "holy", mark: .accent),
            Run(text: " is the LORD"),
        ])

        for missing in [0, 3] {
            let none = block(.body, text, [.init(text: "holy", occurrence: missing)])
            #expect(none.drawnRuns(on: .titleAndBody) == [Run(text: text)])
        }
    }

    @Test("Matching is case-sensitive")
    func caseSensitive() {
        let runs = block(.body, "Holy, holy", [.init(text: "Holy")]).drawnRuns(on: .titleAndBody)
        #expect(runs == [Run(text: "Holy", mark: .accent), Run(text: ", holy")])
    }

    @Test("Composed and decomposed accents are the same letter")
    func canonicalEquivalence() {
        let decomposed = "the cafe\u{0301} door"
        let runs = block(.body, decomposed, [.init(text: "caf\u{00E9}")]).drawnRuns(on: .titleAndBody)
        #expect(runs.filter { $0.mark != nil }.count == 1)

        // A combining mark belongs to the letter before it, so a word that
        // goes on past it is not matched in part.
        let longer = block(.body, "grace\u{0301}d", [.init(text: "grace")]).drawnRuns(on: .titleAndBody)
        #expect(longer.allSatisfy { $0.mark == nil })

        // Pointed Hebrew: the points travel with their letters.
        let pointed = "\u{05D1}\u{05B0}\u{05BC}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05B4}\u{05C1}\u{05D9}\u{05EA}"
        let hebrew = block(.body, pointed + " \u{05D1}\u{05B8}\u{05BC}\u{05E8}\u{05B8}\u{05D0}", [
            .init(text: pointed),
        ]).drawnRuns(on: .titleAndBody)
        #expect(hebrew.first == Run(text: pointed, mark: .accent))
    }

    @Test("A match overlapping words already emphasised is not drawn")
    func earlierEntryWins() {
        let runs = block(.body, "the grace of God", [
            .init(text: "grace of God", highlight: "grace"),
            .init(text: "God", highlight: "law"),
        ]).drawnRuns(on: .titleAndBody)
        #expect(runs == [Run(text: "the "), Run(text: "grace of God", mark: .highlight("grace"))])
    }

    @Test("Quotation marks and ellipses Lamp adds are not emphasised, and typed dots keep theirs")
    func quotationTypography() {
        let runs = block(.scripture, "for by grace you have been saved...", [
            .init(text: "grace"),
            .init(text: "saved..."),
        ]).drawnRuns(on: .scripture)
        #expect(runs == [
            Run(text: "\u{201C}\u{2026}for by "),
            Run(text: "grace", mark: .accent),
            Run(text: " you have been "),
            Run(text: "saved\u{2026}", mark: .accent),
            Run(text: "\u{201D}"),
        ])
        // The stored text is untouched.
        #expect(runs.map(\.text).joined() == LampPresentationQuoteTypography.displayText(
            "for by grace you have been saved..."
        ))
    }

    @Test("A list item keeps its emphasis, one item to a line")
    func listItems() {
        let items = block(.body, "Capacity\n  Attention \n\nRestraint", [.init(text: "Attention")], listStyle: .unordered)
            .listItemRuns
        #expect(items == [
            [Run(text: "Capacity")],
            [Run(text: "Attention", mark: .accent)],
            [Run(text: "Restraint")],
        ])
    }

    @Test("Emphasis survives a round trip, and a block without it reads as before")
    func roundTrip() throws {
        let original = block(.body, "by grace", [.init(text: "grace", highlight: "grace", occurrence: 1)])
        let decoded = try JSONDecoder().decode(
            LampPresentationBlock.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)

        let bare = try JSONDecoder().decode(
            LampPresentationBlock.self,
            from: Data(#"{"id":"a","kind":"body","text":"plain"}"#.utf8)
        )
        #expect(bare.emphasis == nil)
        #expect(bare.drawnRuns(on: .titleAndBody) == [Run(text: "plain")])

        let themed = try JSONDecoder().decode(LampPresentationTheme.self, from: JSONEncoder().encode(theme))
        #expect(themed.highlights == theme.highlights)
    }

    // MARK: What the validator says

    @Test("Emphasis that will draw as written raises nothing")
    func cleanEmphasis() {
        #expect(warnings(block(.body, "Grace and law", [
            .init(text: "Grace", highlight: "grace"),
            .init(text: "law"),
        ])).isEmpty)
    }

    @Test("Every way an entry fails to draw is named at that entry, as a warning")
    func degenerateEntries() {
        let text = "the law and the law"
        #expect(warnings(block(.body, text, [.init(text: "")])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [.init(text: "grace")])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [.init(text: "Law")])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [.init(text: "law", occurrence: 0)])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [.init(text: "law", occurrence: 3)])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [.init(text: "law", highlight: "torah")])) == ["slides[0].blocks[1].emphasis[0]"])
        #expect(warnings(block(.body, text, [
            .init(text: "the law"),
            .init(text: "law", highlight: "law"),
        ])) == ["slides[0].blocks[1].emphasis[1]"])

        let image = LampPresentationBlock(
            kind: .image, assetPath: "Assets/a.jpg", altText: "A picture",
            emphasis: [.init(text: "a")]
        )
        #expect(warnings(image, layout: .image) == ["slides[0].blocks[1].emphasis"])

        // None of these stops a deck from saving: a reworded slide must not
        // make its deck unsavable.
        let deck = LampPresentationDeck(title: "Deck", theme: theme, slides: [
            .init(layout: .titleAndBody, blocks: [block(.body, text, [.init(text: "grace")])]),
        ])
        #expect(LampPresentationDeckValidator.errors(in: deck).isEmpty)
    }

    @Test("A highlight colour must be one, and is held to the accent's contrast")
    func themeHighlights() {
        func issues(_ highlights: [String: String]) -> [LampPresentationDeckIssue] {
            var theme = self.theme
            theme.highlights = highlights
            return LampPresentationDeckValidator.validate(LampPresentationDeck(title: "Deck", theme: theme, slides: [
                .init(layout: .titleAndBody, blocks: [.init(kind: .body, text: "Body")]),
            ]))
            .filter { $0.path.hasPrefix("theme.highlights") }
        }
        #expect(issues(["grace": "#60A5FA"]).isEmpty)
        #expect(issues(["grace": "blue"]).map(\.severity) == [.error])
        #expect(issues(["": "#60A5FA"]).map(\.severity) == [.error])
        // Navy on near-black.
        #expect(issues(["grace": "#1E3A8A"]).map { "\($0.severity):\($0.path)" } == [
            "warning:theme.highlights.grace",
        ])
    }

    // MARK: Over a picture

    @Test("A highlight that would not read over the picture takes the words' colour")
    func highlightsFallBackToTheText() {
        let white = LampPresentationColor(red: 1, green: 1, blue: 1)
        var theme = LampPresentationTheme.lampDark
        theme.highlights = ["dark": "#1E3A8A", "pale": "#FDE68A"]
        let overWhite = LampPresentationBackdrop.uniform(white)
            .treatment(for: [CGRect(x: 0, y: 0, width: 1, height: 1)], theme: theme)
        // Set dark over white: navy still reads, pale yellow does not.
        #expect(overWhite.highlights["dark"] == "#1E3A8A")
        #expect(overWhite.highlights["pale"] == overWhite.text)
    }
}
