import Testing
@testable import LampCore

struct LampHighlightSearchTests {
    @Test func usesYellowDefaultAndPreservesSelectedText() {
        #expect(LampHighlightSearch.matchesColor(nil, in: ["#FFCC00"]))
        #expect(!LampHighlightSearch.matchesColor("00FF00", in: ["FFCC00"]))
        #expect(LampHighlightSearch.markedSnippet(
            text: "the light shines", startOffset: 4, endOffset: 9
        ) == "<mark>light</mark>")
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
