import Foundation
import Markdown

/// What a Markdown text is made of, in the ranges Swift works in.
///
/// Core reads Markdown in several places — where a mark may be placed,
/// what a clear may reach, how a document is drawn — and each reader
/// was written by hand against the cases it was built for. Six rounds
/// of review found six ways one of them took in a delimiter belonging
/// to text the writer never selected. The rule behind all of them is
/// CommonMark's, so this asks a CommonMark parser instead.
///
/// Every range is UTF-16, the units `NSRange` and `NSString` count in.
/// swift-markdown reports a line and a **UTF-8 column**, so converting
/// is this type's real work: a Hebrew letter is two UTF-16 units and
/// two or three UTF-8 bytes, and an emoji is two UTF-16 units and four
/// UTF-8 bytes. Getting that wrong moves every range on a line after
/// the first such character.
public struct LampMarkdownModel: Sendable {
    /// An inline span the writer sees as formatting: its delimiters and
    /// the content between them.
    public struct Inline: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case emphasis
            case strong
            case strikethrough
            case inlineCode
            case link
            case image
        }

        public let kind: Kind
        /// The whole span, delimiters and all.
        public let range: NSRange
        /// What stands between the delimiters. For a link this is the
        /// label; the address is `range` less this and the brackets.
        public let content: NSRange

        public init(kind: Kind, range: NSRange, content: NSRange) {
            self.kind = kind
            self.range = range
            self.content = content
        }

        /// Whether this span's delimiter runs are its own.
        ///
        /// cmark can hand a nested span the *whole* opening run it
        /// shares with its parent: in `***one** two*` the inner strong
        /// node's range begins at the first of three stars, one of
        /// which opens the outer emphasis and covers the unselected
        /// ` two`. Taking that star in would partly clear the outer
        /// change. A run longer than the kind needs is the sign.
        public var ownsItsDelimiters: Bool {
            let needed: Int
            switch kind {
            case .emphasis: needed = 1
            case .strong, .strikethrough: needed = 2
            // A code span's run may be any length, and a link's
            // brackets are not a run at all; neither is ever taken in.
            case .inlineCode, .link, .image: return true
            }
            let (opening, closing) = delimiters
            return opening.length == needed && closing.length == needed
        }

        /// The delimiters themselves: what is in `range` but not
        /// `content`, as the opening and closing pieces.
        public var delimiters: (opening: NSRange, closing: NSRange) {
            (
                NSRange(location: range.location, length: content.location - range.location),
                NSRange(
                    location: NSMaxRange(content),
                    length: NSMaxRange(range) - NSMaxRange(content)
                )
            )
        }
    }

    /// A block and the syntax that opens it.
    public struct Block: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case heading
            case listItem
            case blockQuote
            case codeBlock
            case table
            case tableCell
            case paragraph
            case thematicBreak
        }

        public let kind: Kind
        public let range: NSRange
        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    public let text: String
    public let blocks: [Block]
    public let inlines: [Inline]

    /// Where code is written as it stands: fenced and indented blocks,
    /// and inline code spans. Nothing inside is formatting.
    public var codeRanges: [NSRange] {
        blocks.filter { $0.kind == .codeBlock }.map(\.range)
            + inlines.filter { $0.kind == .inlineCode }.map(\.range)
    }

    public func isInCode(_ location: Int) -> Bool {
        codeRanges.contains { NSLocationInRange(location, $0) }
    }

    public init(parsing text: String) {
        self.text = text
        let offsets = Self.lineOffsets(of: text)
        // A one-tilde run is literal here. cmark-gfm reads `~text~` as
        // strikethrough; the editor page reads Markdown with
        // markdown-it, which needs `~~`, and core must not see
        // formatting the writer does not see.
        //
        // Dropping the nodes afterwards was not enough: a single tilde
        // still took part in pairing, so `~~a ~b~~ c~` produced no
        // strikethrough at all where markdown-it strikes `a ~b`. The
        // tildes are made literal *before* parsing instead, each
        // replaced by a character of the same UTF-8 and UTF-16 width
        // so every offset still lands where it did. Found by the iOS
        // session.
        let forParsing = Self.hidingSingleTildes(text)
        // No `.parseBlockDirectives`: `@someone **word**` is a DocC
        // directive to swift-markdown and loses its inline content,
        // where the editor's markdown-it gives a plain paragraph. Core
        // must read what the writer's editor reads. Found by the iOS
        // session, who probed the editor's own install.
        let document = Document(parsing: forParsing)
        var blocks: [Block] = []
        var inlines: [Inline] = []
        Self.walk(document, text: text, offsets: offsets, blocks: &blocks, inlines: &inlines)
        self.blocks = blocks
        self.inlines = inlines
    }
}

extension LampMarkdownModel {
    /// For each line, where it starts in UTF-16 units and the UTF-16
    /// offset of each UTF-8 byte position within it.
    ///
    /// swift-markdown counts columns in UTF-8 bytes from 1. A Hebrew
    /// letter is one Character, two UTF-16 units and two UTF-8 bytes;
    /// an emoji can be one Character, two UTF-16 units and four UTF-8
    /// bytes. Converting by assuming any of those equal costs every
    /// range on the line after the first such character, so each line
    /// carries a map built from its own content.
    struct LineMap: Sendable {
        /// UTF-16 offset of the line's first character in the text.
        let start: Int
        /// `utf16[b]` is the UTF-16 offset within the line of the
        /// character beginning at UTF-8 byte `b`. One longer than the
        /// line's byte count, so the end converts too.
        let utf16: [Int]

        func offset(ofColumn column: Int) -> Int {
            // Columns are 1-based byte positions.
            let byte = max(0, column - 1)
            guard byte < utf16.count else { return start + (utf16.last ?? 0) }
            return start + utf16[byte]
        }
    }

    static func lineOffsets(of text: String) -> [LineMap] {
        var maps: [LineMap] = []
        var start = 0
        // cmark ends a line at `\r\n`, `\r` or `\n`, so splitting on
        // `\n` alone counts a classic-Mac or Windows file's lines
        // differently from the parser and every range after the first
        // such break lands on unrelated text. The separator's own
        // UTF-16 length is carried rather than assumed to be one.
        for (line, separator) in Self.lines(of: text) {
            var utf16: [Int] = []
            utf16.reserveCapacity(line.utf8.count + 1)
            var offset = 0
            // By scalar, not by Character: a grapheme may be several
            // scalars — a letter and a combining mark, a flag — and
            // cmark can report a column at a scalar boundary inside
            // one. Mapping whole Characters puts every byte of the
            // cluster at the cluster's start.
            for scalar in line.unicodeScalars {
                let bytes = UTF8.width(scalar)
                for _ in 0..<bytes { utf16.append(offset) }
                offset += UTF16.width(scalar)
            }
            utf16.append(offset)
            maps.append(LineMap(start: start, utf16: utf16))
            start += offset + separator
        }
        return maps
    }

    /// Each line and the UTF-16 length of the break that ended it.
    ///
    /// By Unicode scalar, not by Character. In Swift `"\r\n"` is a
    /// *single* Character — one grapheme cluster — so a splitter
    /// comparing Characters matches neither `"\r"` nor `"\n"` and
    /// hands back the whole text as one line. Every range after the
    /// first Windows line ending then lands wherever that one line's
    /// map happens to reach, which here meant the span was dropped.
    static func lines(of text: String) -> [(line: String, separator: Int)] {
        var out: [(String, Int)] = []
        var current = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                let crlf = index + 1 < scalars.count && scalars[index + 1] == "\n"
                out.append((String(current), crlf ? 2 : 1))
                current = String.UnicodeScalarView()
                index += crlf ? 2 : 1
            } else if scalar == "\n" {
                out.append((String(current), 1))
                current = String.UnicodeScalarView()
                index += 1
            } else {
                current.append(scalar)
                index += 1
            }
        }
        out.append((String(current), 0))
        return out
    }

    /// A parsed node's source range, in UTF-16.
    static func range(of markup: Markup, offsets: [LineMap]) -> NSRange? {
        guard let source = markup.range else { return nil }
        let from = source.lowerBound
        let to = source.upperBound
        guard from.line >= 1, from.line <= offsets.count,
              to.line >= 1, to.line <= offsets.count
        else { return nil }
        let start = offsets[from.line - 1].offset(ofColumn: from.column)
        let end = offsets[to.line - 1].offset(ofColumn: to.column)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    static func walk(
        _ markup: Markup, text: String, offsets: [LineMap],
        blocks: inout [Block], inlines: inout [Inline]
    ) {
        if let kind = blockKind(of: markup), var range = range(of: markup, offsets: offsets) {
            // cmark-gfm starts a table's source position at the
            // paragraph before it. Its first cell is right, so the
            // table begins where its head row does. Found by the iOS
            // session porting the Files reader.
            if kind == .table, let first = firstCellStart(of: markup, offsets: offsets),
               first > range.location {
                range = NSRange(location: first, length: NSMaxRange(range) - first)
            }
            blocks.append(Block(kind: kind, range: range))
        }
        if let inline = self.inline(markup, text: text, offsets: offsets) {
            inlines.append(inline)
        }
        for child in markup.children {
            walk(child, text: text, offsets: offsets, blocks: &blocks, inlines: &inlines)
        }
    }

    static func blockKind(of markup: Markup) -> Block.Kind? {
        switch markup {
        case is Heading: .heading
        case is ListItem: .listItem
        case is BlockQuote: .blockQuote
        case is CodeBlock: .codeBlock
        case is Table: .table
        case is Table.Cell: .tableCell
        case is Paragraph: .paragraph
        case is ThematicBreak: .thematicBreak
        default: nil
        }
    }

    static func inline(_ markup: Markup, text: String, offsets: [LineMap]) -> Inline? {
        let kind: Inline.Kind
        switch markup {
        case is Emphasis: kind = .emphasis
        case is Strong: kind = .strong
        case is Strikethrough: kind = .strikethrough
        case is InlineCode: kind = .inlineCode
        case is Link: kind = .link
        case is Image: kind = .image
        default: return nil
        }
        guard let whole = range(of: markup, offsets: offsets) else { return nil }
        // The content is what the children cover. An inline code span's
        // children are not reported, so its content is the whole less
        // its backtick runs, counted from the text.
        let content: NSRange
        if kind == .inlineCode {
            // Its children are not reported, so the content is the
            // span less its backtick runs, counted from the text. Set
            // to the whole span its delimiters were empty, and a clear
            // of the code never reached the backticks the assistant
            // added.
            content = Self.insideBackticks(whole, in: text) ?? whole
        } else {
            let childRanges = markup.children.compactMap { range(of: $0, offsets: offsets) }
            guard let first = childRanges.first, let last = childRanges.last else { return nil }
            content = NSRange(
                location: first.location, length: NSMaxRange(last) - first.location
            )
        }
        // cmark can report a multi-line strikethrough's end on its
        // opening line, which makes the closing delimiter negative and
        // the range a truncation. A content range that does not sit
        // inside the span is not a span this can reason about.
        guard content.location >= whole.location,
              NSMaxRange(content) <= NSMaxRange(whole)
        else { return nil }
        return Inline(kind: kind, range: whole, content: content)
    }
}

extension LampMarkdownModel {
    /// The smallest formatting span whose content `range` covers
    /// whole.
    ///
    /// Covers, not merely falls inside. A selection *within* a span's
    /// content must take nothing in: widening it to the span would
    /// clear marks on everything else the span holds. In
    /// `**one *two* three**`, clearing ` three` would otherwise reach
    /// the outer `**` and sweep `one` and the inner `*two*` on the way
    /// — delimiters belonging to text the writer never selected,
    /// which is the whole harm this exists to avoid.
    /// Every formatting span whose content the selection covers.
    public func coveredInlines(by range: NSRange) -> [Inline] {
        inlines.filter {
            range.location <= $0.content.location
                && NSMaxRange(range) >= NSMaxRange($0.content)
                && $0.ownsItsDelimiters
        }
    }

    public func inlineCovered(by range: NSRange) -> Inline? {
        inlines
            .filter {
                range.location <= $0.content.location
                    && NSMaxRange(range) >= NSMaxRange($0.content)
                    && $0.ownsItsDelimiters
            }
            .min { $0.range.length < $1.range.length }
    }
}

extension LampMarkdownModel {
    /// What lies between a code span's backtick runs.
    static func insideBackticks(_ span: NSRange, in text: String) -> NSRange? {
        let source = text as NSString
        guard span.length >= 2, NSMaxRange(span) <= source.length else { return nil }
        var open = span.location
        while open < NSMaxRange(span), source.character(at: open) == 0x60 { open += 1 }
        var close = NSMaxRange(span)
        while close > open, source.character(at: close - 1) == 0x60 { close -= 1 }
        guard close >= open else { return nil }
        return NSRange(location: open, length: close - open)
    }

    /// Where a table's first cell begins, which is where its head row
    /// begins.
    static func firstCellStart(of markup: Markup, offsets: [LineMap]) -> Int? {
        for child in markup.children {
            if child is Table.Cell, let range = range(of: child, offsets: offsets) {
                return range.location
            }
            if let found = firstCellStart(of: child, offsets: offsets) { return found }
        }
        return nil
    }
}

extension LampMarkdownModel {
    /// The text with every one-tilde run replaced by a character the
    /// parser reads as ordinary.
    ///
    /// Same width in UTF-8 and in UTF-16, so every line and column the
    /// parser reports still points at the same place in the original.
    /// `~` is one byte and one unit; `+` is too, and means nothing to
    /// Markdown in any position.
    static func hidingSingleTildes(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let run = rest.firstRange(of: "~") {
            var end = run.lowerBound
            while end < rest.endIndex, rest[end] == "~" { end = rest.index(after: end) }
            let length = rest.distance(from: run.lowerBound, to: end)
            out += rest[rest.startIndex..<run.lowerBound]
            out += length == 1 ? "+" : String(repeating: "~", count: length)
            rest = rest[end...]
        }
        return out + rest
    }
}
