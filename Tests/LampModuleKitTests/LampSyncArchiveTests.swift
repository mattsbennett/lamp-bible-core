import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncArchiveTests {
    @Test func hiddenMediaIsCapturedAndMediaLinkStopsPublication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-hidden-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let media = source.appendingPathComponent("Media/Devotionals/entry", isDirectory: true)
        let notes = source.appendingPathComponent("Study/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let hiddenMedia = media.appendingPathComponent(".image-123.png")
        try Data("attachment".utf8).write(to: hiddenMedia)
        try Data("draft".utf8).write(to: notes.appendingPathComponent(".draft.json"))

        let outside = root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let linkedMedia = media.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: linkedMedia, withDestinationURL: outside
        )
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try LampSyncArchive.create(from: source)
        }

        try FileManager.default.removeItem(at: linkedMedia)
        let archive = try LampSyncArchive.create(from: source)
        #expect(archive.entries.map(\.path) == ["Media/Devotionals/entry/.image-123.png"])
        #expect(archive.entries.first?.data == Data("attachment".utf8))
    }

    @Test func missingSourceCannotBecomeEmptySnapshot() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-archive-\(UUID().uuidString)")
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try LampSyncArchive.create(from: missing)
        }
    }

    @Test func createsValidatesAndExtractsVersionTwoSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-sync-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source/Study/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data("{\"note\":true}".utf8)
        try payload.write(to: source.appendingPathComponent("notes.json"))

        let archive = try LampSyncArchive.create(from: root.appendingPathComponent("Source"))
        #expect(archive.formatVersion == 2)
        #expect(archive.entries.map(\.path) == ["Study/Notes/notes.json"])
        #expect(archive.entries[0].sha256?.count == 64)

        let decoded = try LampSyncArchive.decode(compressedData: archive.compressedData())
        let destination = root.appendingPathComponent("Destination")
        try decoded.extract(to: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Study/Notes/notes.json")) == payload)
    }

    @Test func readsLegacyVersionOneArchiveWithoutHashes() throws {
        let legacy = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "Study/Notes/note.json", data: Data("legacy".utf8), modifiedAt: .distantPast),
        ])
        let decoded = try LampSyncArchive.decode(compressedData: legacy.compressedData())
        #expect(decoded.formatVersion == 1)
        #expect(decoded.entries[0].data == Data("legacy".utf8))
    }

    @Test func replacesOneEntryAndUpgradesChecksumsWithoutChangingOtherFiles() throws {
        let original = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "Modules/book.lamp", data: Data("module".utf8), modifiedAt: .distantPast),
            .init(path: "settings.plist", data: Data("preferences".utf8), modifiedAt: .distantPast),
        ])
        let updated = try original.replacingEntry(
            at: LampPortableBackupLayout.sharedPreferencesPath,
            with: Data("ledger".utf8)
        )
        #expect(updated.formatVersion == 2)
        #expect(updated.entries.first(where: { $0.path == "Modules/book.lamp" })?.data == Data("module".utf8))
        #expect(updated.entries.first(where: { $0.path == "settings.plist" })?.data == Data("preferences".utf8))
        #expect(updated.entries.allSatisfy { $0.sha256?.count == 64 })
        let decoded = try LampSyncArchive.decode(compressedData: updated.compressedData())
        #expect(decoded.entries.first(where: {
            $0.path == LampPortableBackupLayout.sharedPreferencesPath
        })?.data == Data("ledger".utf8))
    }

    @Test func selectsOnlyDirectPortableModulesAfterCheckingManifest() throws {
        let manifest = LampPortableBackupManifest(
            generatedAt: .distantPast,
            summary: .init(
                moduleCount: 1,
                noteDocumentCount: 0,
                highlightDocumentCount: 0,
                devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath, data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Compatibility/Notes/notes.lamp", data: Data("notes".utf8), modifiedAt: .distantPast),
            .init(path: "Modules/hashed-storage-key.lamp", data: Data("module".utf8), modifiedAt: .distantPast),
            .init(path: "Study/Notes/note.json", data: Data("note".utf8), modifiedAt: .distantPast),
            .init(path: "Compatibility/Notes/Nested/other.lamp", data: Data("nested".utf8), modifiedAt: .distantPast),
        ])
        #expect(try archive.portableModuleEntries().map(\.path) == ["Modules/hashed-storage-key.lamp"])
        #expect(try archive.compatibleModuleEntries().map(\.path) == ["Compatibility/Notes/notes.lamp"])
        #expect(try archive.syncableModuleEntries().map(\.path) == [
            "Modules/hashed-storage-key.lamp",
            "Compatibility/Notes/notes.lamp",
        ])

        let missingManifest = LampSyncArchive(formatVersion: 1, entries: Array(archive.entries.dropFirst()))
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try missingManifest.portableModuleEntries()
        }
    }

    @Test func rejectsDamagedAndUnsafeArchivesBeforeExtraction() throws {
        let damaged = LampSyncArchive(entries: [
            .init(path: "safe.txt", data: Data("changed".utf8), modifiedAt: .distantPast, sha256: String(repeating: "0", count: 64)),
        ])
        let encoded = try JSONEncoder().encode(damaged)
        let compressed = try (encoded as NSData).compressed(using: .zlib) as Data
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try LampSyncArchive.decode(compressedData: compressed)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-sync-unsafe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafe = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "safe.txt", data: Data("safe".utf8), modifiedAt: .distantPast),
            .init(path: "../escape.txt", data: Data("escape".utf8), modifiedAt: .distantPast),
        ])
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try unsafe.extract(to: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("safe.txt").path))

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-sync-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        let redirected = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "safe.txt", data: Data("safe".utf8), modifiedAt: .distantPast),
            .init(path: "linked/escape.txt", data: Data("escape".utf8), modifiedAt: .distantPast),
        ])
        #expect(throws: LampSyncArchive.ArchiveError.self) {
            try redirected.extract(to: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("safe.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
    }
}
