import Foundation
import Testing
@testable import LampCore

/// The shared block parse, held to what the writer's editor shows.
///
/// Every case here is a divergence found in real writing — by dumping block
/// trees for 138 files through markdown-it with the editor's options and
/// through the apps' own readers — or a way an earlier design of this file
/// changed the writer's words, found by review.
struct LampProseTests {
    private func paragraph(_ source: String, _ options: LampProseOptions = .writing) throws
        -> LampProseText
    {
        guard case .paragraph(let text)? = LampProse.blocks(source, options: options).first else {
            throw TestFailure.noParagraph(source)
        }
        return text
    }

    private enum TestFailure: Error { case noParagraph(String) }

    private func words(_ text: LampProseText) -> [String] { text.lines.map(\.plain) }

    // MARK: Lines

    /// A soft-wrapped line is a continuation in a writing: the writer
    /// wrapped it to keep the file readable, not to break the sentence.
    @Test func asoftWrappedLineJoinsInAWriting() throws {
        #expect(try paragraph("made when nobody\nis watching").plain == "made when nobody is watching")
    }

    /// The same text in a note is three lines, because the note editor is
    /// set to show them.
    @Test func anotesTypedLinesAreKept() throws {
        #expect(try words(paragraph("Grace\nMercy\nPeace", .note)) == ["Grace", "Mercy", "Peace"])
    }

    /// A hard break is a line whatever the setting: the writer asked for it.
    @Test func ahardBreakIsALineInEitherSetting() throws {
        #expect(try words(paragraph("line one\\\nline two")) == ["line one", "line two"])
        #expect(try words(paragraph("line one  \nline two")) == ["line one", "line two"])
    }

    /// Content that runs past the end of a line.
    ///
    /// Every case here lost or mangled the writer's words in the first
    /// version of this file, which recovered inline Markdown by asking cmark
    /// where each span was in the source. cmark's block positions are
    /// dependable; its inline positions are not. Found by Codex.
    @Test func contentThatRunsPastALineIsKeptWhole() throws {
        guard case .quote(let inner)? = LampProse.blocks("> one\ntwo").first,
              case .paragraph(let lazy)? = inner.first
        else { return #expect(Bool(false), "no quote") }
        #expect(lazy.plain == "one two")
        #expect(try paragraph("one\n  two").plain == "one two")
        #expect(try words(paragraph("a\\\n**bold**")) == ["a", "bold"])
        #expect(try paragraph("~~one\ntwo~~").plain == "one two")
    }

    /// A table's header cell is reported at the paragraph above it, which
    /// emptied the header when cells were read by position.
    @Test func atablesHeaderSurvivesAParagraphAboveIt() {
        guard case .table(let headers, let rows)? = LampProse.blocks(
            "intro\n| A | B |\n| --- | --- |\n| x | y |"
        ).last else { return #expect(Bool(false), "no table") }
        #expect(headers.map(\.plain) == ["A", "B"])
        #expect(rows.map { $0.map(\.plain) } == [["x", "y"]])
    }

    // MARK: What the words come out as

    /// The writer's words, drawn as the editor draws them.
    ///
    /// Each of these changed under an earlier design that handed readers a
    /// Markdown string to parse again: an escaped backtick reopened a code
    /// span, `&copy;` was re-encoded, a code span lost its own backticks,
    /// and two spans side by side ran their delimiters together into
    /// `**a****b**`, which drew four literal stars.
    @Test func thewordsAreTheWritersWords() throws {
        #expect(try paragraph("An escaped backtick, \\`, stays.").plain
            == "An escaped backtick, `, stays.")
        #expect(try paragraph("about ~ three days").plain == "about ~ three days")
        #expect(try paragraph("a_b_c and 2 * 3 * 4").plain == "a_b_c and 2 * 3 * 4")
        #expect(try paragraph("the note's text -- and more").plain
            == "the note's text -- and more")
        #expect(try paragraph("**a**__b__").plain == "ab")
        #expect(try paragraph("a `` `x` `` b").plain == "a `x` b")
        #expect(try paragraph("[x](/u 'say \"yes\"')").plain == "x")
    }

    /// Emphasis arrives as Foundation's own attributes, which is what all
    /// three readers already walk the runs for.
    @Test func emphasisArrivesAsAttributes() throws {
        let text = try paragraph("plain **bold** and *italic* and `code`").text
        var found: [String: InlinePresentationIntent] = [:]
        for run in text.runs {
            found[String(text[run.range].characters)] = run.inlinePresentationIntent ?? []
        }
        #expect(found["bold"] == .stronglyEmphasized)
        #expect(found["italic"] == .emphasized)
        #expect(found["code"] == .code)
    }

    /// Both of `**a**__b__` are bold, where spelling them back ran their
    /// delimiters together and drew stars.
    @Test func twoSpansSideBySideAreBothEmphasised() throws {
        let text = try paragraph("**a**__b__").text
        for run in text.runs {
            #expect(run.inlinePresentationIntent == .stronglyEmphasized)
        }
    }

    /// A span broken by a line keeps its emphasis on both lines, which a
    /// reader splitting Markdown by hand cannot manage.
    @Test func emphasisCarriesAcrossABreak() throws {
        let lines = try paragraph("**one\ntwo**", .note).lines
        #expect(lines.map(\.plain) == ["one", "two"])
        for line in lines {
            for run in line.text.runs {
                #expect(run.inlinePresentationIntent == .stronglyEmphasized)
            }
        }
    }

    /// A link's address rides on its words.
    @Test func alinksAddressRidesOnItsWords() throws {
        let text = try paragraph("see [the place](lampbible://verse/40024036) here").text
        let linked = text.runs.first { $0.link != nil }
        #expect(linked.map { String(text[$0.range].characters) } == "the place")
        #expect(linked?.link?.absoluteString == "lampbible://verse/40024036")
    }

    /// A picture is one run carrying its address, as Foundation gives it.
    ///
    /// Walking the picture's own words instead lost a picture with no
    /// caption entirely, and gave a captioned one a run per span — and the
    /// phone's reader draws a picture for every run that carries an address,
    /// so it drew it several times.
    @Test func apictureIsOneRunCarryingItsAddress() throws {
        let text = try paragraph("x ![](media/p) y").text
        let carrying = text.runs.filter { $0.imageURL != nil }
        #expect(carrying.count == 1)
        #expect(carrying.first?.imageURL?.absoluteString == "media/p")
        #expect(try paragraph("x ![**bold** words](media/p) y").text.runs
            .filter { $0.imageURL != nil }.count == 1)
    }

    /// A blank line the writer left between two breaks is a line.
    @Test func ablankLineBetweenBreaksIsKept() throws {
        #expect(try words(paragraph("a<br><br>b")) == ["a", "", "b"])
    }

    /// Any spelling of a break tag is a break, as it is to the editor.
    @Test func anyspellingOfABreakTagIsABreak() throws {
        #expect(try words(paragraph("a<br   />b")) == ["a", "b"])
        #expect(try words(paragraph("a<br class=\"x\">b")) == ["a", "b"])
    }

    /// A link written `[x][r]` resolves even when its definition sits past a
    /// footnote, which splits the text into separate documents.
    @Test func areferenceResolvesAcrossAFootnote() {
        let blocks = LampProse.blocks("[x][r]\n\n[^n]: note\n\n[r]: /url")
        guard case .paragraph(let text)? = blocks.first
        else { return #expect(Bool(false), "no paragraph") }
        #expect(text.plain == "x")
        #expect(text.text.runs.first?.link?.absoluteString == "/url")
    }

    /// A paragraph whose whole content is a space set in code is still a
    /// paragraph: trimming its words away deleted it.
    @Test func aparagraphOfOnlyACodeSpanSurvives() {
        guard case .paragraph(let text)? = LampProse.blocks("`  `").first
        else { return #expect(Bool(false), "the paragraph was dropped") }
        #expect(!text.isEmpty)
    }

    // MARK: Lists

    /// A wrapped item is still one item. Read as prose, the wrapped half
    /// ended the list and the next marker opened another, so a three-item
    /// outline came back as three lists.
    @Test func awrappedItemIsOneItem() {
        guard case .list(_, _, let items)? = LampProse.blocks(
            "1. **Changed wording:** substitution,\n   addition.\n2. **Changed application:** a redirection\n   of speaker."
        ).first else { return #expect(Bool(false), "no list") }
        #expect(items.count == 2)
        guard case .paragraph(let first)? = items.first?.blocks.first
        else { return #expect(Bool(false), "no paragraph") }
        #expect(first.plain == "Changed wording: substitution, addition.")
    }

    /// A list that begins at 3 begins at 3.
    @Test func alistKeepsTheNumberItStartsAt() {
        guard case .list(let ordered, let start, _)? = LampProse.blocks("3. third\n4. fourth").first
        else { return #expect(Bool(false), "no list") }
        #expect(ordered)
        #expect(start == 3)
    }

    /// Nesting is the tree's, not a count of spaces: both apps divided the
    /// indent by two, so the editor's four-space level drew two steps in.
    @Test func nestingIsTheTreesOwn() {
        guard case .list(_, _, let items)? = LampProse.blocks("- outer\n    - inner").first
        else { return #expect(Bool(false), "no list") }
        #expect(items.count == 1)
        #expect(items.first?.blocks.contains { if case .list = $0 { return true } else { return false } } == true)
    }

    /// A ticked task is a ticked task.
    @Test func atasksTickIsKept() {
        guard case .list(_, _, let items)? = LampProse.blocks("- [x] done\n- [ ] not").first
        else { return #expect(Bool(false), "no list") }
        #expect(items.map(\.checked) == [true, false])
    }

    // MARK: Quotes, code, and the editor's own blocks

    /// Two lines that both open with `>` keep their break; a line
    /// continuing a quote without its own `>` does not.
    @Test func aquotesBreaksAreTheEditorsBreaks() {
        guard case .quote(let stanza)? = LampProse.blocks(
            "> She gave what she had,\n> and it was everything."
        ).first, case .paragraph(let text)? = stanza.first
        else { return #expect(Bool(false), "no quote") }
        #expect(text.lines.map(\.plain) == ["She gave what she had,", "and it was everything."])
    }

    /// A quoted heading is a heading, and gets no break written into it.
    @Test func aquotedHeadingIsNotGivenABreak() {
        guard case .quote(let inner)? = LampProse.blocks("> # one\n> two").first
        else { return #expect(Bool(false), "no quote") }
        guard case .heading(let level, let text)? = inner.first
        else { return #expect(Bool(false), "no heading") }
        #expect(level == 1)
        #expect(text.plain == "one")
    }

    @Test func afenceKeepsItsOwnWhitespaceAndItsLanguage() {
        #expect(
            LampProse.blocks("```swift\nlet readiness = watch(for: day)\n```")
                == [.code(language: "swift", code: "let readiness = watch(for: day)")]
        )
        #expect(
            LampProse.blocks("```\n# not a heading\n- not a bullet\n```")
                == [.code(language: nil, code: "# not a heading\n- not a bullet")]
        )
        // A fence's own tilde is the writer's.
        #expect(LampProse.blocks("```\na ~ b\n```") == [.code(language: nil, code: "a ~ b")])
    }

    /// A run of three backticks inside a four-backtick fence does not end it.
    @Test func ashorterRunDoesNotCloseALongerFence() {
        #expect(
            LampProse.blocks("````\n```\ninner\n```\n````")
                == [.code(language: nil, code: "```\ninner\n```")]
        )
    }

    /// The editor's own blocks, which no Markdown parser reads. Each was
    /// found by the iOS session, whose line-by-line reader met them one at a
    /// time over three rounds of review.
    @Test func theEditorsOwnBlocksAreReadAsTheEditorReadsThem() {
        let blocks = LampProse.blocks("Body text.\n\n[^1]: The note.\nBody after.")
        #expect(blocks.count == 3)
        guard case .footnote(let label, let inner) = blocks[1]
        else { return #expect(Bool(false), "no footnote") }
        #expect(label == "1")
        guard case .paragraph(let note)? = inner.first
        else { return #expect(Bool(false), "no note text") }
        #expect(note.plain == "The note.")
        guard case .paragraph(let after) = blocks[2]
        else { return #expect(Bool(false), "no body after") }
        #expect(after.plain == "Body after.")

        #expect(
            LampProse.blocks("[Reading](media/abc123)")
                == [.audio(caption: "Reading", path: "media/abc123")]
        )
        #expect(
            LampProse.blocks("![A view](media/pic1)")
                == [.picture(caption: "A view", path: "media/pic1")]
        )
    }

    /// `<br>` is a break, not characters to print.
    @Test func abreakTagIsABreak() throws {
        #expect(try words(paragraph("line<br>next")) == ["line", "next"])
    }

    /// The editor runs with html on and draws a block of HTML. Dropped, the
    /// writer's words went missing with nobody deciding they should.
    @Test func ablockOfHtmlIsKept() {
        #expect(LampProse.blocks("<p>Visible text</p>") == [.html("<p>Visible text</p>")])
    }

    @Test func arulesAndHeadingsAreRead() {
        let blocks = LampProse.blocks("# The Days of Noah\n\n---")
        guard case .heading(let level, let text)? = blocks.first
        else { return #expect(Bool(false), "no heading") }
        #expect(level == 1)
        #expect(text.plain == "The Days of Noah")
        #expect(blocks.last == .rule)
    }

    /// A heading written over two lines is one line of words.
    @Test func asetextHeadingKeepsItsSpace() {
        guard case .heading(_, let text)? = LampProse.blocks("one\ntwo\n===").first
        else { return #expect(Bool(false), "no heading") }
        #expect(text.plain == "one two")
    }

    /// `@name **word**` is a paragraph, as the editor draws it, not a DocC
    /// directive that swallows its content.
    @Test func anatSignOpensNothing() throws {
        #expect(try paragraph("@someone **word**").plain == "@someone word")
    }
}
