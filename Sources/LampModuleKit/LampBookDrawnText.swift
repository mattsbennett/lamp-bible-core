import Foundation

/// The words a book section's readers draw, in the order they draw them.
///
/// Search is built from these, so a word is found where a reader shows it and
/// nowhere else. It was built by walking the section's raw JSON for a list of
/// keys, which made it a second reading of each block beside the readers' own:
/// a table's cells were missed altogether, then — once added — were taken in
/// the order written rather than by column, with cells the layout hides, and
/// from blocks never drawn as tables (`Documentation/RichModulesPlan.md`,
/// record 0029). So the section is decoded as the readers decode it
/// (`LampPortableBookJSON.decodeArray`, which drops a block they cannot read)
/// and each block gives what its type draws, a table's rows through
/// `LampBookTableLayout`, as both readers place them.
///
/// Media metadata is not read: the readers disagree about it — the Mac falls
/// back to a picture's alt text when it has no caption, the phone to its
/// media entry's caption — so only the caption on the block, which both show,
/// is taken.
public enum LampBookDrawnText {
    /// How a figure is read: as its stored `content`, as today's readers
    /// draw it, or as its own parts — title, second line, caption, each
    /// child, notes — which is what a compiler projects into that content.
    public enum Figures: Sendable {
        case asContent, asParts
    }

    /// Between blocks, between lines of one block, and between a table
    /// row's columns, in a projection. Each begins and ends with whitespace,
    /// so a page marker at a join is spaced as it is at the end of its own
    /// text. A column's is visible: a tab is a tab stop, not a column, and
    /// a sparse row's value moved under an earlier heading. Found by Codex.
    /// A box-drawing bar, `│`, which prose does not hold, where a `|` is
    /// written in real tables' cells (found by Codex). A cell that holds a
    /// `│` reads as two: text cannot show every table unambiguously, and
    /// this one is for a reader that draws no tables, until step 6's do.
    /// Held left to right by a mark either side, or a bar between two
    /// Hebrew cells joined them in one right-to-left run, the cells swapped.
    /// Found by Codex, in a bundled book's tables.
    public static let blockSeparator = "\n\n"
    public static let lineSeparator = "\n"
    public static let cellSeparator = " \u{200E}\u{2502}\u{200E} "

    /// One text a block draws, and the table column it is in: 0 for any
    /// text not in a table.
    public struct Field: Equatable, Sendable {
        public let column: Int
        public let text: LampBookAnnotatedText
        /// A table cell's or a list item's, which a projection keeps on its
        /// line: a break in it read as the next row or the next item.
        public let isCell: Bool

        public init(column: Int = 0, text: LampBookAnnotatedText, isCell: Bool = false) {
            self.column = column
            self.text = text
            self.isCell = isCell
        }
    }

    /// A cell's text on one line: each line-breaking scalar a space, one
    /// for one, so no offset moves, and whitespace for whitespace, so a page
    /// marker beside one is spaced alike. Kept as written, a break in a cell
    /// started what read as the next row. Found by Codex.
    static func onOneLine(_ text: String) -> String {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
        guard text.unicodeScalars.contains(where: breaks.contains) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { scalars.append(breaks.contains(scalar) ? " " : scalar) }
        return String(scalars)
    }

    /// The texts a block draws, in reading order, a line at a time: a line
    /// per list item, depth first, and per table row (its cells as the
    /// layout places them, `LampBookTableLayout.placements`); a picture's
    /// caption; a figure as `figures` says; and any other block's content.
    /// The one switch over a block's type that search, a figure's words and
    /// a projection all read, so none of them reads a block its own way.
    public static func lines(of block: LampBookContentBlock, figures: Figures) -> [[Field]] {
        var lines: [[Field]] = []
        forEachLine(of: block, figures: figures) { lines.append($0) }
        return lines
    }

    /// `lines(of:figures:)` a line at a time, kept by no one: search reads a
    /// long table a row at a time, as it did before this walk, rather than
    /// every row's fields at once. Found by Codex.
    public static func forEachLine(of block: LampBookContentBlock, figures: Figures, _ body: ([Field]) -> Void) {
        switch block.type {
        case "list":
            for item in block.items { forEachLine(of: item, body) }
        case "table":
            let columnCount = LampBookTableLayout.resolvedColumnCount(
                declared: block.columnCount, rows: block.rows
            )
            // Each placed cell with its column, so a projection keeps a sparse
            // row's words under their headings (kept only in turn, they moved
            // under earlier ones; found by Codex) — and only the cells there
            // are: a field per column held a value for every empty slot of a
            // long sparse table, which search throws away. Found by Codex.
            for row in block.rows {
                body(LampBookTableLayout.placements(of: row, columnCount: columnCount).compactMap { placement in
                    placement.cell.map { Field(column: placement.column, text: $0.content, isCell: true) }
                })
            }
        case "image", "audio":
            if let caption = block.caption?.annotatedText { body([Field(text: caption)]) }
        case "figure":
            switch figures {
            case .asContent:
                // As the readers draw one today: they know no figures, and
                // draw a block of a type they do not know as its `content` —
                // the projection a compiler writes there of the figure's own
                // words (`RichModulesPlan.md`, step 5). Indexed from its
                // parts, a hit opened onto a figure drawn blank, and words
                // drawn were not found. Found by Codex.
                if let content = block.content { body([Field(text: content)]) }
            case .asParts:
                for head in [block.title, block.subtitle, block.caption].compactMap({ $0?.annotatedText }) {
                    body([Field(text: head)])
                }
                for child in block.children { forEachLine(of: child, figures: .asContent, body) }
                for note in block.notes { body([Field(text: note)]) }
            }
        case "thematic-break":
            break
        default:
            // Heading, paragraph, quotation, and any type a reader does not
            // know, which both draw as its content.
            if let content = block.content { body([Field(text: content)]) }
        }
    }

    private static func forEachLine(of item: LampBookListItem, _ body: ([Field]) -> Void) {
        body([Field(text: item.content, isCell: true)])
        for child in item.children { forEachLine(of: child, body) }
    }

    /// The section's drawn words, joined by spaces.
    ///
    /// A NUL in the words is a space here: bound as search text it ended the
    /// string there, and every word after it — a whole later paragraph — was
    /// lost from the index. Found by Codex.
    public static func text(of blocks: [LampBookContentBlock]) -> String {
        var words: [String] = []
        for block in blocks {
            forEachLine(of: block, figures: .asContent) { line in
                words += line.map(\.text.text).filter { !$0.isEmpty }
            }
        }
        return words.joined(separator: " ").replacingOccurrences(of: "\0", with: " ")
    }

    /// The words of a section's stored content, decoded block by block.
    public static func text(ofContentJSON json: String?) -> String {
        text(of: LampPortableBookJSON.decodeArray(json, as: LampBookContentBlock.self).items)
    }

    /// A figure's own words, as a reader that knows figures draws them: its
    /// title and second line, its caption, each child, then its notes. What
    /// a compiler projects into the figure's `content`.
    public static func figureText(of figure: LampBookContentBlock) -> String {
        words(lines(of: figure, figures: .asParts))
    }

    private static func words(_ lines: [[Field]]) -> String {
        lines.joined().map(\.text.text).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "\0", with: " ")
    }

    /// The blocks as one annotated text, for a reader that knows only one:
    /// their lines joined — blocks by `blockSeparator`, lines by
    /// `lineSeparator`, a row's cells by a `cellSeparator` for each column
    /// from one to the next — with each text's
    /// annotations and footnote references moved to where its words now
    /// start, and an annotation kept only where `keeping` says.
    ///
    /// Each annotation is clipped first, by the resolver's own bounds
    /// (`LampBookTextResolver.coveredScalars`, `markerOffset`,
    /// `pageMarker`), and only then moved: so resolving the projection
    /// draws what resolving each text and joining them would, and no offset
    /// from a file, however large, is added to anything. One that `resolve`
    /// leaves out is left out. Offsets count Unicode scalars, as the
    /// resolver's do. A NUL is kept: made a space here, the resolver spaced a
    /// page marker beside it otherwise than beside the NUL (found by Codex);
    /// search text, which a NUL would end, replaces it there. A text left with nothing in it once filtered and clipped — the
    /// empty default — adds nothing, not even a separator.
    public static func projection(
        of blocks: [LampBookContentBlock],
        figures: Figures,
        keeping: (LampBookAnnotation) -> Bool = { _ in true }
    ) -> LampBookAnnotatedText {
        // Appended to a `String`, the scalars counted beside it: appended to
        // a `UnicodeScalarView`, a long projection took time growing as its
        // square. Found by Codex.
        var projected = ""
        var length = 0
        var annotations: [LampBookAnnotation] = []
        var references: [LampBookFootnoteReference] = []
        func append(_ text: String) {
            projected += text
            length += text.unicodeScalars.count
        }
        // Each text as the resolver would draw it — annotations it keeps and
        // `resolve` applies, clipped; markers clamped — offsets still its
        // own. Judged empty only then, against the empty default: judged
        // before, an empty paragraph whose one page marker `keeping` refused
        // still added a paragraph break. Found by Codex.
        func kept(_ piece: LampBookAnnotatedText) -> LampBookAnnotatedText {
            let pieceLength = piece.text.unicodeScalars.count
            let annotations = piece.annotations.filter(keeping).compactMap { annotation -> LampBookAnnotation? in
                let covered: Range<Int>?
                if annotation.type == "page" {
                    // As its span where it covers words — an older
                    // commentary reader styles the printed label it covers,
                    // and `resolve` places the marker by its start alone.
                    // A span is kept whether or not it names a page; a point
                    // only if it draws a marker. Found by Codex.
                    covered = LampBookTextResolver.coveredScalars(annotation.start, annotation.end, length: pieceLength)
                        ?? LampBookTextResolver.pageMarker(annotation, length: pieceLength)
                            .map { $0.offset..<$0.offset }
                } else {
                    covered = LampBookTextResolver.coveredScalars(annotation.start, annotation.end, length: pieceLength)
                }
                return covered.map {
                    LampBookAnnotation(
                        type: annotation.type, start: $0.lowerBound, end: $0.upperBound,
                        text: annotation.text, data: annotation.data
                    )
                }
            }
            let references = piece.footnoteReferences.map {
                LampBookFootnoteReference(
                    id: $0.id, offset: LampBookTextResolver.markerOffset($0.offset, length: pieceLength)
                )
            }
            return LampBookAnnotatedText(text: piece.text, annotations: annotations, footnoteReferences: references)
        }
        let empty = LampBookAnnotatedText(text: "")
        var firstBlock = true
        for block in blocks {
            let blockLines = lines(of: block, figures: figures)
                .map { $0.map { Field(column: $0.column, text: kept($0.text), isCell: $0.isCell) }.filter { $0.text != empty } }
                .filter { !$0.isEmpty }
            guard !blockLines.isEmpty else { continue }
            if !firstBlock { append(blockSeparator) }
            firstBlock = false
            for (lineIndex, line) in blockLines.enumerated() {
                if lineIndex > 0 { append(lineSeparator) }
                // A cell separator for each column from the last field's to
                // this one's, so a row's words stay under their headings.
                var column = 0
                for field in line {
                    for _ in 0..<max(field.column - column, 0) { append(cellSeparator) }
                    column = field.column
                    let piece = field.text
                    // Clipped already, so only now moved: nothing from a
                    // file is added to.
                    let base = length
                    for annotation in piece.annotations {
                        annotations.append(LampBookAnnotation(
                            type: annotation.type, start: base + annotation.start, end: base + annotation.end,
                            text: annotation.text, data: annotation.data
                        ))
                    }
                    for reference in piece.footnoteReferences {
                        references.append(LampBookFootnoteReference(id: reference.id, offset: base + reference.offset))
                    }
                    append(field.isCell ? onOneLine(piece.text) : piece.text)
                }
            }
        }
        return LampBookAnnotatedText(
            text: projected, annotations: annotations, footnoteReferences: references
        )
    }
}
