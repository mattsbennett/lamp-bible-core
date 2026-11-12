import Foundation
import LampCore
import LampModuleKit
import Testing

/// Two devices, each with its own library, syncing by exporting a backup and
/// importing the other's — as the sync engines do.
struct LampPersonalDeletionSyncTests {
    private let verse = 43_003_016

    private struct Devices {
        let root: URL
        let a: LampLibrary
        let b: LampLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-deletion-sync-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            a = LampLibrary(rootURL: root.appendingPathComponent("A"))
            b = LampLibrary(rootURL: root.appendingPathComponent("B"))
        }

        func sync(from source: LampLibrary, to destination: LampLibrary) async throws {
            let backup = root.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
            _ = try await source.exportPortableBackup(to: backup)
            try await destination.receive(exportAt: backup)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Lets the next save or deletion fall in a later millisecond.
    private func pause() async throws { try await Task.sleep(for: .milliseconds(5)) }

    private func writing(_ id: String, _ title: String) -> LampDevotional {
        LampDevotional(
            id: id, moduleID: "personal-devotionals", moduleName: "My Writing",
            title: title, content: "Body"
        )
    }

    // MARK: - Writing

    /// The phone keeps its own ledger with these, so both clients record and
    /// key items the same way.
    @Test func recordingKeepsTheLaterTimeAndKeysMatch() {
        var ledger = LampPersonalDeletionLedger()
        let key = LampPersonalDeletionLedger.highlightKey(
            setID: "set", reference: verse, start: 0, end: 4, style: 1, color: "yellow"
        )
        ledger.recordPresence(.highlight, key, at: 10)
        ledger.recordPresence(.highlight, key, at: 5)
        ledger.recordDeletion(.highlight, key, at: 20)
        ledger.recordDeletion(.highlight, key, at: 15)
        #expect(ledger.entry(.highlight, key) == .init(presentSince: 10, deletedAt: 20))
        #expect(ledger.entries(of: .highlight).keys.sorted() == [key])
        #expect(ledger.entries(of: .note).isEmpty)
        #expect(key == "set\u{1F}\(verse)\u{1F}0\u{1F}4\u{1F}1\u{1F}yellow")
        #expect(LampPersonalDeletionLedger.highlightThemeKey(setID: "set", color: "red", style: 2)
            == "set\u{1F}red\u{1F}2")
    }

    @Test func deletedWritingStaysDeletedOnEveryDevice() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        try await devices.a.savePersonalDevotional(writing("w", "Gone"))
        try await devices.a.savePersonalDevotional(writing("k", "Kept"))
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        try await devices.a.deletePersonalDevotional(id: "w")
        // B, which still has it, publishes first.
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await devices.a.personalDevotionals().map(\.id) == ["k"])
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.b.personalDevotionals().map(\.id) == ["k"])
    }

    @Test func writingEditedAfterItsDeletionIsKept() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        try await devices.a.savePersonalDevotional(writing("w", "Draft"))
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        try await devices.a.deletePersonalDevotional(id: "w")
        try await pause()
        try await devices.b.savePersonalDevotional(writing("w", "Still wanted"))

        try await devices.sync(from: devices.a, to: devices.b)
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await devices.a.personalDevotionals().map(\.title) == ["Still wanted"])
        #expect(try await devices.b.personalDevotionals().map(\.title) == ["Still wanted"])
    }

    @Test func importingAFileBringsDeletedWritingBackForGood() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        try await devices.a.savePersonalDevotional(writing("w", "Restored"))
        try await devices.sync(from: devices.a, to: devices.b)
        let file = devices.root.appendingPathComponent("w.json")
        try await devices.a.personalDevotionalDocument(id: "w").jsonData.write(to: file)

        try await pause()
        try await devices.a.deletePersonalDevotional(id: "w")
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.b.personalDevotionals().isEmpty)

        // The person chose to import it, so it returns, and sync keeps it.
        try await pause()
        _ = try await devices.b.importPersonalDevotional(from: file)
        try await devices.sync(from: devices.a, to: devices.b)
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await devices.a.personalDevotionals().map(\.title) == ["Restored"])
        #expect(try await devices.b.personalDevotionals().map(\.title) == ["Restored"])
    }

    // MARK: - Notes

    @Test func deletedNotesStayDeletedAndANewNoteOnTheVerseIsKept() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        _ = try await devices.a.setPersonalVerseNote(reference: verse, content: "First thought")
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        // Clearing a note deletes it.
        _ = try await devices.a.setPersonalVerseNote(reference: verse, content: "")
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await devices.a.verseNotes(reference: verse).isEmpty)
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.b.verseNotes(reference: verse).isEmpty)

        // The same verse, written about again: notes there share one ID.
        try await pause()
        _ = try await devices.b.setPersonalVerseNote(reference: verse, content: "Second thought")
        try await devices.sync(from: devices.b, to: devices.a)
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.a.verseNotes(reference: verse).map(\.content) == ["Second thought"])
        #expect(try await devices.b.verseNotes(reference: verse).map(\.content) == ["Second thought"])
    }

    // MARK: - Highlights

    private func highlights(_ library: LampLibrary) async throws -> [String] {
        try await library.verseHighlights(translationID: "TEST", reference: verse)
            .map { "\($0.startOffset)-\($0.endOffset) \($0.color ?? "")" }
            .sorted()
    }

    @Test func removedHighlightsStayRemoved() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let gone = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 5, endOffset: 9, color: "#FFCC00"
        )
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        try await devices.a.deleteVerseHighlight(id: gone.id)
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await highlights(devices.a) == ["5-9 FFCC00"])
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await highlights(devices.b) == ["5-9 FFCC00"])
    }

    @Test func aPassageHighlightedAgainAfterRemovalStaysHighlighted() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let first = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        try await devices.sync(from: devices.a, to: devices.b)
        try await pause()
        try await devices.a.deleteVerseHighlight(id: first.id)
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await highlights(devices.b).isEmpty)

        // Exactly the same highlight, made again: highlights carry no identity
        // of their own, so this is where re-adding could be lost.
        try await pause()
        _ = try await devices.b.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        try await devices.sync(from: devices.b, to: devices.a)
        try await devices.sync(from: devices.a, to: devices.b)
        try await devices.sync(from: devices.b, to: devices.a)
        #expect(try await highlights(devices.a) == ["0-4 FFCC00"])
        #expect(try await highlights(devices.b) == ["0-4 FFCC00"])
    }

    @Test func aRecolouredHighlightDoesNotLeaveItsOldColourBehind() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let yellow = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        try await devices.a.deleteVerseHighlight(id: yellow.id)
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#34C759"
        )
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await highlights(devices.b) == ["0-4 34C759"])
    }

    @Test func aDeletedHighlightSetTakesItsContentsWithIt() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let set = try await devices.a.saveHighlightSet(LampHighlightSet(
            id: "sermon", name: "Sermon", translationID: "TEST"
        ))
        _ = try await devices.a.saveHighlightTheme(LampHighlightTheme(
            setID: set.id, color: "FFCC00", style: .highlight, name: "Promises"
        ))
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4,
            color: "#FFCC00", setID: set.id
        )
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.b.highlightSets(translationID: "TEST").map(\.id).contains("sermon"))

        try await pause()
        try await devices.a.deleteHighlightSet(id: set.id)
        try await devices.sync(from: devices.b, to: devices.a)
        try await devices.sync(from: devices.a, to: devices.b)
        for library in [devices.a, devices.b] {
            #expect(try await !library.highlightSets(translationID: "TEST").map(\.id).contains("sermon"))
            #expect(try await library.highlightThemes(setID: "sermon").isEmpty)
            #expect(try await highlights(library).isEmpty)
        }
    }

    @Test func aDeletedThemeStaysDeleted() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        let set = try await devices.a.saveHighlightSet(LampHighlightSet(
            id: "study", name: "Study", translationID: "TEST"
        ))
        _ = try await devices.a.saveHighlightTheme(LampHighlightTheme(
            setID: set.id, color: "FFCC00", style: .highlight, name: "Promises"
        ))
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4,
            color: "#FFCC00", setID: set.id
        )
        try await devices.sync(from: devices.a, to: devices.b)

        try await pause()
        try await devices.a.deleteHighlightTheme(setID: set.id, color: "FFCC00", style: .highlight)
        try await devices.sync(from: devices.b, to: devices.a)
        try await devices.sync(from: devices.a, to: devices.b)
        #expect(try await devices.a.highlightThemes(setID: set.id).isEmpty)
        #expect(try await devices.b.highlightThemes(setID: set.id).isEmpty)
    }

    @Test func aRoundTripLeavesOneCopyOfEachHighlight() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        try await devices.sync(from: devices.a, to: devices.b)
        try await devices.sync(from: devices.b, to: devices.a)

        for library in [devices.a, devices.b] {
            #expect(try await highlights(library) == ["0-4 FFCC00"])
            #expect(try await library.highlightSets(translationID: "TEST").map(\.id) == ["personal-highlights:TEST"])
        }
    }

    // MARK: - Format

    @Test func theLedgerStaysOutOfWhatOlderVersionsRead() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        try await devices.a.savePersonalDevotional(writing("w", "Gone"))
        try await devices.a.deletePersonalDevotional(id: "w")
        _ = try await devices.a.setPersonalVerseNote(reference: verse, content: "Kept")
        let backup = devices.root.appendingPathComponent("backup", isDirectory: true)
        _ = try await devices.a.exportPortableBackup(to: backup)

        #expect(FileManager.default.fileExists(
            atPath: backup.appendingPathComponent(LampPortableBackupLayout.deletionLedgerPath).path
        ))
        // Older versions import every JSON file under these folders as content.
        for folder in [LampPortableBackupLayout.devotionalsDirectory, LampPortableBackupLayout.studyDirectory] {
            let enumerator = FileManager.default.enumerator(atPath: backup.appendingPathComponent(folder).path)
            let files = (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".json") }
            #expect(!files.contains { $0.localizedCaseInsensitiveContains("ledger") })
        }
    }

    @Test func aBackupWithoutALedgerStillImports() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        try await devices.a.savePersonalDevotional(writing("w", "From an older device"))
        let backup = devices.root.appendingPathComponent("backup", isDirectory: true)
        _ = try await devices.a.exportPortableBackup(to: backup)
        try? FileManager.default.removeItem(
            at: backup.appendingPathComponent(LampPortableBackupLayout.deletionLedgerPath)
        )

        try await devices.b.receive(exportAt: backup)
        #expect(try await devices.b.personalDevotionals().map(\.title) == ["From an older device"])
    }

    @Test func kindsFromALaterVersionArePassedOver() throws {
        let data = Data("""
        {"formatVersion": 1, "items": {
          "devotional": {"w": {"deletedAt": 2000}},
          "somethingNew": {"x": {"deletedAt": 2000}}
        }}
        """.utf8)
        let ledger = try LampPersonalDeletionLedger.decode(data)
        #expect(ledger.isDeleted(.devotional, "w", itemModified: 1))
        #expect(ledger.entries.count == 1)
    }

    @Test func theLaterSaveOrDeletionDecides() {
        let entry = LampPersonalDeletionLedger.Entry(presentSince: 5_000, deletedAt: 7_000)
        #expect(entry.isDeleted(itemModified: nil))
        // Modified at 8 s: after the deletion.
        #expect(!entry.isDeleted(itemModified: 8))
        #expect(!LampPersonalDeletionLedger.Entry(presentSince: 9_000, deletedAt: 7_000).isDeleted(itemModified: nil))
        #expect(!LampPersonalDeletionLedger.Entry(presentSince: 9_000).isDeleted(itemModified: nil))
    }

    /// A deletion recorded inside the second a note was saved in does not
    /// beat the save.
    ///
    /// The ledger's times are milliseconds; a note's own modification time
    /// comes from the file in seconds. Read as the start of that second, a
    /// deletion recorded *earlier* in it beat a *later* save — an earlier
    /// deletion winning over a later edit, out of nothing but the rounding.
    /// Since nothing says where in the second the save happened, a deletion
    /// counts only once the second has passed. That errs towards keeping
    /// the note, which is the side to err on: one kept that should have
    /// gone can be deleted again, one deleted that should have been kept is
    /// gone. Modelled as `tombstoneDeletesSecondsCopy`.
    @Test func aDeletionInsideTheSavesOwnSecondDoesNotCount() {
        let saved = 1_700_000_010      // seconds, as the file records it
        func deleted(at milliseconds: Int64) -> Bool {
            LampPersonalDeletionLedger.Entry(presentSince: nil, deletedAt: milliseconds)
                .isDeleted(itemModified: saved)
        }

        // Anywhere inside that second, before the save or after it.
        #expect(deleted(at: Int64(saved) * 1_000) == false)
        #expect(deleted(at: Int64(saved) * 1_000 + 100) == false)
        #expect(deleted(at: Int64(saved) * 1_000 + 999) == false)
        // Once it has passed, it deletes, as it always did.
        #expect(deleted(at: Int64(saved + 1) * 1_000))
        #expect(deleted(at: Int64(saved + 5) * 1_000))
        // While a deletion from before the save loses to it, as it should.
        #expect(deleted(at: Int64(saved - 5) * 1_000) == false)

        // **Where the ledger recorded the save itself, there is nothing to
        // assume.** A presence at or after the start of that second is the
        // record of that very save, so it is compared exactly. Without
        // this, a note deleted moments after it was written came back on
        // every device, for good — which is what
        // `deletedNotesStayDeletedAndANewNoteOnTheVerseIsKept` was telling
        // me while I read the end of a test log instead of its exit code.
        func withSave(at saveMilliseconds: Int64, deletedAt: Int64) -> Bool {
            LampPersonalDeletionLedger.Entry(
                presentSince: saveMilliseconds, deletedAt: deletedAt
            ).isDeleted(itemModified: saved)
        }
        let second = Int64(saved) * 1_000
        #expect(withSave(at: second + 100, deletedAt: second + 300))
        #expect(withSave(at: second + 100, deletedAt: second + 100), "at the same instant")
        #expect(withSave(at: second + 300, deletedAt: second + 100) == false, "before the save")

        // A presence from before that second says nothing about this save,
        // so the end of the second is assumed, as above.
        #expect(withSave(at: second - 5_000, deletedAt: second + 900) == false)

        // And a save with no copy to compare against speaks for itself.
        let exact = LampPersonalDeletionLedger.Entry(
            presentSince: second + 900, deletedAt: second + 100
        )
        #expect(exact.isDeleted(itemModified: nil) == false)
    }

    /// A note written again after its deletion arrives stays written, even
    /// on a device whose clock is behind.
    ///
    /// Presence was stamped with the wall clock alone. A device that
    /// receives a deletion made at `s+.900` and then writes the note again
    /// records presence at its own `s+.600`, and the deletion — now the
    /// later time — takes the note away on the next pass. On every device,
    /// and the person's second attempt is lost as quietly as the first.
    ///
    /// The rule the model already carried for plan progress, `stampSet`: a
    /// change is stamped now, but never at or before the time it overrides.
    @Test func writingANoteAgainAfterItsDeletionHolds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        _ = try await library.setPersonalVerseNote(reference: verse, content: "First thought")
        _ = try await library.setPersonalVerseNote(reference: verse, content: "")

        // A deletion from a device whose clock runs ahead — far enough that
        // this device's own clock cannot overtake it.
        let ahead = Int64(Date().timeIntervalSince1970 * 1_000) + 60 * 60 * 1_000
        var incoming = LampPersonalDeletionLedger()
        incoming.recordDeletion(.note, "personal-notes:\(verse)", at: ahead)
        try await library.mergePersonalDeletionLedger(incoming)

        // Written again here, now.
        _ = try await library.setPersonalVerseNote(reference: verse, content: "Second thought")

        let ledger = try await library.personalDeletionLedger()
        let entry = try #require(ledger.entry(.note, "personal-notes:\(verse)"))
        #expect(
            (entry.presentSince ?? 0) > ahead,
            "the writing is stamped past the deletion it undoes, not at this clock's now"
        )
        #expect(entry.isDeleted(itemModified: Int(Date().timeIntervalSince1970)) == false)

        try await library.applyPersonalDeletionLedger()
        #expect(
            try await library.verseNotes(reference: verse).map(\.content) == ["Second thought"],
            "and it is still there after the ledger is applied"
        )
    }

    /// A highlight deleted on a device that had not yet learned a set's
    /// real name is still deleted here.
    ///
    /// A ledger key names the set and no module, so `personal-highlights-ESV`
    /// could be the default set under its old flattened name or a set the
    /// reader genuinely called that. This device's own sets settle it:
    /// holding the colon form and nothing named the flattened one, there is
    /// only one set the key can mean. Holding both, it is left alone.
    @Test func anOldSpellingOfASetIsReadWhereThisDeviceCanTell() async throws {
        func library(at name: String) throws -> (LampLibrary, URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (LampLibrary(rootURL: root), root)
        }

        let (mine, root) = try library(at: "spelling")
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await mine.saveVerseHighlight(
            translationID: "ESV", reference: verse, startOffset: 0, endOffset: 3,
            color: "#FFCC00"
        )
        #expect(saved.setID == "personal-highlights:ESV", "the set this device holds")

        // A deletion recorded by a device that knew the set only as the
        // flattened module name.
        let flattened = LampLibrary.highlightKey(
            setID: "personal-highlights-ESV", reference: verse,
            start: saved.startOffset, end: saved.endOffset,
            style: saved.style.rawValue, color: saved.color
        )
        var incoming = LampPersonalDeletionLedger()
        incoming.recordDeletion(
            .highlight, flattened,
            at: Int64(Date().timeIntervalSince1970 * 1_000) + 60 * 60 * 1_000
        )
        try await mine.mergePersonalDeletionLedger(incoming)
        try await mine.applyPersonalDeletionLedger()

        #expect(
            try await mine.verseHighlights(translationID: "ESV", reference: verse).isEmpty,
            "the deletion lands, rather than naming a set this device does not have"
        )
    }
}
