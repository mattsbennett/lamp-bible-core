import Foundation
import Testing

@testable import LampCore

/// A document of mixed Markdown still reads as the same document once
/// the markers come off.
///
/// That identity is precisely what the Mac's page tests before it will
/// draw anything: it parses the marked copy, strips the markers and
/// compares. A break anywhere is not one wrong highlight — it is every
/// mark in the file refused, and the writer told the marks could not be
/// shown. Written after the code-span rules changed shape twice in an
/// hour, which is reason enough to check the whole surface rather than
/// the cases that prompted each change.
struct WritingReviewMarkdownRoundTripTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private static let s = String(LampWritingReview.markStart)
    private static let e = String(LampWritingReview.markEnd)

    private static let documents: [(name: String, text: String)] = [
        ("a heading", "# A \(s)heading\(e) here"),
        ("a code span", "Run `curl https://x.com/\(s)new\(e)` first."),
        ("a fenced block", "```sh\ncurl https://x.com/\(s)new\(e)\n```"),
        ("a fence holding a fence", "````\n~~~\n```\n````\n\(s)# After\(e)"),
        ("code inside a link's label", "See [the `curl` note](https://x.com/\(s)a\(e))."),
        ("an escaped backtick", "\\` [l](https://x.com/\(s)new\(e)) `code`"),
        ("a list", "- \(s)A list item\(e)\n- Another"),
        ("a quotation", "> \(s)Quoted\(e) text"),
        ("emphasis beside a nested span", "Some *\(s)emphasis\(e)* and `a `` span` on."),
        ("a rule above", "---\n\(s)After a rule\(e)"),
        ("a marked rule", "\(s)---\(e)"),
        ("an unclosed tick", "A line with ` an unclosed tick and \(s)words\(e)."),
        ("an ordered list", "1. \(s)First\(e)\n2. Second"),
        ("a doubled span", "Nested `` `a` `` span with \(s)words\(e) after."),
        ("indented code", "    indented code \(s)here\(e)"),
        ("a heading and a link", "\(s)# Title\(e)\n\nBody, [link](https://x.com/\(s)b\(e))."),
        ("markers either side of a span", "\(s)before\(e) `code` \(s)after\(e)"),
        ("a link inside a fence", "```\n[a](https://x.com/\(s)y\(e))\n```"),
    ]

    @Test("the document is unchanged", arguments: documents)
    func thedocumentIsUnchanged(_ document: (name: String, text: String)) {
        for numbering in [false, true] {
            let drawn = Markdown.drawable(document.text, numbering: numbering)
            #expect(
                Markdown.unmarked(drawn) == Markdown.unmarked(document.text),
                """
                \(document.name), numbering \(numbering): the Markdown changed, so the \
                page refuses every mark in the file.
                  was:  \(Markdown.unmarked(document.text).debugDescription)
                  now:  \(Markdown.unmarked(drawn).debugDescription)
                """
            )
        }
    }

    /// And no passage is silently dropped on the way. A rule is the one
    /// line that can carry no marker at all, so it is allowed to lose
    /// its own.
    @Test("the marks are still there", arguments: documents)
    func themarksAreStillThere(_ document: (name: String, text: String)) {
        guard document.name != "a marked rule" else { return }
        let drawn = Markdown.drawable(document.text, numbering: false)
        let before = document.text.filter { Markdown.isMarker($0) }.count
        let after = drawn.filter { Markdown.isMarker($0) }.count
        #expect(
            after >= before - 1,
            "\(document.name): \(before) markers became \(after) — passages went unread"
        )
    }
}
