import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

struct LampSyncImportTests {
    @Test func receivedWritingKeepsLocalAndIncoming() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-staged-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "incoming-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Incoming writing",
            content: "Remote entry"
        ))
        let destination = LampLibrary(rootURL: root.appendingPathComponent("Destination"))
        _ = try await destination.savePersonalDevotional(LampDevotional(
            id: "local-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Local writing",
            content: "Local entry"
        ))
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        _ = try await source.exportPortableBackup(to: backup)

        let result = try await destination.receive(exportAt: backup)
        #expect(result.devotionals == 1)
        #expect(Set(try await destination.personalDevotionals().map(\.title))
            == ["Incoming writing", "Local writing"])
    }

    @Test func devotionalImportPreservesRevisionAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-sync-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let revision = Date(timeIntervalSince1970: 1_600_000_000)
        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "stable-revision",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "Original",
            content: "A remote revision",
            lastModified: revision
        ), preserveLastModified: true)

        let backup = root.appendingPathComponent("Backup")
        _ = try await source.exportPortableBackup(to: backup)
        let destination = LampLibrary(rootURL: root.appendingPathComponent("Destination"))
        let first = try await destination.receive(exportAt: backup)
        let second = try await destination.receive(exportAt: backup)

        #expect(first.devotionals == 1)
        #expect(second.devotionals == 0)
        #expect(try await destination.personalDevotionals().first?.lastModified == revision)
    }
}

private enum StagedSyncTestError: Error {
    case laterItemFailed
}

private final class LibraryEditDuringCopyFileManager: FileManager {
    let liveRoot: URL
    private(set) var didInjectEdit = false

    init(liveRoot: URL) {
        self.liveRoot = liveRoot
        super.init()
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.copyItem(at: sourceURL, to: destinationURL)
        if !didInjectEdit,
           sourceURL.standardizedFileURL == liveRoot.standardizedFileURL,
           destinationURL.lastPathComponent.hasPrefix(".lamp-backup-import-") {
            try Data("local change".utf8).write(
                to: liveRoot.appendingPathComponent("local-edit.txt"), options: .atomic
            )
            didInjectEdit = true
        }
    }
}
