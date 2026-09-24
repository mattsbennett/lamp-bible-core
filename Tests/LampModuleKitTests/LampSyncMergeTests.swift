import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncMergeTests {
    private struct Record: Equatable {
        let id: String
        let revision: Int
        let content: String
    }

    @Test func recordSetMergesEveryKeyAndReportsConflicts() {
        let result = LampSyncMerge.records(
            local: [
                Record(id: "a", revision: 1, content: "old"),
                Record(id: "b", revision: 2, content: "local"),
                Record(id: "x", revision: 4, content: "mine"),
            ],
            incoming: [
                Record(id: "a", revision: 3, content: "new"),
                Record(id: "c", revision: 1, content: "first"),
                Record(id: "c", revision: 2, content: "duplicate"),
                Record(id: "x", revision: 4, content: "theirs"),
            ],
            key: { $0.id },
            modified: { $0.revision },
            sameContent: { $0.content == $1.content }
        )
        #expect(result.recordsToSave.map(\.id) == ["a", "b", "x", "c"])
        #expect(result.recordsToSave.map(\.content) == ["new", "local", "mine", "first"])
        #expect(result.conflicts.map(\.key) == ["x"])
        #expect(result.incomingCount == 2)
        #expect(result.localCount == 1)
    }

    @Test func recordDecisionMatchesVerifiedCases() {
        for local in -1...1 {
            for incoming in -1...1 {
                for sameContent in [false, true] {
                    let decision = LampSyncMerge.decide(
                        localModified: local,
                        incomingModified: incoming,
                        sameContent: sameContent
                    )
                    let expected: LampSyncMergeDecision =
                        incoming > local ? .incoming :
                        local > incoming ? .local :
                        sameContent ? .local : .conflict
                    #expect(decision == expected)
                }
            }
        }
        #expect(LampSyncMerge.decide(
            localModified: nil, incomingModified: nil, sameContent: false
        ) == .conflict)
    }

    @Test func resolvedRecordRevisionIsNewerThanBothCopies() {
        #expect(LampSyncMerge.resolutionTimestamp(
            localModified: 42, incomingModified: 42, now: 40
        ) == 43)
        #expect(LampSyncMerge.resolutionTimestamp(
            localModified: 42, incomingModified: 41, now: 100
        ) == 101)
        #expect(LampSyncMerge.resolutionTimestamp(
            localModified: Int.max, incomingModified: 0, now: 1
        ) == nil)
    }

    @Test func fileOrderIsStableAcrossThreeVersions() {
        let versions: [(Data, Date)] = [
            (Data([3]), Date(timeIntervalSince1970: 10.0001)),
            (Data([2]), Date(timeIntervalSince1970: 10.0006)),
            (Data([1]), Date(timeIntervalSince1970: 10.0012)),
        ]
        func merge(_ a: (Data, Date), _ b: (Data, Date)) -> (Data, Date) {
            LampSyncMerge.shouldReplaceFile(
                currentData: a.0, currentDate: a.1,
                incomingData: b.0, incomingDate: b.1
            ) ? b : a
        }
        for a in versions {
            for b in versions {
                for c in versions {
                    let left = merge(merge(a, b), c)
                    let right = merge(a, merge(b, c))
                    #expect(left.0 == right.0)
                    #expect(left.1 == right.1)
                }
            }
        }
        #expect(merge(versions[0], versions[1]).0 == Data([3]))
        #expect(merge(versions[0], versions[2]).0 == Data([1]))
    }
}
