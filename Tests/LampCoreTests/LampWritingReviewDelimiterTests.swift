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

    /// Windows line endings. `"\r\n"` is a single Character in Swift,
    /// so a splitter comparing Characters sees no line break at all
    /// and calls the whole text one line — after which every range is
    /// measured against the wrong line and the span is lost. Found by
    /// a review, diagnosed by printing both sides' line count: the
    /// parser said line 3 and this said line 1.
    @Test func windowsLineEndingsAreLineEndings() {
        let text = "a\r\n\r\nThen **word** here"
        #expect(LampMarkdownModel.lines(of: text).count == 3)
        let model = LampMarkdownModel(parsing: text)
        let strong = model.inlines.first { $0.kind == .strong }
        #expect(
            strong.map { slice($0.range, of: text) } == "**word**",
            "got \(String(describing: strong.map { slice($0.range, of: text) }))"
        )
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

/// The stand-in a lone tilde is hidden behind must have no Markdown
/// meaning anywhere. `+` had one — at a line's start it opens a
/// bullet list — which the iOS session caught.
struct LampMarkdownTildeStandInTests {
    private func slice(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    /// A line beginning `~ ` is a paragraph, as the editor shows it,
    /// not a list.
    @Test func atildeAtALineStartDoesNotOpenAList() {
        let text = "~ approx 3 days"
        let model = LampMarkdownModel(parsing: text)
        #expect(
            !model.blocks.contains { $0.kind == .listItem },
            "the stand-in opened a list: \(model.blocks.map(\.kind))"
        )
        #expect(model.blocks.contains { $0.kind == .paragraph })
    }

    /// And after a container's prefix, where a bullet would also open.
    @Test func atildeAfterAQuoteDoesNotOpenAList() {
        let model = LampMarkdownModel(parsing: "> ~ approx")
        #expect(!model.blocks.contains { $0.kind == .listItem })
    }

    /// The stand-in is ASCII punctuation, so an adjacent emphasis run
    /// pairs exactly as it does with the real tilde.
    @Test func emphasisAroundATildePairsTheSame() {
        let text = "*~a~*"
        let model = LampMarkdownModel(parsing: text)
        let emphasis = model.inlines.first { $0.kind == .emphasis }
        #expect(
            emphasis.map { slice($0.range, of: text) } == "*~a~*",
            "got \(String(describing: emphasis.map { slice($0.range, of: text) }))"
        )
    }

    /// A doubled tilde is still a strikethrough, which is the point of
    /// hiding only lone ones.
    @Test func adoubledTildeIsStillStrikethrough() {
        let text = "a ~~two~~ b"
        let model = LampMarkdownModel(parsing: text)
        #expect(model.inlines.contains { $0.kind == .strikethrough })
    }

    /// And the text itself is never changed by any of this.
    @Test func thetextIsUnchanged() {
        for text in ["~ approx", "a ~b~ c", "~~x~~", "no tildes here"] {
            let model = LampMarkdownModel(parsing: text)
            #expect(model.text == text)
        }
    }
}

/// Where a link's address is, taken from the parser.
struct LampMarkdownLinkReaderTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    /// A marker in an inline link's address comes out before the link
    /// as a point: in the address it is taken into where the link
    /// goes, and the change it marks has nothing to reach.
    @Test func amarkerInAnAddressComesOutAsAPoint() {
        let marked = "See [the note](https://x.com/\(s)a\(e)) now."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("(https://x.com/a)"), "\(drawn.debugDescription)")
        #expect(Markdown.unmarked(drawn) == "See [the note](https://x.com/a) now.")
    }

    /// An autolink is a link too.
    @Test func anautolinksAddressIsAnAddress() {
        let marked = "An <https://x.com/\(s)a\(e)> autolink."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("<https://x.com/a>"), "\(drawn.debugDescription)")
    }

    /// **A bare URL is not a link**, so its marks stay where they are.
    ///
    /// The editor page has `linkify` off in its markdown-it, so the
    /// writer sees plain text; cmark-gfm reports no link either.
    /// Moving the markers out cost a highlight and left a point beside
    /// the line, for a link that was never there.
    @Test func abareUrlKeepsItsMarksWhereTheyAre() {
        let marked = "Bare https://x.com/\(s)a\(e) here."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(
            drawn.contains("x.com/\(s)a\(e)"),
            "the mark left a word that is not in a link: \(drawn.debugDescription)"
        )
        #expect(Markdown.unmarked(drawn) == "Bare https://x.com/a here.")
    }

    /// A label may hold a code span and the link is still seen whole.
    @Test func alabelHoldingCodeIsStillALink() {
        let marked = "See [the `curl` note](https://x.com/\(s)a\(e))."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("(https://x.com/a)"), "\(drawn.debugDescription)")
        #expect(drawn.contains("`curl`"))
    }

    /// And a label marked rather than the address keeps its highlight.
    @Test func amarkedLabelKeepsItsHighlight() {
        let marked = "See [the \(s)note\(e)](https://x.com/a)."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("\(s)note\(e)"), "\(drawn.debugDescription)")
    }
}

/// The parser judging where markers may stand.
///
/// A marker is a private-use scalar, which to cmark is an ordinary
/// character like a letter — so it can turn a literal `*` into a
/// delimiter, or split a run so a real one stops pairing. A parse of
/// the unmarked text cannot see either. The marked line is parsed too
/// and the two shapes compared. The design is the iOS session's.
struct LampMarkdownJudgeTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    /// The shape, not the rendering: a run a marker split writes back
    /// the same characters as a real strong once the markers are off,
    /// so only the kinds tell them apart.
    @Test func asplitRunIsNotTheSameAsAStrongOne() {
        let split = "A *\(s)*strong*\(e)* word."
        #expect(!Markdown.readsTheSame(split), "a split run read as unchanged")
        // And the repair is judged sound.
        #expect(Markdown.readsTheSame(Markdown.repairingInlineSyntax(split)))
    }

    /// Markers that change nothing are left exactly where they are.
    @Test func harmlessMarkersAreNotMoved() {
        for line in [
            "A \(s)plain\(e) word.",
            "Some **\(s)bold\(e)** here.",
            "A [\(s)label\(e)](https://x.com/a).",
        ] {
            #expect(Markdown.readsTheSame(line), "\(line.debugDescription)")
            #expect(Markdown.keepingInlineSyntax(line) == line)
        }
    }

    /// An entity is text to the parser, so a marker inside one is a
    /// difference in words rather than in spans — which a comparison
    /// of spans alone would miss.
    @Test func amarkerInsideAnEntityIsSeen() {
        #expect(!Markdown.readsTheSame("a &l\(s)t\(e); b"))
    }

    /// The fallback: where no repair satisfies the judge, the line's
    /// markers become points at its start. That loses where in the
    /// line each passage was; it never loses the reading.
    @Test func thefallbackKeepsTheReading() {
        // A line built to defeat the hand rules: markers inside a
        // fence's info string, where no rule moves them.
        let awkward = "```s\(s)h\(e)\n"
        let kept = Markdown.keepingInlineSyntax(awkward)
        #expect(
            Markdown.unmarked(kept) == Markdown.unmarked(awkward),
            "the words changed: \(kept.debugDescription)"
        )
        #expect(Markdown.readsTheSame(kept) || kept == awkward)
    }

    /// Whatever the judge decides, the words are never changed.
    @Test func thewordsAreNeverChanged() {
        for line in [
            "A *\(s)*strong*\(e)* word.",
            "a &l\(s)t\(e); b",
            "\(s)# Heading\(e)",
            "`co\(s)de\(e)` and *it*",
            "[a](https://x.com/\(s)b\(e))",
        ] {
            let kept = Markdown.keepingInlineSyntax(line)
            #expect(
                Markdown.unmarked(kept) == Markdown.unmarked(line),
                "\(line.debugDescription) became \(kept.debugDescription)"
            )
        }
    }
}
