import Foundation
import Testing
@testable import LampModuleKit

/// The archive is the whole library. Read whole into memory beside its
/// unpacked form, it got the iOS app stopped by the system, so every path
/// that touches a body that size must stream it to disk instead.
struct LampSyncStreamingTests {
    @Test func theArchiveIsReadThroughAFile() async throws {
        let archive = try archive()
        let store = DownloadOnlyStore()
        store.files[LampSyncLayout.archivePath] = .init(data: try archive.compressedData(), revision: "\"a\"")
        let snapshot = try #require(try await LampSyncArchiveRemote.read(from: store))
        #expect(snapshot.archive == archive)
        #expect(snapshot.revision == "\"a\"")
        #expect(store.scratchFilesLeft().isEmpty)

        let absent = DownloadOnlyStore()
        #expect(try await LampSyncArchiveRemote.read(from: absent) == nil)
    }

    @Test func aWriteIsConfirmedFromAFile() async throws {
        let store = DownloadOnlyStore()
        let revision = try await LampSyncConditionalWrite.writeAndConfirm(
            Data("body".utf8), to: "a.lamp", in: store, condition: .ifAbsent
        )
        #expect(revision == "\"w\"")
        #expect(store.scratchFilesLeft().isEmpty)
    }

    @Test func anotherBodyStillFailsBothReadBacks() async throws {
        let store = DownloadOnlyStore()
        store.readBackOverride = Data("theirs".utf8)
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.writeAndConfirm(
                Data("ours".utf8), to: "a.lamp", in: store, condition: .ifAbsent
            )
        }
        #expect(store.downloads.count == 2)
        #expect(store.scratchFilesLeft().isEmpty)
    }

    @Test func aConditionWithoutAHeadRevisionDropsTheBody() async throws {
        let store = DownloadOnlyStore()
        store.files["a.lamp"] = .init(data: Data("body".utf8), revision: "\"r\"")
        let condition = try await LampSyncConditionalWrite.condition(for: "a.lamp", in: store, matching: "r")
        #expect(condition == .ifRevision("\"r\""))
        #expect(try await LampSyncConditionalWrite.condition(for: "b.lamp", in: store, matching: nil) == .ifAbsent)
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.condition(for: "b.lamp", in: store, matching: "r")
        }
        #expect(store.scratchFilesLeft().isEmpty)
    }

    @Test func anArchiveDecodesFromAFileAndDamageIsStillRefused() throws {
        let archive = try archive()
        let file = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: file) }
        try archive.compressedData().write(to: file)
        #expect(try LampSyncArchive.decode(compressedFileAt: file) == archive)

        let compressed = try archive.compressedData()
        #expect(throws: (any Error).self) {
            try LampSyncArchive.decode(compressedData: compressed.prefix(compressed.count / 2))
        }
        #expect(throws: (any Error).self) {
            try LampSyncArchive.decode(compressedData: Data("not an archive".utf8))
        }
    }

    private func archive() throws -> LampSyncArchive {
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
        return LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Modules/book.lamp", data: Data(repeating: 7, count: 300_000), modifiedAt: .distantPast),
        ])
    }
}

/// A store that answers bodies only through `download`, so a path that reads
/// a whole body into memory fails the test.
private final class DownloadOnlyStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: LampSyncRemoteFile] = [:]
    var readBackOverride: Data?
    private(set) var downloads: [URL] = []
    private(set) var sentFiles: [URL] = []

    func scratchFilesLeft() -> [URL] {
        (downloads + sentFiles).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        Issue.record("Read the whole body of \(path) into memory")
        return files[path]
    }

    /// No HEAD revision, so a condition has to ask GET.
    func revision(path: String) async throws -> String? { nil }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        if path == LampSyncLayout.archivePath {
            Issue.record("Held the whole archive in memory to send it")
        }
        files[path] = LampSyncRemoteFile(data: data, revision: "\"w\"")
        return nil // No revision in the response, so the write is confirmed by reading back.
    }

    func write(fileAt url: URL, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        sentFiles.append(url)
        files[path] = LampSyncRemoteFile(data: try Data(contentsOf: url), revision: "\"w\"")
        return nil
    }

    func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile? {
        downloads.append(url)
        #expect(url.lastPathComponent.hasPrefix(LampSyncScratchFile.prefix))
        guard let file = files[path] else { return nil }
        try (readBackOverride ?? file.data).write(to: url)
        return LampSyncDownloadedFile(url: url, revision: file.revision)
    }
}
