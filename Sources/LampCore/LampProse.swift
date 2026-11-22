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

    /// The blocks of a piece of prose.
    public static func blocks(
        _ text: String, options: LampProseOptions = .writing
    ) -> [LampProseBlock] {
        let prepared = markingQuoteLineBreaks(standingInForLoneTildes(text))
        // Taking the footnotes out leaves each piece its own document, and a
        // link written `[x][r]` is resolved by a definition that may be in
        // another piece. So every piece is given all of them.
        let definitions = referenceDefinitions(of: prepared)
        return regions(of: prepared)
            .flatMap { region -> [LampProseBlock] in
                switch region {
                case .prose(let source):
                    return children(of: document(definitions + source), options: options)
                case .footnote(let label, let source):
                    return [.footnote(
                        label: restored(label),
                        blocks: children(of: document(definitions + source), options: options)
                    )]
                }
            }
    }

    /// `.disableSmartOpts`: cmark otherwise curls the writer's quotes and
    /// turns `--` into a dash, where the editor runs with its typographer
    /// off. No `.parseBlockDirectives`: `@someone **word**` is a DocC
    /// directive to swift-markdown and loses its inline content, where the
    /// editor gives a plain paragraph.
    private static func document(_ source: String) -> Document {
        Document(parsing: source, options: [.disableSmartOpts])
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
        if let link = children.first as? Markdown.Link {
            let path = restored(link.destination ?? "")
            guard path.hasPrefix("media/") || path.hasPrefix("lamp-media://") else { return nil }
            return .audio(caption: restored(link.plainText), path: path)
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

    private enum Region {
        case prose(String)
        case footnote(label: String, source: String)
    }

    /// The text split into the footnotes the editor gathers and the prose
    /// between them.
    ///
    /// A footnote definition runs until a line that is neither blank nor
    /// indented: an unindented line after one is body text again, which is
    /// the rule the editor reads them by and the one that was lost when a
    /// definition and the body after it became a single paragraph. Not
    /// looked for inside a fence, where it is code.
    private static func regions(of text: String) -> [Region] {
        let lines = LampMarkdownModel.linesWithEndings(of: text)
        var out: [Region] = []
        var prose = ""
        var fence: String?
        var index = 0

        func takeProse() {
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.prose(prose))
            }
            prose = ""
        }

        while index < lines.count {
            let line = lines[index]
            let wasFenced = fence != nil
            fence = fenceState(fence, after: line.line)

            if !wasFenced, fence == nil, let note = footnoteOpening(line.line) {
                takeProse()
                var body = note.text + "\n"
                index += 1
                while index < lines.count {
                    let next = lines[index].line
                    let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
                    let indented = next.hasPrefix("    ") || next.hasPrefix("\t")
                    guard blank || indented else { break }
                    body += next.drop { $0 == " " || $0 == "\t" } + "\n"
                    index += 1
                }
                out.append(.footnote(label: note.label, source: body))
                continue
            }

            prose += line.line + line.ending
            index += 1
        }
        takeProse()
        return out
    }

    /// Every `[label]: address` the text defines, gathered so each piece
    /// of it can resolve a link written in another.
    ///
    /// They go in **front** of a piece, never after it. A block can only
    /// swallow what follows it, and a piece ending in an unclosed fence,
    /// HTML block or indented code swallowed the definitions written after
    /// it and drew them as code the writer never typed. Nothing can precede
    /// them to swallow them. A definition repeated in the piece that already
    /// held it is harmless: the first of a label wins, and a definition
    /// draws nothing. Found by Codex, reviewing the phone's adoption.
    private static func referenceDefinitions(of text: String) -> String {
        var fence: String?
        var out = ""
        for line in LampMarkdownModel.linesWithEndings(of: text) {
            let wasFenced = fence != nil
            fence = fenceState(fence, after: line.line)
            guard !wasFenced, fence == nil else { continue }
            let trimmed = line.line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[^"),
                  let close = trimmed.firstIndex(of: "]"),
                  trimmed.index(after: close) < trimmed.endIndex,
                  trimmed[trimmed.index(after: close)] == ":"
            else { continue }
            out += trimmed + "\n\n"
        }
        return out
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
        var fence: String?
        var out = ""
        for (index, line) in lines.enumerated() {
            let wasFenced = fence != nil
            fence = fenceState(fence, after: line.line)
            var next = line.line
            if !wasFenced, fence == nil, index + 1 < lines.count,
               let body = quotedBody(of: line.line), isPlainProse(body),
               let following = quotedBody(of: lines[index + 1].line), isPlainProse(following),
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

    // MARK: Tildes

    private static func standingInForLoneTildes(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "~" else {
                out.append(text[index])
                index = text.index(after: index)
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
        text.contains(tildeStandIn)
            ? String(text.map { $0 == tildeStandIn ? "~" : $0 })
            : text
    }
}
