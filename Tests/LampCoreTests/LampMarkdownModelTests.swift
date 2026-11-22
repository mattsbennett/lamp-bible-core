import Foundation
import Testing

@testable import LampCore

/// The document model's ranges, and above all the conversion into
/// them.
///
/// swift-markdown reports a line and a UTF-8 column; `NSRange` counts
/// UTF-16. A Hebrew letter is two UTF-16 units and two UTF-8 bytes, an
/// emoji two UTF-16 units and four UTF-8 bytes, so assuming any of
/// those equal moves every range on a line after the first such
/// character. These check the ranges by slicing the text with them and
/// reading what comes out, rather than by asserting numbers.
struct LampMarkdownModelTests {
    private func slice(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    @Test func emphasisAndStrongCarryTheirDelimitersAndContent() {
        let text = "Her **red dog** and *cat* here."
        let model = LampMarkdownModel(parsing: text)
        let strong = try! #require(model.inlines.first { $0.kind == .strong })
        #expect(slice(strong.range, of: text) == "**red dog**")
        #expect(slice(strong.content, of: text) == "red dog")
        let emphasis = try! #require(model.inlines.first { $0.kind == .emphasis })
        #expect(slice(emphasis.range, of: text) == "*cat*")
        #expect(slice(emphasis.content, of: text) == "cat")
    }

    /// Hebrew: two UTF-16 units per letter and two UTF-8 bytes, so the
    /// counts differ from ASCII in both directions at once.
    @Test func hebrewBeforeAnEmphasisDoesNotMoveIt() {
        let text = "בראשית **word** here"
        let model = LampMarkdownModel(parsing: text)
        let strong = try! #require(model.inlines.first { $0.kind == .strong })
        #expect(
            slice(strong.range, of: text) == "**word**",
            "got \(slice(strong.range, of: text).debugDescription)"
        )
        #expect(slice(strong.content, of: text) == "word")
    }

    /// An emoji: one Character, two UTF-16 units, four UTF-8 bytes.
    @Test func anastralCharacterBeforeAnEmphasisDoesNotMoveIt() {
        let text = "🕯️ a **word** here"
        let model = LampMarkdownModel(parsing: text)
        let strong = try! #require(model.inlines.first { $0.kind == .strong })
        #expect(
            slice(strong.range, of: text) == "**word**",
            "got \(slice(strong.range, of: text).debugDescription)"
        )
    }

    /// And on a later line, where the line's own start must be right
    /// as well as the column.
    @Test func alaterLineAfterWideCharactersIsStillRight() {
        let text = "בראשית ברא אלהים\n\nThen **word** here"
        let model = LampMarkdownModel(parsing: text)
        let strong = try! #require(model.inlines.first { $0.kind == .strong })
        #expect(slice(strong.range, of: text) == "**word**")
    }

    @Test func codeIsFoundAndKnown() {
        let text = "Run `curl x` now\n\n```sh\ninside\n```"
        let model = LampMarkdownModel(parsing: text)
        let span = try! #require(model.inlines.first { $0.kind == .inlineCode })
        #expect(slice(span.range, of: text) == "`curl x`")
        #expect(model.isInCode((text as NSString).range(of: "curl").location))
        #expect(model.isInCode((text as NSString).range(of: "inside").location))
        #expect(!model.isInCode((text as NSString).range(of: "now").location))
    }

    @Test func alinkCarriesItsLabelAsContent() {
        let text = "See [the note](https://x.com/a) now."
        let model = LampMarkdownModel(parsing: text)
        let link = try! #require(model.inlines.first { $0.kind == .link })
        #expect(slice(link.content, of: text) == "the note")
        #expect(slice(link.range, of: text) == "[the note](https://x.com/a)")
    }

    @Test func blocksCarryTheirKinds() {
        let text = "# Title\n\n- item\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let model = LampMarkdownModel(parsing: text)
        let kinds = Set(model.blocks.map(\.kind))
        #expect(kinds.contains(.heading))
        #expect(kinds.contains(.listItem))
        #expect(kinds.contains(.blockQuote))
        #expect(kinds.contains(.table))
        #expect(kinds.contains(.tableCell))
    }

    /// The delimiters of a span, which is what a clear needs.
    @Test func delimitersAreTheRunsEitherSide() {
        let text = "a **bold** b"
        let model = LampMarkdownModel(parsing: text)
        let strong = try! #require(model.inlines.first { $0.kind == .strong })
        let (opening, closing) = strong.delimiters
        #expect(slice(opening, of: text) == "**")
        #expect(slice(closing, of: text) == "**")
    }
}

/// Where a table begins.
///
/// cmark-gfm starts a table's source position at the paragraph above
/// it, and gives the head row and that row's cells the same wrong
/// line — so nothing inside the table can be used to find its start.
/// The end is right, and a table is one line per row plus the
/// alignment row, so the first line is counted back from the last.
///
/// All five cases are the iOS session's, from taking their own rescan
/// out of the Files reader because every hand-written version misread
/// something.
struct LampMarkdownTableStartTests {
    private func slice(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    private static let cases: [(name: String, text: String)] = [
        ("a table between two paragraphs", "After.\n| A | B |\n|:--|--:|\n| 1 | 2 |\nEnd."),
        ("a tab in the alignment row", "paragraph\n| A | B |\n| ---\t| --- |\n| x | y |"),
        ("a colon line above", "paragraph\n: - :\n| A | B |\n|--|--|\n| x | y |"),
        ("an indented dash line above", "foo\n    --\n| A | B |\n|--|--|\n| x | y |"),
        ("a form feed in the alignment row", "intro\n| A | B |\n|---\u{0C}|---|\n|x|y|"),
    ]

    @Test("a table begins at its head row", arguments: cases)
    func atableBeginsAtItsHeadRow(_ example: (name: String, text: String)) {
        let model = LampMarkdownModel(parsing: example.text)
        let table = model.blocks.first { $0.kind == .table }
        let got = table.map { slice($0.range, of: example.text) }
        #expect(
            got?.hasPrefix("|") == true,
            """
            \(example.name): the table starts at the prose above it — \
            \(got?.prefix(40).debugDescription ?? "no table")
            """
        )
    }

    /// And no cell is left claiming a position outside its table.
    @Test("no cell sits outside its table", arguments: cases)
    func nocellSitsOutsideItsTable(_ example: (name: String, text: String)) {
        let model = LampMarkdownModel(parsing: example.text)
        guard let table = model.blocks.first(where: { $0.kind == .table }) else { return }
        for cell in model.blocks where cell.kind == .tableCell {
            #expect(
                cell.range.location >= table.range.location,
                "\(example.name): a cell at \(cell.range.location) before the table"
            )
        }
    }
}
