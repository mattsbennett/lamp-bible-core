import Testing
@testable import LampCore

struct LampPersonalMarkdownDocumentTests {
    @Test func preservesMetadataKeysAndMultilineFootnotes() {
        let document = LampPersonalMarkdownDocument.frontmatter(in: """
            ---
            book: John
            bookNumber: 43
            title: "A: Title"
            ---
            ### 1:1
            Word[^one].

            ---

            [^one]: A note
                with another line
            """)
        #expect(document.metadata["bookNumber"] == "43")
        #expect(document.metadata["title"] == "A: Title")
        let extracted = LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: document.body)
        #expect(extracted.definitions["one"] == "A note\nwith another line")
        #expect(!extracted.body.contains("[^one]:"))
        let restored = LampPersonalMarkdownDocument.restoringFootnotes(
            in: "Word[^one].", definitions: extracted.definitions
        )
        #expect(restored.contains("[^one]: A note\n    with another line"))
    }

    @Test func leavesOrdinaryThematicBreakInBody() {
        let body = "First\n---\nSecond"
        let extracted = LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: body)
        #expect(extracted.body == body)
        #expect(extracted.definitions.isEmpty)
        let mixed = "First\n---\n[^one]: A note\nA closing paragraph"
        #expect(LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: mixed).body == mixed)
    }

    @Test func parsesNestedDevotionalFrontmatter() {
        let parsed = LampDevotionalFrontmatter(lines: [
            "title: \"Living Hope\"",
            "tags: [\"hope\", \"grace\"]",
            "series:",
            "  id: \"series-1\"",
            "  name: \"Daily Hope\"",
            "  order: 2",
            "keyScriptures:",
            "  - ref: \"John 1:1\"",
            "    sv: 43001001",
            "    ev: 43001002",
        ])
        #expect(parsed.values["title"] == "Living Hope")
        #expect(parsed.tags == ["hope", "grace"])
        #expect(parsed.series["name"] == "Daily Hope")
        #expect(parsed.series["order"] == "2")
        #expect(parsed.scriptures.first?.startReference == 43_001_001)
        #expect(parsed.scriptures.first?.endReference == 43_001_002)
    }
}
