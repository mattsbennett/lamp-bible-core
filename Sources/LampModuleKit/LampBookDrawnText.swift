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
    /// The section's drawn words, joined by spaces.
    ///
    /// A NUL in the words is a space here: bound as search text it ended the
    /// string there, and every word after it — a whole later paragraph — was
    /// lost from the index. Found by Codex.
    public static func text(of blocks: [LampBookContentBlock]) -> String {
        blocks.flatMap(pieces).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "\0", with: " ")
    }

    /// The words of a section's stored content, decoded block by block.
    public static func text(ofContentJSON json: String?) -> String {
        text(of: LampPortableBookJSON.decodeArray(json, as: LampBookContentBlock.self).items)
    }

    private static func pieces(_ block: LampBookContentBlock) -> [String] {
        switch block.type {
        case "list":
            return block.items.flatMap(pieces)
        case "table":
            let columnCount = LampBookTableLayout.resolvedColumnCount(
                declared: block.columnCount, rows: block.rows
            )
            return block.rows.flatMap { row in
                LampBookTableLayout.placements(of: row, columnCount: columnCount)
                    .compactMap { $0.cell?.content.text }
            }
        case "image", "audio":
            return [block.caption?.text].compactMap { $0 }
        case "figure":
            // As the readers draw one today: they know no figures, and draw
            // a block of a type they do not know as its `content` — the
            // projection a compiler writes there of the figure's own words
            // (`RichModulesPlan.md`, step 5). Indexed from its parts, a hit
            // opened onto a figure drawn blank, and words drawn were not
            // found. Found by Codex. The parts are `figureText`'s.
            return [block.content?.text].compactMap { $0 }
        case "thematic-break":
            return []
        default:
            // Heading, paragraph, quotation, and any type a reader does not
            // know, which both draw as its content.
            return [block.content?.text].compactMap { $0 }
        }
    }

    /// A figure's own words, as a reader that knows figures draws them: its
    /// title and second line, its caption, each child, then its notes. What
    /// a compiler projects into the figure's `content`.
    public static func figureText(of figure: LampBookContentBlock) -> String {
        ([figure.title?.text, figure.subtitle?.text, figure.caption?.text].compactMap { $0 }
            + figure.children.flatMap(pieces)
            + figure.notes.map(\.text))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\0", with: " ")
    }

    private static func pieces(_ item: LampBookListItem) -> [String] {
        [item.content.text] + item.children.flatMap(pieces)
    }
}
