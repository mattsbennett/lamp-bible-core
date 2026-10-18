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
            remoteReadings: remote,
            revision: \.time
        )
        #expect(localWins.settingsDecision == .local)
        #expect(localWins.readings == remote)
        #expect(localWins.needsPublish)

        let remoteWins = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "local", localRevision: 1,
            localReadings: remote,
            remoteSettings: "remote", remoteRevision: 2,
            remoteReadings: remote,
            revision: \.time
        )
        #expect(remoteWins.settingsDecision == .remote)
        #expect(!remoteWins.needsPublish)

        #expect(throws: LampSyncSettingsPlanner.MergeError.concurrentSettings) {
            try LampSyncSettingsPlanner.planWithoutBase(
                localSettings: "local", localRevision: 2,
                localReadings: remote,
                remoteSettings: "remote", remoteRevision: 2,
                remoteReadings: remote,
                revision: \.time
            )
        }

    }

    /// Refusing a baseless merge because the two sides differ was a dead end:
    /// nothing about the refusal changed the next attempt's inputs, so a
    /// client could never earn the baseline that would resolve it.
    @Test func bootstrapKeepsRowsOnlyOneSideHolds() throws {
        let plan = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "same", localRevision: 2,
            localReadings: ["mine": Reading(time: 1, metadata: "local")],
            remoteSettings: "same", remoteRevision: 2,
            remoteReadings: ["theirs": Reading(time: 1, metadata: "remote")],
            revision: \.time
        )

        #expect(plan.readingIDs == ["mine", "theirs"])
        // The remote has not seen "mine" yet, so this has to go up.
        #expect(plan.needsPublish)
    }

    /// A row both sides hold is not ambiguous — they agree it exists — so the
    /// newer copy wins, the same rule a baseline merge would apply.
    @Test func bootstrapTakesTheNewerOfARowBothSidesHold() throws {
        let localNewer = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "same", localRevision: 2,
            localReadings: ["one": Reading(time: 9, metadata: "local")],
            remoteSettings: "same", remoteRevision: 2,
            remoteReadings: ["one": Reading(time: 4, metadata: "remote")],
            revision: \.time
        )
        #expect(localNewer.readings["one"]?.metadata == "local")
        #expect(localNewer.needsPublish)

        let remoteNewer = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "same", localRevision: 2,
            localReadings: ["one": Reading(time: 4, metadata: "local")],
            remoteSettings: "same", remoteRevision: 2,
            remoteReadings: ["one": Reading(time: 9, metadata: "remote")],
            revision: \.time
        )
        #expect(remoteNewer.readings["one"]?.metadata == "remote")
        #expect(!remoteNewer.needsPublish)
    }

    /// An exact tie keeps the remote, deterministically: this client is the
    /// one joining, and the alternative is publishing over what it just read.
    @Test func bootstrapKeepsTheRemoteCopyOnAnExactTie() throws {
        let plan = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "same", localRevision: 2,
            localReadings: ["one": Reading(time: 5, metadata: "local")],
            remoteSettings: "same", remoteRevision: 2,
            remoteReadings: ["one": Reading(time: 5, metadata: "remote")],
            revision: \.time
        )

        #expect(plan.readings["one"]?.metadata == "remote")
        #expect(!plan.needsPublish)
    }

    /// Agreeing on every row still leaves nothing to publish.
    @Test func bootstrapPublishesNothingWhenBothSidesAgree() throws {
        let rows = ["one": Reading(time: 1, metadata: "same")]
        let plan = try LampSyncSettingsPlanner.planWithoutBase(
            localSettings: "same", localRevision: 1,
            localReadings: rows,
            remoteSettings: "same", remoteRevision: 2,
            remoteReadings: rows,
            revision: \.time
        )

        #expect(!plan.needsPublish)
        #expect(plan.readings == rows)
    }
}
