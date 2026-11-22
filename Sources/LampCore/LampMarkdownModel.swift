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
        let document = Document(parsing: text, options: [.parseBlockDirectives])
        var blocks: [Block] = []
        var inlines: [Inline] = []
        Self.walk(document, offsets: offsets, blocks: &blocks, inlines: &inlines)
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
        // `components` keeps empty lines, which `enumerateLines` drops,
        // and the parser counts those.
        for line in text.components(separatedBy: "\n") {
            var utf16: [Int] = []
            utf16.reserveCapacity(line.utf8.count + 1)
            var offset = 0
            for character in line {
                let bytes = String(character).utf8.count
                let units = String(character).utf16.count
                for _ in 0..<bytes { utf16.append(offset) }
                offset += units
            }
            utf16.append(offset)
            maps.append(LineMap(start: start, utf16: utf16))
            // The newline itself is one UTF-16 unit.
            start += offset + 1
        }
        return maps
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
        _ markup: Markup, offsets: [LineMap],
        blocks: inout [Block], inlines: inout [Inline]
    ) {
        if let kind = blockKind(of: markup), let range = range(of: markup, offsets: offsets) {
            blocks.append(Block(kind: kind, range: range))
        }
        if let inline = self.inline(markup, offsets: offsets) {
            inlines.append(inline)
        }
        for child in markup.children {
            walk(child, offsets: offsets, blocks: &blocks, inlines: &inlines)
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

    static func inline(_ markup: Markup, offsets: [LineMap]) -> Inline? {
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
            content = whole
        } else {
            let childRanges = markup.children.compactMap { range(of: $0, offsets: offsets) }
            guard let first = childRanges.first, let last = childRanges.last else { return nil }
            content = NSRange(
                location: first.location, length: NSMaxRange(last) - first.location
            )
        }
        let inline = Inline(kind: kind, range: whole, content: content)
        // cmark-gfm reads a single `~text~` as strikethrough; the
        // editor page reads Markdown with markdown-it, which needs
        // `~~`. Core must not see formatting the writer does not see,
        // so a one-tilde run is literal here. Found by the iOS
        // session, who own the page.
        if kind == .strikethrough, inline.delimiters.opening.length < 2 { return nil }
        return inline
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
    public func inlineCovered(by range: NSRange) -> Inline? {
        inlines
            .filter {
                range.location <= $0.content.location
                    && NSMaxRange(range) >= NSMaxRange($0.content)
            }
            .min { $0.range.length < $1.range.length }
    }
}
