import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncConditionalWriteTests {
    @Test func onlyStrongRevisionCanBecomeStoredToken() {
        #expect(LampSyncConditionalWrite.strongToken(for: "\"old\"") == "old")
        #expect(LampSyncConditionalWrite.strongToken(for: "W/\"old\"") == nil)
        #expect(LampSyncConditionalWrite.strongToken(for: "\"a\",\"b\"") == nil)
        #expect(LampSyncConditionalWrite.strongToken(for: nil) == nil)
    }

    @Test func combinedETagCannotBecomeAConditionalWrite() {
        #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try LampSyncConditionalWrite.condition(forExistingRevision: "\"a\",\"b\"")
        }
    }

    @Test func preparesOnlyAgainstTheExpectedStrongRevision() async throws {
        let store = ConditionalStore(
            headRevision: "\"old\"",
            remote: LampSyncRemoteFile(data: Data("old".utf8), revision: "\"old\"")
        )
        let condition = try await LampSyncConditionalWrite.condition(
            for: "settings.db", in: store, matching: "old"
        )
        #expect(condition == .ifRevision("\"old\""))
        await store.setHeadRevision("\"new\"")
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.condition(
                for: "settings.db", in: store, matching: "old"
            )
        }
        await store.setHeadRevision(nil)
        let recovered = try await LampSyncConditionalWrite.condition(
            for: "settings.db", in: store, matching: "old"
        )
        #expect(recovered == .ifRevision("\"old\""))
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.condition(
                for: "settings.db", in: store, matching: nil
            )
        }
        await store.setRemote(
            LampSyncRemoteFile(data: Data("old".utf8), revision: "W/\"old\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.condition(
                for: "settings.db", in: store, matching: "old"
            )
        }
        await store.setRemote(nil)
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.condition(
                for: "settings.db", in: store, matching: "old"
            )
        }
        let absent = try await LampSyncConditionalWrite.condition(
            for: "settings.db", in: store, matching: nil
        )
        #expect(absent == .ifAbsent)
    }

    @Test func confirmsAWriteFromOneMatchingGetWhenPutOmitsItsRevision() async throws {
        let data = Data("new settings".utf8)
        let store = ConditionalStore(
            headRevision: nil,
            remote: nil,
            writeRevision: nil,
            remoteAfterWrite: LampSyncRemoteFile(data: data, revision: "\"committed\"")
        )
        let revision = try await LampSyncConditionalWrite.writeAndConfirm(
            data, to: "settings.db", in: store, condition: .ifAbsent
        )
        #expect(revision == "\"committed\"")
        #expect(await store.lastCondition() == .ifAbsent)

        await store.setRemoteAfterWrite(
            LampSyncRemoteFile(data: Data("other writer".utf8), revision: "\"later\"")
        )
        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.writeAndConfirm(
                data, to: "settings.db", in: store, condition: .ifAbsent
            )
        }
    }
}

private actor ConditionalStore: LampSyncRemoteStore {
    private var headRevision: String?
    private var remote: LampSyncRemoteFile?
    private let writeRevision: String?
    private var remoteAfterWrite: LampSyncRemoteFile?
    private var condition: LampSyncWriteCondition?

    init(
        headRevision: String?,
        remote: LampSyncRemoteFile?,
        writeRevision: String? = nil,
        remoteAfterWrite: LampSyncRemoteFile? = nil
    ) {
        self.headRevision = headRevision
        self.remote = remote
        self.writeRevision = writeRevision
        self.remoteAfterWrite = remoteAfterWrite
    }

    func setHeadRevision(_ value: String?) { headRevision = value }
    func setRemote(_ value: LampSyncRemoteFile?) { remote = value }
    func setRemoteAfterWrite(_ value: LampSyncRemoteFile?) { remoteAfterWrite = value }
    func lastCondition() -> LampSyncWriteCondition? { condition }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { remote }
    func revision(path: String) async throws -> String? { headRevision }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        self.condition = condition
        remote = remoteAfterWrite
        return writeRevision
    }
}
