import Foundation
import Testing
@testable import LampModuleKit

private final class EditBeforeCoordinatedWriteFileManager: FileManager {
    let target: URL
    private var edited = false

    init(target: URL) { self.target = target }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if !edited && url.standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL {
            edited = true
            try Data("later edit".utf8).write(to: target)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

private final class FailBeforeCoordinatedWriteFileManager: FileManager {
    let target: URL
    private var failed = false

    init(target: URL) { self.target = target }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if !failed && url.standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL {
            failed = true
            throw LampSyncFolderPublisher.FolderError.unreadable(target.path)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

struct LampSyncFolderPublisherTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-folder-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func publishesOnlyAgainstObservedFolder() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let oldFile = folder.appendingPathComponent("Study/notes.txt")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldFile)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        let newFile = outgoing.appendingPathComponent("Study/notes.txt")
        try FileManager.default.createDirectory(
            at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: newFile)
        try Data("added".utf8).write(to: outgoing.appendingPathComponent("added.txt"))

        try await LampSyncFolderPublisher.publish(
            LampSyncArchive.create(from: outgoing), to: folder, replacing: observed
        )
        #expect(try Data(contentsOf: oldFile) == Data("new".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("added.txt")) == Data("added".utf8))
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(LampSyncFolderPublisher.snapshotPath).path
        ))
        _ = try await LampSyncFolderPublisher.capture(from: folder)
    }

    @Test func rejectsEditAfterPullWithoutOverwritingIt() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: file)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        try Data("new local".utf8).write(to: outgoing.appendingPathComponent("notes.txt"))
        try Data("other device".utf8).write(to: file)

        await #expect(throws: LampSyncFolderPublisher.FolderError.self) {
            try await LampSyncFolderPublisher.publish(
                LampSyncArchive.create(from: outgoing), to: folder, replacing: observed
            )
        }
        #expect(try Data(contentsOf: file) == Data("other device".utf8))
    }

    @Test func downloadsHiddenPlaceholderBeforeSnapshot() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let placeholder = folder.appendingPathComponent(".notes.txt.icloud")
        try Data("cloud note".utf8).write(to: placeholder)

        let archive = try await LampSyncFolderPublisher.capture(
            from: folder,
            downloadItem: { original in
                try FileManager.default.moveItem(at: placeholder, to: original)
            }
        )
        #expect(archive.entries.map(\.path) == ["notes.txt"])
        #expect(archive.entries.first?.data == Data("cloud note".utf8))
    }

    @Test func rechecksFileAfterWholeFolderPreflight() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        let file = folder.appendingPathComponent("Study/notes.txt")
        let newFile = outgoing.appendingPathComponent("Study/notes.txt")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: file)
        try Data("outgoing".utf8).write(to: newFile)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        let changingFileManager = EditBeforeCoordinatedWriteFileManager(target: file)

        await #expect(throws: LampSyncFolderPublisher.FolderError.self) {
            try await LampSyncFolderPublisher.publish(
                LampSyncArchive.create(from: outgoing),
                to: folder,
                replacing: observed,
                fileManager: changingFileManager
            )
        }
        #expect(try Data(contentsOf: file) == Data("later edit".utf8))
    }

    @Test func missingFolderDoesNotLookEmpty() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: LampSyncFolderPublisher.FolderError.self) {
            try await LampSyncFolderPublisher.capture(from: root.appendingPathComponent("Missing"))
        }
    }

    @Test func stoppedBatchCannotBeImportedAsCompleteSnapshot() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        for base in [folder, outgoing] {
            for directory in ["A", "Z"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(directory),
                    withIntermediateDirectories: true
                )
            }
        }
        let first = folder.appendingPathComponent("A/notes.txt")
        let second = folder.appendingPathComponent("Z/notes.txt")
        try Data("old A".utf8).write(to: first)
        try Data("old Z".utf8).write(to: second)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        try Data("new A".utf8).write(to: outgoing.appendingPathComponent("A/notes.txt"))
        try Data("new Z".utf8).write(to: outgoing.appendingPathComponent("Z/notes.txt"))

        let changingFileManager = EditBeforeCoordinatedWriteFileManager(target: second)
        await #expect(throws: LampSyncFolderPublisher.FolderError.self) {
            try await LampSyncFolderPublisher.publish(
                LampSyncArchive.create(from: outgoing),
                to: folder,
                replacing: observed,
                fileManager: changingFileManager
            )
        }
        #expect(try Data(contentsOf: first) == Data("new A".utf8))
        #expect(try Data(contentsOf: second) == Data("later edit".utf8))
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            try await LampSyncFolderPublisher.capture(from: folder)
        }
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            try await LampSyncFolderPublisher.recoverIncompletePublication(from: folder)
        }
        #expect(try Data(contentsOf: second) == Data("later edit".utf8))
    }

    @Test func interruptedBatchResumesWithoutOverwritingOtherEdits() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        for base in [folder, outgoing] {
            for directory in ["A", "Z"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(directory), withIntermediateDirectories: true
                )
            }
        }
        let first = folder.appendingPathComponent("A/notes.txt")
        let second = folder.appendingPathComponent("Z/notes.txt")
        try Data("old A".utf8).write(to: first)
        try Data("old Z".utf8).write(to: second)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        try Data("new A".utf8).write(to: outgoing.appendingPathComponent("A/notes.txt"))
        try Data("new Z".utf8).write(to: outgoing.appendingPathComponent("Z/notes.txt"))

        let failing = FailBeforeCoordinatedWriteFileManager(target: second)
        await #expect(throws: LampSyncFolderPublisher.FolderError.unreadable(second.path)) {
            try await LampSyncFolderPublisher.publish(
                LampSyncArchive.create(from: outgoing),
                to: folder,
                replacing: observed,
                fileManager: failing
            )
        }
        #expect(try Data(contentsOf: first) == Data("new A".utf8))
        #expect(try Data(contentsOf: second) == Data("old Z".utf8))
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            try await LampSyncFolderPublisher.capture(from: folder)
        }

        let sealURL = folder.appendingPathComponent(LampSyncFolderPublisher.snapshotPath)
        let seal = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: sealURL)
        ) as? [String: Any])
        let stagePath = try #require(seal["pendingArchivePath"] as? String)
        let stageURL = folder.appendingPathComponent(stagePath)
        let stagedData = try Data(contentsOf: stageURL)
        try Data("damaged stage".utf8).write(to: stageURL)
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            try await LampSyncFolderPublisher.recoverIncompletePublication(from: folder)
        }
        #expect(try Data(contentsOf: second) == Data("old Z".utf8))
        try stagedData.write(to: stageURL)

        let recovered = try await LampSyncFolderPublisher.recoverIncompletePublication(from: folder)
        #expect(recovered.entries.first(where: { $0.path == "A/notes.txt" })?.data == Data("new A".utf8))
        #expect(recovered.entries.first(where: { $0.path == "Z/notes.txt" })?.data == Data("new Z".utf8))
        _ = try await LampSyncFolderPublisher.capture(from: folder)
    }

    @Test func changedSealedFileCannotBeImported() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: outgoing.appendingPathComponent("notes.txt"))
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        try await LampSyncFolderPublisher.publish(
            LampSyncArchive.create(from: outgoing), to: folder, replacing: observed
        )
        try Data("later edit".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            try await LampSyncFolderPublisher.capture(from: folder)
        }
    }

    @Test func completePendingSnapshotCanBeImportedAfterFinalMarkerWriteWasInterrupted() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remote", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let newData = Data("new".utf8)
        try newData.write(to: outgoing.appendingPathComponent("notes.txt"))
        try await LampSyncFolderPublisher.publish(
            LampSyncArchive.create(from: outgoing),
            to: folder,
            replacing: try await LampSyncFolderPublisher.capture(from: folder)
        )

        let sealURL = folder.appendingPathComponent(LampSyncFolderPublisher.snapshotPath)
        var seal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sealURL)) as? [String: Any])
        seal["pendingFiles"] = seal["files"]
        seal["files"] = []
        try JSONSerialization.data(withJSONObject: seal).write(to: sealURL, options: .atomic)
        let captured = try await LampSyncFolderPublisher.capture(from: folder)
        #expect(captured.entries.first(where: { $0.path == "notes.txt" })?.data == newData)
    }
}
