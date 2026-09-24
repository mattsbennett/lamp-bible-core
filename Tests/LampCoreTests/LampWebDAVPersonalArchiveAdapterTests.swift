import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

struct LampWebDAVPersonalArchiveAdapterTests {
    @Test func addsMediaMetadataWhilePreservingRichContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-media-adapter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let attachment = root.appendingPathComponent("photo.png")
        try Data("image".utf8).write(to: attachment)
        let stored = try await library.storePersonalDevotionalMedia(
            from: attachment, devotionalID: "daily"
        )
        let markdown = "![Morning](lamp-media://daily/\(stored.lastPathComponent))"
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: markdown
        ))
        let source = root.appendingPathComponent("writing.lamp")
        try await library.exportPersonalModule(.writing, format: .lamp, to: source)

        let converted = try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: source), replacingModuleIDWith: "devotionals",
            kind: .devotionals, mediaRootURL: library.rootURL
        )
        let convertedURL = root.appendingPathComponent("converted.sqlite")
        try ((converted as NSData).decompressed(using: .zlib) as Data).write(to: convertedURL)
        let convertedRow = try await DatabaseQueue(path: convertedURL.path).read { db in
            try #require(try Row.fetchOne(db, sql: "SELECT content_json, media_json FROM devotional_entries WHERE id = 'daily'"))
        }
        let content: String = convertedRow["content_json"]
        let mediaJSON: String = convertedRow["media_json"]
        #expect(content == markdown)
        let media = try #require(JSONSerialization.jsonObject(with: Data(mediaJSON.utf8)) as? [[String: String]])
        #expect(media.count == 1)
        #expect(media[0]["id"] == "lamp-media://daily/\(stored.lastPathComponent)")
        #expect(media[0]["filename"] == stored.lastPathComponent)
        #expect(media[0]["type"] == "image")
        let compatibleURL = root.appendingPathComponent("compatible.lamp")
        try converted.write(to: compatibleURL)
        let enriched = try await library.importPersonalDevotional(from: compatibleURL)
        #expect(enriched.count == 1)
        #expect(try await library.personalDevotionals().first?.mediaReferences.first?.filename
            == stored.lastPathComponent)

        let richContent = #"[{"type":"paragraph","content":{"text":"Rich","marks":["bold"]}}]"#
        let existingMedia = #"[{"id":"old","type":"audio","filename":"old.m4a","mimeType":"audio/mp4","transcription":"Keep me"}]"#
        let richMediaDirectory = library.rootURL.appendingPathComponent(
            "Media/Devotionals/daily", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: richMediaDirectory, withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: richMediaDirectory.appendingPathComponent("old.m4a"))
        let editableURL = root.appendingPathComponent("editable.sqlite")
        try ((try Data(contentsOf: source) as NSData).decompressed(using: .zlib) as Data)
            .write(to: editableURL)
        try await DatabaseQueue(path: editableURL.path).write { db in
            try db.execute(
                sql: "UPDATE devotional_entries SET content_json = ?, media_json = ? WHERE id = 'daily'",
                arguments: [richContent, existingMedia]
            )
        }
        let richArchive = try (Data(contentsOf: editableURL) as NSData).compressed(using: .zlib) as Data
        let richConverted = try LampWebDAVPersonalArchiveAdapter.archive(
            richArchive, replacingModuleIDWith: "devotionals", kind: .devotionals,
            mediaRootURL: library.rootURL
        )
        let richURL = root.appendingPathComponent("rich.sqlite")
        try ((richConverted as NSData).decompressed(using: .zlib) as Data).write(to: richURL)
        let richRow = try await DatabaseQueue(path: richURL.path).read { db in
            try #require(try Row.fetchOne(db, sql: "SELECT content_json, media_json FROM devotional_entries WHERE id = 'daily'"))
        }
        #expect((richRow["content_json"] as String) == richContent)
        #expect((richRow["media_json"] as String) == existingMedia)

        try FileManager.default.removeItem(at: stored)
        #expect(throws: LampWebDAVCompatibilityError.self) {
            try LampWebDAVPersonalArchiveAdapter.archive(
                Data(contentsOf: source), replacingModuleIDWith: "devotionals",
                kind: .devotionals, mediaRootURL: library.rootURL
            )
        }
    }

    @Test func importsIOSMediaMetadataWithoutLosingFutureFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-ios-media-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = """
        [{"id":"image-id","type":"image","filename":"morning.png",
          "mimeType":"image/png","width":1200,"alt":"Morning light",
          "futureField":"keep this value"}]
        """
        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: "![Morning](media/image-id)",
            mediaJSON: metadata
        ))
        let moduleURL = root.appendingPathComponent("writing.lamp")
        try await source.exportPersonalModule(.writing, format: .lamp, to: moduleURL)

        let destination = LampLibrary(rootURL: root.appendingPathComponent("Destination"))
        _ = try await destination.importPersonalDevotional(from: moduleURL)
        let imported = try #require(try await destination.personalDevotionals().first)
        #expect(imported.content == "![Morning](media/image-id)")
        #expect(imported.mediaJSON == metadata)
        #expect(imported.mediaReferences.first?.width == 1200)
        #expect(imported.mediaReferences.first?.alt == "Morning light")

        let backupURL = root.appendingPathComponent("Backup")
        _ = try await destination.exportPortableBackup(to: backupURL)
        let restored = LampLibrary(rootURL: root.appendingPathComponent("Restored"))
        _ = try await restored.importPortableBackup(from: backupURL)
        let roundTrip = try #require(try await restored.personalDevotionals().first)
        #expect(roundTrip.mediaJSON?.contains("keep this value") == true)
        #expect(roundTrip.mediaReferences.first?.alt == "Morning light")
    }

    @Test func retainsStructuredDevotionalBlocksAcrossMetadataEditAndExports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-rich-devotional-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("daily.json")
        let document = #"{"meta":{"schemaVersion":"1.1","id":"daily","type":"devotional","title":"Daily"},"content":[{"type":"heading","level":2,"content":{"text":"Hope","marks":["bold"]}},{"type":"paragraph","content":{"text":"Read on"}}]}"#
        try Data(document.utf8).write(to: source)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await library.importPersonalDevotional(from: source)
        let imported = try #require(try await library.personalDevotionals().first)
        #expect(imported.contentJSON?.contains("\"marks\"") == true)

        _ = try await library.savePersonalDevotional(LampDevotional(
            id: imported.id, moduleID: imported.moduleID, moduleName: imported.moduleName,
            title: "Daily Renamed", content: imported.content
        ))
        let edited = try #require(try await library.personalDevotionals().first)
        #expect(edited.contentJSON == imported.contentJSON)
        let json = try await library.personalDevotionalDocument(id: "daily")
        let rootObject = try #require(JSONSerialization.jsonObject(with: json.jsonData) as? [String: Any])
        let blocks = try #require(rootObject["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "heading")
        #expect((blocks[0]["content"] as? [String: Any])?["marks"] as? [String] == ["bold"])

        let lampURL = root.appendingPathComponent("writing.lamp")
        try await library.exportPersonalModule(.writing, format: .lamp, to: lampURL)
        let sqliteURL = root.appendingPathComponent("writing.sqlite")
        try ((try Data(contentsOf: lampURL) as NSData).decompressed(using: .zlib) as Data)
            .write(to: sqliteURL)
        let exported = try await DatabaseQueue(path: sqliteURL.path).read { db in
            try String.fetchOne(db, sql: "SELECT content_json FROM devotional_entries WHERE id = 'daily'")
        }
        #expect(exported == imported.contentJSON)

        let revisedJSON = try LampPortableDevotionalContent.replacingMarkdown(
            "## Hope\n\nRead farther", in: try #require(imported.contentJSON)
        )
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: edited.id, moduleID: edited.moduleID, moduleName: edited.moduleName,
            title: edited.title,
            content: LampPortableDevotionalContent.plainText(from: revisedJSON) ?? "",
            contentJSON: revisedJSON
        ))
        let bodyEdited = try #require(try await library.personalDevotionals().first)
        #expect(bodyEdited.displayMarkdown == "## Hope\n\nRead farther")
        #expect(bodyEdited.contentJSON == revisedJSON)
        let revisedDocument = try await library.personalDevotionalDocument(id: "daily")
        let revisedRoot = try #require(JSONSerialization.jsonObject(
            with: revisedDocument.jsonData
        ) as? [String: Any])
        let revisedBlocks = try #require(revisedRoot["content"] as? [[String: Any]])
        #expect((revisedBlocks[0]["content"] as? [String: Any])?["marks"] as? [String]
            == ["bold"])
        #expect((revisedBlocks[1]["content"] as? [String: Any])?["text"] as? String
            == "Read farther")
    }

    @Test func macAuthoredRichAttachmentPublishesWithItsMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-rich-authoring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("photo.png")
        let body = Data("image".utf8)
        try body.write(to: source)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let stored = try await library.storePersonalDevotionalMedia(
            from: source, devotionalID: "daily"
        )
        let reference = LampDevotionalMediaReference(
            id: "rich-image", type: .image, filename: stored.lastPathComponent,
            mimeType: "image/png", size: body.count, width: 1200,
            alt: "Morning light"
        )
        let mediaJSON = try LampPortableDevotionalMedia.appending(reference, to: nil)
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: "![Morning](media/rich-image)",
            mediaJSON: mediaJSON
        ))
        let outgoing = try LampSyncDevotionalMedia.outgoingFiles(
            for: await library.personalDevotionals(),
            to: "devotionals", from: library.rootURL
        )
        #expect(outgoing.map(\.remotePath) == [
            "DevotionalMedia/devotionals/daily/\(stored.lastPathComponent)"
        ])
        #expect(outgoing.first?.data == body)

        let moduleURL = root.appendingPathComponent("writing.lamp")
        try await library.exportPersonalModule(.writing, format: .lamp, to: moduleURL)
        let compatible = try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: moduleURL), replacingModuleIDWith: "devotionals",
            kind: .devotionals, mediaRootURL: library.rootURL
        )
        let sqliteURL = root.appendingPathComponent("compatible.sqlite")
        try ((compatible as NSData).decompressed(using: .zlib) as Data).write(to: sqliteURL)
        let row = try await DatabaseQueue(path: sqliteURL.path).read { db in
            try #require(try Row.fetchOne(
                db, sql: "SELECT content_json, media_json FROM devotional_entries WHERE id = 'daily'"
            ))
        }
        #expect((row["content_json"] as String) == "![Morning](media/rich-image)")
        let exportedMedia: String = row["media_json"]
        let exported = try #require(JSONSerialization.jsonObject(
            with: Data(exportedMedia.utf8)
        ) as? [[String: Any]])
        #expect(exported.first?["id"] as? String == "rich-image")
        #expect(exported.first?["width"] as? Int == 1200)
        #expect(exported.first?["alt"] as? String == "Morning light")
    }
}
