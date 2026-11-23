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

    /// A piece that ends inside an unclosed fence must not swallow the
    /// definitions carried to it.
    ///
    /// They were written after each piece, and an unclosed fence, HTML block
    /// or indented code at its end took them in and drew them as code the
    /// writer never typed. They go in front now, where nothing can precede
    /// them. Found by Codex, reviewing the phone's adoption.
    @Test func anunclosedFenceDoesNotSwallowTheDefinitionsCarriedToIt() {
        let blocks = LampProse.blocks("[guide]: /docs\n\n```\nnever closed")
        let code = blocks.compactMap { block -> String? in
            if case .code(_, let text) = block { return text } else { return nil }
        }
        #expect(code == ["never closed"], "the fence drew \(code)")
        #expect(!blocks.contains { block in
            if case .code(_, let text) = block { return text.contains("/docs") }
            return false
        }, "a definition was drawn as code")
    }

    /// The same, for a piece ending in indented code.
    @Test func indentedCodeDoesNotSwallowThemEither() {
        let blocks = LampProse.blocks("[guide]: /docs\n\nSee [it][guide].\n\n    indented")
        #expect(!blocks.contains { block in
            if case .code(_, let text) = block { return text.contains("/docs") }
            return false
        })
        guard case .paragraph(let text)? = blocks.first(where: {
            if case .paragraph = $0 { return true } else { return false }
        }) else { return #expect(Bool(false), "no paragraph") }
        #expect(text.text.runs.contains { $0.link?.absoluteString == "/docs" })
    }

    /// A line that merely looks like a definition is an ordinary line.
    ///
    /// A destination cannot hold a space unless it is written in angle
    /// brackets, so cmark reads no definition in "[Status]: Ready for
    /// review" — but it was carried to every piece as one, and drawn twice.
    /// Found by Codex, reviewing the phone's adoption.
    @Test func alineThatLooksLikeADefinitionIsStillALine() throws {
        let blocks = LampProse.blocks("[Status]: Ready for review\n\nThe body.")
        let drawn = blocks.compactMap { block -> String? in
            if case .paragraph(let text) = block { return text.plain } else { return nil }
        }
        #expect(drawn == ["[Status]: Ready for review", "The body."], "drew \(drawn)")
    }

    /// A title has to end the line. Taking a title and stopping there read
    /// `[Status]: Ready (see below) tomorrow` as a definition, and the line
    /// was drawn twice. Found by Codex, reviewing the phone's adoption.
    @Test func alineWithWordsAfterATitleIsStillALine() throws {
        for source in [
            "A\n[Status]: Ready (see below) tomorrow",
            "A\n[Status]: Ready \"today\" and tomorrow",
            "A\n[Status]: Ready (unclosed",
        ] {
            let drawn = LampProse.blocks(source).compactMap { block -> String? in
                if case .paragraph(let text) = block { return text.plain } else { return nil }
            }
            #expect(drawn.count == 1, "drew \(drawn) for \(source.debugDescription)")
        }
        // A real one, with a title that does end the line, still works.
        let blocks = LampProse.blocks("[r]: /url \"The Title\"\n\nSee [it][r].")
        guard case .paragraph(let text)? = blocks.first(where: {
            if case .paragraph(let value) = $0 { return value.plain.contains("See") }
            return false
        }) else { return #expect(Bool(false), "no paragraph") }
        #expect(text.text.runs.first { $0.link != nil }?.link?.absoluteString == "/url")
    }

    /// A definition shown as an example in code is not a definition.
    ///
    /// The scan stripped the indentation and gathered it; a label keeps its
    /// first address, so an example above the real one sent the link to the
    /// wrong place.
    @Test func anexampleOfADefinitionInCodeIsNotOne() throws {
        let blocks = LampProse.blocks(
            "    [guide]: /wrong\n\nSee [it][guide].\n\n[guide]: /right"
        )
        guard case .paragraph(let text)? = blocks.first(where: {
            if case .paragraph = $0 { return true } else { return false }
        }) else { return #expect(Bool(false), "no paragraph") }
        #expect(text.text.runs.first(where: { $0.link != nil })?.link?.absoluteString == "/right")
    }

    /// A tilde the writer escaped is their character, and keeps no backslash.
    ///
    /// Standing it in before cmark consumed the backslash left it in the
    /// address: `[x](/a\~b)` opened `/a%5C~b`. Found by Codex, reviewing the
    /// phone's adoption.
    @Test func anescapedTildeInAnAddressStaysATilde() throws {
        let text = try paragraph("[profile](https://example.com/\\~name)")
        let link = text.text.runs.first { $0.link != nil }?.link?.absoluteString
        #expect(link == "https://example.com/~name", "opened \(link ?? "nothing")")
    }

    /// And in the words, where it is drawn rather than followed.
    @Test func anescapedTildeInTheWordsIsDrawnAsATilde() throws {
        #expect(try paragraph("about \\~ three days").plain == "about ~ three days")
    }

    /// Nothing is written into indented code.
    ///
    /// The quote-break pass skipped fences but not indented code, so a
    /// quoted line inside an indented block was given a backslash the writer
    /// never typed, and drew and copied with it. Found by Codex, reviewing
    /// the phone's adoption.
    @Test func thequoteBreakPassLeavesIndentedCodeAlone() {
        let blocks = LampProse.blocks("Before.\n\n    > one\n    > two\n\nAfter.")
        let code = blocks.compactMap { block -> String? in
            if case .code(_, let text) = block { return text } else { return nil }
        }
        #expect(code == ["> one\n> two"], "the block drew \(code)")
    }

    /// A paragraph that wraps onto an indented line is prose, not code, so
    /// its break is still marked where the editor marks it.
    @Test func awrappedLineIsNotMistakenForCode() {
        guard case .quote(let inner)? = LampProse.blocks("> one\n>     two").first,
              case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no quote") }
        #expect(text.plain.contains("one"))
        #expect(!text.plain.contains("\\"), "a backslash was written in: \(text.plain)")
    }

    /// A definition commented out in HTML is not a definition.
    ///
    /// It was gathered and carried to every piece, and a label keeps its
    /// first address, so the commented-out one won and the link opened it.
    @Test func adefinitionCommentedOutIsNotGathered() {
        let blocks = LampProse.blocks(
            "<!--\n[ref]: https://one.example\n-->\n\nSee [text][ref].\n\n[ref]: https://two.example"
        )
        guard case .paragraph(let text)? = blocks.first(where: {
            if case .paragraph(let value) = $0 { return value.plain.contains("See") }
            return false
        }) else { return #expect(Bool(false), "no paragraph") }
        let address = text.text.runs.first { $0.link != nil }?.link?.absoluteString
        #expect(address == "https://two.example", "opened \(address ?? "nothing")")
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

    /// A footnote's marker is marked, not left as the brackets the writer
    /// typed. The editor draws it as a superscript number; both apps drew
    /// `[^1]`. Found by the iOS session while adopting this.
    @Test func afootnotesMarkerIsMarked() throws {
        let text = try paragraph("A claim.[^1] And more.[^note]")
        #expect(text.footnoteReferences.map(\.label) == ["1", "note"])
        let marked = text.text.runs.compactMap { run -> String? in
            guard run.lampFootnoteReference != nil else { return nil }
            return String(text.text[run.range].characters)
        }
        #expect(marked == ["[^1]", "[^note]"])
        // The words around it are untouched and unmarked.
        #expect(text.plain == "A claim.[^1] And more.[^note]")
    }

    /// What is not a marker stays the characters the writer typed.
    @Test func whatisnotAFootnoteMarkerIsLeftAlone() throws {
        for source in ["an empty [^] one", "a spaced [^a b] one", "a caret [^a^b] one"] {
            let text = try paragraph(source)
            #expect(text.footnoteReferences.isEmpty, "marked something in \(source)")
            #expect(text.plain == source)
        }
        // Inside code it is code.
        let code = try paragraph("the text `[^1]` as code")
        #expect(code.footnoteReferences.isEmpty)

        // A marker followed by a bracket of its own is still a marker: the
        // bracket is the writer's, and the editor draws it too.
        let trailing = try paragraph("a bracket [^a]]")
        #expect(trailing.footnoteReferences.map(\.label) == ["a"])
        #expect(trailing.plain == "a bracket [^a]]")
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

    // MARK: One parse

    /// A line shaped like a definition in the middle of a paragraph is part
    /// of the paragraph, and the real definition is the one that counts.
    ///
    /// It was gathered and carried to every piece, and a label keeps its
    /// first address, so `[verse][ref]` opened verse 17 where the editor
    /// opens verse 16. Parsed once, cmark decides. Found by Codex, reviewing
    /// the phone's adoption.
    @Test func adefinitionShapedLineInAParagraphIsTheParagraphs() throws {
        let blocks = LampProse.blocks(
            "See [verse][ref].\n\n[^n]: A note.\n\nA line\n[ref]: lampbible://verse/43003017\n\n"
                + "[ref]: lampbible://verse/43003016"
        )
        let links = blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            return text.text.runs.first { $0.link != nil }?.link?.absoluteString
        }
        // The line in the paragraph is words, its `[ref]` a link like the
        // first: both open the definition that is one.
        #expect(links == ["lampbible://verse/43003016", "lampbible://verse/43003016"], "opened \(links)")
        let drawn = blocks.compactMap { block -> String? in
            if case .paragraph(let text) = block { return text.plain } else { return nil }
        }
        #expect(drawn == ["See verse.", "A line ref: lampbible://verse/43003017"], "drew \(drawn)")
    }

    /// A footnote comes back where it was written, between the blocks
    /// either side of it, and ends the list it was written under.
    @Test func afootnoteKeepsItsPlace() {
        let blocks = LampProse.blocks("- one\n[^1]: The note.\n- two\n\nAfter.")
        let kinds = blocks.map { block -> String in
            switch block {
            case .list: return "list"
            case .footnote: return "footnote"
            case .paragraph: return "paragraph"
            default: return "other"
            }
        }
        #expect(kinds == ["list", "footnote", "list", "paragraph"], "read \(kinds)")
    }

    /// Footnotes written one after another each come back, in order.
    @Test func footnotesInARunComeBackInOrder() {
        let labels = LampProse.blocks("Body.[^a][^b]\n\n[^a]: First.\n[^b]: Second.\n\nEnd.")
            .compactMap { block -> String? in
                if case .footnote(let label, _) = block { return label } else { return nil }
            }
        #expect(labels == ["a", "b"])
    }

    /// A footnote inside an HTML block the writer left open is not lost: the
    /// block is cut around it.
    @Test func afootnoteInsideAnOpenHTMLBlockIsKept() {
        let blocks = LampProse.blocks("<pre>\n\n[^1]: The note.\n</pre>")
        #expect(blocks.contains { block in
            if case .footnote("1", _) = block { return true } else { return false }
        }, "read \(blocks)")
        #expect(!blocks.contains { block in
            if case .html(let raw) = block { return raw.contains("\u{E0F1}") } else { return false }
        }, "the marker was drawn")
    }

    /// A footnote's words are its own: the editor reads them line by line,
    /// with none of the body's definitions, so `[x][r]` in one is words.
    @Test func afootnoteDoesNotReadTheBodysDefinitions() {
        let blocks = LampProse.blocks("Body.[^n]\n\n[^n]: See [x][r].\n\n[r]: /url")
        guard case .footnote(_, let inner)? = blocks.first(where: {
            if case .footnote = $0 { return true } else { return false }
        }), case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no footnote") }
        #expect(text.plain == "See [x][r].")
        #expect(!text.text.runs.contains { $0.link != nil })
    }

    // MARK: Media captions

    /// A picture whose caption holds a bracket is one picture, as the editor
    /// reads it, not words and a link. Found by Codex, reviewing the phone's
    /// adoption.
    @Test func apicturesCaptionMayHoldABracket() {
        #expect(
            LampProse.blocks("![Pool [north side](media/pic)")
                == [.picture(caption: "Pool [north side", path: "media/pic")]
        )
        #expect(
            LampProse.blocks("[Reading [part one](media/abc)")
                == [.audio(caption: "Reading [part one", path: "media/abc")]
        )
    }

    /// A caption is shown as it was typed, marks and all, as the editor's is.
    @Test func acaptionIsTheWritersCharacters() {
        #expect(
            LampProse.blocks("![**Pool** at ~dawn\\](lamp-media://pic)")
                == [.picture(caption: "**Pool** at ~dawn\\", path: "lamp-media://pic")]
        )
    }

    /// Only the editor's own addresses: any other picture is cmark's to read.
    @Test func anotherPicturesCaptionIsLeftToTheParser() {
        #expect(
            LampProse.blocks("![A *view*](https://example.com/pic.jpg)")
                == [.picture(caption: "A view", path: "https://example.com/pic.jpg")]
        )
    }

    // MARK: Nested quotes

    /// A deeper quote opens a block of its own, so the line above it ends a
    /// paragraph and gets no break, which would be drawn as a backslash.
    /// Found by Codex, reviewing the phone's adoption.
    @Test func alineAboveADeeperQuoteIsGivenNoBreak() {
        guard case .quote(let outer)? = LampProse.blocks("> Outer\n> > Inner").first,
              case .paragraph(let text)? = outer.first,
              case .quote(let inner)? = outer.last,
              case .paragraph(let innerText)? = inner.first
        else { return #expect(Bool(false), "no nested quote") }
        #expect(text.plain == "Outer")
        #expect(innerText.plain == "Inner")
    }

    /// A shallower line carries the deeper paragraph on, lazily, so the
    /// break between them is still the editor's.
    @Test func ashallowerLineCarriesTheDeeperParagraphOn() {
        guard case .quote(let outer)? = LampProse.blocks("> > one\n> two").first,
              case .quote(let inner)? = outer.first,
              case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no nested quote") }
        #expect(text.lines.map(\.plain) == ["one", "two"])
    }

    // MARK: Found reviewing the one parse

    /// An indented link carrying a paragraph on is a link, not a recording:
    /// the editor reads a recording only from a line's first column.
    @Test func anindentedLinkKeepsItsEmphasis() throws {
        let text = try paragraph("Listen to\n  [*this*](media/a)")
        #expect(text.plain == "Listen to this")
        #expect(text.text.runs.contains {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
                && $0.link?.absoluteString == "media/a"
        })
    }

    /// A `>` set four spaces in is the paragraph's own character, so the
    /// break before its line is still the editor's.
    @Test func alongIndentedMarkIsNoDeeperQuote() {
        guard case .quote(let inner)? = LampProse.blocks("> one\n>     > two").first,
              inner.count == 1, case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no single paragraph") }
        #expect(text.lines.map(\.plain) == ["one", "> two"])
    }

    /// Backticks in indented code open no fence. Read as one, the fence
    /// that really opens after it was taken for its close, and a note inside
    /// that fence was taken out of it, leaving its marker drawn as code.
    @Test func backticksInIndentedCodeOpenNoFence() {
        #expect(
            LampProse.blocks("    ```\n\n```\n[^n]: note\nafter")
                == [.code(language: nil, code: "```"), .code(language: nil, code: "[^n]: note\nafter")]
        )
    }

    /// A note holding `</pre>` closes the `<pre>` left open above it, as the
    /// editor's block of the note's own HTML does, and the body after it is
    /// prose again.
    @Test func anoteThatClosesAnOpenBlockClosesIt() {
        let blocks = LampProse.blocks("<pre>\n[^n]: </pre>\nAfter")
        guard case .paragraph(let after)? = blocks.last
        else { return #expect(Bool(false), "read \(blocks)") }
        #expect(after.plain == "After")
    }

    /// A fence set in under a list item is a fence, and the quote after the
    /// list keeps its breaks.
    @Test func afenceUnderAListItemIsAFence() {
        let blocks = LampProse.blocks("- item\n\n    ```\n  code\n  ```\n\n> one\n> two")
        guard case .quote(let inner)? = blocks.last, case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "read \(blocks)") }
        #expect(text.lines.map(\.plain) == ["one", "two"])
    }

    /// A tab after a quote's mark runs to its stop, and the mark after it is
    /// still a mark.
    @Test func atabBetweenQuoteMarksIsCountedToItsStop() {
        guard case .quote(let outer)? = LampProse.blocks("> \t> one\n> > two").first,
              case .quote(let inner)? = outer.first,
              case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no nested quote") }
        #expect(text.lines.map(\.plain) == ["one", "two"])
    }

    /// A recording is a line that is nothing else, from its first column to
    /// its last, as the editor's pattern has it. Set in, or with a space
    /// after it, or quoted, it is a link.
    @Test func arecordingIsOnlyALineThatIsNothingElse() {
        for source in ["  [*this*](media/a)", "[this](media/a) ", "> [this](media/a)"] {
            #expect(!LampProse.blocks(source).contains { block in
                if case .audio = block { return true }
                if case .quote(let inner) = block {
                    return inner.contains { if case .audio = $0 { return true } else { return false } }
                }
                return false
            }, "\(source.debugDescription) was read as a recording")
        }
        #expect(LampProse.blocks("[this](media/a)") == [.audio(caption: "this", path: "media/a")])
    }

    /// A closing tag in a note's code span is the characters, to the editor,
    /// and closes nothing.
    @Test func aclosingTagInANotesCodeClosesNothing() {
        let blocks = LampProse.blocks("<pre>\n[^n]: `</pre>`\nAfter")
        guard case .html(let raw)? = blocks.last
        else { return #expect(Bool(false), "read \(blocks)") }
        #expect(raw.contains("After"))
    }

    /// A quote set in under a list item counts its marks from where it is
    /// set in, so the line above a deeper quote is given no break there
    /// either.
    @Test func aquoteUnderAListItemCountsItsOwnDepth() {
        guard case .list(_, _, let items)? = LampProse.blocks("- item\n\n    > Outer\n    > > Inner").first,
              case .quote(let outer)? = items.first?.blocks.last,
              case .paragraph(let text)? = outer.first
        else { return #expect(Bool(false), "no quote under the item") }
        #expect(text.plain == "Outer")
    }

    /// A tab that fills one column after a mark is used up by it.
    @Test func atabFillingOneColumnIsUsedUp() {
        guard case .quote(let outer)? = LampProse.blocks("  >\t> one\n> > two").first,
              case .quote(let inner)? = outer.first,
              case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "no nested quote") }
        #expect(text.lines.map(\.plain) == ["one", "two"])
    }

    /// Code set in under a list item is code, and its backticks open no
    /// fence that would take the quote after it.
    @Test func codeUnderAListItemOpensNoFence() {
        let blocks = LampProse.blocks("- An opening fence:\n\n      ```swift\n\n> one\n> two")
        guard case .quote(let inner)? = blocks.last, case .paragraph(let text)? = inner.first
        else { return #expect(Bool(false), "read \(blocks)") }
        #expect(text.lines.map(\.plain) == ["one", "two"])
    }

    /// Backticks the writer escaped make no code span, so a closing tag
    /// between them still closes.
    @Test func escapedBackticksMakeNoCodeSpan() {
        let blocks = LampProse.blocks("<pre>\n[^n]: \\`</pre>\\`\nAfter")
        guard case .paragraph(let after)? = blocks.last
        else { return #expect(Bool(false), "read \(blocks)") }
        #expect(after.plain == "After")
    }

    /// A quote under a nested item, or under an item whose marker is
    /// followed by a tab, is a quote, and keeps the editor's breaks.
    @Test func aquoteUnderANestedOrTabbedItemKeepsItsBreaks() {
        func quoteLines(_ blocks: [LampProseBlock]) -> [String]? {
            for block in blocks {
                switch block {
                case .quote(let inner):
                    if case .paragraph(let text)? = inner.first { return text.lines.map(\.plain) }
                case .list(_, _, let items):
                    for item in items { if let found = quoteLines(item.blocks) { return found } }
                default: continue
                }
            }
            return nil
        }
        for source in [
            "- item\n    - nested\n\n        > one\n        > two",
            "-\titem\n\n    > one\n    > two",
        ] {
            #expect(quoteLines(LampProse.blocks(source)) == ["one", "two"], "\(source.debugDescription)")
        }
    }
}
