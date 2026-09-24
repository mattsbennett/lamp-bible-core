import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncArchiveRemoteTests {
    @Test func skipsGetOnlyForMatchingStrongCachedRevision() async throws {
        let body = try archive(moduleData: Data("module".utf8)).compressedData()
        let store = ArchiveStore(remote: .init(data: body, revision: "\"first\""))
        let unchanged = try await LampSyncArchiveRemote.readIfChanged(
            from: store, knownRevision: "\"first\""
        )
        if case .unchanged(let revision) = unchanged {
            #expect(revision == "\"first\"")
        } else {
            Issue.record("A matching strong revision should reuse the local cache")
        }
        #expect(await store.readCount() == 0)

        let changed = try await LampSyncArchiveRemote.readIfChanged(
            from: store, knownRevision: "\"older\""
        )
        if case .snapshot(let snapshot) = changed {
            #expect(snapshot?.revision == "\"first\"")
        } else {
            Issue.record("A changed revision must fetch the archive body")
        }
        #expect(await store.readCount() == 1)

        _ = try await LampSyncArchiveRemote.readIfChanged(
            from: store, knownRevision: "W/\"first\""
        )
        #expect(await store.readCount() == 2)
        _ = try await LampSyncArchiveRemote.readIfChanged(
            from: store, knownRevision: nil
        )
        #expect(await store.readCount() == 3)
        #expect(await store.revisionCount() == 2)
    }

    @Test func readsOneSnapshotAndPublishesOnlyAgainstItsRevision() async throws {
        let original = try archive(moduleData: Data("module".utf8))
        let store = ArchiveStore(
            remote: LampSyncRemoteFile(data: try original.compressedData(), revision: "\"first\"")
        )
        let snapshot = try #require(await LampSyncArchiveRemote.read(from: store))
        #expect(snapshot.revision == "\"first\"")
        #expect(snapshot.archive.entries.contains { $0.path == "Modules/book.lamp" })

        let updated = try snapshot.archive.replacingEntry(
            at: LampPortableBackupLayout.sharedPreferencesPath,
            with: Data("preferences".utf8)
        )
        let revision = try await LampSyncArchiveRemote.publish(
            updated, replacing: snapshot, in: store
        )
        #expect(revision == "\"next\"")
        #expect(await store.lastCondition() == .ifRevision("\"first\""))
        let saved = try #require(await LampSyncArchiveRemote.read(from: store))
        #expect(saved.archive.entries.first { $0.path == "Modules/book.lamp" }?.data == Data("module".utf8))
        #expect(saved.archive.entries.first {
            $0.path == LampPortableBackupLayout.sharedPreferencesPath
        }?.data == Data("preferences".utf8))

        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncArchiveRemote.publish(updated, replacing: snapshot, in: store)
        }
    }

    @Test func createsOnlyWhenAbsentAndRejectsAnUnversionedExistingArchive() async throws {
        let archive = try archive(moduleData: Data("module".utf8))
        let store = ArchiveStore(remote: nil)
        #expect(try await LampSyncArchiveRemote.read(from: store) == nil)
        _ = try await LampSyncArchiveRemote.publish(archive, replacing: nil, in: store)
        #expect(await store.lastCondition() == .ifAbsent)

        let remote = LampSyncRemoteFile(data: try archive.compressedData(), revision: nil)
        let unversioned = ArchiveStore(remote: remote)
        let snapshot = try #require(await LampSyncArchiveRemote.read(from: unversioned))
        #expect(snapshot.archive == archive)
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncArchiveRemote.publish(archive, replacing: snapshot, in: unversioned)
        }
    }

    private func archive(moduleData: Data) throws -> LampSyncArchive {
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
            .init(path: "Modules/book.lamp", data: moduleData, modifiedAt: .distantPast),
        ])
    }
}

private actor ArchiveStore: LampSyncRemoteStore {
    private var remote: LampSyncRemoteFile?
    private var condition: LampSyncWriteCondition?
    private var reads = 0
    private var revisions = 0

    init(remote: LampSyncRemoteFile?) { self.remote = remote }

    func lastCondition() -> LampSyncWriteCondition? { condition }
    func readCount() -> Int { reads }
    func revisionCount() -> Int { revisions }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? {
        reads += 1
        return remote
    }
    func revision(path: String) async throws -> String? {
        revisions += 1
        return remote?.revision
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        self.condition = condition
        switch condition {
        case .ifAbsent where remote != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let revision) where remote?.revision != revision:
            throw LampSyncConditionalWrite.WriteError.conflict
        default:
            break
        }
        remote = LampSyncRemoteFile(data: data, revision: "\"next\"")
        return nil // Confirm through GET when PUT omits its ETag.
    }
}
