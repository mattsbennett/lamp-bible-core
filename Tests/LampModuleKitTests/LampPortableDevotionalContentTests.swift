import Foundation
import Testing
@testable import LampModuleKit

struct LampPortableDevotionalContentTests {
    @Test func sharedParserKeepsIOSMarkdownFeatures() throws {
        let markdown = """
        ##Heading without a space

        A __bold__ and _italic_ [link](https://example.com)[^note].

        1. First

          1. Child
            continuation
        2. Second

        [^note]: Footnote body

        ![Sunrise](media/photo)
        [Prayer](media/prayer)
        """
        let blocks = try #require(JSONSerialization.jsonObject(
            with: LampPortableDevotionalContent.blocksJSON(from: markdown)
        ) as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == [
            "heading", "paragraph", "list", "image", "audio",
        ])
        let paragraph = try #require(blocks[1]["content"] as? [String: Any])
        #expect(paragraph["text"] as? String == "A bold and italic link.")
        #expect((paragraph["annotations"] as? [[String: Any]])?.count == 3)
        #expect((paragraph["footnote_refs"] as? [[String: Any]])?.count == 1)
        let items = try #require(blocks[2]["items"] as? [[String: Any]])
        #expect(items.count == 2)
        let child = try #require(items[0]["children"] as? [[String: Any]])
        #expect((child[0]["content"] as? [String: Any])?["text"] as? String
            == "Child continuation")
        #expect(blocks[3]["alignment"] as? String == "center")
        #expect(blocks[4]["showWaveform"] as? Bool == true)
    }

    @Test func projectsIOSBlocksWithoutChangingTheirSource() throws {
        let source = #"[{"type":"heading","level":2,"content":{"text":"Morning"},"future":"keep"},{"type":"paragraph","content":{"text":"Faith 🌿 grows","annotations":[{"type":"emphasis","start":0,"end":5,"data":{"style":"bold"}},{"type":"link","start":8,"end":13,"data":{"url":"https://example.com"}}],"footnote_refs":[{"id":"one","offset":5}]}},{"type":"list","listType":"bullet","items":[{"content":{"text":"First"},"children":[{"content":{"text":"Nested"}}]}]},{"type":"image","mediaId":"photo","caption":{"text":"Sunrise"},"alignment":"right"},{"type":"audio","mediaId":"prayer","caption":{"text":"Prayer"},"showWaveform":true},{"type":"table","tableData":{"headers":["A","B"],"rows":[["1","2"]]}}]"#

        let markdown = try #require(LampPortableDevotionalContent.markdown(from: source))
        #expect(markdown.contains("## Morning"))
        #expect(markdown.contains("**Faith**[^one] 🌿 [grows](https://example.com)"))
        #expect(markdown.contains("- First\n  - Nested"))
        #expect(markdown.contains("![Sunrise](media/photo)"))
        #expect(markdown.contains("[Prayer](media/prayer)"))
        #expect(markdown.contains("| A | B |\n| --- | --- |\n| 1 | 2 |"))
        #expect(source.contains(#""future":"keep""#))
    }

    @Test func projectsStructuredSectionsInOrder() throws {
        let source = #"{"introduction":[{"type":"paragraph","content":{"text":"Opening"}}],"sections":[{"title":"First","level":2,"blocks":[{"type":"paragraph","content":{"text":"Inside"}}],"subsections":[{"title":"Deeper","level":3,"blocks":[{"type":"paragraph","content":{"text":"Below"}}]}]}],"conclusion":[{"type":"paragraph","content":{"text":"Closing"}}]}"#
        #expect(LampPortableDevotionalContent.markdown(from: source) ==
            "Opening\n\n## First\n\nInside\n\n### Deeper\n\nBelow\n\nClosing")
    }

    @Test func preservesAuthoredMacMarkdownAndRejectsUnrenderableJSON() {
        let mac = ##"[{"type":"paragraph","content":{"text":"# Title\n\nA **formatted** paragraph."}}]"##
        #expect(LampPortableDevotionalContent.markdown(from: mac) ==
            "# Title\n\nA **formatted** paragraph.")
        #expect(LampPortableDevotionalContent.markdown(from: "not JSON") == nil)
        #expect(LampPortableDevotionalContent.markdown(from: #"{"example":true}"#) == nil)
    }

    @Test func richEditsKeepUnchangedBlocksAndParseEditedAnnotations() throws {
        let source = #"[{"type":"heading","level":2,"content":{"text":"Hope"},"future":"header"},{"type":"paragraph","content":{"text":"Old text","future":"inline"},"future":"paragraph"},{"type":"image","mediaId":"photo","caption":{"text":"Sunrise"},"alignment":"right","future":"image"}]"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            "## Hope\n\nNew **faith**[^one] and [grace](lampbible://verse/43003016)\n\n![Sunrise](media/photo)",
            in: source
        )
        let blocks = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [[String: Any]])
        #expect(blocks[0]["future"] as? String == "header")
        #expect(blocks[1]["future"] as? String == "paragraph")
        #expect((blocks[1]["content"] as? [String: Any])?["future"] as? String == "inline")
        #expect(blocks[2]["alignment"] as? String == "right")
        #expect(blocks[2]["future"] as? String == "image")
        #expect(LampPortableDevotionalContent.markdown(from: revised)?.contains("**faith**[^one]") == true)
        #expect(LampPortableDevotionalContent.plainText(from: revised)?.contains("New faith and grace") == true)
    }

    @Test func structuredBodyEditsKeepSectionMetadataAndDoNotDuplicateBlocks() throws {
        let source = #"{"future":"root","introduction":[{"type":"paragraph","content":{"text":"Opening"}}],"sections":[{"title":"First","level":2,"future":"section","blocks":[{"type":"paragraph","content":{"text":"Old"}}]}],"conclusion":[{"type":"paragraph","content":{"text":"Closing"}}]}"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            "Opening\n\n## First\n\nChanged\n\nClosing", in: source
        )
        let structured = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        #expect(structured["future"] as? String == "root")
        let sections = try #require(structured["sections"] as? [[String: Any]])
        #expect(sections[0]["future"] as? String == "section")
        let blocks = try #require(sections[0]["blocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect((blocks[0]["content"] as? [String: Any])?["text"] as? String == "Changed")
    }

    @Test func insertedBlocksRemainEditableByIOS() throws {
        let source = #"[{"type":"paragraph","content":{"text":"First"},"future":"keep"}]"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            "First\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- One\n  - Child\n    - Grandchild\n\n[Prayer](media/audio-id)",
            in: source
        )
        let blocks = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == [
            "paragraph", "table", "list", "audio",
        ])
        #expect(blocks[0]["future"] as? String == "keep")
        #expect(blocks[3]["mediaId"] as? String == "audio-id")
        let items = try #require(blocks[2]["items"] as? [[String: Any]])
        let children = try #require(items[0]["children"] as? [[String: Any]])
        let grandchildren = try #require(children[0]["children"] as? [[String: Any]])
        #expect((grandchildren[0]["content"] as? [String: Any])?["text"] as? String
            == "Grandchild")
    }

    @Test func nestedSectionEditKeepsItsOutlineAndOtherMetadata() throws {
        let source = #"{"sections":[{"title":"Outer","level":2,"future":"outer","blocks":[{"type":"paragraph","content":{"text":"First"}}],"subsections":[{"title":"Inner","level":3,"future":"inner","blocks":[{"type":"paragraph","content":{"text":"Old"}}]}]}]}"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            "## Outer\n\nFirst\n\n### Inner\n\nNew", in: source
        )
        let result = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(result["sections"] as? [[String: Any]])
        let inner = try #require(sections[0]["subsections"] as? [[String: Any]])
        #expect(sections[0]["future"] as? String == "outer")
        #expect(inner[0]["future"] as? String == "inner")
        let blocks = try #require(inner[0]["blocks"] as? [[String: Any]])
        #expect((blocks[0]["content"] as? [String: Any])?["text"] as? String == "New")
    }

    @Test func insertingIntoNestedSectionKeepsRootAndSectionFields() throws {
        let source = #"{"future":"root","sections":[{"title":"Outer","level":2,"future":"outer","blocks":[{"type":"paragraph","content":{"text":"First"}}],"subsections":[{"title":"Inner","level":3,"future":"inner","blocks":[{"type":"paragraph","content":{"text":"Keep"},"future":"block"}]}]}]}"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            "## Outer\n\nFirst\n\n### Inner\n\nKeep\n\nAdded", in: source
        )
        let result = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        #expect(result["future"] as? String == "root")
        let sections = try #require(result["sections"] as? [[String: Any]])
        let inner = try #require(sections[0]["subsections"] as? [[String: Any]])
        #expect(inner[0]["future"] as? String == "inner")
        let blocks = try #require(inner[0]["blocks"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["future"] as? String == "block")
        #expect((blocks[1]["content"] as? [String: Any])?["text"] as? String == "Added")
    }

    @Test func bodyEditDoesNotDropAnUnknownInvisibleFutureBlock() throws {
        let source = #"[{"type":"futureWidget","future":{"payload":"keep"}},{"type":"paragraph","content":{"text":"Old"}}]"#
        let revised = try LampPortableDevotionalContent.replacingMarkdown("New", in: source)
        let blocks = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "futureWidget")
        #expect((blocks[0]["future"] as? [String: String])?["payload"] == "keep")
        #expect((blocks[1]["content"] as? [String: Any])?["text"] as? String == "New")
    }

    @Test func changedOutlineKeepsRootAndMovesExistingSectionMetadata() throws {
        let source = #"{"future":"root","introduction":[{"type":"paragraph","content":{"text":"Opening"}}],"sections":[{"id":"a","title":"Alpha","level":2,"future":"alpha","blocks":[{"type":"paragraph","content":{"text":"A body"}}]},{"id":"b","title":"Beta","level":2,"future":"beta","blocks":[{"type":"paragraph","content":{"text":"B body"}}]}],"conclusion":[{"type":"paragraph","content":{"text":"Closing"}}]}"#
        let edited = "Opening\n\n## Beta\n\nB body\n\n## New\n\nNew body\n\n## Alpha\n\nA body\n\nClosing"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        #expect(root["future"] as? String == "root")
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.map { $0["title"] as? String } == ["Beta", "New", "Alpha"])
        #expect(sections[0]["id"] as? String == "b")
        #expect(sections[0]["future"] as? String == "beta")
        #expect(sections[2]["id"] as? String == "a")
        #expect(sections[2]["future"] as? String == "alpha")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func promotedSubsectionKeepsItsIdentity() throws {
        let source = #"{"future":"root","sections":[{"id":"outer","title":"Outer","level":2,"blocks":[{"type":"paragraph","content":{"text":"Outer body"}}],"subsections":[{"id":"inner","title":"Inner","level":3,"future":"inner","blocks":[{"type":"paragraph","content":{"text":"Inner body"}}]}]}]}"#
        let edited = "## Outer\n\nOuter body\n\n## Inner\n\nInner body"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.count == 2)
        #expect(sections[1]["id"] as? String == "inner")
        #expect(sections[1]["future"] as? String == "inner")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func renamedSectionWithInsertedPeerKeepsItsIdentityAndHiddenBlock() throws {
        let source = #"{"sections":[{"id":"first","title":"First","level":2,"blocks":[{"type":"futureWidget","future":"keep"},{"type":"paragraph","content":{"text":"Original body"}}]}]}"#
        let edited = "## Renamed\n\nOriginal body\n\n## Added\n\nNew body"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.count == 2)
        #expect(sections[0]["id"] as? String == "first")
        let blocks = try #require(sections[0]["blocks"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "futureWidget")
        #expect(blocks[0]["future"] as? String == "keep")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func editingHeadingInsideSectionKeepsItAsABlock() throws {
        let source = #"{"sections":[{"id":"outer","title":"Outer","level":2,"blocks":[{"type":"heading","level":3,"content":{"text":"Note"},"future":"heading"},{"type":"paragraph","content":{"text":"Body"}}]}]}"#
        let edited = "## Outer\n\n### Revised note\n\nBody"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.count == 1)
        #expect(sections[0]["id"] as? String == "outer")
        #expect(sections[0]["subsections"] == nil)
        let blocks = try #require(sections[0]["blocks"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "heading")
        #expect(blocks[0]["future"] as? String == "heading")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func newHigherLevelSectionKeepsExistingSectionIdentity() throws {
        let source = #"{"sections":[{"id":"old","title":"Existing","level":2,"blocks":[{"type":"paragraph","content":{"text":"Old body"}}]}]}"#
        let edited = "# New section\n\nNew body\n\n## Existing\n\nOld body"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.count == 1)
        #expect(sections[0]["title"] as? String == "New section")
        let nested = try #require(sections[0]["subsections"] as? [[String: Any]])
        #expect(nested[0]["id"] as? String == "old")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func repeatedSectionTitlesFollowTheirBodiesWhenReordered() throws {
        let source = #"{"sections":[{"id":"first","title":"Prayer","level":2,"blocks":[{"type":"paragraph","content":{"text":"Morning words"}}]},{"id":"second","title":"Prayer","level":2,"blocks":[{"type":"paragraph","content":{"text":"Evening words"}}]}]}"#
        let edited = "## Prayer\n\nEvening words\n\n## Prayer\n\nMorning words"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.map { $0["id"] as? String } == ["second", "first"])
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }

    @Test func movedSectionDoesNotTurnItsContentHeadingIntoASection() throws {
        let source = #"{"sections":[{"id":"a","title":"Alpha","level":2,"blocks":[{"type":"heading","level":3,"content":{"text":"A note"}},{"type":"paragraph","content":{"text":"A body"}}]},{"id":"b","title":"Beta","level":2,"blocks":[{"type":"paragraph","content":{"text":"B body"}}]}]}"#
        let edited = "## Beta\n\nB body\n\n## Alpha\n\n### A note\n\nA body"
        let revised = try LampPortableDevotionalContent.replacingMarkdown(edited, in: source)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(revised.utf8)
        ) as? [String: Any])
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.map { $0["id"] as? String } == ["b", "a"])
        #expect(sections[1]["subsections"] == nil)
        let blocks = try #require(sections[1]["blocks"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "heading")
        #expect(LampPortableDevotionalContent.markdown(from: revised) == edited)
    }
}
