import Foundation
import Testing
@testable import LampCore

/// A slide that reveals its content arrives with its first part and brings in
/// one more each click: a passage a block at a time with its citation last,
/// a list an item at a time, a contrast a column at a time.
struct LampPresentationRevealTests {
    private typealias Part = LampPresentationRevealPlan.Part

    @Test func aPassageArrivesAVerseAtATimeWithItsCitationLast() {
        let slide = LampPresentationSlide(
            layout: .scripture,
            blocks: [
                .init(id: "v1", kind: .scripture, text: "In the beginning was the Word,"),
                .init(id: "v2", kind: .scripture, text: "and the Word was with God,"),
                .init(id: "c", kind: .citation, text: "John 1:1 (ESV)"),
            ],
            reveal: .stepwise
        )
        let plan = slide.revealPlan
        #expect(plan.units == [[.block("v1")], [.block("v2"), .block("c")]])
        #expect(plan.stepCount == 1)
        #expect(!plan.isShown(.block("c"), atStep: 0))
        #expect(!plan.isShown(.block("v2"), atStep: 0))
        #expect(plan.isShown(.block("v2"), atStep: 1))
        // Everywhere but the presenter draws the whole slide.
        #expect(plan.isShown(.block("v2"), atStep: nil))
    }

    @Test func aListArrivesAnItemAtATimeUnderAHeadingThatIsAlwaysThere() {
        let slide = LampPresentationSlide(
            layout: .titleAndBody,
            blocks: [
                .init(id: "t", kind: .title, text: "Three dials"),
                .init(id: "l", kind: .body, text: "Capacity\nAttention\nTime", listStyle: .unordered),
            ],
            reveal: .stepwise
        )
        let plan = slide.revealPlan
        #expect(plan.stepCount == 2)
        #expect(plan.isShown(.block("t"), atStep: 0))
        #expect(plan.isShown(.listItem(block: "l", index: 0), atStep: 0))
        #expect(!plan.isShown(.listItem(block: "l", index: 2), atStep: 1))
        #expect(plan.isShown(.listItem(block: "l", index: 2), atStep: 2))
    }

    @Test func aContrastArrivesAColumnAtATime() {
        let slide = LampPresentationSlide(
            layout: .twoColumn,
            blocks: [
                .init(id: "t", kind: .title, text: "Two attitudes"),
                .init(id: "h1", kind: .subtitle, text: "Resignation"),
                .init(id: "q1", kind: .scripture, text: "We will not walk in it."),
                .init(id: "h2", kind: .subtitle, text: "Expectancy"),
                .init(id: "q2", kind: .scripture, text: "yet I shall again look upon your holy temple."),
            ],
            reveal: .stepwise
        )
        let plan = slide.revealPlan
        #expect(plan.units == [[.block("h1"), .block("q1")], [.block("h2"), .block("q2")]])
        #expect(plan.isShown(.block("t"), atStep: 0))
    }

    @Test func emphasisLightsOnALastStepOfItsOwnAndOnlyWhenThereIsSome() {
        let emphasised = LampPresentationBlock(
            id: "q", kind: .scripture, text: "On the third day there was a wedding",
            emphasis: [.init(text: "third day")]
        )
        let slide = LampPresentationSlide(layout: .scripture, blocks: [emphasised], revealsEmphasis: true)
        let plan = slide.revealPlan
        // One passage has nothing to reveal, but its emphasis still waits.
        #expect(plan.units.isEmpty)
        #expect(plan.stepCount == 1)
        #expect(!plan.isEmphasisLit(atStep: 0))
        #expect(plan.isEmphasisLit(atStep: 1))
        #expect(plan.isEmphasisLit(atStep: nil))

        var plain = slide
        plain.blocks[0].emphasis = nil
        #expect(plain.revealPlan.stepCount == 0)
    }

    @Test func aSlideWithOnePartOrAPictureArrivesWholeAndIsToldSo() throws {
        let one = LampPresentationSlide(
            layout: .quotation,
            blocks: [.init(kind: .quotation, text: "Nothing to be done.")],
            reveal: .stepwise
        )
        #expect(one.revealPlan.stepCount == 0)
        let deck = LampPresentationDeck(title: "Deck", slides: [one])
        let issues = LampPresentationDeckValidator.validate(deck)
        #expect(issues.contains { $0.path == "slides[0].reveal" && $0.severity == .warning })
    }

    @Test func aValueFromANewerLampOpensRatherThanFailingTheDeck() throws {
        let json = #"""
        {"schemaVersion":1,"id":"d","title":"Deck","aspectRatio":"widescreen",
         "theme":{"id":"lamp-dark","backgroundColor":"#111827","foregroundColor":"#F9FAFB","accentColor":"#F59E0B"},
         "transition":"spiral",
         "slides":[{"id":"s","layout":"blank","blocks":[],"speakerNotes":"","isHidden":false,"reveal":"cascade"}]}
        """#
        let deck = try JSONDecoder().decode(LampPresentationDeck.self, from: Data(json.utf8))
        #expect(deck.transition == .dissolve)
        #expect(deck.slides[0].reveal == .together)
    }

    @Test func absentFieldsAreLeftOutWhenWritten() throws {
        let deck = LampPresentationDeck(title: "Deck", slides: [.init(layout: .blank)])
        let written = String(decoding: try JSONEncoder().encode(deck), as: UTF8.self)
        #expect(!written.contains("transition"))
        #expect(!written.contains("reveal"))
    }
}

/// Forward brings in a part or the next slide; back takes one away or returns
/// to the previous slide complete.
struct LampPresentationPositionTests {
    private let slides = [
        LampPresentationSlide(
            layout: .titleAndBody,
            blocks: [.init(kind: .body, text: "One\nTwo\nThree", listStyle: .ordered)],
            reveal: .stepwise
        ),
        LampPresentationSlide(layout: .title, blocks: [.init(kind: .title, text: "End")]),
    ]

    @Test func forwardStepsThroughARevealThenOnToTheNextSlide() {
        var position = LampPresentationPosition()
        var visited: [LampPresentationPosition] = [position]
        while let next = position.advanced(in: slides) {
            position = next
            visited.append(next)
        }
        #expect(visited == [.init(slide: 0, step: 0), .init(slide: 0, step: 1),
                            .init(slide: 0, step: 2), .init(slide: 1, step: 0)])
    }

    @Test func backReturnsToThePreviousSlideAsItWasLeft() {
        let back = LampPresentationPosition(slide: 1, step: 0).retreated(in: slides)
        #expect(back == .init(slide: 0, step: 2))
        #expect(LampPresentationPosition().retreated(in: slides) == nil)
    }
}

/// Review findings: a stale emphasis entry is no step, and a list says which
/// of its items are held back.
struct LampPresentationRevealFindingsTests {
    @Test func emphasisThatNoLongerMatchesItsTextTakesNoClick() {
        let slide = LampPresentationSlide(
            layout: .scripture,
            blocks: [.init(kind: .scripture, text: "In the beginning", emphasis: [.init(text: "the Word")])],
            revealsEmphasis: true
        )
        #expect(slide.revealPlan.stepCount == 0)
    }

    @Test func aListSaysItsItemsArriveOneAtATime() {
        let slide = LampPresentationSlide(
            layout: .titleAndBody,
            blocks: [.init(id: "l", kind: .body, text: "One\nTwo", listStyle: .unordered)],
            reveal: .stepwise
        )
        #expect(slide.revealPlan.revealsItems(of: "l"))
        #expect(!LampPresentationRevealPlan.together.revealsItems(of: "l"))
    }
}

extension LampPresentationRevealFindingsTests {
    @Test func aChartsHeadingLightsNothing() {
        let chart = LampPresentationBlock(
            kind: .chart, text: "Where love is found", emphasis: [.init(text: "love")],
            chart: .init(source: .init(strongs: "G26", translationID: "ESV"), by: .book)
        )
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [chart], revealsEmphasis: true)
        #expect(slide.revealPlan.stepCount == 0)
    }
}

extension LampPresentationRevealFindingsTests {
    @Test func aCaptionWithNoPictureLightsNothing() {
        let slide = LampPresentationSlide(
            layout: .blank,
            blocks: [
                .init(kind: .body, text: "Plain words"),
                .init(kind: .caption, text: "A credit", emphasis: [.init(text: "credit")]),
            ],
            revealsEmphasis: true
        )
        #expect(slide.revealPlan.stepCount == 0)
    }
}
