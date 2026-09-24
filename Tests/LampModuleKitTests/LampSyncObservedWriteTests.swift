import CryptoKit
import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncObservedWriteTests {
    @Test func refusesToReplaceAFileChangedSinceImport() async throws {
        let store = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: Data("remote edit".utf8), revision: "\"new\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncObservedWrite.publish(
                Data("local edit".utf8), to: "Notes/notes.lamp",
                in: store, matching: "\"old\""
            )
        }
        #expect(await store.writeCount() == 0)
    }

    @Test func usesTheObservedRevisionAndConfirmsThePublishedBody() async throws {
        let old = Data("old module".utf8)
        let store = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: old, revision: "\"old\"")
        )
        let revision = try await LampSyncObservedWrite.publish(
            Data("merged module".utf8), to: "Notes/notes.lamp",
            in: store, matching: "\"old\""
        )
        #expect(revision == "\"next\"")
        #expect(await store.lastCondition() == .ifRevision("\"old\""))
        #expect(await store.writeCount() == 1)
    }

    @Test func acceptsAnOlderContentDigestAndCreateOnlyWrites() async throws {
        let old = Data("old module".utf8)
        let digest = SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined()
        let existing = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: old, revision: "\"old\"")
        )
        _ = try await LampSyncObservedWrite.publish(
            Data("merged module".utf8), to: "Notes/notes.lamp",
            in: existing, matching: digest
        )
        #expect(await existing.lastCondition() == .ifRevision("\"old\""))

        let absent = ObservedWriteStore(remote: nil)
        _ = try await LampSyncObservedWrite.publish(
            old, to: "Notes/notes.lamp", in: absent, matching: nil
        )
        #expect(await absent.lastCondition() == .ifAbsent)
    }

    @Test func refusesAnExistingFileWithoutAStrongRevision() async throws {
        let store = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: Data("old".utf8), revision: nil)
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncObservedWrite.publish(
                Data("new".utf8), to: "Notes/notes.lamp", in: store, matching: nil
            )
        }
        #expect(await store.writeCount() == 0)
    }

    @Test func unknownMediaBaseMayRepeatIdenticalBytesButCannotReplaceDifferentBytes() async throws {
        let existing = Data("photo".utf8)
        let store = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: existing, revision: "\"media\"")
        )
        _ = try await LampSyncObservedWrite.publish(
            existing, to: "DevotionalMedia/photo.jpg", in: store, matching: nil
        )
        #expect(await store.lastCondition() == .ifRevision("\"media\""))

        let changed = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: Data("other photo".utf8), revision: "\"changed\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncObservedWrite.publish(
                existing, to: "DevotionalMedia/photo.jpg", in: changed, matching: nil
            )
        }
        #expect(await changed.writeCount() == 0)
    }

    @Test func archivePayloadMayReplaceOnlyItsSupersededFolderRevision() async throws {
        let archived = Data("archive module".utf8)
        let file = LampCompatibilityManifest.File(
            path: "Notes/notes.lamp",
            data: archived,
            baseRevision: "\"folder-base\""
        )
        let oldFolder = Data("older folder module".utf8)
        let matching = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: oldFolder, revision: "\"folder-base\"")
        )
        _ = try await LampSyncObservedWrite.publish(
            archived, to: file.path, in: matching,
            matching: file.sha256, supersededBy: file
        )
        #expect(await matching.lastCondition() == .ifRevision("\"folder-base\""))

        let changed = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: Data("later edit".utf8), revision: "\"later\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncObservedWrite.publish(
                archived, to: file.path, in: changed,
                matching: file.sha256, supersededBy: file
            )
        }
        #expect(await changed.writeCount() == 0)

        let wrongPath = LampCompatibilityManifest.File(
            path: "Highlights/other.lamp",
            data: archived,
            baseRevision: "\"folder-base\""
        )
        let unrelated = ObservedWriteStore(
            remote: LampSyncRemoteFile(data: oldFolder, revision: "\"folder-base\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncObservedWrite.publish(
                archived, to: file.path, in: unrelated,
                matching: file.sha256, supersededBy: wrongPath
            )
        }
        #expect(await unrelated.writeCount() == 0)
    }
}

private actor ObservedWriteStore: LampSyncRemoteStore {
    private var remote: LampSyncRemoteFile?
    private var condition: LampSyncWriteCondition?
    private var writes = 0

    init(remote: LampSyncRemoteFile?) { self.remote = remote }

    func writeCount() -> Int { writes }
    func lastCondition() -> LampSyncWriteCondition? { condition }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { remote }
    func revision(path: String) async throws -> String? { remote?.revision }

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
        writes += 1
        remote = LampSyncRemoteFile(data: data, revision: "\"next\"")
        return nil
    }
}
