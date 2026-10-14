import Testing
@testable import LampCore

struct LampPersonalMarkdownNotesTests {
    @Test func numberedFootnotesFollowMarkerOrderRatherThanDefinitionOrder() throws {
        let drafts = try LampPersonalMarkdownParser.notes(from: """
        ## John 1:1
        First[^second], then[^first].
        > [!footnote] first
        > Listed first.
        > [!footnote] second
        > Listed second.
        """, filename: "notes")
        let note = try #require(drafts.first).withNumberedFootnotes()
        #expect(note.content == "First[^1], then[^2].")
        #expect(note.footnotes.map(\.content) == ["Listed second.", "Listed first."])
    }

    @Test func renumberingRepeatedFootnotesDoesNotCascadeOrLoseUnknownMarkers() throws {
        let drafts = try LampPersonalMarkdownParser.notes(from: """
        ## John 1:1
        🌿 First[^7], second[^1], repeated[^7], unknown[^missing].
        ---
        [^7]: First definition.
        [^1]: Second definition.
        """, filename: "notes")
        let note = try #require(drafts.first).withNumberedFootnotes()
        #expect(note.content == "🌿 First[^1], second[^2], repeated[^1], unknown[^missing].")
        #expect(note.footnotes.map(\.id) == ["1", "2"])
        #expect(note.footnotes.map(\.content) == ["First definition.", "Second definition."])
    }

    @Test func invalidLaterRangeRejectsTheDocumentBeforeAnythingIsImported() {
        #expect(throws: LampLibraryError.self) {
            try LampPersonalMarkdownParser.notes(from: """
            ## John 1:1
            Valid note.
            ### 1:1000
            Must not be attached to the previous verse.
            """, filename: "notes")
        }
    }

    @Test func caseVariantsInFrontmatterCannotCrashTheImporter() throws {
        let drafts = try LampPersonalMarkdownParser.devotionals(from: """
        ---
        Title: Older title
        title: Canonical title
        ---
        A draft.
        """, filename: "draft")
        #expect(drafts.first?.title == "Canonical title")
    }

    @Test func multiBookImportKeepsRangesIntroductionsAndPerNoteFootnotes() throws {
        let drafts = try LampPersonalMarkdownParser.notes(from: """
        # My Notes

        ## John
        ### Chapter 1
        #### Introduction
        Opening[^intro].
        #### 1:1-2:3
        The Word[^word].

        ## Genesis
        ### Chapter 1
        #### 1:1
        Beginning.

        ---
        [^intro]: Introduction footnote.
        [^word]: Verse footnote.
            Second line.
        """, filename: "notes")
        try #require(drafts.count == 3)
        #expect(drafts.map(\.reference) == [43_001_000, 43_001_001, 1_001_001])
        #expect(drafts[1].verseReferences == [43_001_001, 43_002_003])
        #expect(drafts[0].footnotes.map(\.id) == ["intro"])
        #expect(drafts[1].footnotes.map(\.id) == ["word"])
        #expect(drafts[1].footnotes.first?.content == "Verse footnote.\nSecond line.")
        #expect(drafts[2].footnotes.isEmpty)
    }

    @Test func numericBookMetadataWorksWithoutARecognizableFilename() throws {
        let drafts = try LampPersonalMarkdownParser.notes(from: """
        ---
        bookNumber: 43
        ---
        ## Chapter 1
        ### 1:1
        A note.
        """, filename: "untitled")
        #expect(drafts.first?.reference == 43_001_001)
    }

    @Test func legacyCalloutsKeepTheIDsUsedByRepeatedMarkers() throws {
        let drafts = try LampPersonalMarkdownParser.notes(from: """
        ## John 1:1
        One[^7], again[^7], and an unresolved reference[^missing].

        > [!footnote] 7
        > First line.
        > Second line.
        """, filename: "notes")
        try #require(drafts.count == 1)
        #expect(drafts[0].content == "One[^7], again[^7], and an unresolved reference[^missing].")
        #expect(drafts[0].footnotes == [.init(id: "7", content: "First line.\nSecond line.")])
    }

    @Test func markdownExamplesCannotBecomeNotesOrFootnotes() throws {
        let content = """
        An example:
        ````markdown
        ### 1:2
        [^literal]: This is code.
        ### Footnotes
        - **literal:** Also code.
        ```
        Still inside the longer fence.
        ````
        Back in the note.
        """
        let drafts = try LampPersonalMarkdownParser.notes(
            from: "## John 1:1\n\(content)", filename: "notes"
        )
        try #require(drafts.count == 1)
        #expect(drafts[0].content == content)
        #expect(drafts[0].footnotes.isEmpty)
    }
}
