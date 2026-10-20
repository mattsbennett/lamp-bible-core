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

    @Test func missingFolderDoesNotLookEmpty() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: LampSyncFolderPublisher.FolderError.self) {
            try await LampSyncFolderPublisher.capture(from: root.appendingPathComponent("Missing"))
        }
    }

}
