import Foundation
import LampCore
import LampModuleKit
import Testing

struct LampSyncDevotionalMediaTests {
    @Test func transfersRichReferencesIntoMacLibraryAndRepairsMissingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-ios-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaJSON = """
        [{"id":"image-id","type":"image","filename":".morning.png",
          "mimeType":"image/png","alt":"Morning light","width":1200},
         {"id":"audio-id","type":"audio","filename":"prayer.m4a",
          "mimeType":"audio/mp4","transcription":"A prayer"}]
        """
        let devotional = LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: "![Morning](media/image-id)", mediaJSON: mediaJSON
        )
        let files = [
            "DevotionalMedia/devotionals/daily/.morning.png": Data("image".utf8),
            "DevotionalMedia/devotionals/daily/prayer.m4a": Data("audio".utf8),
        ]
        try await LampSyncDevotionalMedia.downloadToLibrary(
            for: [devotional], from: "devotionals", into: root
        ) { path in
            guard let data = files[path] else { throw TestFailure.missing }
            return data
        }
        let imageURL = root.appendingPathComponent("Media/Devotionals/daily/.morning.png")
        let audioURL = root.appendingPathComponent("Media/Devotionals/daily/prayer.m4a")
        #expect(try Data(contentsOf: imageURL) == files["DevotionalMedia/devotionals/daily/.morning.png"])
        #expect(try Data(contentsOf: audioURL) == files["DevotionalMedia/devotionals/daily/prayer.m4a"])
        #expect(devotional.mediaReferences.first?.alt == "Morning light")
        #expect(devotional.mediaReferences.last?.transcription == "A prayer")

        try FileManager.default.removeItem(at: imageURL)
        try await LampSyncDevotionalMedia.downloadToLibrary(
            for: [devotional], from: "devotionals", into: root
        ) { path in
            guard let data = files[path] else { throw TestFailure.missing }
            return data
        }
        #expect(try Data(contentsOf: imageURL) == files["DevotionalMedia/devotionals/daily/.morning.png"])
    }

    @Test func rejectsUnsafeReferencedFilenameBeforeWritingIt() async throws {
        let devotional = LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: "![Bad](media/bad)",
            mediaJSON: #"[{"id":"bad","type":"image","filename":"../bad.png","mimeType":"image/png"}]"#
        )
        await #expect(throws: LampPortableDevotionalMedia.MetadataError.self) {
            try await LampSyncDevotionalMedia.downloadToLibrary(
                for: [devotional], from: "devotionals",
                into: FileManager.default.temporaryDirectory
            ) { _ in Data() }
        }
    }

    @Test func plansLegacyRichAndFutureMediaBeforeModulePublication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-outgoing-devotional-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Media/Devotionals/daily", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: folder.appendingPathComponent("old.png"))
        try Data("rich".utf8).write(to: folder.appendingPathComponent("new.m4a"))
        try Data("future".utf8).write(to: folder.appendingPathComponent("future.bin"))
        let devotional = LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Daily", content: "![Old](lamp-media://daily/old.png)",
            mediaJSON: #"[{"id":"old","type":"image","filename":"old.png"},{"id":"new","type":"audio","filename":"new.m4a"},{"id":"future","type":"video","filename":"future.bin","futureField":true}]"#
        )
        let files = try LampSyncDevotionalMedia.outgoingFiles(
            for: [devotional], to: "devotionals", from: root
        )
        #expect(files.map(\.remotePath) == [
            "DevotionalMedia/devotionals/daily/old.png",
            "DevotionalMedia/devotionals/daily/new.m4a",
            "DevotionalMedia/devotionals/daily/future.bin",
        ])
        #expect(files.map(\.data) == [
            Data("legacy".utf8), Data("rich".utf8), Data("future".utf8),
        ])

        try FileManager.default.removeItem(at: folder.appendingPathComponent("new.m4a"))
        #expect(throws: LampSyncDevotionalMedia.UploadError.self) {
            try LampSyncDevotionalMedia.outgoingFiles(
                for: [devotional], to: "devotionals", from: root
            )
        }
    }

    @Test func mediaUploadSkipsIdenticalRemoteAndRejectsDifferentRemote() async throws {
        let old = LampSyncDevotionalMedia.UploadFile(
            remotePath: "DevotionalMedia/devotionals/daily/old.png",
            data: Data("same".utf8)
        )
        let new = LampSyncDevotionalMedia.UploadFile(
            remotePath: "DevotionalMedia/devotionals/daily/new.png",
            data: Data("new".utf8)
        )
        let pending = try await LampSyncDevotionalMedia.pendingUploads([old, new]) { path in
            path == old.remotePath
                ? LampSyncRemoteFile(data: old.data, revision: "\"old\"") : nil
        }
        #expect(pending.map(\.remotePath) == [new.remotePath])
        #expect(pending.first?.condition == .ifAbsent)
        await #expect(throws: LampSyncDevotionalMedia.UploadError.self) {
            try await LampSyncDevotionalMedia.pendingUploads([old]) { _ in
                LampSyncRemoteFile(data: Data("different".utf8), revision: "\"old\"")
            }
        }
    }

    private enum TestFailure: Error { case missing }
}
