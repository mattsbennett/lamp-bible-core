import Testing
@testable import LampCore

struct LampHighlightSearchTests {
    @Test func usesYellowDefaultAndPreservesSelectedText() {
        #expect(LampHighlightSearch.matchesColor(nil, in: ["#FFCC00"]))
        #expect(!LampHighlightSearch.matchesColor("00FF00", in: ["FFCC00"]))
        #expect(LampHighlightSearch.markedSnippet(
            text: "the light shines", startOffset: 4, endOffset: 9
        ) == "<mark>light</mark>")
        #expect(LampHighlightSearch.markedVerse(
            text: "the light shines", startOffset: 4, endOffset: 9
        ) == "the <mark>light</mark> shines")
        // Late in a long verse: cut to the words around it, at a word.
        let long = String(repeating: "and the word ", count: 20) + "light" + String(repeating: " shines on", count: 20)
        let start = long.count - 5 - 200
        let cut = LampHighlightSearch.markedVerse(text: long, startOffset: start, endOffset: start + 5, context: 20)
        #expect(cut == "…word and the word <mark>light</mark> shines on shines on shines on shines…")
    }

    /// A search's words find the highlight; the highlight's own words are
    /// what is marked, so they are not drawn as the reader's highlight.
    @Test func aHighlightFoundByWordsMarksItsOwnWords() async throws {
        let hits = LampModuleSearch.highlights(
            in: [("set", [LampVerseHighlight(
                id: 1, setID: "set", translationID: "T", reference: 43_003_016, startOffset: 4, endOffset: 7
            )])],
            query: LampSearchQuery("world"), colors: nil, bookRange: nil, limit: 5
        ) { _, _ in [43_003_016: "For God so loved the world"] }
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(LampHighlightSearch.markedVerse(
            text: hit.text, startOffset: hit.highlight.startOffset, endOffset: hit.highlight.endOffset
        ) == "For <mark>God</mark> so loved the world")
    }

    @Test func coloursAndStylesNarrowTogetherAndAThemeIsFoundBesides() {
        func found(
            _ color: String?, _ style: LampHighlightStyle,
            colors: Set<String>? = nil, styles: Set<LampHighlightStyle>? = nil, themes: Set<LampHighlightMark>? = nil
        ) -> Bool {
            LampHighlightSearch.matches(color: color, style: style, colors: colors, styles: styles, themes: themes)
        }
        #expect(found("34C759", .underlineDotted), "nothing chosen asks for every highlight")
        #expect(found("34C759", .underlineDotted, colors: [], styles: [], themes: []))
        #expect(found("#34c759", .underlineDotted, colors: ["34C759"], styles: [.underlineDotted]))
        #expect(!found("34C759", .highlight, colors: ["34C759"], styles: [.underlineDotted]))
        #expect(found("34C759", .highlight, colors: ["34C759"]))
        #expect(found("FFCC00", .underlineDashed, styles: [.underlineDashed]))
        let theme = LampHighlightMark(color: "#ff3b30", style: .underlineSolid)
        #expect(theme.color == "FF3B30")
        #expect(found("FF3B30", .underlineSolid, themes: [theme]))
        #expect(!found("FF3B30", .highlight, themes: [theme]), "a theme's colour in another style is not the theme")
        #expect(found("FF3B30", .underlineSolid, colors: ["34C759"], themes: [theme]))
        #expect(found("34C759", .highlight, colors: ["34C759"], themes: [theme]))
        #expect(!found("FFCC00", .highlight, colors: ["34C759"], themes: [theme]))
    }
}
