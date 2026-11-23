import Foundation
import Markdown

/// One structural piece of a writing, read the way the writer's editor reads
/// it.
///
/// The apps draw prose natively — a note carries attachments and verse
/// links, a chapter's notes cannot each afford a web view, an agent's reply
/// streams and must be selectable across blocks — but drawing is not
/// parsing, and each app having written its own block reader is how they
/// came to disagree with the editor the writer types into, and with each
/// other. A note typed as three lines was read back as one; a list whose
/// items wrapped was cut into one list per item. Both were found by dumping
/// block trees for 138 real writings through the editor's own markdown-it
/// and through each reader, and diffing them.
///
/// So the parse is shared and the drawing is not.
public enum LampProseBlock: Equatable, Sendable {
    case heading(level: Int, text: LampProseText)
    case paragraph(LampProseText)
    case quote([LampProseBlock])
    /// `start` is the first item's own number, which a writer who begins at
    /// 3, or resumes after a paragraph, meant.
    case list(ordered: Bool, start: Int, items: [LampProseItem])
    case code(language: String?, code: String)
    case table(headers: [LampProseText], rows: [[LampProseText]])
    /// Raw HTML the writer put in a block of its own. The editor runs with
    /// html on and draws it; a native reader will not, but dropping it here
    /// would lose the writer's words without anyone deciding to.
    case html(String)
    /// A footnote the writer defined, `[^1]: its text`, which the editor
    /// gathers in its readFootnotes pass and no Markdown parser here reads.
    /// Left to the parser, its text ran on into the paragraph after it.
    case footnote(label: String, blocks: [LampProseBlock])
    /// A recording on a line of its own, which the editor draws as a player
    /// in its resolveAudioBlocks pass.
    case audio(caption: String, path: String)
    /// A picture on a line of its own.
    case picture(caption: String, path: String)
    case rule
}

/// One item of a list, and whether it is a task the writer has ticked.
public struct LampProseItem: Equatable, Sendable {
    /// `nil` for an ordinary item; `true` or `false` for a task list's.
    public let checked: Bool?
    public let blocks: [LampProseBlock]

    public init(checked: Bool? = nil, blocks: [LampProseBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

/// What the editor was set to when the writer typed.
///
/// `lineBreaks` is markdown-it's `breaks`, which both note editors turn on
/// by calling setLineBreaks(true), and a writing's editor leaves off. With
/// it on, a newline the writer typed is a line they get back; with it off, a
/// soft-wrapped source line is a continuation and joins. It is one option,
/// not a second grammar — which is what four hand-written block readers were
/// standing in for.
public struct LampProseOptions: Equatable, Sendable {
    public var lineBreaks: Bool

    public init(lineBreaks: Bool = false) {
        self.lineBreaks = lineBreaks
    }

    /// A writing's prose, typed with soft wraps that join.
    public static let writing = Self(lineBreaks: false)
    /// A note, whose typed lines are the writer's own.
    public static let note = Self(lineBreaks: true)
}

public enum LampProse {
    /// A lone `~` is a tilde to the editor and a strikethrough opener to
    /// cmark, so it is stood in for while parsing and put back after.
    ///
    /// cmark-gfm has a switch for this, CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE,
    /// which swift-markdown does not expose; reaching it means parsing
    /// through cmark-gfm itself, which is the better answer and a bigger
    /// change. Until then the stand-in does the same job. It is a
    /// private-use scalar so it can be told from a character the writer
    /// typed, and it is put back wherever text leaves this file.
    private static let tildeStandIn: Character = "\u{E0F0}"

    /// Set at the front of a recording's address while parsing, on a line
    /// the editor reads as one: from the first column to the last, and
    /// nothing else on it. A paragraph of one media link is a recording only
    /// with it, so an indented `[*this*](media/a)` is the link it is to the
    /// editor. Found by Codex, reviewing the one parse.
    private static let recordingMark: Character = "\u{E0F2}"

    /// The blocks of a piece of prose.
    ///
    /// The text is parsed **once**, as the editor parses it. Its footnotes
    /// are taken out first, because the editor gathers them in a pass of its
    /// own (readFootnotes) and no Markdown parser here reads them, but each
    /// leaves a marker where it was, set apart by blank lines, as the editor
    /// leaves its definitions block (resolveFootnotes). The footnote is put
    /// back where its marker is read.
    ///
    /// Splitting the text at its footnotes instead left each piece its own
    /// document, so a link written `[x][r]` could not see a definition in
    /// another piece, and the definitions had to be found by hand and
    /// carried to every piece. Every guess at where cmark reads one was
    /// wrong somewhere: in the middle of a paragraph, with words after its
    /// title, in code, in a comment. Parsed once, cmark resolves its own.
    public static func blocks(
        _ text: String, options: LampProseOptions = .writing
    ) -> [LampProseBlock] {
        let prepared = markingQuoteLineBreaks(standingInForLoneTildes(literalMediaCaptions(text)))
        let (body, notes) = footnotesTakenOut(of: prepared)
        // A footnote's own words are read on their own, as the editor reads
        // them, line by line with nothing from the body.
        let footnotes = notes.map { note in
            LampProseBlock.footnote(
                label: restored(note.label),
                blocks: children(of: document(note.source), options: options)
            )
        }
        return placing(footnotes, in: children(of: document(body), options: options))
    }

    /// The marker a footnote leaves in the body: an HTML comment, which is a
    /// block of its own wherever it starts a line, and holds a private-use
    /// scalar so it cannot be one the writer typed.
    ///
    /// The editor's block holds the note's own HTML, so a note reading
    /// `</pre>` closes a `<pre>` the writer left open above it, and the body
    /// after it is prose again. The marker carries any such closing tag the
    /// note holds, for the same reason. Found by Codex, reviewing the one
    /// parse.
    private static func footnoteMarker(_ index: Int, for source: String) -> String {
        // Not in a code span, which the editor draws as the characters.
        let lowered = outsideCodeSpans(source).lowercased()
        let closing = ["</script>", "</pre>", "</style>", "</textarea>"]
            .filter { lowered.contains($0) }
        return "<!--\u{E0F1}\(index)" + closing.map { " " + $0 }.joined() + "-->"
    }

    /// Code with the markers it took in, and the lines set around them,
    /// taken back out.
    private static func withoutMarkers(_ code: String) -> String {
        var out = ""
        var rest = Substring(code)
        while let open = rest.range(of: "<!--\u{E0F1}"),
              let close = rest[open.upperBound...].range(of: "-->") {
            var before = rest[..<open.lowerBound]
            if before.hasSuffix("\n\n") { before = before.dropLast() }
            else if before == "\n" { before = "" }
            out += before
            rest = rest[close.upperBound...]
            if rest.hasPrefix("\n\n") { rest = rest.dropFirst(2) }
            else if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        }
        out += rest
        // Taken from the end, the marker leaves the line before it ending.
        if out.hasSuffix("\n"), !code.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// A note's text without its code spans: a run of backticks to the next
    /// run of the same length. A backtick the writer escaped opens nothing.
    private static func outsideCodeSpans(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                out.append(character)
                out.append(characters[index + 1])
                index += 2
                continue
            }
            guard character == "`" else {
                out.append(character)
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end] == "`" { end += 1 }
            let run = end - index
            // The closing run, the same length and no longer.
            var search = end
            var close: Int?
            while search < characters.count {
                guard characters[search] == "`" else { search += 1; continue }
                var runEnd = search
                while runEnd < characters.count, characters[runEnd] == "`" { runEnd += 1 }
                if runEnd - search == run { close = runEnd; break }
                search = runEnd
            }
            if let close {
                index = close
            } else {
                out += String(characters[index..<end])
                index = end
            }
        }
        return out
    }

    /// The body's blocks with each footnote put back at its marker.
    ///
    /// The marker is read as a block of HTML, and is one unless something
    /// the writer left open — `<pre>` with no `</pre>` — runs on over the
    /// blank line before it. Then it is found inside that block, which is cut
    /// around it. A footnote whose marker is not found at all is kept, after
    /// the rest, rather than lost.
    private static func placing(
        _ footnotes: [LampProseBlock], in blocks: [LampProseBlock]
    ) -> [LampProseBlock] {
        guard !footnotes.isEmpty else { return blocks }
        var placed = Set<Int>()
        var out: [LampProseBlock] = []
        for block in blocks {
            switch block {
            case .html(let raw) where raw.contains("<!--\u{E0F1}"):
                var rest = Substring(raw)
                while let open = rest.range(of: "<!--\u{E0F1}"),
                      let close = rest[open.upperBound...].range(of: "-->"),
                      let index = Int(rest[open.upperBound..<close.lowerBound].prefix { $0.isNumber }),
                      footnotes.indices.contains(index) {
                    let before = rest[..<open.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty { out.append(.html(before)) }
                    out.append(footnotes[index])
                    placed.insert(index)
                    rest = rest[close.upperBound...]
                }
                let after = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { out.append(.html(after)) }
            case .code(let language, let code) where code.contains("<!--\u{E0F1}"):
                // A fence this file did not see open took the marker in. The
                // marker is not the writer's and is not drawn; its footnote
                // is kept after the rest.
                out.append(.code(language: language, code: withoutMarkers(code)))
            default:
                out.append(block)
            }
        }
        out += footnotes.indices.filter { !placed.contains($0) }.map { footnotes[$0] }
        return out
    }

    /// `.disableSmartOpts`: cmark otherwise curls the writer's quotes and
    /// turns `--` into a dash, where the editor runs with its typographer
    /// off. No `.parseBlockDirectives`: `@someone **word**` is a DocC
    /// directive to swift-markdown and loses its inline content, where the
    /// editor gives a plain paragraph.
    private static func document(_ source: String) -> Document {
        Document(parsing: source, options: [.disableSmartOpts])
    }


    /// Which of a text's lines are not prose, and so are left alone by every
    /// pass that reads the text before it is parsed.
    ///
    /// Three passes run before the parser — the quote-break marking, the
    /// footnote split and the definition gathering — and each used to decide
    /// for itself what to skip. Each got it differently wrong: a quoted line
    /// inside indented code had a backslash written into it, and a
    /// definition commented out in HTML was gathered and won the label over
    /// the real one. They now ask the same question once.
    ///
    /// A line is not prose when it is inside a fence, inside an HTML
    /// comment, or part of an indented code block — one that opens on a line
    /// indented four spaces or a tab where no paragraph is already running,
    /// as CommonMark has it, so a wrapped line of prose is not mistaken for
    /// code. Found by Codex, reviewing the phone's adoption.
    private static func linesToLeaveAlone(
        _ lines: [(line: String, ending: String)]
    ) -> [Bool] {
        var out: [Bool] = []
        var fence: String?
        var inComment = false
        var inIndentedCode = false
        var previousWasBlank = true
        // Where the list item the text is in sets its content, if it is in
        // one. Code under an item is set four columns past that, not past
        // the margin: a fence set in four under `- item` is a fence, and
        // backticks set in six are code. Found by Codex, reviewing the one
        // parse.
        var listContent: Int?
        for line in lines {
            let text = line.line
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let blank = trimmed.isEmpty
            let width = indentWidth(of: text)
            let wasFenced = fence != nil
            let wasComment = inComment

            if !wasFenced, !wasComment, !blank, !inIndentedCode {
                if let content = listItemContent(text, under: listContent) {
                    listContent = content
                } else if width == 0 {
                    listContent = nil
                }
            }
            let indented = width >= (listContent ?? 0) + 4

            // A line of indented code is code whatever it holds. Read for a
            // fence first, three backticks in it opened one, and the fence
            // that really opened after it was taken for its close. Found by
            // Codex, reviewing the one parse.
            if !wasFenced, !wasComment, !blank, indented,
               inIndentedCode || previousWasBlank {
                inIndentedCode = true
                out.append(true)
                previousWasBlank = false
                continue
            }

            if !wasFenced, !wasComment, trimmed.contains("<!--") {
                inComment = !trimmed.contains("-->")
                    || trimmed.range(of: "-->")!.lowerBound
                        < trimmed.range(of: "<!--")!.lowerBound
            } else if wasComment, trimmed.contains("-->") {
                inComment = false
            }

            if !inComment, !wasComment {
                fence = fenceState(fence, after: text)
            }

            if fence == nil, !inComment, !wasComment {
                if inIndentedCode {
                    inIndentedCode = blank || indented
                } else if indented, previousWasBlank {
                    inIndentedCode = true
                }
            } else {
                inIndentedCode = false
            }

            out.append(wasFenced || fence != nil || inComment || wasComment || inIndentedCode)
            if fence == nil, !inComment { previousWasBlank = blank }
        }
        return out
    }

    /// The column a list item's content starts at, if the line opens one:
    /// a bullet or a number set in no more than three columns past the
    /// content of the item it is under, if any, then one to four columns of
    /// space. Five or more after the marker are the content's own, and it
    /// starts one past the marker. Tabs run to their stops, after the marker
    /// as before it. A nested item set in four under `- item` is an item,
    /// and `-<tab>item` is one. Found by Codex, reviewing the one parse.
    private static func listItemContent(_ line: String, under content: Int?) -> Int? {
        let expanded = expandedTabs(line)
        let spaces = expanded.prefix { $0 == " " }
        guard spaces.count <= (content ?? 0) + 3 else { return nil }
        let rest = expanded.dropFirst(spaces.count)
        var marker = 0
        if let first = rest.first, "-*+".contains(first) {
            marker = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = rest.dropFirst(digits.count).first
            guard after == "." || after == ")" else { return nil }
            marker = digits.count + 1
        }
        let afterMarker = spaces.count + marker
        var gap = 0
        var characters = 0
        for character in rest.dropFirst(marker) {
            if character == " " { gap += 1 }
            else if character == "\t" { gap += 4 - (afterMarker + gap) % 4 }
            else { break }
            characters += 1
        }
        let emptyAfter = rest.dropFirst(marker + characters).isEmpty
        guard gap > 0 || emptyAfter else { return nil }
        return afterMarker + (gap > 4 || emptyAfter ? 1 : gap)
    }

    /// How far in a line's first character is, a tab running to its stop.
    private static func indentWidth(of line: String) -> Int {
        expandedTabs(line).prefix { $0 == " " }.count
    }

    /// The line with the tabs in its leading whitespace and quote marks set
    /// out as the spaces they stand for, each running to the next stop of
    /// four, as CommonMark measures them.
    private static func expandedTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var column = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            guard character == " " || character == "\t" || character == ">" else { break }
            if character == "\t" {
                let width = 4 - column % 4
                out += String(repeating: " ", count: width)
                column += width
            } else {
                out.append(character)
                column += 1
            }
            index = line.index(after: index)
        }
        return out + line[index...]
    }

    // MARK: Blocks

    private static func children(
        of markup: Markup, options: LampProseOptions
    ) -> [LampProseBlock] {
        markup.children.compactMap { block(from: $0, options: options) }
    }

    private static func block(
        from markup: Markup, options: LampProseOptions
    ) -> LampProseBlock? {
        switch markup {
        case let heading as Heading:
            // A heading written over two lines is one line of words: its
            // soft break is a space, never a break.
            return .heading(level: heading.level, text: text(of: heading, options: .writing))
        case let paragraph as Paragraph:
            // A line holding nothing but a picture or a recording is that
            // picture or recording, as the editor draws it. Read from the
            // tree, where both apps used a whole-line regex.
            if let media = media(of: paragraph) { return media }
            let read = text(of: paragraph, options: options)
            return read.isEmpty ? nil : .paragraph(read)
        case let quote as BlockQuote:
            let inner = children(of: quote, options: options)
            return inner.isEmpty ? nil : .quote(inner)
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: items(of: list, options: options))
        case let list as OrderedList:
            return .list(
                ordered: true, start: Int(list.startIndex),
                items: items(of: list, options: options)
            )
        case let code as CodeBlock:
            let language = restored(code.language ?? "").trimmingCharacters(in: .whitespaces)
            return .code(
                language: language.isEmpty ? nil : language,
                // cmark hands the content back with a trailing newline it
                // did not write.
                code: restored(
                    code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
                )
            )
        case let table as Markdown.Table:
            return .table(
                headers: table.head.cells.map { text(of: $0, options: .writing) },
                rows: table.body.rows.map { row in
                    row.cells.map { text(of: $0, options: .writing) }
                }
            )
        case let html as HTMLBlock:
            let raw = restored(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : .html(raw)
        case is ThematicBreak:
            return .rule
        default:
            return nil
        }
    }

    private static func items(
        of list: ListItemContainer, options: LampProseOptions
    ) -> [LampProseItem] {
        list.listItems.map { item in
            LampProseItem(
                // A task list is markdown-it's `[x]`, which cmark takes off
                // the text and reports here. Dropped, a ticked task became
                // an ordinary item and the tick was gone.
                checked: item.checkbox.map { $0 == .checked },
                blocks: children(of: item, options: options)
            )
        }
    }

    /// A paragraph holding nothing but one picture or one recording.
    private static func media(of paragraph: Paragraph) -> LampProseBlock? {
        let children = Array(paragraph.children)
        guard children.count == 1 else { return nil }
        if let image = children.first as? Markdown.Image {
            return .picture(
                caption: restored(image.plainText), path: restored(image.source ?? "")
            )
        }
        if let link = children.first as? Markdown.Link,
           link.destination?.first == recordingMark {
            return .audio(caption: restored(link.plainText), path: restored(link.destination ?? ""))
        }
        return nil
    }

    // MARK: Inline

    /// The inline content of a block, with Foundation's own attributes on it.
    private static func text(of markup: Markup, options: LampProseOptions) -> LampProseText {
        var out = AttributedString()
        walk(markup, into: &out, intent: [], link: nil, image: nil, options: options)
        return LampProseText(out)
    }

    private static func walk(
        _ markup: Markup, into out: inout AttributedString,
        intent: InlinePresentationIntent, link: String?, image: String?,
        options: LampProseOptions
    ) {
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                // A footnote's marker is marked rather than left as the
                // brackets the writer typed: the editor draws it as a
                // superscript number, and both apps drew `[^1]`.
                for piece in markers(in: restored(text.string)) {
                    append(
                        piece.text, to: &out, intent: intent, link: link, image: image,
                        footnote: piece.label
                    )
                }
            case let code as InlineCode:
                // The backticks and the spaces inside them are the code's,
                // and nothing here has to count them.
                append(
                    restored(code.code), to: &out,
                    intent: intent.union(.code), link: link, image: image
                )
            case is SoftBreak:
                // A wrap in the source. The editor draws it as a space
                // unless the writer's editor was set to show the break.
                if options.lineBreaks {
                    append(
                        "\n", to: &out, intent: intent.union(.lineBreak),
                        link: link, image: image
                    )
                } else {
                    append(
                        " ", to: &out, intent: intent.union(.softBreak),
                        link: link, image: image
                    )
                }
            case is LineBreak:
                append(
                    "\n", to: &out, intent: intent.union(.lineBreak), link: link, image: image
                )
            case let html as InlineHTML:
                // `<br>` is a break in the editor, which runs with html on;
                // drawn as characters it showed the tag.
                if isBreakTag(html.rawHTML) {
                    append(
                        "\n", to: &out, intent: intent.union(.lineBreak),
                        link: link, image: image
                    )
                } else {
                    append(restored(html.rawHTML), to: &out, intent: intent, link: link, image: image)
                }
            case let emphasis as Emphasis:
                walk(
                    emphasis, into: &out, intent: intent.union(.emphasized),
                    link: link, image: image, options: options
                )
            case let strong as Strong:
                walk(
                    strong, into: &out, intent: intent.union(.stronglyEmphasized),
                    link: link, image: image, options: options
                )
            case let struck as Strikethrough:
                walk(
                    struck, into: &out, intent: intent.union(.strikethrough),
                    link: link, image: image, options: options
                )
            case let inner as Markdown.Link:
                walk(
                    inner, into: &out, intent: intent,
                    link: restored(inner.destination ?? ""), image: image, options: options
                )
            case let inner as Markdown.Image:
                // One run carrying the address, as Foundation gives it: its
                // alt text if it has any, and the object replacement
                // character if it does not. Walking the children instead
                // lost an image with no alt text entirely, and gave a
                // formatted one several image-bearing runs where the readers
                // expect one, so each drew the picture more than once.
                let alt = restored(inner.plainText)
                append(
                    alt.isEmpty ? "\u{FFFC}" : alt, to: &out, intent: intent,
                    link: link, image: restored(inner.source ?? "")
                )
            case let attributes as InlineAttributes:
                // Apple's own `^[word](attrs)`, which the fork reads with no
                // option to turn it off. The editor shows the characters the
                // writer typed, so they are put back.
                append("^[", to: &out, intent: intent, link: link, image: image)
                walk(
                    attributes, into: &out, intent: intent,
                    link: link, image: image, options: options
                )
                append(
                    "](\(restored(attributes.attributes)))",
                    to: &out, intent: intent, link: link, image: image
                )
            default:
                walk(child, into: &out, intent: intent, link: link, image: image, options: options)
            }
        }
    }

    private static func append(
        _ string: String, to out: inout AttributedString,
        intent: InlinePresentationIntent, link: String?, image: String?,
        footnote: String? = nil
    ) {
        guard !string.isEmpty else { return }
        var piece = AttributedString(string)
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if let link, let url = URL(string: link) { piece.link = url }
        if let image, let url = URL(string: image) { piece.imageURL = url }
        if let footnote { piece.lampFootnoteReference = footnote }
        out.append(piece)
    }

    /// A run of text cut around the footnote markers in it.
    ///
    /// A label is what the editor accepts between the brackets: no space, no
    /// bracket of its own, and not empty. `[^]` and `[^a b]` are the
    /// characters the writer typed.
    private static func markers(in text: String) -> [(text: String, label: String?)] {
        guard text.contains("[^") else { return [(text, nil)] }
        var out: [(String, String?)] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "[", text.index(after: index) < text.endIndex,
                  text[text.index(after: index)] == "^",
                  let close = text[index...].firstIndex(of: "]")
            else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            let label = String(text[text.index(index, offsetBy: 2)..<close])
            guard !label.isEmpty,
                  !label.contains(where: { $0 == " " || $0 == "[" || $0 == "]" || $0 == "^" })
            else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            if !plain.isEmpty { out.append((plain, nil)); plain = "" }
            out.append((String(text[index...close]), label))
            index = text.index(after: close)
        }
        if !plain.isEmpty { out.append((plain, nil)) }
        return out.isEmpty ? [(text, nil)] : out
    }

    /// Whether a piece of inline HTML is a line break.
    ///
    /// Any spelling of it: `<br   />` and `<br class="x">` are breaks to the
    /// editor too, and matching three exact spellings drew the tag.
    private static func isBreakTag(_ raw: String) -> Bool {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces).lowercased())
        guard rest.hasPrefix("<br") else { return false }
        rest = rest.dropFirst(3)
        guard rest.hasSuffix(">") else { return false }
        rest = rest.dropLast().drop(while: { $0 == "/" || $0 == " " })
        // `<br>`, `<br/>`, `<br />`, or a tag with attributes on it.
        return rest.isEmpty || rest.first == " " || raw.contains("=")
            || rest.allSatisfy { $0 == "/" || $0 == " " }
    }

    // MARK: The editor's own blocks

    /// The text with its footnotes taken out, each leaving its marker, and
    /// the footnotes themselves in the order they were written.
    ///
    /// A footnote definition runs until a line that is neither blank nor
    /// indented: an unindented line after one is body text again, which is
    /// the rule the editor reads them by and the one that was lost when a
    /// definition and the body after it became a single paragraph. Not
    /// looked for inside code or a comment.
    private static func footnotesTakenOut(
        of text: String
    ) -> (body: String, notes: [(label: String, source: String)]) {
        let lines = LampMarkdownModel.linesWithEndings(of: text)
        let leaveAlone = linesToLeaveAlone(lines)
        var body = ""
        var notes: [(label: String, source: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard !leaveAlone[index], let note = footnoteOpening(line.line) else {
                body += line.line + line.ending
                index += 1
                continue
            }
            var source = note.text + "\n"
            index += 1
            while index < lines.count {
                let next = lines[index].line
                let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
                let indented = next.hasPrefix("    ") || next.hasPrefix("\t")
                guard blank || indented else { break }
                source += next.drop { $0 == " " || $0 == "\t" } + "\n"
                index += 1
            }
            // Blank lines either side, as the editor sets its block: the one
            // before ends the paragraph, list or quote the note was written
            // under, and the one after lets the body start afresh.
            body += "\n" + footnoteMarker(notes.count, for: source) + "\n\n"
            notes.append((note.label, source))
        }
        return (body, notes)
    }

    /// `[^label]: text`, at the start of a line.
    private static func footnoteOpening(_ line: String) -> (label: String, text: String)? {
        guard line.hasPrefix("[^"), let close = line.firstIndex(of: "]") else { return nil }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == ":" else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
        guard !label.isEmpty else { return nil }
        let text = line[line.index(after: afterClose)...].drop { $0 == " " || $0 == "\t" }
        return (label, String(text))
    }

    /// The break between two quoted lines, written where the parser reads it.
    ///
    /// The editor keeps a break between two lines that both open with `>`,
    /// in its resolveBlockquoteLineBreaks pass, whatever breaks is set to: a
    /// stanza is quoted a line at a time and meant to be read a line at a
    /// time. It does this before markdown-it sees the text, so the same is
    /// done here. Found by the iOS session, from the editor's own source.
    ///
    /// Only between two plain quoted lines: a quoted heading, list item,
    /// table row or fence opens a block of its own, and a backslash on the
    /// end of one would be drawn.
    private static func markingQuoteLineBreaks(_ text: String) -> String {
        guard text.contains(">") else { return text }
        let lines = LampMarkdownModel.linesWithEndings(of: text)
        let leaveAlone = linesToLeaveAlone(lines)
        var out = ""
        for (index, line) in lines.enumerated() {
            var next = line.line
            // And only when the next line carries on the same paragraph. A
            // deeper quote opens a block of its own, so `> Outer` above
            // `> > Inner` ended its paragraph on the backslash, which was
            // drawn. A shallower one carries on the deeper paragraph, lazily,
            // as CommonMark has it, so its break is still the editor's.
            // Found by Codex, reviewing the phone's adoption.
            if !leaveAlone[index], index + 1 < lines.count, !leaveAlone[index + 1],
               let body = quotedBody(of: line.line), isPlainProse(body),
               let following = quotedBody(of: lines[index + 1].line), isPlainProse(following),
               quoteDepth(of: lines[index + 1].line) <= quoteDepth(of: line.line),
               !next.hasSuffix("\\"), !next.hasSuffix("  ") {
                next += "\\"
            }
            out += next + line.ending
        }
        return out
    }

    /// What a line says after its quote markers, or nil if it is not quoted.
    private static func quotedBody(of line: String) -> String? {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard rest.first == ">" else { return nil }
        while rest.first == ">" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        return String(rest)
    }

    /// How many quotes deep a line is, as CommonMark counts its markers.
    ///
    /// A marker after the first is a `>` set in no more than three spaces
    /// past the one before it and the space that may follow it. One set
    /// further in is the paragraph's own character: `> one` above
    /// `>     > two` carries the paragraph on, and its break is still the
    /// editor's. The first may be set in any distance, since a list item
    /// sets its quotes in under it. Tabs run to their stops. Found by Codex,
    /// reviewing the one parse.
    private static func quoteDepth(of line: String) -> Int {
        var rest = Substring(expandedTabs(line))
        rest = rest.drop { $0 == " " }
        var depth = 0
        while rest.first == ">" {
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            let spaces = rest.prefix { $0 == " " }
            guard spaces.count <= 3, rest.dropFirst(spaces.count).first == ">" else { break }
            rest = rest.dropFirst(spaces.count)
        }
        return depth
    }

    /// Whether a quoted line's words are prose, rather than opening a block
    /// of their own.
    private static func isPlainProse(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```")
            || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("[^") { return false }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return false
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, let after = trimmed.dropFirst(digits.count).first,
           after == "." || after == ")" {
            return false
        }
        return true
    }

    /// The fence a line opens or closes, carried along the text.
    ///
    /// A closing fence is the same character and at least as long, so a run
    /// of three backticks inside a four-backtick fence does not end it.
    private static func fenceState(_ fence: String?, after line: String) -> String? {
        let body = quotedBody(of: line) ?? line
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return fence }
        let run = trimmed.prefix { $0 == marker }
        guard run.count >= 3 else { return fence }
        guard let open = fence else {
            // An opening backtick fence's info string cannot hold a backtick.
            if marker == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
            return String(run)
        }
        let closes = open.first == marker && run.count >= open.count
            && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
        return closes ? nil : open
    }

    // MARK: Media

    /// A picture's or a recording's caption, made literal before parsing.
    ///
    /// The editor finds a picture by its own pattern, `![caption](media/id)`
    /// with any caption but a closing bracket, and a recording the same way
    /// on a line of its own (resolveMediaPaths, resolveAudioBlocks), and
    /// shows the caption as typed. cmark reads `![Pool [north side](media/pic)`
    /// as words and a link, so the picture was gone. Each of the caption's
    /// marks is escaped, so cmark reads it as the editor does, and
    /// `![**Pool**](media/pic)` keeps its stars as the editor's caption does.
    /// Only on a line holding nothing else, where this file reads media, and
    /// only for the editor's own addresses. Found by Codex, reviewing the
    /// phone's adoption.
    private static func literalMediaCaptions(_ text: String) -> String {
        guard text.contains("](media/") || text.contains("](lamp-media://") else { return text }
        let lines = LampMarkdownModel.linesWithEndings(of: text)
        let leaveAlone = linesToLeaveAlone(lines)
        var out = ""
        for (index, line) in lines.enumerated() {
            let literal = leaveAlone[index] ? nil : literalMediaCaption(line.line)
            out += (literal ?? line.line) + line.ending
        }
        return out
    }

    private static func literalMediaCaption(_ line: String) -> String? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let trailing = line.reversed().prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent.count).dropLast(trailing)
        let bang = rest.hasPrefix("![")
        // The editor finds a picture wherever it is, and a recording only on
        // a line that is nothing else, from its first column to its last.
        // Read the same way, an indented `[*this*](media/a)` continuing a
        // paragraph was taken for a recording and lost its emphasis. Found
        // by Codex, reviewing the one parse.
        guard bang || (rest.hasPrefix("[") && indent.isEmpty && trailing == 0) else { return nil }
        let afterOpen = rest.dropFirst(bang ? 2 : 1)
        guard let close = afterOpen.firstIndex(of: "]") else { return nil }
        let caption = afterOpen[..<close]
        let address = afterOpen[afterOpen.index(after: close)...]
        guard address.hasPrefix("(media/") || address.hasPrefix("(lamp-media://"),
              address.hasSuffix(")"),
              !address.dropFirst().dropLast().contains(")")
        else { return nil }
        // A recording needs a caption, as the editor's pattern does.
        guard bang || !caption.isEmpty else { return nil }
        let escaped = caption.map { character -> String in
            character.isASCII && (character.isPunctuation || character.isSymbol)
                ? "\\" + String(character) : String(character)
        }.joined()
        let opening: String = bang ? "![" : "["
        let target: String = bang
            ? String(address) : "(" + String(recordingMark) + String(address.dropFirst())
        return String(indent) + opening + escaped + "]" + target + String(line.suffix(trailing))
    }

    // MARK: Tildes

    private static func standingInForLoneTildes(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        var escaped = false
        while index < text.endIndex {
            guard text[index] == "~" else {
                // A run of backslashes escapes what follows it when it is odd.
                escaped = text[index] == "\\" ? !escaped : false
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            // A tilde the writer escaped is already their character and
            // opens nothing, and standing it in left the backslash behind:
            // `[x](/a\~b)` opened `/a%5C~b` where the address is `/a~b`.
            // Found by Codex, reviewing the phone's adoption.
            if escaped {
                out.append(text[index])
                index = text.index(after: index)
                escaped = false
                continue
            }
            var end = index
            while end < text.endIndex, text[end] == "~" { end = text.index(after: end) }
            let length = text.distance(from: index, to: end)
            out += length == 1 ? String(tildeStandIn) : String(repeating: "~", count: length)
            index = end
        }
        return out
    }

    private static func restored(_ text: String) -> String {
        var out = text
        if out.contains(recordingMark) { out.removeAll { $0 == recordingMark } }
        return out.contains(tildeStandIn)
            ? String(out.map { $0 == tildeStandIn ? "~" : $0 })
            : out
    }
}
