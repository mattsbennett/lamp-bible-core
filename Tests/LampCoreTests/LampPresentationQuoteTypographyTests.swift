import Foundation
import Testing
@testable import LampCore

/// Quotation marks and ellipses follow from a block's role, so an author types
/// the words and Lamp sets them. Every case here is from a real deck.
struct LampPresentationQuoteTypographyTests {
    @Test(arguments: [
        // Begins mid-sentence, ends complete.
        (
            "it would probably be better to say that we are more modern, which is hardly surprising!",
            "\u{201C}\u{2026}it would probably be better to say that we are more modern, which is hardly surprising!\u{201D}"
        ),
        // A middle ellipsis the author typed is left where it is.
        (
            "then the LORD God formed the man of dust \u{2026} a living creature.",
            "\u{201C}\u{2026}then the LORD God formed the man of dust \u{2026} a living creature.\u{201D}"
        ),
        // Ends on a word: cut short, so it closes with an ellipsis.
        (
            "sin came into the world through one man, \u{2026} because all sinned",
            "\u{201C}\u{2026}sin came into the world through one man, \u{2026} because all sinned\u{2026}\u{201D}"
        ),
        (
            "our Savior Christ Jesus, who abolished death \u{2026} through the gospel",
            "\u{201C}\u{2026}our Savior Christ Jesus, who abolished death \u{2026} through the gospel\u{2026}\u{201D}"
        ),
        // A quotation inside a quotation steps down a level.
        (
            "And he said to man, \"Behold, the fear of the Lord, that is wisdom, and to turn away from evil is understanding.\"",
            "\u{201C}And he said to man, \u{2018}Behold, the fear of the Lord, that is wisdom, and to turn away from evil is understanding.\u{2019}\u{201D}"
        ),
        (
            "\"For God knows \u{2026} knowing good and evil.\" So when the woman saw \u{2026} and he ate.",
            "\u{201C}\u{2018}For God knows \u{2026} knowing good and evil.\u{2019} So when the woman saw \u{2026} and he ate.\u{201D}"
        ),
        // Three typed dots become one character, and count as a leading ellipsis.
        (
            "...cannot be sought from machines.",
            "\u{201C}\u{2026}cannot be sought from machines.\u{201D}"
        ),
        // A complete sentence gains nothing but its marks.
        (
            "Once AI started to solve them, there is no point anymore.",
            "\u{201C}Once AI started to solve them, there is no point anymore.\u{201D}"
        ),
        (
            "Such \u{201C}wisdom of the heart\u{201D}... \u{201C}cannot be sought from machines.\u{201D}",
            "\u{201C}Such \u{2018}wisdom of the heart\u{2019}\u{2026} \u{2018}cannot be sought from machines.\u{2019}\u{201D}"
        ),
    ])
    func setsAQuotationAsTheDeckIntended(stored: String, drawn: String) {
        #expect(LampPresentationQuoteTypography.displayText(stored) == drawn)
    }

    @Test func takesOffMarksTheAuthorTypedRatherThanDoublingThem() {
        #expect(
            LampPresentationQuoteTypography.displayText("\u{201C}A whole sentence.\u{201D}")
                == "\u{201C}A whole sentence.\u{201D}"
        )
        #expect(
            LampPresentationQuoteTypography.displayText("\"A whole sentence.\"")
                == "\u{201C}A whole sentence.\u{201D}"
        )
    }

    @Test func keepsMarksThatBelongToTheText() {
        // Opens and closes with a mark, but they are not a pair: there is a
        // third between them, so the text is two speakers, not one quotation.
        let stored = "\"First speaker,\" and then \"second speaker.\""
        let drawn = LampPresentationQuoteTypography.displayText(stored)
        #expect(drawn.hasPrefix("\u{201C}\u{2018}First speaker"))
        #expect(drawn.hasSuffix("second speaker.\u{2019}\u{201D}"))
    }

    @Test func dropsPunctuationThatOnlyMarksTheCut() {
        // A trailing comma is where the excerpt was severed; the ellipsis says
        // so better than the comma does.
        #expect(
            LampPresentationQuoteTypography.displayText("He went up to the mountain,")
                == "\u{201C}He went up to the mountain\u{2026}\u{201D}"
        )
        #expect(
            LampPresentationQuoteTypography.displayText("and so he waited \u{2014}")
                == "\u{201C}\u{2026}and so he waited\u{2026}\u{201D}"
        )
    }

    @Test func leavesAScriptWithoutCaseAlone() {
        // Hebrew has no lowercase, so nothing here says "mid-sentence".
        let hebrew = "\u{05D1}\u{05B0}\u{05BC}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05C1}\u{05B4}\u{05D9}\u{05EA}."
        #expect(
            LampPresentationQuoteTypography.displayText(hebrew)
                == "\u{201C}" + hebrew + "\u{201D}"
        )
    }

    @Test func leavesEmptyTextAlone() {
        #expect(LampPresentationQuoteTypography.displayText("") == "")
        #expect(LampPresentationQuoteTypography.displayText("   ") == "   ")
    }

    @Test func appliesOnlyWhereAQuotationIsDrawnAsOne() {
        let quotation = LampPresentationBlock(kind: .quotation, text: "words")
        let body = LampPresentationBlock(kind: .body, text: "words")
        let verbatim = LampPresentationBlock(kind: .quotation, text: "words", typography: .verbatim)

        #expect(LampPresentationQuoteTypography.applies(to: quotation, layout: .quotation))
        #expect(LampPresentationQuoteTypography.applies(to: quotation, layout: .scripture))
        #expect(LampPresentationQuoteTypography.applies(to: quotation, layout: .titleAndBody))
        // Where an author types what they mean, nothing is added.
        #expect(!LampPresentationQuoteTypography.applies(to: quotation, layout: .twoColumn))
        #expect(!LampPresentationQuoteTypography.applies(to: quotation, layout: .blank))
        #expect(!LampPresentationQuoteTypography.applies(to: body, layout: .quotation))
        #expect(!LampPresentationQuoteTypography.applies(to: verbatim, layout: .quotation))
    }

    @Test func curlsTheStraightMarksScriptureIsStoredWith() {
        // An installed translation stores typewriter punctuation, and a verse
        // inserted from Slide Studio carries it onto the slide unchanged.
        #expect(
            LampPresentationQuoteTypography.displayText("Cain's offering he had no regard.")
                == "\u{201C}Cain\u{2019}s offering he had no regard.\u{201D}"
        )
        #expect(
            LampPresentationQuoteTypography.displayText("And they shall not teach, 'Know the LORD,' for they shall all know me.")
                == "\u{201C}And they shall not teach, \u{2018}Know the LORD,\u{2019} for they shall all know me.\u{201D}"
        )
    }

    @Test func readsAStraightMarkFromWhatPrecedesIt() {
        // Opening after a bracket, closing before one.
        #expect(
            LampPresentationQuoteTypography.displayText("He answered ('yes') and left.")
                == "\u{201C}He answered (\u{2018}yes\u{2019}) and left.\u{201D}"
        )
        // A mark starting the text opens.
        #expect(
            LampPresentationQuoteTypography.displayText("'Enough,' he said.")
                == "\u{201C}\u{2018}Enough,\u{2019} he said.\u{201D}"
        )
    }

    @Test func leavesACurledApostropheAlone() {
        #expect(
            LampPresentationQuoteTypography.displayText("Cain\u{2019}s offering.")
                == "\u{201C}Cain\u{2019}s offering.\u{201D}"
        )
    }

    /// The new fields are optional additions to schema 1, so they have to
    /// survive a round trip through the stored file without a custom coder.
    @Test func theNewFieldsSurviveTheFile() throws {
        let deck = LampPresentationDeck(
            title: "Round trip",
            source: .init(kind: .devotional, id: "abc"),
            slides: [
                .init(
                    layout: .quotation,
                    blocks: [
                        .init(
                            kind: .quotation,
                            text: "words",
                            manuscriptCheck: .skip,
                            typography: .verbatim
                        ),
                    ],
                    notesAnchor: "The first dial"
                ),
            ],
            speakerNotesSource: .manuscript
        )
        let data = try LampPresentationDeckStore.encodedUnvalidated(deck)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"speakerNotesSource\" : \"manuscript\""))
        #expect(json.contains("\"notesAnchor\""))
        #expect(json.contains("\"typography\" : \"verbatim\""))

        let read = try LampPresentationDeckStore.decodeUnvalidated(data)
        #expect(read.followsManuscript)
        #expect(read.slides.first?.notesAnchor == "The first dial")
        #expect(read.slides.first?.blocks.first?.typography == .verbatim)
        #expect(read.slides.first?.blocks.first?.manuscriptCheck == .skip)
        #expect(read == deck)
    }
}
