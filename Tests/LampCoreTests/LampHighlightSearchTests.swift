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
}
