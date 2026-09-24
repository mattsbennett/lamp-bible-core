import Foundation
import Testing
@testable import LampModuleKit

struct LampPortableDevotionalMediaTests {
    @Test func extractsDistinctLegacyReferencesWithoutDroppingTheirKinds() throws {
        let content = """
        ![Morning](lamp-media://daily/.morning-123.png)
        [▶︎ Prayer](lamp-media://daily/prayer-456.m4a)
        ![Again](lamp-media://daily/.morning-123.png)
        """
        let references = try LampPortableDevotionalMedia.references(
            in: content, devotionalID: "daily"
        )
        #expect(references.count == 2)
        #expect(references[0].kind == .image)
        #expect(references[0].archivePath == "Media/Devotionals/daily/.morning-123.png")
        #expect(references[0].mimeType == "image/png")
        #expect(references[1].kind == .audio)
        #expect(references[1].mimeType == "audio/mp4")
    }

    @Test func rejectsReferencesThatCannotBeSafelyTransferred() throws {
        #expect(try LampPortableDevotionalMedia.references(
            in: "A draft may mention `lamp-media://daily/example.png` in prose.",
            devotionalID: "daily"
        ).isEmpty)
        #expect(throws: LampPortableDevotionalMedia.ReferenceError.self) {
            try LampPortableDevotionalMedia.references(
                in: "![Wrong](lamp-media://another/photo.png)", devotionalID: "daily"
            )
        }
        #expect(throws: LampPortableDevotionalMedia.ReferenceError.self) {
            try LampPortableDevotionalMedia.references(
                in: "![Broken](lamp-media://daily/../photo.png)", devotionalID: "daily"
            )
        }
    }

    @Test func resolvesLegacyAndRichLinksToTheSamePortableLibraryMedia() throws {
        let root = URL(fileURLWithPath: "/tmp/lamp-library")
        let reference = LampDevotionalMediaReference(
            id: "image-id", type: .image, filename: ".morning.png",
            mimeType: "image/png", alt: "Morning light"
        )
        let legacy = try #require(URL(string: "lamp-media://daily/.morning.png"))
        let rich = try #require(URL(string: "media/image-id"))
        let expected = root.appendingPathComponent("Media/Devotionals/daily/.morning.png")
        #expect(LampPortableDevotionalMedia.libraryURL(
            for: legacy, rootURL: root, devotionalID: "daily", references: [reference]
        ) == expected)
        #expect(LampPortableDevotionalMedia.libraryURL(
            for: rich, rootURL: root, devotionalID: "daily", references: [reference]
        ) == expected)
        #expect(try LampPortableDevotionalMedia.iOSRemotePath(
            moduleID: "devotionals", devotionalID: "daily", filename: ".morning.png"
        ) == "DevotionalMedia/devotionals/daily/.morning.png")
    }

    @Test func visualEditorPreservesLegacyLinksAndRichMediaIDs() {
        let authored = """
        ![Morning](lamp-media://daily/.morning.png)
        [▶︎ Prayer](media/audio-id)
        """
        let editor = LampPortableDevotionalMedia.editorMarkdown(from: authored)
        #expect(editor.contains("![Morning](media/.morning.png)"))
        #expect(editor.contains("[▶︎ Prayer](media/audio-id)"))
        #expect(LampPortableDevotionalMedia.portableMarkdown(
            from: editor, devotionalID: "daily", richMediaIDs: ["audio-id"]
        ) == authored)
    }

    @Test func appendsRichReferenceWithoutLosingFutureMediaFields() throws {
        let existing = #"[{"id":"older","type":"image","filename":"older.png","future":{"quality":"original"}}]"#
        let reference = LampDevotionalMediaReference(
            id: "audio-id", type: .audio, filename: "prayer.m4a",
            mimeType: "audio/mp4", size: 42, duration: 12.5,
            waveform: [0.2, 0.7], transcription: "Prayer"
        )
        let combined = try LampPortableDevotionalMedia.appending(reference, to: existing)
        let values = try #require(JSONSerialization.jsonObject(
            with: Data(combined.utf8)
        ) as? [[String: Any]])
        #expect(values.count == 2)
        #expect((values[0]["future"] as? [String: String])?["quality"] == "original")
        #expect(values[1]["id"] as? String == "audio-id")
        #expect(values[1]["duration"] as? Double == 12.5)
        #expect(values[1]["transcription"] as? String == "Prayer")
        #expect(throws: LampPortableDevotionalMedia.MetadataError.self) {
            try LampPortableDevotionalMedia.appending(reference, to: combined)
        }
    }
}
