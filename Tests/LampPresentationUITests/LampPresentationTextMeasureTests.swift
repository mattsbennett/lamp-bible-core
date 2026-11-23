import Testing
@testable import LampCore
@testable import LampPresentationUI

/// Measuring text as the canvas draws it, for figures that reserve room
/// before they are laid out.
struct LampPresentationTextMeasureTests {
    @Test func chineseBreaksBetweenCharactersAndEnglishBetweenWords() {
        #expect(LampPresentationTextMeasure.longestUnbreakable("David king in Jerusalem") == 9)
        #expect(LampPresentationTextMeasure.longestUnbreakable(String(repeating: "大衛在耶路撒冷作王", count: 10)) == 1)
        #expect(LampPresentationTextMeasure.longestUnbreakable("") == 0)
    }

    @Test func emphasisAndTheSmallestSizeAreMeasuredAsDrawn() {
        let plain = LampPresentationTextMeasure.size("Jerusalem falls", family: nil, size: 30, bold: false)
        let marked = LampPresentationTextMeasure.size(
            [.init(text: "Jerusalem falls", mark: .accent)], family: nil, size: 30, bold: false
        )
        #expect(marked.width > plain.width)
        // The canvas draws nothing under ten points on a slide.
        let tiny = LampPresentationTextMeasure.size("722 BC", family: nil, size: 4, bold: true)
        let floor = LampPresentationTextMeasure.size("722 BC", family: nil, size: 10, bold: true)
        #expect(tiny == floor)
        let serif = LampPresentationTextMeasure.size("Jerusalem falls", family: "system-serif", size: 30, bold: false)
        #expect(serif.width != plain.width)
    }
}
