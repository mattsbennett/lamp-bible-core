import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

struct LampSyncPlanProgressTests {
    // MARK: - Reading IDs

    /// A plan ID with underscores of its own comes back whole, where the
    /// phone's `plan_id` column would hold only "the".
    @Test func readsAReadingIDFromTheRight() throws {
        let id = LampLibrary.completedReadingID(
            planID: "the_bible_companion", day: 60, readingIndex: 2, year: 2026
        )
        let parts = try #require(LampSyncPlanProgress.readingParts(of: id))

        #expect(parts.planID == "the_bible_companion")
        #expect(parts.day == 60)
        #expect(parts.readingIndex == 2)
        #expect(parts.year == 2026)
    }

    @Test func refusesWhatIsNotAReadingID() {
        #expect(LampSyncPlanProgress.readingParts(of: "plan_1_r0_2026") == nil)
        #expect(LampSyncPlanProgress.readingParts(of: "_1_0_2026") == nil)
        #expect(LampSyncPlanProgress.readingParts(of: "1_0_2026") == nil)
    }

    // MARK: - Recording

    @Test func recordsTicksAndSelectionsAsSet() {
        var progress = LampSyncPlanProgress()
        progress.recordSelection("mcheyne", at: 1_000)
        progress.recordCompletion("mcheyne_1_0_2026", at: 2_000)
        progress.recordCompletion("mcheyne_1_1_2026", at: 3_000)
        progress.recordUncompletion("mcheyne_1_1_2026", at: 4_000)

        #expect(progress.selectedPlanIDs == ["mcheyne"])
        #expect(progress.completedReadings == ["mcheyne_1_0_2026": 2_000])
    }

    /// Unticking on a device whose clock is behind the one that ticked still
    /// unticks: the untick is stamped after the tick it undoes.
    @Test func anUntickBeatsATickFromAClockAhead() throws {
        var progress = try decoded(readings: ["r_1_0_2026": .init(presentSince: 9_000)])
        progress.recordUncompletion("r_1_0_2026", at: 5_000)

        #expect(progress.readings["r_1_0_2026"]?.deletedAt == 9_001)
        #expect(progress.completedReadings.isEmpty)
    }

    /// Seeding is safe on every pass: it never clears, and a held copy
    /// recorded at 0 loses to any change recorded elsewhere.
    @Test func recordingWhatIsHeldOnlySets() throws {
        var progress = try decoded(
            readings: ["r_1_0_2026": .init(presentSince: 1_000, deletedAt: 2_000)],
            selections: ["gone": .init(presentSince: 500, deletedAt: 1_500)]
        )
        progress.recordHeld(
            completed: ["r_1_0_2026": 1_000, "r_1_1_2026": 3_000],
            selected: ["gone": 0, "kept": 0]
        )
        let again = progress
        progress.recordHeld(
            completed: ["r_1_0_2026": 1_000, "r_1_1_2026": 3_000],
            selected: ["gone": 0, "kept": 0]
        )

        #expect(progress == again)
        #expect(progress.completedReadings == ["r_1_1_2026": 3_000])
        #expect(progress.selectedPlanIDs == ["kept"])
    }

    // MARK: - Applying

    @Test func appliesEveryPlanAndReadingAtOnce() throws {
        let progress = try decoded(
            readings: [
                "new_1_0_2026": .init(presentSince: 4_000),
                "later_1_0_2026": .init(presentSince: 6_000),
                "unticked_1_0_2026": .init(presentSince: 1_000, deletedAt: 2_000),
                "since_1_0_2026": .init(presentSince: 1_000, deletedAt: 2_000),
            ],
            selections: [
                "chosen": .init(presentSince: 1_000),
                "dropped": .init(presentSince: 1_000, deletedAt: 3_000),
            ]
        )

        let changes = progress.changes(
            toApplyTo: [
                "later_1_0_2026": 5_000,
                "unticked_1_0_2026": 1_500,
                "since_1_0_2026": 2_500,
                "unknown_1_0_2026": 7_000,
            ],
            selected: ["dropped": 0, "mine": 0]
        )

        #expect(changes.complete == ["new_1_0_2026": 4_000, "later_1_0_2026": 6_000])
        #expect(changes.uncomplete == ["unticked_1_0_2026"])
        #expect(changes.select == ["chosen"])
        #expect(changes.deselect == ["dropped"])
    }

    // MARK: - In the bundle

    /// An app from before plan progress decodes the bundle, passes over the
    /// part and writes the bundle back without it. The next client's
    /// contribution puts the part back, and nothing reads as unticked.
    @Test func aPartAnOlderAppDroppedIsRestored() throws {
        var mine = LampSyncPlanProgress()
        mine.recordCompletion("mcheyne_1_0_2026", at: 1_000)
        var bundle = LampSyncSettingsBundle()
        try LampSyncBundleLedgers.Contribution(personal: .init(), planProgress: mine).apply(to: &bundle)
        let withPart = try LampSyncSettingsBundle.decode(bundle.encoded())
        #expect(LampSyncBundleLedgers.planProgress(in: withPart)?.completedReadings == ["mcheyne_1_0_2026": 1_000])

        var rewritten = withPart
        rewritten.planProgress = nil
        #expect(LampSyncBundleLedgers.planProgress(in: rewritten) == nil)
        #expect(mine.changes(toApplyTo: ["mcheyne_1_0_2026": 1_000], selected: [:]).isEmpty)

        try LampSyncBundleLedgers.Contribution(personal: .init(), planProgress: mine).apply(to: &rewritten)
        #expect(LampSyncBundleLedgers.planProgress(in: rewritten) == mine)
    }

    @Test func aBundleWithoutThePartEncodesAsBefore() throws {
        let bundle = LampSyncSettingsBundle(userSettings: Data("phone".utf8))
        let json = String(decoding: try (bundle.encoded() as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)

        #expect(!json.contains("planProgress"))
        #expect(try LampSyncSettingsBundle.decode(bundle.encoded()) == bundle)
    }

    // MARK: - File format

    @Test func encodesTheSameLedgerToTheSameBytes() throws {
        var a = LampSyncPlanProgress()
        var b = LampSyncPlanProgress()
        for index in 0..<20 {
            a.recordCompletion("plan_\(index)_0_2026", at: Int64(index))
        }
        for index in (0..<20).reversed() {
            b.recordCompletion("plan_\(index)_0_2026", at: Int64(index))
        }

        #expect(try a.encoded() == b.encoded())
        #expect(try LampSyncPlanProgress.decode(a.encoded()) == a)
    }

    /// A client that read a later format in part and wrote it back would drop
    /// what it couldn't read.
    @Test func refusesALaterFormat() {
        let later = Data(#"{"formatVersion":2,"readings":{}}"#.utf8)
        #expect(throws: (any Error).self) { try LampSyncPlanProgress.decode(later) }
    }

    private func decoded(
        readings: [String: LampSyncPlanProgress.Mark] = [:],
        selections: [String: LampSyncPlanProgress.Mark] = [:]
    ) throws -> LampSyncPlanProgress {
        struct File: Encodable {
            let formatVersion = LampSyncPlanProgress.formatVersion
            let readings: [String: LampSyncPlanProgress.Mark]
            let selections: [String: LampSyncPlanProgress.Mark]
        }
        return try LampSyncPlanProgress.decode(
            JSONEncoder().encode(File(readings: readings, selections: selections))
        )
    }
}
