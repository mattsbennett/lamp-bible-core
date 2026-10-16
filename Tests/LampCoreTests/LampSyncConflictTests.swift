import Foundation
import GRDB
import LampCore
import Testing

/// Two devices that changed the same record at the same second, which is the
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

    // MARK: - Notes

    /// Saves a note on both devices at one timestamp and hands device A the
    /// book document device B would have published.
    private func collideNotes(
        _ devices: Devices,
        here: String,
        there: String,
        title: String? = nil,
        reference: Int = 43_003_016,
        at moment: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> URL {
        func note(_ body: String) -> LampVerseNote {
            LampVerseNote(
                id: "personal-notes:\(reference)",
                reference: reference,
                title: title,
                content: body,
                lastModified: moment
            )
        }
        try await devices.a.saveVerseNote(note(here))
        try await devices.b.saveVerseNote(note(there))
        let document = try await devices.b.personalNotesDocument(bookNumber: reference / 1_000_000)
        let file = devices.root.appendingPathComponent(document.suggestedJSONFilename)
        try document.jsonData.write(to: file)
        return file
    }

    @Test func anEqualTimeNoteDisagreementIsSetAsideRatherThanStoppingTheRun() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(devices, here: "Written here", there: "Written there")

        // The run finishes, and the rest of the book's notes would come with it.
        let result = try await devices.a.importPersonalStudyData(from: file, forSync: true)
        #expect(result.importedCount == 0)
        #expect(try await devices.a.verseNotes(reference: 43_003_016).map(\.content) == ["Written here"])

        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)
        #expect(conflict.kind == .note)
        #expect(conflict.itemKey == "personal-notes:43003016")
        #expect(conflict.thisDevicePreview == "Written here")
        #expect(conflict.otherDevicePreview == "Written there")
    }

    /// An import someone chose from a file still stops and says so: there is a
    /// person right there to tell, and no sync run to protect.
    @Test func anImportSomeoneAskedForStillStopsOnANoteDisagreement() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(devices, here: "Written here", there: "Written there")

        await #expect(throws: LampLibraryError.self) {
            _ = try await devices.a.importPersonalStudyData(from: file)
        }
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
        #expect(try await devices.a.verseNotes(reference: 43_003_016).map(\.content) == ["Written here"])
    }

    @Test func keepingTheOtherDevicesNoteAdoptsItAndDatesItLater() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalStudyData(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)

        let resolved = try #require(
            try await devices.a.resolveSyncConflict(id: conflict.id, keeping: .otherDevice)
        )
        #expect(resolved.content == "Written there")
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)

        // Saved under the key this library files notes by, not whatever id the
        // document carried, so it replaces the note rather than joining it.
        let stored = try await devices.a.verseNotes(reference: 43_003_016)
        #expect(stored.map(\.content) == ["Written there"])
        #expect(stored.map(\.id) == ["personal-notes:43003016"])

        let kept = try #require(resolved.lastModified)
        #expect(kept > (try #require(conflict.thisDeviceModified)))
        #expect(kept > (try #require(conflict.otherDeviceModified)))
    }

    @Test func keepingThisDevicesNoteRepublishesItRatherThanLeavingItEqual() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalStudyData(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)

        let resolved = try #require(
            try await devices.a.resolveSyncConflict(id: conflict.id, keeping: .thisDevice)
        )
        #expect(resolved.content == "Written here")
        #expect(try await devices.a.verseNotes(reference: 43_003_016).map(\.content) == ["Written here"])
        let kept = try #require(resolved.lastModified)
        #expect(kept > (try #require(conflict.otherDeviceModified)))
    }

    /// A note usually has no title, so the verse it is attached to has to name
    /// it; one that does keeps the verse as a second line.
    @Test func aNoteIsNamedByItsVerseUnlessItHasATitle() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let untitled = try await collideNotes(devices, here: "Here", there: "There")
        _ = try await devices.a.importPersonalStudyData(from: untitled, forSync: true)
        let plain = try #require(try await devices.a.pendingSyncConflicts().first)
        #expect(plain.title == "John 3:16")
        #expect(plain.subtitle == nil)

        let titled = try Devices()
        defer { titled.remove() }
        let file = try await collideNotes(titled, here: "Here", there: "There", title: "On being born again")
        _ = try await titled.a.importPersonalStudyData(from: file, forSync: true)
        let named = try #require(try await titled.a.pendingSyncConflicts().first)
        #expect(named.title == "On being born again")
        #expect(named.subtitle == "John 3:16")
    }

    /// A chapter introduction is filed at verse zero. Named by the same rule as
    /// any other note it would come out as "Numbers 31:0".
    @Test func aChapterIntroductionIsNamedByItsChapter() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(
            devices, here: "Here", there: "There", reference: 4_031_000
        )
        _ = try await devices.a.importPersonalStudyData(from: file, forSync: true)

        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)
        // The document names every introduction, so the chapter is the subtitle.
        #expect(conflict.subtitle == "Numbers 31")
        #expect(!conflict.title.contains(":0"))
    }

    @Test func aConflictWhoseNoteWasDeletedHereStopsBeingOne() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let file = try await collideNotes(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalStudyData(from: file, forSync: true)
        #expect(try await devices.a.pendingSyncConflicts().count == 1)

        try await devices.a.deleteVerseNote(id: "personal-notes:43003016")
        #expect(try await devices.a.pendingSyncConflicts().isEmpty)
    }

    /// A note's own key carries a colon, so the two kinds have to stay apart in
    /// one table without one being mistaken for the other.
    @Test func aNoteAndAWritingCanBothBeWaitingAtOnce() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let writing = try await collide(devices, here: "Writing here", there: "Writing there")
        let note = try await collideNotes(devices, here: "Note here", there: "Note there")
        _ = try await devices.a.importPersonalDevotional(from: writing, forSync: true)
        _ = try await devices.a.importPersonalStudyData(from: note, forSync: true)

        let conflicts = try await devices.a.pendingSyncConflicts()
        #expect(conflicts.count == 2)
        #expect(Set(conflicts.map(\.kind)) == [.devotional, .note])

        // Deciding one leaves the other exactly where it was.
        let noteConflict = try #require(conflicts.first { $0.kind == .note })
        _ = try await devices.a.resolveSyncConflict(id: noteConflict.id, keeping: .otherDevice)
        let left = try await devices.a.pendingSyncConflicts()
        #expect(left.map(\.kind) == [.devotional])
        #expect(try await devices.a.personalDevotionals().map(\.content) == ["Writing here"])
    }

    // MARK: - The stash itself

    /// The stash was devotional-shaped before notes could land in it. It only
    /// ever holds a copy the other device still has, so the old layout is
    /// dropped rather than migrated, and the next run raises the same
    /// disagreement again.
    @Test func aStashFromBeforeNotesIsReplacedRatherThanBrokenOpen() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        // Touch the library so its directories and database exist.
        _ = try await devices.a.pendingSyncConflicts()

        let databaseURL = devices.root.appendingPathComponent("A/UserData.sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS sync_conflicts")
            try db.execute(sql: """
                CREATE TABLE sync_conflicts (
                    kind TEXT NOT NULL, id TEXT NOT NULL, detected INTEGER NOT NULL,
                    title TEXT NOT NULL, tags_json TEXT NOT NULL,
                    key_scriptures_json TEXT NOT NULL, content TEXT NOT NULL,
                    created INTEGER NOT NULL, last_modified INTEGER NOT NULL,
                    PRIMARY KEY (kind, id)
                )
                """)
            try db.execute(sql: """
                INSERT INTO sync_conflicts VALUES
                ('devotional', 'w', 1, 'Shared', '[]', '[]', 'Written there', 1, 1)
                """)
        }

        // A run against the old table finishes and stashes into the new one.
        let file = try await collide(devices, here: "Written here", there: "Written there")
        _ = try await devices.a.importPersonalDevotional(from: file, forSync: true)
        let conflict = try #require(try await devices.a.pendingSyncConflicts().first)
        #expect(conflict.otherDevicePreview == "Written there")

        let columns = try await database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sync_conflicts)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.sorted() == ["detected", "id", "kind", "payload_json"])
    }
}
