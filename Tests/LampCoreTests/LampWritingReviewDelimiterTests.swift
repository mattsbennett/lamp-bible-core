import Foundation
import Testing

@testable import LampCore

/// The six cases that defeated six hand-written versions of the
/// emphasis reach, now put to the parser.
///
/// Each was found by the iOS session's codex, one round at a time, and
/// each fix of mine was one case narrower than the problem. They are
/// kept together here because what they test is not six behaviours but
/// one: that what counts as emphasis is decided by the same rules the
/// writer's editor uses, rather than by a pattern that happens to
/// cover the cases we thought of.
struct LampWritingReviewDelimiterTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private func slice(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    /// What it is all for: a clear of the bolded words reaches the
    /// marks sitting on the `**`.
    @Test func anenclosingEmphasisIsTakenIn() {
        let text = "Her **red dog** barked."
        let words = (text as NSString).range(of: "red dog")
        #expect(slice(Markdown.takingInDelimiters(words, of: text), of: text) == "**red dog**")
    }

    /// 1. A run that merely matches is not a pair. Selecting the words
    /// before a bolded one must take nothing in.
    @Test func arunTouchedFromOutsideIsLeftAlone() {
        let text = "intro **word** after"
        let intro = NSRange(location: 0, length: 6)
        #expect(slice(intro, of: text) == "intro ")
        #expect(Markdown.takingInDelimiters(intro, of: text) == intro)
    }

    /// 2. Two emphases on a line: clearing between them must not pair
    /// the first's closer with the second's opener.
    @Test func thewordsBetweenTwoEmphasesTakeNothingIn() {
        let text = "**one** middle **two**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// 3. Stars inside a code span are letters.
    @Test func starsInsideACodeSpanAreNotDelimiters() {
        let text = "`**` middle **word**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// 4. An escaped star is a star.
    @Test func anescapedDelimiterIsNotADelimiter() {
        let text = "\\** middle **word**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// 5. A list bullet is not an opener.
    @Test func alistBulletIsNotAnOpener() {
        let text = "* intro *word* end"
        let intro = (text as NSString).range(of: "intro ")
        #expect(Markdown.takingInDelimiters(intro, of: text) == intro)
    }

    /// 6. Nesting: clearing part of an outer emphasis must take
    /// nothing in. Widened to the outer pair it would sweep the inner
    /// one's delimiters, which belong to text the writer never
    /// selected.
    @Test func anestedEmphasisIsNotSweptUp() {
        let text = "**one *two* three** end"
        let tail = (text as NSString).range(of: " three")
        #expect(Markdown.takingInDelimiters(tail, of: text) == tail)
    }

    /// And the inner emphasis still takes in its own pair when it is
    /// the thing being cleared.
    @Test func theinnerEmphasisTakesInItsOwnPair() {
        let text = "**one *two* three** end"
        let two = (text as NSString).range(of: "two")
        #expect(slice(Markdown.takingInDelimiters(two, of: text), of: text) == "*two*")
    }

    /// A selection inside a span takes nothing in, for the same
    /// reason: it would clear marks on the rest of the span.
    @Test func partOfABoldedPhraseTakesNothingIn() {
        let text = "Her **red dog** barked."
        let red = (text as NSString).range(of: "red")
        #expect(Markdown.takingInDelimiters(red, of: text) == red)
    }

    /// A caret is left where it is: widened, Mark Selection as
    /// Reviewed becomes a partial clear of the delimiters instead of a
    /// clear of the whole mark under the caret.
    @Test func acaretIsLeftExactlyWhereItIs() {
        let text = "Her **red dog** barked."
        for at in [6, 13] {
            let caret = NSRange(location: at, length: 0)
            #expect(Markdown.takingInDelimiters(caret, of: text) == caret)
        }
    }

    /// A single tilde is literal here, because the editor's own parser
    /// reads it that way and core must not see formatting the writer
    /// does not.
    @Test func asingleTildeIsNotStrikethrough() {
        let text = "a ~one~ b"
        let one = (text as NSString).range(of: "one")
        #expect(Markdown.takingInDelimiters(one, of: text) == one)
        let doubled = "a ~~two~~ b"
        let two = (doubled as NSString).range(of: "two")
        #expect(slice(Markdown.takingInDelimiters(two, of: doubled), of: doubled) == "~~two~~")
    }

    /// A link's own brackets are not emphasis delimiters, and a clear
    /// inside its label must not swallow its address.
    @Test func alinkIsNotTakenIn() {
        let text = "See [the note](https://x.com/a) now."
        let note = (text as NSString).range(of: "the note")
        #expect(Markdown.takingInDelimiters(note, of: text) == note)
    }

    /// And the combined form still reaches block syntax from a caret.
    @Test func thecombinedFormStillReachesBlockSyntax() {
        let text = "# **Title** here"
        let caret = NSRange(location: 2, length: 0)
        #expect(
            Markdown.takingInSyntaxAndDelimiters(caret, of: text)
                == NSRange(location: 0, length: 2)
        )
    }
}

/// The four faults a review of the parser work found, each of which
/// the six hand-written versions had never reached — they are faults
/// of trusting a parser, not of pattern-matching.
struct LampMarkdownModelReviewTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private func slice(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    /// The reach must never answer with less than it was asked for.
    /// Given the whole of a line holding two emphases it returned the
    /// first span alone, turning a complete clear into a partial one
    /// and leaving the rest of the selection unread.
    @Test func thereachNeverReturnsLessThanItWasGiven() {
        for text in [
            "**one** middle **two**",
            "Her **red dog** barked.",
            "plain words only",
            "**one *two* three** end",
        ] {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            let reached = Markdown.takingInDelimiters(whole, of: text)
            #expect(
                reached.location <= whole.location && NSMaxRange(reached) >= NSMaxRange(whole),
                "\(text.debugDescription) shrank to \(slice(reached, of: text).debugDescription)"
            )
        }
    }

    /// A span sharing its opening run with its parent is not taken in.
    /// cmark hands the inner strong node all three stars of
    /// `***one** two*`, one of which opens the outer emphasis and
    /// covers the unselected ` two`.
    @Test func asharedDelimiterRunIsNotTakenIn() {
        let text = "***one** two*"
        let one = (text as NSString).range(of: "one")
        let reached = Markdown.takingInDelimiters(one, of: text)
        #expect(
            !slice(reached, of: text).contains("two"),
            "reached \(slice(reached, of: text).debugDescription) into unselected text"
        )
    }

    /// The reach stays on its own line.
    @Test func thereachDoesNotCrossALine() {
        let text = "**one\ntwo**"
        let first = (text as NSString).range(of: "one")
        let reached = Markdown.takingInDelimiters(first, of: text)
        #expect(!slice(reached, of: text).contains("\n"), "\(slice(reached, of: text))")
    }

    /// Carriage returns: cmark ends a line at a bare `\r` as well as
    /// at `\n`, so splitting on `\n` alone counted lines differently
    /// from the parser and dropped every span after one.
    @Test func carriageReturnsCountAsLineEndings() {
        for text in ["x\r**word**", "a\r\rThen **word** here"] {
            let model = LampMarkdownModel(parsing: text)
            let strong = model.inlines.first { $0.kind == .strong }
            #expect(
                strong.map { slice($0.range, of: text) } == "**word**",
                "\(text.debugDescription) gave \(String(describing: strong))"
            )
        }
    }

    /// **Not yet right, and deliberately pinned as it stands.**
    ///
    /// A `\r\n` followed by a blank `\r\n` still loses the span: the
    /// line map agrees with the parser on how many lines there are and
    /// where each begins, so the cause is elsewhere and I have not
    /// found it. The guard on a span whose content falls outside it
    /// turns the disagreement into a dropped span rather than a wrong
    /// range, so the reach simply does not fire — the behaviour before
    /// any of this existed, and safe. This records the gap so the next
    /// reader meets it as a known limit rather than a surprise.
    @Test func acrlfBlankLineStillLosesTheSpan() {
        let text = "a\r\n\r\nThen **word** here"
        let model = LampMarkdownModel(parsing: text)
        #expect(
            model.inlines.first(where: { $0.kind == .strong }) == nil,
            "if this now finds the span, the limit is fixed — assert the range instead"
        )
        // And the reach is a no-op there, which is the point: nothing
        // wrong happens, only nothing helpful.
        let word = (text as NSString).range(of: "word")
        #expect(Markdown.takingInDelimiters(word, of: text) == word)
    }

    /// A grapheme of several scalars — a letter and a combining mark —
    /// is mapped scalar by scalar, since a column can fall between
    /// them.
    @Test func acombiningMarkDoesNotMoveALaterRange() {
        let text = "e\u{0301}cole **word** here"
        let model = LampMarkdownModel(parsing: text)
        let strong = model.inlines.first { $0.kind == .strong }
        #expect(strong.map { slice($0.range, of: text) } == "**word**")
    }
}
