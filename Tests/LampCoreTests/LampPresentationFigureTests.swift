import Foundation
import Testing
@testable import LampCore

/// A body block's lines drawn as a timeline or a structure, from the words
/// themselves, so anything that does not know the figure shows the list.
struct LampPresentationFigureTests {
    @Test func aTimelineLineDividesAtItsSpacedDashAndNotAtAColon() throws {
        let line = "c. 586 BC \u{2014} Jerusalem falls; John 3:16 is not a date"
        let split = try #require(LampPresentationFigure.timelineSplit(line))
        let characters = Array(line)
        #expect(String(characters[..<split.dateEnd]) == "c. 586 BC")
        #expect(String(characters[split.eventStart...]).hasPrefix("Jerusalem falls"))
        #expect(LampPresentationFigure.timelineSplit("AD 30 - The cross")?.dateEnd == 5)
        #expect(LampPresentationFigure.timelineSplit("John 3:16 says so") == nil)
        // A hyphenated word is not a separator.
        #expect(LampPresentationFigure.timelineSplit("Well-known event") == nil)
    }

    @Test func aSplitKeepsEmphasisOnBothSides() {
        let runs: [LampPresentationTextRun] = [
            .init(text: "AD 3"), .init(text: "0 \u{2014} The cr", mark: .accent), .init(text: "oss"),
        ]
        let (before, after) = LampPresentationTextRun.split(runs, at: 4)
        #expect(before.map(\.text) == ["AD 3"])
        #expect(after.first?.text == "0 \u{2014} The cr")
        #expect(after.first?.mark == .accent)
    }

    @Test func aChiasmLettersItsMirrorAndStepsInToTheCentre() {
        let chiasm = LampPresentationFigure.chiasm
        #expect((0..<5).map { chiasm.letter(at: $0, of: 5) } == ["A", "B", "C", "B\u{2032}", "A\u{2032}"])
        #expect((0..<5).map { chiasm.indent(at: $0, of: 5) } == [0, 1, 2, 1, 0])
        #expect((0..<4).map { chiasm.letter(at: $0, of: 4) } == ["A", "B", "B\u{2032}", "A\u{2032}"])
        let parallel = LampPresentationFigure.parallel
        #expect((0..<4).map { parallel.letter(at: $0, of: 4) } == ["A", "A\u{2032}", "B", "B\u{2032}"])
        #expect((0..<4).map { parallel.indent(at: $0, of: 4) } == [0, 1, 0, 1])
    }

    @Test func aFigureRevealsALineAtATime() {
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(id: "t", kind: .body, text: "1000 BC \u{2014} David\n970 BC \u{2014} Solomon\n930 BC \u{2014} The kingdom divides", figure: .timeline),
        ], reveal: .stepwise)
        #expect(slide.revealPlan.stepCount == 2)
        #expect(slide.revealPlan.revealsItems(of: "t"))
    }

    @Test func aFigureIsDrawnOnlyWhereItsLinesRevealAndItsDashLightsNothing() {
        let block = LampPresentationBlock(id: "t", kind: .body, text: "AD 30 \u{2014} Cross\nAD 33 \u{2014} Pentecost", figure: .timeline)
        #expect(block.drawnFigure(on: .titleAndBody) == .timeline)
        #expect(block.drawnFigure(on: .twoColumn) == .none)
        let columns = LampPresentationSlide(layout: .twoColumn, blocks: [block, .init(kind: .body, text: "Other")])
        #expect(LampPresentationDeckValidator.validate(LampPresentationDeck(title: "D", slides: [columns]))
            .contains { $0.path == "slides[0].blocks[0].figure" })
        var dash = block
        dash.emphasis = [.init(text: "\u{2014}")]
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [dash], revealsEmphasis: true)
        #expect(!slide.revealPlan.emphasisStep)
    }

    @Test func aFigureIsCheckedAndAnUnknownOneIsText() throws {
        let undated = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .body, text: "1000 BC \u{2014} David\nSolomon", figure: .timeline),
            .init(kind: .body, text: "A\nB", figure: .chiasm),
            .init(kind: .title, text: "T", figure: .parallel),
        ])
        let issues = LampPresentationDeckValidator.validate(LampPresentationDeck(title: "D", slides: [undated]))
        #expect(issues.contains { $0.path == "slides[0].blocks[0].figure" && $0.message.contains("line 2") })
        #expect(issues.contains { $0.path == "slides[0].blocks[1].figure" })
        #expect(issues.contains { $0.path == "slides[0].blocks[2].figure" })
        let json = #"{"id":"b","kind":"body","text":"x","figure":"spiral"}"#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(block.drawnFigure == .none)
    }
}
