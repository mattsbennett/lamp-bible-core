import Foundation
import Testing
@testable import LampCore

/// Cutting a growing text so each piece reads alone as it reads in the whole.
///
/// The cases are the iOS session's, from the phone's reply panel, where they
/// were found over two rounds of review and pinned by
/// `AgentRemoteTests.testAGrowingReplyDrawsOnlyItsEnd`. They are kept here
/// because the rules now live here.
struct LampProsePiecesTests {
    /// What the cutting is for: a reply that has grown by a paragraph is
    /// read only at its end.
    @Test func aplainTextIsCutAtItsBlankLines() {
        #expect(
            LampProse.pieces(of: "One.\n\nTwo.\n\nThree.") == ["One.", "Two.", "Three."]
        )
    }

    /// A list counts on across a blank line, so a cut before an item would
    /// make the piece a list of its own, numbered from 1.
    @Test func alistCountingOnIsNotCut() {
        let text = "1. first\n\n2. second\n\n3. third"
        #expect(LampProse.pieces(of: text) == [text])
        // The whole list reads as one, which is what the cut must not break.
        guard case .list(_, let start, let items)? = LampProse.blocks(text).first else {
            return #expect(Bool(false), "no list")
        }
        #expect(start == 1)
        #expect(items.count == 3)
    }

    /// An indented line may carry on the item above it.
    @Test func anindentedLineIsNotCutFrom() {
        let text = "- item\n\n    carried on"
        #expect(LampProse.pieces(of: text) == [text])
    }

    /// A link's target can be written anywhere and reach back, so a text
    /// holding one is read whole.
    @Test func atextDefiningALinkTargetIsNotCut() {
        for text in [
            "See [it][r].\n\nWords.\n\n[r]: /url",
            "Words.\n\n> [r]: /url\n\nSee [it][r].",
        ] {
            #expect(LampProse.pieces(of: text) == [text], "cut \(text.debugDescription)")
        }
    }

    /// A fence holds its blank lines.
    @Test func afenceIsNotCutThrough() {
        let text = "Before.\n\n```\none\n\ntwo\n```\n\nAfter."
        let pieces = LampProse.pieces(of: text)
        #expect(pieces.count == 3, "cut into \(pieces)")
        #expect(pieces[1] == "```\none\n\ntwo\n```")
    }

    /// A closer four spaces in is code, not a closer, so the fence runs on.
    @Test func acloserTooFarInDoesNotCloseTheFence() {
        let text = "```\none\n\n    ```\n\ntwo"
        #expect(LampProse.pieces(of: text) == [text], "cut \(LampProse.pieces(of: text))")
    }

    /// A preformatted block and a comment both reach past a blank line.
    @Test func preformattedTextAndCommentsAreNotCut() {
        for text in ["<pre>\none\n\ntwo\n</pre>", "<!--\none\n\ntwo\n-->"] {
            #expect(LampProse.pieces(of: text) == [text], "cut \(text.debugDescription)")
        }
    }

    /// The point of it: every piece read alone says what it says in the
    /// whole.
    @Test func everyPieceReadsAloneAsItReadsInTheWhole() {
        let text = """
            # A heading

            A paragraph that wraps
            onto a second line.

            > quoted here,
            > and here

            | A | B |
            | --- | --- |
            | 1 | 2 |

            ```swift
            let x = 1
            ```

            The last word.
            """
        let whole = LampProse.blocks(text)
        let piecemeal = LampProse.pieces(of: text).flatMap { LampProse.blocks($0) }
        #expect(piecemeal == whole, "reading in pieces differs from reading whole")
    }

    /// Nothing to cut is not an empty answer.
    @Test func atextWithNoBreakIsOnePiece() {
        #expect(LampProse.pieces(of: "Just a sentence.") == ["Just a sentence."])
        #expect(LampProse.pieces(of: "").isEmpty)
    }
}
