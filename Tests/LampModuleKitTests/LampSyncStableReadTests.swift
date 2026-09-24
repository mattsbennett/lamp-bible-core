import Foundation
import Testing
@testable import LampModuleKit

private actor StableReadTokens {
    private let values: [String?]
    private var index = 0

    init(_ values: [String?]) { self.values = values }

    func next() -> String? {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

struct LampSyncStableReadTests {
    @Test func pairsBodyWithUnchangedProviderToken() async throws {
        let tokens = StableReadTokens(["same", "same"])
        let observed = try await LampSyncStableRead.read(
            revision: { await tokens.next() },
            data: { Data("body".utf8) }
        )
        #expect(observed.data == Data("body".utf8))
        #expect(observed.revision == "same")
    }

    @Test func rejectsTokenChangedDuringRead() async {
        let tokens = StableReadTokens(["before", "after"])
        await #expect(throws: LampSyncStableRead.ReadError.changedDuringRead) {
            try await LampSyncStableRead.read(
                revision: { await tokens.next() },
                data: { Data("body".utf8) }
            )
        }
    }

    @Test func rejectsExistingBodyWithoutProviderToken() async {
        let tokens = StableReadTokens([nil, nil])
        await #expect(throws: LampSyncStableRead.ReadError.missingRevision) {
            try await LampSyncStableRead.read(
                revision: { await tokens.next() },
                data: { Data("existing body".utf8) }
            )
        }
    }

    @Test func rejectsBodyThatDiffersFromEqualContentTokens() async {
        let a = Data("A".utf8)
        let b = Data("B".utf8)
        let token = LampSyncContentRevision.token(for: a)
        let tokens = StableReadTokens([token, token])
        await #expect(throws: LampSyncStableRead.ReadError.changedDuringRead) {
            try await LampSyncStableRead.read(
                revision: { await tokens.next() },
                data: { b },
                bodyRevision: LampSyncContentRevision.token(for:)
            )
        }
    }
}
