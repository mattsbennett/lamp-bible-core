import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

struct LampSyncImportTests {
    @Test func stagedSyncCombinesBackupAndLaterWorkspaceChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-staged-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "incoming-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Incoming writing",
            content: "Remote entry"
        ))
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        _ = try await source.exportPortableBackup(to: backup)

        let destination = LampLibrary(rootURL: root.appendingPathComponent("Destination"))
        _ = try await destination.savePersonalDevotional(LampDevotional(
            id: "local-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Local writing",
            content: "Local entry"
        ))
        let workspacePath = "AgentWorkspaces/Devotionals/example.md"
        let liveWorkspace = destination.rootURL.appendingPathComponent(workspacePath)
        await #expect(throws: StagedSyncTestError.laterItemFailed) {
            try await destination.withStagedChanges { staged in
                _ = try await staged.importPortableBackup(from: backup)
                let stagedWorkspace = staged.rootURL.appendingPathComponent(workspacePath)
                try FileManager.default.createDirectory(
                    at: stagedWorkspace.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("incoming workspace".utf8).write(to: stagedWorkspace)
                throw StagedSyncTestError.laterItemFailed
            }
        }
        #expect(!FileManager.default.fileExists(atPath: liveWorkspace.path))
        #expect(try await destination.personalDevotionals().map(\.title) == ["Local writing"])

        try await destination.withStagedChanges { staged in
            _ = try await staged.importPortableBackup(from: backup)
            let stagedWorkspace = staged.rootURL.appendingPathComponent(workspacePath)
            try FileManager.default.createDirectory(
                at: stagedWorkspace.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("incoming workspace".utf8).write(to: stagedWorkspace)
        }
        #expect(try Data(contentsOf: liveWorkspace) == Data("incoming workspace".utf8))
        #expect(Set(try await destination.personalDevotionals().map(\.title))
            == ["Incoming writing", "Local writing"])
    }

    @Test func localEditDuringStagedImportIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-staged-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "incoming-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Incoming writing",
            content: "Remote entry"
        ))
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        _ = try await source.exportPortableBackup(to: backup)

        let liveRoot = root.appendingPathComponent("Destination", isDirectory: true)
        let fileManager = LibraryEditDuringCopyFileManager(liveRoot: liveRoot)
        let destination = LampLibrary(rootURL: liveRoot, fileManager: fileManager)
        _ = try await destination.savePersonalDevotional(LampDevotional(
            id: "local-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Local writing",
            content: "Local entry"
        ))

        await #expect(throws: LampLibraryError.syncConflict(
            "Local library changed during sync import."
        )) {
            _ = try await destination.importPortableBackup(from: backup)
        }
        #expect(fileManager.didInjectEdit)
        #expect(FileManager.default.fileExists(
            atPath: liveRoot.appendingPathComponent("local-edit.txt").path
        ))
        #expect(try await destination.personalDevotionals().map(\.title) == ["Local writing"])
    }

    @Test func stagedBackupImportKeepsLocalAndIncomingWriting() async throws {
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

        let result = try await destination.importPortableBackup(from: backup)
        #expect(result.importedDevotionals == 1)
        #expect(Set(try await destination.personalDevotionals().map(\.title))
            == ["Incoming writing", "Local writing"])
    }

    @Test func laterBackupFailureLeavesLocalLibraryUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-staged-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = LampLibrary(rootURL: root.appendingPathComponent("Destination"))
        _ = try await destination.savePersonalDevotional(LampDevotional(
            id: "installed-writing", moduleID: "personal-devotionals",
            moduleName: "My Writing", title: "Installed writing",
            content: "Keep this entry"
        ))

        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        let modules = backup.appendingPathComponent("Modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 2, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: backup.appendingPathComponent("manifest.json"))

        let sourceURL = root.appendingPathComponent("valid.sqlite")
        let queue = try DatabaseQueue(path: sourceURL.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('incoming', 'dictionary')")
            try db.execute(sql: "CREATE TABLE module_metadata (id TEXT, name TEXT, language TEXT)")
            try db.execute(sql: "INSERT INTO module_metadata VALUES ('incoming', 'Incoming dictionary', 'en')")
            try db.execute(sql: "CREATE TABLE dictionary_entries (id TEXT, module_id TEXT)")
            try db.execute(sql: "INSERT INTO dictionary_entries VALUES ('incoming:G1', 'incoming')")
        }
        let valid = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        try valid.write(to: modules.appendingPathComponent("a-good.lamp"))
        try Data("damaged archive".utf8).write(to: modules.appendingPathComponent("z-bad.lamp"))

        await #expect(throws: LampLibraryError.self) {
            _ = try await destination.importPortableBackup(from: backup)
        }
        #expect(try await destination.installedModules().isEmpty)
        #expect(try await destination.personalDevotionals().map(\.title) == ["Installed writing"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".lamp-backup-import-") }
        #expect(leftovers.isEmpty)
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
        let first = try await destination.importPortableBackup(from: backup)
        let second = try await destination.importPortableBackup(from: backup)

        #expect(first.importedDevotionals == 1)
        #expect(second.importedDevotionals == 0)
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
