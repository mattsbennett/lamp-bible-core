import Foundation
import LampCore
import Testing

/// Two devices that changed the same writing at the same second, which is the
/// one case sync cannot decide for itself.
struct LampSyncConflictTests {
    private struct Devices {
        let root: URL
        let a: LampLibrary
        let b: LampLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-sync-conflict-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            a = LampLibrary(rootURL: root.appendingPathComponent("A"))
            b = LampLibrary(rootURL: root.appendingPathComponent("B"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func writing(
        _ id: String,
        title: String,
        body: String,
        modified: Date
    ) -> LampDevotional {
        LampDevotional(
            id: id, moduleID: "personal-devotionals", moduleName: "My Writing",
            title: title, content: body, created: modified, lastModified: modified
        )
    }

    /// Saves both versions at one timestamp and hands device A the file device
    /// B would have published, which is what a sync run does.
    private func collide(
        _ devices: Devices,
        here: String,
        there: String,
        at moment: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> URL {
        try await devices.a.savePersonalDevotional(
            writing("w", title: "Shared", body: here, modified: moment),
            preserveLastModified: true
        )
        try await devices.b.savePersonalDevotional(
            writing("w", title: "Shared", body: there, modified: moment),
            preserveLastModified: true
        )
        let file = devices.root.appendingPathComponent("w-\(UUID().uuidString).json")
        try await devices.b.personalDevotionalDocument(id: "w").jsonData.write(to: file)
        return file
    }

    @Test func anEqualTimeDisagreementIsSetAsideRatherThanStoppingTheRun() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")

        // The run finishes. Before, this threw and took the whole sync with it.
        let imported = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        #expect(imported.isEmpty)
        #expect(try await devices.a.personalDevotionals().map(\.content) == ["Written here"])

        let conflicts = try await devices.a.pendingSyncConflicts()
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.kind == .devotional)
        #expect(conflict.itemKey == "w")
        #expect(conflict.thisDevicePreview == "Written here")
        #expect(conflict.otherDevicePreview == "Written there")
        #expect(conflict.thisDeviceModified == conflict.otherDeviceModified)
    }

    @Test func keepingTheOtherDeviceAdoptsItsVersionAndDatesItLater() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)

        let resolved = try #require(
            try await devices.a.resolveSyncConflict(id: conflict.id, keeping: .otherDevice)
        )
        #expect(resolved.content == "Written there")
        #expect(try await devices.a.personalDevotionals().map(\.content) == ["Written there"])
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)

        // Later than both, so the choice wins on the next device rather than
        // meeting the same equal-time disagreement again.
        let kept = try #require(resolved.lastModified)
        let here = try #require(conflict.thisDeviceModified)
        let there = try #require(conflict.otherDeviceModified)
        #expect(kept > here)
        #expect(kept > there)
    }

    @Test func keepingThisDeviceRepublishesItRatherThanLeavingItEqual() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)

        let resolved = try #require(
            try await devices.a.resolveSyncConflict(id: conflict.id, keeping: .thisDevice)
        )
        #expect(resolved.content == "Written here")
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
        // Keeping what is already here still has to advance the clock, or the
        // other device offers its version again on the next run.
        let kept = try #require(resolved.lastModified)
        let there = try #require(conflict.otherDeviceModified)
        #expect(kept > there)
    }

    @Test func theSameDisagreementArrivingTwiceIsStillOneConflict() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        #expect(try await devices.a.pendingSyncConflicts().count == 1)
    }

    @Test func aConflictWhoseWritingWasDeletedHereStopsBeingOne() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        #expect(try await devices.a.pendingSyncConflicts().count == 1)

        try await devices.a.deletePersonalDevotional(id: "w")
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
    }

    @Test func dismissingAConflictLeavesThisDevicesVersionAlone() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)

        try await devices.a.discardSyncConflict(id: conflict.id)
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
        #expect(try await devices.a.personalDevotionals().map(\.content) == ["Written here"])
    }

    @Test func versionsThatAgreeNeverBecomeAConflict() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collide(devices, here: "The same", there: "The same")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
    }
}
