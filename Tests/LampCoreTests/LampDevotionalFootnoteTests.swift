import Foundation
import Testing
@testable import LampCore

/// A devotional's markers and definitions were shown exactly as typed, so the
/// labels *were* the numbering: adding a footnote early in a talk with
/// thirty-five of them meant renumbering every later one by hand, twice over.
struct LampDevotionalFootnoteTests {
    @Test func numbersByTheOrderOfTheFirstReference() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Capacity[^lewis] has not changed[^2a], whatever is said[^lewis].",
            footnotes: """
            [^2a]: Mentioned second, defined first.
            [^lewis]: Lewis, *The Weight of Glory*, p. 26.
            """
        )

        #expect(numbered.footnotes.map(\.number) == [1, 2])
        #expect(numbered.footnotes.map(\.label) == ["lewis", "2a"])
        #expect(numbered.footnotes.first?.content == "Lewis, *The Weight of Glory*, p. 26.")
        // A repeated marker takes the number of its first appearance.
        #expect(numbered.content == "Capacity[^1] has not changed[^2], whatever is said[^1].")
    }

    /// The case from the talk: a footnote added at the front used to push every
    /// later label along by hand, in the prose and in the definitions.
    @Test func aFootnoteAddedAtTheFrontRenumbersTheRest() {
        let footnotes = """
        [^a]: The first note.
        [^b]: The second note.
        [^c]: A note added later, at the front.
        """
        let before = LampDevotionalFootnotes.numbered(
            content: "One[^a] and two[^b].",
            footnotes: footnotes
        )
        #expect(before.content == "One[^1] and two[^2].")

        let after = LampDevotionalFootnotes.numbered(
            content: "Nought[^c], one[^a] and two[^b].",
            footnotes: footnotes
        )
        #expect(after.content == "Nought[^1], one[^2] and two[^3].")
        #expect(after.footnotes.map(\.content) == [
            "A note added later, at the front.",
            "The first note.",
            "The second note.",
        ])
    }

    /// A note nothing refers to is still the writer's work, so it keeps its
    /// place after the ones that are referred to.
    @Test func keepsADefinitionNothingRefersTo() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Only this one[^b].",
            footnotes: """
            [^a]: Written but never cited.
            [^b]: Cited.
            """
        )
        #expect(numbered.footnotes.map(\.number) == [1, 2])
        #expect(numbered.footnotes.map(\.content) == ["Cited.", "Written but never cited."])
        #expect(numbered.content == "Only this one[^1].")
    }

    /// Silently dropping a marker with no definition would hide the mistake.
    @Test func leavesAMarkerWithNoDefinitionAsWritten() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Defined[^a], and not[^missing].",
            footnotes: "[^a]: Here."
        )
        #expect(numbered.content == "Defined[^1], and not[^missing].")
        #expect(numbered.footnotes.count == 1)
    }

    @Test func readsAnyLabelWithoutASpaceOrAClosingBracket() {
        // What a label may be is the one thing every platform has to agree on.
        // The editor on iOS looked for `\w+`, so a label like `pinker-48` was
        // shown there as typed and its note stayed in the prose.
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Vocabulary[^pinker-48], capacity[^lewis.26], and both[^a,b].",
            footnotes: """
            [^pinker-48]: Pinker, p. 48.
            [^lewis.26]: Lewis, p. 26.
            [^a,b]: Both of them.
            """
        )
        #expect(numbered.content == "Vocabulary[^1], capacity[^2], and both[^3].")
        #expect(numbered.footnotes.map(\.label) == ["pinker-48", "lewis.26", "a,b"])
    }

    @Test func doesNothingToWritingWithNoFootnotes() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Plain prose, with nothing to note.",
            footnotes: nil
        )
        #expect(numbered.content == "Plain prose, with nothing to note.")
        #expect(numbered.isEmpty)
        #expect(LampDevotionalFootnotes.displayContent(numbered) == numbered.content)
        #expect(LampDevotionalFootnotes.displayFootnotes(numbered).isEmpty)
    }

    @Test func keepsTheLinesOfADefinitionThatRunsOn() {
        let parsed = LampDevotionalFootnotes.definitions(in: """
        Written above the notes.

        [^a]: The first line.
            A second, indented line.
        [^b]: On its own.
        """)
        #expect(parsed.preamble == "Written above the notes.")
        #expect(parsed.definitions.map(\.label) == ["a", "b"])
        #expect(parsed.definitions.first?.content == "The first line.\n    A second, indented line.")
    }

    // MARK: - Shown to a reader

    @Test func setsAMarkerAsASuperscriptNumber() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: Array(repeating: "x", count: 0).joined()
                + (1...12).map { "Sentence \($0)[^n\($0)]." }.joined(separator: " "),
            footnotes: (1...12).map { "[^n\($0)]: Note \($0)." }.joined(separator: "\n")
        )
        let shown = LampDevotionalFootnotes.displayContent(numbered)
        #expect(shown.contains("Sentence 1¹."))
        #expect(shown.contains("Sentence 12¹²."))
        #expect(!shown.contains("[^"))

        let list = LampDevotionalFootnotes.displayFootnotes(numbered)
        #expect(list.hasPrefix("1. Note 1."))
        #expect(list.contains("12. Note 12."))
    }

    @Test func numbersEveryDigitAsASuperscript() {
        #expect(LampDevotionalFootnotes.superscript(1) == "¹")
        #expect(LampDevotionalFootnotes.superscript(35) == "³⁵")
        #expect(LampDevotionalFootnotes.superscript(1_024) == "¹⁰²⁴")
    }

    // MARK: - Clicking a marker

    /// A marker can be a link to its note, for a surface that can take a
    /// reader there. The writer's preview does; the exported document and
    /// anything else asking for plain markers is untouched by this.
    @Test func linksAMarkerToItsNoteWhenAsked() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Capacity[^lewis] has not changed[^2a].",
            footnotes: """
            [^2a]: Defined first.
            [^lewis]: Lewis, p. 26.
            """
        )

        #expect(
            LampDevotionalFootnotes.displayContent(numbered, linkingMarkers: true)
                == "Capacity[¹](lamp-footnote:1) has not changed[²](lamp-footnote:2)."
        )
        #expect(
            LampDevotionalFootnotes.displayContent(numbered)
                == "Capacity¹ has not changed².",
            "the plain form is what every other surface still gets"
        )
    }

    /// The link is read back by the view that drew it, so the two have to agree
    /// about more than one digit.
    @Test func readsTheFootnoteBackOutOfAMarkersLink() throws {
        for number in [1, 9, 10, 35, 1_024] {
            let url = try #require(URL(string: LampDevotionalFootnotes.markerURL(number: number)))
            #expect(LampDevotionalFootnotes.markerNumber(in: url) == number)
        }
    }

    /// Any other link in the writing is the writer's own and must be left to
    /// open as it would anywhere else.
    @Test func doesNotTakeAnOrdinaryLinkForAMarker() throws {
        for text in [
            "https://example.com/1",
            "lampbible://read?reference=John.3.16",
            "lamp-footnote:none",
        ] {
            let url = try #require(URL(string: text))
            #expect(LampDevotionalFootnotes.markerNumber(in: url) == nil)
        }
    }

    /// A marker nothing defines is left exactly as written, linked markers or
    /// not: there is no note to go to, and silently dropping it would hide the
    /// mistake.
    @Test func leavesAMarkerWithNoNoteUnlinked() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Defined[^a], not defined[^b].",
            footnotes: "[^a]: The one note."
        )

        #expect(
            LampDevotionalFootnotes.displayContent(numbered, linkingMarkers: true)
                == "Defined[¹](lamp-footnote:1), not defined[^b]."
        )
    }

    /// A footnote running to several lines is one note, so it reads as one item
    /// of the list it is drawn as.
    @Test func joinsADefinitionThatRunsOnIntoOneItem() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "A claim[^a].",
            footnotes: """
            [^a]: The source,
                and the page.
            """
        )
        #expect(LampDevotionalFootnotes.displayFootnotes(numbered) == "1. The source, and the page.")
    }

    // MARK: - Exported

    /// An exported document has to carry real Markdown footnotes, numbered the
    /// way the reader was shown them.
    @Test func exportsMarkdownFootnotesInReadingOrder() {
        let numbered = LampDevotionalFootnotes.numbered(
            content: "Capacity[^lewis] has not changed[^2a].",
            footnotes: """
            [^2a]: Defined first.
            [^lewis]: Lewis, p. 26.
            """
        )
        #expect(numbered.content == "Capacity[^1] has not changed[^2].")
        #expect(LampDevotionalFootnotes.exportedFootnotes(numbered) == """
        [^1]: Lewis, p. 26.

        [^2]: Defined first.
        """)
    }

    @Test func numbersTheFootnotesOfAnExportedDevotional() {
        let markdown = LampPersonalMarkdownWriter.devotionalEntry(
            LampMarkdownDevotionalEntry(
                title: "Two Dials",
                content: "Capacity[^lewis] has not changed[^2a].",
                footnotes: """
                [^2a]: Defined first.
                [^lewis]: Lewis, p. 26.
                """
            )
        )
        #expect(markdown.contains("Capacity[^1] has not changed[^2]."))
        #expect(markdown.contains("### Footnotes\n\n[^1]: Lewis, p. 26."))
        #expect(!markdown.contains("[^lewis]"))
    }
}
