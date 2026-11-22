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
