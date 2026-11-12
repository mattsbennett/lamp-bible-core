import Foundation
@testable import LampCore
import LampModuleKit
import Testing

/// The document one of the reader's highlight sets travels as.
///
/// The odd one of the three personal kinds: notes and writings cross as the
/// whole collection written directly as SQLite, while a highlight set
/// crosses as one file per set, authored as portable JSON and compiled. So
/// the thing two apps have to agree on here is the **document** — which
/// fields, under which names, and which of them are left out when there is
/// nothing to say.
struct LampPersonalHighlightsFileTests {
    private func highlight(
        _ reference: Int, _ start: Int, _ end: Int, color: String? = "#ffcc00"
    ) -> LampVerseHighlight {
        LampVerseHighlight(
            id: Int64(reference &+ start), setID: "set", translationID: "ESV",
            reference: reference, startOffset: start, endOffset: end,
            style: .highlight, color: color
        )
    }

    private func object(_ document: [String: Any], _ key: String) -> [String: Any] {
        document[key] as? [String: Any] ?? [:]
    }

    @Test func theDocumentNamesTheSetAndItsSpans() throws {
        let document = try LampPersonalHighlightsFile.document(for: .init(
            id: "personal-highlights:ESV",
            moduleID: "esvs-highlights",
            name: "Mine",
            translationID: "ESV",
            description: "A set",
            created: 1_700_000_000,
            lastModified: 1_700_000_001,
            highlights: [highlight(43_003_016, 0, 3), highlight(43_001_001, 4, 9)],
            themes: [LampHighlightTheme(
                setID: "set", color: "#ffcc00", style: .highlight,
                name: "Promise", description: nil
            )]
        ))

        let meta = object(document, "meta")
        #expect(meta["id"] as? String == "esvs-highlights", "the module's id, not the set's")
        #expect(meta["type"] as? String == "highlights")
        #expect(meta["translationId"] as? String == "ESV")
        #expect(meta["created"] as? Int == 1_700_000_000)
        #expect(meta["lastModified"] as? Int == 1_700_000_001)

        // A theme with no description leaves the key out, not an empty one.
        let themes = meta["themes"] as? [[String: Any]] ?? []
        #expect(themes.count == 1)
        #expect(themes[0]["name"] as? String == "Promise")
        #expect(themes[0]["description"] == nil)

        // Verses in reference order, whatever order the highlights arrived in.
        let verses = document["verses"] as? [[String: Any]] ?? []
        #expect(verses.map { $0["ref"] as? Int } == [43_001_001, 43_003_016])
        let spans = verses[0]["highlights"] as? [[String: Any]] ?? []
        #expect(spans[0]["sc"] as? Int == 4)
        #expect(spans[0]["ec"] as? Int == 9)
        #expect(spans[0]["color"] as? String == "#ffcc00")
    }

    /// Silence and emptiness are different claims, and a reader that cannot
    /// tell them apart writes one device's description over the other's
    /// having none. So a field with nothing to say is **absent**.
    @Test func aFieldWithNothingToSayIsLeftOut() throws {
        let document = try LampPersonalHighlightsFile.document(for: .init(
            id: "set", moduleID: "m", name: "Mine", translationID: "ESV",
            highlights: [highlight(43_003_016, 0, 3, color: nil)]
        ))
        let meta = object(document, "meta")
        #expect(meta["description"] == nil)
        #expect(meta["created"] == nil)
        #expect(meta["lastModified"] == nil)
        #expect(meta["themes"] == nil, "no themes at all, rather than an empty list")

        let verses = document["verses"] as? [[String: Any]] ?? []
        let spans = verses[0]["highlights"] as? [[String: Any]] ?? []
        #expect(spans[0]["color"] == nil, "a span with no colour of its own takes the theme's")
    }
}
