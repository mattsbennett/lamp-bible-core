import Foundation
import Testing
@testable import LampCore

/// Passages under a title or closing heading: a verse left on screen before a
/// talk begins, or one to close on.
struct LampPresentationTitleEpigraphTests {
    private func titleSlide(
        _ layout: LampPresentationSlideLayout = .title,
        _ blocks: [LampPresentationBlock]
    ) -> LampPresentationSlide {
        LampPresentationSlide(layout: layout, blocks: blocks)
    }

    @Test("A title or closing slide draws the passages under its heading, each with its citation")
    func titleDrawsItsPassages() {
        for layout in [LampPresentationSlideLayout.title, .closing] {
            let plan = titleSlide(layout, [
                .init(kind: .title, text: "Has Mankind Evolved?"),
                .init(kind: .subtitle, text: "A talk"),
                .init(kind: .scripture, text: "But where shall wisdom be found?"),
                .init(kind: .citation, text: "Job 28:12 (ESV)"),
                .init(kind: .quotation, text: "Behold, the fear of the Lord, that is wisdom"),
                .init(kind: .citation, text: "Job 28:28 (ESV)"),
            ]).plan
            #expect(plan.title?.text == "Has Mankind Evolved?")
            #expect(plan.subtitle?.text == "A talk")
            #expect(plan.prose.map(\.kind) == [.scripture, .quotation])
            #expect(plan.quoteGroups.count == 2)
            #expect(plan.quoteGroups.map { $0.citation?.text } == ["Job 28:12 (ESV)", "Job 28:28 (ESV)"])
            #expect(plan.ignored.isEmpty)
        }
    }

    @Test("A title slide still draws one line under its heading, not two")
    func titleKeepsOneLine() {
        let plan = titleSlide(.title, [
            .init(kind: .title, text: "Title"),
            .init(kind: .subtitle, text: "One line"),
            .init(kind: .body, text: "Another"),
        ]).plan
        #expect(plan.subtitle?.text == "One line")
        #expect(plan.ignored.map(\.kind) == [.body])
    }

    @Test("The validator no longer reports a title slide's passages as undrawn")
    func validatorAcceptsAnEpigraph() {
        let deck = LampPresentationDeck(title: "Epigraph", slides: [
            titleSlide(.title, [
                .init(kind: .title, text: "Title"),
                .init(kind: .scripture, text: "But where shall wisdom be found?"),
                .init(kind: .citation, text: "Job 28:12 (ESV)"),
            ]),
        ])
        let messages = LampPresentationDeckValidator.validate(deck).map(\.message)
        #expect(!messages.contains { $0.contains("does not draw") })
    }

    @Test("Two passages sharing one citation under a title are named, as elsewhere")
    func sharedCitationIsNamed() {
        let deck = LampPresentationDeck(title: "Epigraph", slides: [
            titleSlide(.title, [
                .init(kind: .title, text: "Title"),
                .init(kind: .scripture, text: "But where shall wisdom be found?"),
                .init(kind: .scripture, text: "Behold, the fear of the Lord, that is wisdom"),
                .init(kind: .citation, text: "Job 28 (ESV)"),
            ]),
        ])
        let messages = LampPresentationDeckValidator.validate(deck).map(\.message)
        #expect(messages.contains { $0.contains("share one citation") })
    }

    @Test("Passages under a title have about half a slide's room before they crowd it")
    func epigraphCrowdsSooner() {
        let long = String(repeating: "wisdom ", count: 80)
        let underTitle = LampPresentationDeck(title: "Epigraph", slides: [
            titleSlide(.title, [
                .init(kind: .title, text: "Title"),
                .init(kind: .scripture, text: long),
                .init(kind: .citation, text: "Job 28 (ESV)"),
            ]),
        ])
        #expect(LampPresentationDeckValidator.validate(underTitle).map(\.message)
            .contains { $0.contains("under this slide's title") })

        let onItsOwn = LampPresentationDeck(title: "Epigraph", slides: [
            LampPresentationSlide(layout: .scripture, blocks: [
                .init(kind: .scripture, text: long),
                .init(kind: .citation, text: "Job 28 (ESV)"),
            ]),
        ])
        #expect(!LampPresentationDeckValidator.validate(onItsOwn).map(\.message)
            .contains { $0.contains("characters of text") })
    }
}
