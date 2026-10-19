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

    /// The device failure this came from: a pass compared the revision a
    /// PROPFIND gave it against the one a GET gave it, as written, and
    /// concluded on every launch that the archive had moved underneath it.
    @Test func aRevisionNamesTheSameBodyHoweverItIsSpelled() {
        #expect(LampSyncConditionalWrite.namesSameRevision("\"abc\"", "abc"))
        #expect(LampSyncConditionalWrite.namesSameRevision("abc", "\"abc\""))
        #expect(LampSyncConditionalWrite.namesSameRevision("W/\"abc\"", "\"abc\""))
        #expect(LampSyncConditionalWrite.namesSameRevision("\"abc\"", "\"abc\""))
        #expect(LampSyncConditionalWrite.namesSameRevision(nil, nil))
    }

    @Test func differentBodiesStillDiffer() {
        #expect(!LampSyncConditionalWrite.namesSameRevision("\"abc\"", "\"abd\""))
        #expect(!LampSyncConditionalWrite.namesSameRevision("\"abc\"", nil))
        #expect(!LampSyncConditionalWrite.namesSameRevision(nil, "abc"))
    }


    // MARK: - Judging a write after it failed

    /// The case that matters for what a user is told: the write was refused,
    /// so the file really is not on the server.
    @Test func aFileStillAtItsConditionWasNotWritten() {
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifRevision("\"abc\""), serverRevision: "\"abc\""
        ) == .didNotWrite)
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifAbsent, serverRevision: nil
        ) == .didNotWrite)
    }

    /// The write landed and confirming it is what failed, so telling the user
    /// the file is missing would be wrong.
    @Test func aFileThatMovedOffItsConditionWasWritten() {
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifRevision("\"abc\""), serverRevision: "\"def\""
        ) == .wrote)
    }

    /// Nothing was asserted, so nothing could be refused on a precondition:
    /// a failure came from confirming, after the write went through.
    @Test func anUnconditionalWriteCannotHaveBeenRefused() {
        #expect(LampSyncConditionalWrite.landing(
            condition: .unconditional, serverRevision: nil
        ) == .wrote)
    }

    /// A server may spell the same ETag differently between a PROPFIND and a
    /// PUT. Compared as text, an unchanged file reads as a written one, and
    /// a refused write would be reported to the user as a success.
    @Test func theSameRevisionSpeltTwoWaysIsStillTheSameFile() {
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifRevision("\"abc\""), serverRevision: "W/\"abc\""
        ) == .didNotWrite)
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifRevision("abc"), serverRevision: "\"abc\""
        ) == .didNotWrite)
    }

    /// An if-absent write to a path that now holds something is genuinely
    /// ambiguous — this write may have put it there, or what is there may be
    /// what refused the write — and saying so is better than guessing.
    @Test func anIfAbsentWriteOntoSomethingPresentCannotBeJudged() {
        #expect(LampSyncConditionalWrite.landing(
            condition: .ifAbsent, serverRevision: "\"abc\""
        ) == .undecidable)
    }


    // MARK: - Confirming a write the server has not finished settling

    /// A server that answers the confirming read with the body it held
    /// before the write has not taken the write away from us. Read once and
    /// that looks exactly like another device having won, and the user is
    /// told they lost a race over a file that is sitting on the server.
    @Test func aConfirmingReadThatLagsIsAskedAgain() async throws {
        let store = SettlingStore(previousBody: Data("before".utf8), staleReads: 1)

        let revision = try await LampSyncConditionalWrite.writeAndConfirm(
            Data("published".utf8), to: "Library/a.lamp", in: store, condition: .ifAbsent
        )

        #expect(revision == "\"settled\"")
        let reads = await store.reads()
        #expect(reads == 2)
    }

    /// Asking twice must not turn somebody else's write into ours: bytes
    /// that stay different are a real conflict however often they are read.
    @Test func bytesThatStayDifferentAreStillAConflict() async {
        let store = SettlingStore(previousBody: Data("someone else".utf8), staleReads: .max)

        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncConditionalWrite.writeAndConfirm(
                Data("published".utf8), to: "Library/a.lamp", in: store, condition: .ifAbsent
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


/// A store whose PUT returns no ETag, and whose first reads answer with the
/// body it held before that write.
private actor SettlingStore: LampSyncRemoteStore {
    private let previousBody: Data
    private var staleReads: Int
    private var readCount = 0
    private var written: Data?

    init(previousBody: Data, staleReads: Int) {
        self.previousBody = previousBody
        self.staleReads = staleReads
    }

    func reads() -> Int { readCount }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func revision(path: String) async throws -> String? { "\"settled\"" }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        readCount += 1
        if staleReads > 0 {
            staleReads -= 1
            return LampSyncRemoteFile(data: previousBody, revision: "\"stale\"")
        }
        guard let written else { return nil }
        return LampSyncRemoteFile(data: written, revision: "\"settled\"")
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        written = data
        return nil // No ETag on the PUT, so the caller confirms by reading.
    }
}
