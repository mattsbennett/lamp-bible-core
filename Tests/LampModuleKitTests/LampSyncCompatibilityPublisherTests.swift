import Foundation
import Testing
@testable import LampModuleKit

private actor CompatibilityBatchStore: LampSyncRemoteStore {
    private var files: [String: LampSyncRemoteFile] = [:]
    private var attemptedPaths: [String] = []
    private var failingPath: String?
    private var nextRevision = 0

    func failNextWrite(to path: String) { failingPath = path }
    func attempts() -> [String] { attemptedPaths }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { files[path] }
    func revision(path: String) async throws -> String? { files[path]?.revision }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        attemptedPaths.append(path)
        if failingPath == path {
            failingPath = nil
            throw LampSyncConditionalWrite.WriteError.conflict
        }
        switch condition {
        case .ifAbsent where files[path] != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let expected) where files[path]?.revision != expected:
            throw LampSyncConditionalWrite.WriteError.conflict
        default:
            break
        }
        nextRevision += 1
        files[path] = LampSyncRemoteFile(
            data: data,
            revision: "\"compatibility-\(nextRevision)\""
        )
        return nil // Confirm a PUT without ETag by reading its uploaded bytes.
    }
}

private actor PreparedDirectories {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

struct LampSyncCompatibilityPublisherTests {
    @Test func nestedMediaDirectoriesArePreparedBeforeTheAttachment() async throws {
        let store = CompatibilityBatchStore()
        let directories = PreparedDirectories()
        let media = LampSyncCompatibilityPublisher.File(
            remotePath: "DevotionalMedia/devotionals/daily/image.png",
            data: Data("image".utf8), condition: .ifAbsent
        )
        let module = LampSyncCompatibilityPublisher.File(
            remotePath: "Devotionals/devotionals.lamp",
            data: Data("module".utf8), condition: .ifAbsent
        )
        _ = try await LampSyncCompatibilityPublisher.publish(
            [media, module], in: store,
            prepareDirectory: { await directories.append($0) }
        )
        #expect(await directories.all() == [
            "DevotionalMedia", "DevotionalMedia/devotionals",
            "DevotionalMedia/devotionals/daily", "Devotionals",
        ])
        #expect(await store.attempts() == [media.remotePath, module.remotePath])
    }

    @Test func failedMiddleWriteStopsBatchAndRetryUsesFreshConditions() async throws {
        let store = CompatibilityBatchStore()
        let directories = PreparedDirectories()
        let first = LampSyncCompatibilityPublisher.File(
            remotePath: "Notes/first.lamp",
            data: Data("first".utf8),
            condition: .ifAbsent
        )
        let second = LampSyncCompatibilityPublisher.File(
            remotePath: "Notes/second.lamp",
            data: Data("second".utf8),
            condition: .ifAbsent
        )
        let third = LampSyncCompatibilityPublisher.File(
            remotePath: "Highlights/third.lamp",
            data: Data("third".utf8),
            condition: .ifAbsent
        )
        await store.failNextWrite(to: second.remotePath)

        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncCompatibilityPublisher.publish(
                [first, second, third], in: store,
                prepareDirectory: { await directories.append($0) }
            )
        }
        #expect(await store.attempts() == [first.remotePath, second.remotePath])
        #expect(await directories.all() == ["Notes"])
        let committed = try #require(await store.read(path: first.remotePath))
        #expect(committed.data == first.data)
        #expect(try await store.read(path: second.remotePath)?.data == nil)
        #expect(try await store.read(path: third.remotePath)?.data == nil)

        let retryFirst = LampSyncCompatibilityPublisher.File(
            remotePath: first.remotePath,
            data: first.data,
            condition: .ifRevision(try #require(committed.revision))
        )
        let revisions = try await LampSyncCompatibilityPublisher.publish(
            [retryFirst, second, third], in: store,
            prepareDirectory: { await directories.append($0) }
        )
        #expect(revisions.count == 3)
        #expect(await directories.all() == ["Notes", "Notes", "Highlights"])
        #expect(try await store.read(path: second.remotePath)?.data == second.data)
        #expect(try await store.read(path: third.remotePath)?.data == third.data)
    }

    @Test func unsafeRemotePathFailsBeforePreparingOrWriting() async throws {
        let store = CompatibilityBatchStore()
        let directories = PreparedDirectories()
        let unsafe = LampSyncCompatibilityPublisher.File(
            remotePath: "Notes/../outside.lamp",
            data: Data("outside".utf8), condition: .ifAbsent
        )
        await #expect(throws: LampSyncRemoteDirectories.DirectoryError.self) {
            try await LampSyncCompatibilityPublisher.publish(
                [unsafe], in: store,
                prepareDirectory: { await directories.append($0) }
            )
        }
        #expect(await directories.all().isEmpty)
        #expect(await store.attempts().isEmpty)
    }
}
