import Foundation
import Testing
@testable import LampCore

/// Speaker notes derived from the manuscript, so the prose a speaker reads
/// stays right after the writing is edited.
struct LampPresentationManuscriptNotesTests {
    private let manuscript = """
    # Two Dials

    The first dial is capacity. It is the one we reach for, and the one that
    moves least.

    > A quoted line from someone else entirely.

    ## A heading nobody says aloud

    ---

    The second dial is *attention*. It costs nothing and changes everything[^1].

    - One item
    - Another item

    [^1]: A footnote nobody reads out.
    """

    private func deck(
        _ anchors: [(id: String, anchor: String?)],
        blocks: [String: [LampPresentationBlock]] = [:]
    ) -> LampPresentationDeck {
        LampPresentationDeck(
            title: "Two Dials",
            slides: anchors.map { entry in
                LampPresentationSlide(
                    id: entry.id,
                    layout: .titleAndBody,
                    blocks: blocks[entry.id] ?? [.init(kind: .body, text: "body")],
                    speakerNotes: "",
                    notesAnchor: entry.anchor
                )
            },
            speakerNotesSource: .manuscript
        )
    }

    // MARK: - Plain text

    @Test func keepsWhatIsSpokenAndDropsWhatIsNot() {
        let body = LampPresentationManuscriptNotes.plainText(fromMarkdown: manuscript)
        #expect(body.hasPrefix("The first dial is capacity."))
        #expect(!body.contains("Two Dials"), "the title is not spoken")
        #expect(!body.contains("A heading nobody says aloud"))
        #expect(!body.contains("---"))
        #expect(!body.contains("[^1]"))
        #expect(!body.contains("A footnote nobody reads out"))
        // A quotation and a list are spoken; their marks are not.
        #expect(body.contains("A quoted line from someone else entirely."))
        #expect(!body.contains("> A quoted"))
        #expect(body.contains("One item"))
        #expect(!body.contains("- One item"))
        // Emphasis marks go, the emphasised word stays.
        #expect(body.contains("The second dial is attention."))
    }

    @Test func readsATableAsItsCells() {
        let body = LampPresentationManuscriptNotes.plainText(fromMarkdown: """
        # Title

        | Dial | Effect |
        | --- | --- |
        | Capacity | Least |
        """)
        #expect(body.contains("Dial Effect"))
        #expect(body.contains("Capacity Least"))
        #expect(!body.contains("---"))
    }

    // MARK: - Resolving

    @Test func splitsTheManuscriptAtEachAnchor() {
        let subject = deck([
            ("title", nil),
            ("first", "The first dial is capacity"),
            ("second", "The second dial is attention"),
        ])
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: subject,
            manuscript: manuscript
        )
        #expect(resolution.problems.isEmpty, "\(resolution.problems)")
        #expect(resolution.notesBySlideID["title"] == nil, "an unanchored slide stays silent")
        let first = try! #require(resolution.notesBySlideID["first"])
        #expect(first.hasPrefix("The first dial is capacity."))
        #expect(first.contains("A quoted line"), "the passage runs to the next anchor")
        #expect(!first.contains("The second dial"))
        #expect(resolution.notesBySlideID["second"]?.contains("changes everything") == true)
    }

    /// The invariant the whole design rests on.
    @Test func theNotesTogetherAreTheManuscript() {
        let subject = deck([
            ("title", nil),
            ("first", "The first dial is capacity"),
            ("second", "The second dial is attention"),
        ])
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: subject,
            manuscript: manuscript
        )
        let joined = subject.slides
            .compactMap { resolution.notesBySlideID[$0.id] }
            .joined(separator: "\n\n")
        func comparable(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        #expect(
            comparable(joined)
                == comparable(LampPresentationManuscriptNotes.plainText(fromMarkdown: manuscript))
        )
    }

    @Test func keepsTheLastNotesWhenAnAnchorIsReworded() {
        var subject = deck([
            ("first", "The first dial is capacity"),
            ("second", "The second dial is attention"),
        ])
        subject.slides[1].speakerNotes = "What this slide said last time."

        var reworded = subject
        reworded.slides[1].notesAnchor = "The second dial is restraint"
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: reworded,
            manuscript: manuscript
        )
        #expect(resolution.problems.count == 1)
        #expect(resolution.problems.first?.slideID == "second")

        let applied = LampPresentationManuscriptNotes.applying(resolution, to: reworded)
        // A stale passage is more use to a speaker than a blank pane.
        #expect(applied.slides[1].speakerNotes == "What this slide said last time.")
        // And the passage it would have started reads on under the slide before.
        #expect(applied.slides[0].speakerNotes.contains("The second dial is attention"))
    }

    @Test func reportsAnAnchorThatCouldMeanTwoPlaces() {
        let repeated = """
        # Title

        The dial moves. Something else entirely.

        The dial moves. A different ending.
        """
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck([("only", "The dial moves")]),
            manuscript: repeated
        )
        guard case .anchorAmbiguous(_, _, let occurrences) = resolution.problems.first else {
            Issue.record("expected an ambiguous anchor, got \(resolution.problems)")
            return
        }
        #expect(occurrences == 2)
        // The first match still wins, so the notes are usable meanwhile.
        #expect(resolution.notesBySlideID["only"]?.hasPrefix("The dial moves.") == true)
    }

    @Test func reportsManuscriptNoSlideClaims() {
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck([("second", "The second dial is attention")]),
            manuscript: manuscript
        )
        #expect(resolution.problems.contains { problem in
            if case .textBeforeFirstAnchor = problem { return true }
            return false
        })
    }

    @Test func reportsADeckThatFollowsNothing() {
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck([("title", nil)]),
            manuscript: manuscript
        )
        #expect(resolution.problems == [.noAnchors])
    }

    @Test func matchesAcrossCurlyQuotesAndRewrappedLines() {
        let typeset = "# T\n\nThe speaker said \u{201C}enough\u{201D} and\nstopped there."
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck([("only", "The speaker said \"enough\" and stopped")]),
            manuscript: typeset
        )
        #expect(resolution.problems.isEmpty, "\(resolution.problems)")
        // The passage handed back is the prose as written, curls and all.
        #expect(resolution.notesBySlideID["only"]?.contains("\u{201C}enough\u{201D}") == true)
    }

    // MARK: - Quotation check

    @Test func findsAQuotationTheProseNoLongerSupports() {
        let subject = deck(
            [("first", "The first dial is capacity")],
            blocks: ["first": [
                .init(id: "kept", kind: .quotation, text: "It is the one we reach for"),
                .init(id: "stale", kind: .quotation, text: "It is the one we always ignore"),
            ]]
        )
        let stale = LampPresentationManuscriptNotes.staleQuotations(
            in: subject,
            manuscript: manuscript
        )
        #expect(stale.map(\.blockID) == ["stale"])
    }

    @Test func allowsASlideToShowMoreThanTheProseQuotes() {
        let subject = deck(
            [("first", "The first dial is capacity")],
            blocks: ["first": [
                .init(
                    id: "fuller",
                    kind: .quotation,
                    text: "Wording the prose never used at all",
                    manuscriptCheck: .skip
                ),
            ]]
        )
        #expect(LampPresentationManuscriptNotes.staleQuotations(
            in: subject,
            manuscript: manuscript
        ).isEmpty)
    }

    @Test func checksEitherSideOfAnEllipsisSeparately() {
        let subject = deck(
            [("first", "The first dial is capacity")],
            blocks: ["first": [
                .init(
                    id: "elided",
                    kind: .quotation,
                    text: "It is the one we reach for … and the one that moves least"
                ),
            ]]
        )
        // Whole, this never appears; in halves, both do.
        #expect(LampPresentationManuscriptNotes.staleQuotations(
            in: subject,
            manuscript: manuscript
        ).isEmpty)
    }

    @Test func leavesAReferencedScriptureBlockToTheStrongerCheck() {
        let subject = deck(
            [("first", "The first dial is capacity")],
            blocks: ["first": [
                .init(
                    id: "verse",
                    kind: .scripture,
                    text: "In the beginning was the Word, and the Word was with God.",
                    scriptureReference: .init(
                        translationID: "ESVs",
                        bookNumber: 43,
                        chapterNumber: 1,
                        startVerse: 1
                    )
                ),
            ]]
        )
        #expect(LampPresentationManuscriptNotes.staleQuotations(
            in: subject,
            manuscript: manuscript
        ).isEmpty)
    }
}
