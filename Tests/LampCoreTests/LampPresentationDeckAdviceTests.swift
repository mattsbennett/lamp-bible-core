import Foundation
import Testing
@testable import LampCore

/// The validator's job is not only to refuse malformed decks but to say what a
/// slide will not show. A deck author who is not told has to read the renderer
/// to find out, which is how a cover image ended up on its own slide and a
/// source ended up repeated as a body line.
struct LampPresentationDeckAdviceTests {
    private func deck(_ slides: [LampPresentationSlide]) -> LampPresentationDeck {
        LampPresentationDeck(title: "Advice", slides: slides)
    }

    private func warnings(_ slides: [LampPresentationSlide]) -> [String] {
        LampPresentationDeckValidator.validate(deck(slides))
            .filter { $0.severity == .warning }
            .map(\.message)
    }

    @Test func namesABlockTheLayoutWillNotDraw() {
        let messages = warnings([
            .init(layout: .scripture, blocks: [
                .init(kind: .title, text: "A heading"),
                .init(kind: .scripture, text: "In the beginning was the Word."),
            ]),
        ])
        #expect(messages.contains { $0.contains("does not draw title content") })
        #expect(messages.contains { $0.contains("without a heading") })
    }

    @Test func acceptsAQuotationBlockOnAScriptureSlide() {
        // The two are the same role, so neither is dropped and neither is
        // worth warning about.
        let messages = warnings([
            .init(layout: .scripture, blocks: [
                .init(kind: .quotation, text: "A quoted line."),
                .init(kind: .citation, text: "John 1:1"),
            ]),
        ])
        #expect(!messages.contains { $0.contains("does not draw") })
    }

    @Test func namesAThirdColumnAndAStrandedCaption() {
        let columns = warnings([
            .init(layout: .twoColumn, blocks: [
                .init(kind: .title, text: "Two ideas"),
                .init(kind: .body, text: "First"),
                .init(kind: .body, text: "Second"),
                .init(kind: .body, text: "Third"),
            ]),
        ])
        #expect(columns.contains { $0.contains("beyond its first two columns") })

        let caption = warnings([
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Body"),
                .init(kind: .caption, text: "A caption with no picture"),
            ]),
        ])
        #expect(caption.contains { $0.contains("without an image to caption") })
    }

    @Test func leavesAWellFormedSlideAlone() {
        let messages = warnings([
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "One focused idea."),
                .init(kind: .citation, text: "A source"),
                .init(kind: .image, assetPath: "Assets/a.png", altText: "A picture"),
                .init(kind: .caption, text: "Captioned"),
            ]),
        ])
        #expect(messages.isEmpty, "unexpected warnings: \(messages)")
    }

    @Test func namesAnOverfullSlide() {
        // Past what a 42pt quotation fits on a 1,600 x 900 slide.
        let dense = String(repeating: "Every word here is competing for the same room. ", count: 22)
        let plain = warnings([
            .init(layout: .scripture, blocks: [.init(kind: .scripture, text: dense)]),
        ])
        #expect(plain.contains { $0.contains("shrinks to fit") })

        // The same text beside an image is tighter still, and is named at a
        // lower threshold.
        let halved = String(repeating: "Competing for half the room. ", count: 20)
        let beside = warnings([
            .init(layout: .quotation, blocks: [
                .init(kind: .quotation, text: halved),
                .init(kind: .image, assetPath: "Assets/a.png", altText: "A picture"),
            ]),
        ])
        #expect(beside.contains { $0.contains("left by its image") })
    }

    @Test func namesAThemeNobodyCanRead() {
        var faint = LampPresentationDeck(title: "Faint", slides: [
            .init(layout: .blank, blocks: [.init(kind: .body, text: "text")]),
        ])
        faint.theme = LampPresentationTheme(
            id: "faint",
            backgroundColor: "#FFFFFF",
            foregroundColor: "#EFEFEF",
            accentColor: "#F4F4F4"
        )
        let messages = LampPresentationDeckValidator.validate(faint)
            .filter { $0.severity == .warning }
            .map(\.message)
        #expect(messages.contains { $0.contains("contrasts with the background") })

        // The built-in dark theme is comfortably readable.
        let readable = LampPresentationDeckValidator.validate(deck([
            .init(layout: .blank, blocks: [.init(kind: .body, text: "text")]),
        ]))
        #expect(!readable.contains { $0.message.contains("contrasts with the background") })
    }

    @Test func reportsAnImageThatWasNeverDelivered() {
        let subject = deck([
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/missing.png", altText: "A picture"),
            ]),
        ])
        let present = LampPresentationDeckValidator.validate(subject) { _ in true }
        #expect(!present.contains { $0.message.contains("No file at") })

        let absent = LampPresentationDeckValidator.validate(subject) { _ in false }
        #expect(absent.contains { $0.message.contains("No file at 'Assets/missing.png'") })
        // Still only a warning: the slide renders a placeholder rather than failing.
        #expect(LampPresentationDeckValidator.errors(in: subject).isEmpty)
    }
}
