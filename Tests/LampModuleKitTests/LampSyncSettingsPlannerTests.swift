import Testing
@testable import LampModuleKit

struct LampSyncSettingsPlannerTests {
    private struct Reading: Equatable {
        let time: Int
        let metadata: String
    }

    @Test func mergesIndependentReadingChangesAndSettings() throws {
        let plan = try LampSyncSettingsPlanner.plan(
            baseSettings: "old",
            baseReadingIDs: Set(["kept", "deleted-locally", "deleted-remotely"]),
            localSettings: "old",
            localReadings: [
                "kept": Reading(time: 1, metadata: "a"),
                "deleted-remotely": Reading(time: 1, metadata: "b"),
                "added-locally": Reading(time: 2, metadata: "c")
            ],
            remoteSettings: "new",
            remoteReadings: [
                "kept": Reading(time: 1, metadata: "a"),
                "deleted-locally": Reading(time: 1, metadata: "d"),
                "added-remotely": Reading(time: 3, metadata: "e")
            ],
            revision: \.time
        )
        #expect(plan.settingsDecision == .remote)
        #expect(plan.readingIDs == Set(["kept", "added-locally", "added-remotely"]))
        #expect(plan.needsPublish)
    }

    @Test func laterCompletionWinsOnEitherSide() throws {
        let older = Reading(time: 1, metadata: "a")
        let newer = Reading(time: 2, metadata: "a")
        let localWins = try LampSyncSettingsPlanner.plan(
            baseSettings: 0, baseReadingIDs: Set(["one"]),
            localSettings: 0, localReadings: ["one": newer],
            remoteSettings: 0, remoteReadings: ["one": older],
            revision: \.time
        )
        #expect(localWins.readings["one"] == newer)
        #expect(localWins.needsPublish)

        let remoteWins = try LampSyncSettingsPlanner.plan(
            baseSettings: 0, baseReadingIDs: Set(["one"]),
            localSettings: 0, localReadings: ["one": older],
            remoteSettings: 0, remoteReadings: ["one": newer],
            revision: \.time
        )
        #expect(remoteWins.readings["one"] == newer)
        #expect(!remoteWins.needsPublish)
    }

    @Test func equalRevisionWithDifferentMetadataConflicts() {
        #expect(throws: LampSyncSettingsPlanner.MergeError.concurrentReading) {
            try LampSyncSettingsPlanner.plan(
                baseSettings: 0, baseReadingIDs: Set(["one"]),
                localSettings: 0,
                localReadings: ["one": Reading(time: 1, metadata: "local")],
                remoteSettings: 0,
                remoteReadings: ["one": Reading(time: 1, metadata: "remote")],
                revision: \.time
            )
        }
    }

    @Test func divergentSettingsConflict() {
        #expect(throws: LampSyncSettingsPlanner.MergeError.concurrentSettings) {
            try LampSyncSettingsPlanner.plan(
                baseSettings: "base", baseReadingIDs: Set<String>(),
                localSettings: "local", localReadings: [String: Reading](),
                remoteSettings: "remote", remoteReadings: [String: Reading](),
                revision: \.time
            )
        }
    }

    @Test func bootstrapRequiresRevisionOrderAndKeepsRemoteReadings() throws {
        let remote = ["one": Reading(time: 1, metadata: "remote")]
        let localWins = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "local", localRevision: 3,
            localReadings: remote,
            remoteSettings: "remote", remoteRevision: 2,
            remoteReadings: remote
        )
        #expect(localWins.settingsDecision == .local)
        #expect(localWins.readings == remote)
        #expect(localWins.needsPublish)

        let remoteWins = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "local", localRevision: 1,
            localReadings: remote,
            remoteSettings: "remote", remoteRevision: 2,
            remoteReadings: remote
        )
        #expect(remoteWins.settingsDecision == .remote)
        #expect(!remoteWins.needsPublish)

        #expect(throws: LampSyncSettingsPlanner.MergeError.concurrentSettings) {
            try LampSyncSettingsPlanner.planWithoutBase(
                localSettings: "local", localRevision: 2,
                localReadings: remote,
                remoteSettings: "remote", remoteRevision: 2,
                remoteReadings: remote
            )
        }

        #expect(throws: LampSyncSettingsPlanner.MergeError.concurrentReading) {
            try LampSyncSettingsPlanner.planWithoutBase(
                localSettings: "same", localRevision: 2,
                localReadings: ["local": Reading(time: 1, metadata: "local")],
                remoteSettings: "same", remoteRevision: 2,
                remoteReadings: remote
            )
        }
    }
}
