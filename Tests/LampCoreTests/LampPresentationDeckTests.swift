import Foundation
import Testing
@testable import LampCore

@Suite("Presentation decks")
struct LampPresentationDeckTests {
    @Test("Starter decks are valid and round-trip through JSON")
    func starterRoundTrip() throws {
        let deck = LampPresentationDeck.starter(
            title: "Living Hope",
            subtitle: "A devotional",
            source: .init(kind: .devotional, id: "hope-1")
        )

        #expect(LampPresentationDeckValidator.validate(deck).isEmpty)
        let store = LampPresentationDeckStore(rootURL: FileManager.default.temporaryDirectory)
        let decoded = try store.decode(store.encoded(deck))
        #expect(decoded == deck)
        #expect(decoded.slides.count == 3)
        #expect(decoded.source?.id == "hope-1")
    }

    @Test("Body list formatting is semantic and round-trips through JSON")
    func bodyListRoundTrip() throws {
        var deck = LampPresentationDeck.starter(title: "Practices")
        deck.theme.typeface = "system-serif"
        deck.slides[1].blocks[1].text = "Pray\nListen\nRespond"
        deck.slides[1].blocks[1].listStyle = .ordered

        let store = LampPresentationDeckStore(rootURL: FileManager.default.temporaryDirectory)
        let data = try store.encoded(deck)
        let decoded = try store.decode(data)

        #expect(decoded.theme.typeface == "system-serif")
        #expect(decoded.slides[1].blocks[1].listStyle == .ordered)
        #expect(decoded.slides[1].blocks[1].text == "Pray\nListen\nRespond")
    }

    @Test("List formatting is limited to body content")
    func listValidation() {
        var deck = LampPresentationDeck.starter(title: "Practices")
        deck.slides[0].blocks[0].listStyle = .unordered

        let issues = LampPresentationDeckValidator.validate(deck)
        #expect(issues.contains { $0.path.hasSuffix("listStyle") && $0.severity == .error })
    }

    @Test("Structured scripture references round-trip with copied slide text")
    func scriptureReferenceRoundTrip() throws {
        let reference = LampPresentationScriptureReference(
            translationID: "NRSVue",
            bookNumber: 43,
            chapterNumber: 3,
            startVerse: 16,
            endVerse: 17
        )
        let deck = LampPresentationDeck(
            title: "Love",
            slides: [
                .init(
                    layout: .scripture,
                    blocks: [
                        .init(
                            kind: .scripture,
                            text: "For God so loved the world…",
                            scriptureReference: reference
                        ),
                        .init(kind: .citation, text: "John 3:16–17 (NRSVue)"),
                    ]
                ),
            ]
        )

        let store = LampPresentationDeckStore(rootURL: FileManager.default.temporaryDirectory)
        let decoded = try store.decode(store.encoded(deck))
        #expect(decoded.slides[0].blocks[0].scriptureReference == reference)
        #expect(decoded.slides[0].blocks[0].text == "For God so loved the world…")
    }

    @Test("Structured scripture references are validated")
    func scriptureReferenceValidation() {
        let deck = LampPresentationDeck(
            title: "Broken Reference",
            slides: [
                .init(
                    layout: .titleAndBody,
                    blocks: [
                        .init(
                            kind: .body,
                            text: "Not scripture",
                            scriptureReference: .init(
                                translationID: "",
                                bookNumber: 0,
                                chapterNumber: 0,
                                startVerse: 3,
                                endVerse: 2
                            )
                        ),
                    ]
                ),
            ]
        )

        let issues = LampPresentationDeckValidator.validate(deck)
        #expect(issues.contains { $0.path.hasSuffix("scriptureReference.translationID") })
        #expect(issues.contains { $0.path.hasSuffix("scriptureReference.bookNumber") })
        #expect(issues.contains { $0.path.hasSuffix("scriptureReference.chapterNumber") })
        #expect(issues.contains { $0.path.hasSuffix("scriptureReference") })
    }

    @Test("Validation reports structural and accessibility problems")
    func validation() {
        let sharedID = "duplicate"
        let deck = LampPresentationDeck(
            id: "",
            title: "",
            theme: .init(
                id: "broken",
                backgroundColor: "black",
                foregroundColor: "#FFFFFF",
                accentColor: "#FFFFFF"
            ),
            slides: [
                .init(
                    id: sharedID,
                    layout: .image,
                    blocks: [.init(kind: .image)]
                ),
                .init(id: sharedID, layout: .titleAndBody),
            ]
        )

        let issues = LampPresentationDeckValidator.validate(deck)
        #expect(issues.contains { $0.path == "id" && $0.severity == .error })
        #expect(issues.contains { $0.path == "title" && $0.severity == .error })
        #expect(issues.contains { $0.path == "theme.backgroundColor" })
        #expect(issues.contains { $0.path == "slides" && $0.message.contains("duplicated") })
        #expect(issues.contains { $0.path.hasSuffix("assetPath") })
        #expect(issues.contains { $0.path.hasSuffix("altText") && $0.severity == .warning })
        #expect(issues.contains { $0.path == "slides[1].blocks" })
    }

    @Test("The library deck store persists, lists, and removes decks")
    func storeLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        let later = LampPresentationDeck.starter(title: "Zion")
        let earlier = LampPresentationDeck.starter(title: "Abide")

        let savedURL = try store.save(later)
        try store.save(earlier)

        #expect(savedURL.pathExtension == "lampdeck")
        #expect(try store.deck(id: later.id) == later)
        #expect(try store.decks().map(\.title) == ["Abide", "Zion"])

        try store.delete(id: later.id)
        #expect(try store.deck(id: later.id) == nil)
    }
}
