import Foundation
import Testing
@testable import LampModuleKit

/// A module file replaced by hand on the server, outside the apps, reaches an
/// open app by a probe of the listed folders, not only at the next launch.
struct LampSyncRemoteProbeTests {
    @Test func aProbeFindsWhatAPassWouldActOn() {
        let recorded = ["Translations/ESVs.lamp": "\"e1\"", "Books/old.lamp": "\"b1\""]
        // Nothing moved.
        #expect(LampSyncFilePlan.remoteChanges(
            listing: ["Translations/ESVs.lamp": "\"e1\"", "Books/old.lamp": "\"b1\""], recorded: recorded
        ).isEmpty)
        // Replaced by hand, dropped in, and taken away.
        #expect(LampSyncFilePlan.remoteChanges(
            listing: ["Translations/ESVs.lamp": "\"e2\"", "Translations/NETs.lamp": "\"n1\""], recorded: recorded
        ) == ["Translations/ESVs.lamp", "Translations/NETs.lamp", "Books/old.lamp"])
    }

    @Test func aFolderListingReadsNoFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Translations"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("Translations/ESVs.lamp"))
        try Data("b".utf8).write(to: root.appendingPathComponent("Translations/NETs.lamp"))
        let store = LampSyncDirectoryStore(root: root)
        let listing = try await LampSyncFilePlan.listing(
            in: store, recorded: ["Translations/ESVs.lamp": "sha:recorded"]
        )
        // A recorded file keeps its record; an unrecorded one is present.
        #expect(listing == ["Translations/ESVs.lamp": "sha:recorded", "Translations/NETs.lamp": "present"])
        #expect(LampSyncFilePlan.remoteChanges(
            listing: listing, recorded: ["Translations/ESVs.lamp": "sha:recorded"]
        ) == ["Translations/NETs.lamp"])
    }

    @Test func recordsOfferTheirListedRevisions() {
        var records = LampSyncFileRecords()
        records.sources["webdav:x"] = .init()
        records.sources["webdav:x"]?.files = [
            "Translations/ESVs.lamp": .init(installedRevision: "\"e1\""),
            "Books/b.lamp": .init(installedRevision: "\"b1\"", pendingRevision: "\"b2\""),
            "settings/bundle.json": .init(installedRevision: "\"s\""),
        ]
        #expect(records.listedRevisions(in: "webdav:x")
            == ["Translations/ESVs.lamp": "\"e1\"", "Books/b.lamp": "\"b2\""])
        #expect(records.listedRevisions(in: "folder:y").isEmpty)
    }
}
