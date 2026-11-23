import Foundation
import Testing
@testable import LampCore

/// Where a review marker may stand without changing what the text reads as.
///
/// A marker is a letter to a Markdown parser, so one on a fence line stops
/// the fence closing and one outside a table row's pipes becomes a cell. The
/// cases here were found by the iOS session over five rounds of review, on
/// the phone's Files reader, and lifted here when the Mac needed them too.
///
/// None of this has to be complete: a surface reads its file twice, with
/// markers and without, and keeps a piece's markers only where it reads the
/// same either way. What this misses costs a passage its highlight, never
/// its record.
struct LampWritingReviewPlacementTests {
    private let start = String(LampWritingReview.markStart)
    private let end = String(LampWritingReview.markEnd)
    private let point = String(LampWritingReview.markPoint)
    /// Place 0, written after a marker.
    private let place = "\u{E010}\u{E01A}"
    private let place1 = "\u{E011}\u{E01A}"

    private func unmarked(_ text: String) -> String {
        LampWritingReviewMarkdown.unmarked(text)
    }

    // MARK: Ends that know their start

    /// An end carries the place of the start it closes, so two passages that
    /// each lost an edge are not taken for one running between them.
    @Test func anendIsGivenItsStartsPlace() {
        let text = "a\(start)\(place)b\(end)c"
        let placed = LampWritingReviewPlacement.placingEnds(text)
        #expect(placed == "a\(start)\(place)b\(end)\(place)c")
        // The words are untouched.
        #expect(unmarked(placed) == "abc")
    }

    @Test func anendWithNoOpenStartIsLeftAsItIs() {
        let text = "a\(end)b"
        #expect(LampWritingReviewPlacement.placingEnds(text) == text)
    }

    // MARK: Passages the parse kept one edge of

    /// A start whose end the parse lost becomes a point, rather than
    /// highlighting on to the end of the file.
    @Test func astartWithoutItsEndBecomesAPoint() {
        let kept = "one \(start)\(place)two"
        let unpaired = LampWritingReviewPlacement.unpaired(across: [kept])
        #expect(unpaired.lostEnd == [0])
        #expect(unpaired.lostStart.isEmpty)

        var text = kept as NSString
        for edit in LampWritingReviewPlacement.pointingEdits(in: kept, unpaired: unpaired) {
            text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        #expect(text as String == "one \(point)\(place)two")
    }

    /// An end whose start was lost is taken out entirely.
    @Test func anendWithoutItsStartIsTakenOut() {
        let kept = "one \(end)\(place)two"
        let unpaired = LampWritingReviewPlacement.unpaired(across: [kept])
        #expect(unpaired.lostStart == [0])

        var text = kept as NSString
        for edit in LampWritingReviewPlacement.pointingEdits(in: kept, unpaired: unpaired) {
            text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        #expect(text as String == "one two")
    }

    /// A passage whose edges are in two different pieces is whole: every
    /// piece a surface drew has to be looked at together.
    @Test func apassageSpanningTwoPiecesIsNotTouched() {
        let unpaired = LampWritingReviewPlacement.unpaired(
            across: ["opens \(start)\(place)here", "and closes\(end)\(place) there"]
        )
        #expect(unpaired.isEmpty)
    }

    /// Two passages that each lost an edge stay two, because each end knows
    /// its own start's place.
    @Test func twohalfKeptPassagesAreNotTakenForOne() {
        let unpaired = LampWritingReviewPlacement.unpaired(
            across: ["\(start)\(place)one", "two\(end)\(place1)"]
        )
        #expect(unpaired.lostEnd == [0])
        #expect(unpaired.lostStart == [1])
    }

    /// Edits come back latest first, so applying them in order leaves the
    /// earlier ranges still pointing where they did.
    @Test func editsComeBackLatestFirst() {
        let kept = "\(start)\(place)one \(start)\(place1)two"
        let unpaired = LampWritingReviewPlacement.unpaired(across: [kept])
        let edits = LampWritingReviewPlacement.pointingEdits(in: kept, unpaired: unpaired)
        #expect(edits.count == 2)
        #expect(edits[0].range.location > edits[1].range.location)
    }

    // MARK: Markers off what is only syntax

    /// A marker on a fence's own line stops the fence closing, so it is
    /// moved into the code.
    @Test func amarkerOnAFenceLineMovesIntoTheCode() {
        let marked = "\(start)\(place)```\nlet x = 1\n```"
        let settled = LampWritingReviewPlacement.settlingSyntaxLines(marked)
        let lines = settled.components(separatedBy: "\n")
        #expect(unmarked(lines[0]) == "```", "the fence line kept a marker: \(lines[0])")
        #expect(lines[1].contains(where: LampWritingReviewMarkdown.isMarker))
        #expect(unmarked(settled) == unmarked(marked))
    }

    /// A marker outside a table row's pipes would be a cell of its own.
    @Test func amarkerOutsideARowsPipesMovesInside() {
        let marked = "| A | B |\n| --- | --- |\n\(start)\(place)| x | y |"
        let settled = LampWritingReviewPlacement.settlingSyntaxLines(marked)
        let row = settled.components(separatedBy: "\n")[2]
        #expect(row.hasPrefix("|"), "a marker still stands outside the pipes: \(row)")
        #expect(row.contains(where: LampWritingReviewMarkdown.isMarker))
    }

    /// A marker on a table's alignment row moves onto the row after it.
    @Test func amarkerOnTheAlignmentRowMovesOff() {
        let marked = "| A | B |\n\(start)\(place)| --- | --- |\n| x | y |"
        let settled = LampWritingReviewPlacement.settlingSyntaxLines(marked)
        let lines = settled.components(separatedBy: "\n")
        #expect(!lines[1].contains(where: LampWritingReviewMarkdown.isMarker))
        #expect(lines[2].contains(where: LampWritingReviewMarkdown.isMarker))
    }

    /// A footnote's label has to read as its label.
    @Test func amarkerBeforeAFootnotesLabelMovesPastIt() {
        let marked = "\(start)\(place)[^1]: the note"
        let settled = LampWritingReviewPlacement.settlingSyntaxLines(marked)
        #expect(settled.hasPrefix("[^1]:"), "the label did not survive: \(settled)")
        #expect(unmarked(settled) == "[^1]: the note")
    }

    /// A blank line stays blank: its markers move to the next line with
    /// words.
    @Test func amarkerOnABlankLineMovesToWords() {
        let marked = "one\n\(start)\(place)\ntwo"
        let settled = LampWritingReviewPlacement.settlingSyntaxLines(marked)
        let lines = settled.components(separatedBy: "\n")
        #expect(!lines[1].contains(where: LampWritingReviewMarkdown.isMarker))
        #expect(lines[2].contains(where: LampWritingReviewMarkdown.isMarker))
    }

    /// Settling never changes the writer's words, whatever it moves.
    @Test func settlingNeverChangesTheWords() {
        for marked in [
            "\(start)\(place)```\ncode\n```",
            "| A |\n\(start)\(place)| --- |\n| x |",
            "one\n\(start)\(place)\ntwo",
            "\(start)\(place)[^1]: a note",
            "plain \(start)\(place)words\(end)\(place) here",
        ] {
            #expect(
                unmarked(LampWritingReviewPlacement.settlingSyntaxLines(marked)) == unmarked(marked),
                "the words changed for \(marked.debugDescription)"
            )
        }
    }

    /// Text with no markers at all is handed back untouched.
    @Test func textWithNoMarkersIsUntouched() {
        let plain = "# A heading\n\nSome words.\n\n```\ncode\n```"
        #expect(LampWritingReviewPlacement.settlingSyntaxLines(plain) == plain)
        #expect(LampWritingReviewPlacement.placingEnds(plain) == plain)
    }
}
