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
            _ = try await destination.importPortableBackup(from: backup)
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

    @Test func copiesLeftByEarlierRoundTripsAreFoldedBackIn() async throws {
        let devices = try Devices()
        defer { devices.remove() }
        // What earlier versions left: the default set beside its export-named copy.
        _ = try await devices.a.saveVerseHighlight(
            translationID: "TEST", reference: verse, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        _ = try await devices.a.saveHighlightSet(LampHighlightSet(
            id: "personal-highlights-TEST", name: "My Highlights", translationID: "TEST"
        ))
        for start in [0, 6] {
            _ = try await devices.a.saveVerseHighlight(
                translationID: "TEST", reference: verse, startOffset: start, endOffset: start + 4,
                color: "#FFCC00", setID: "personal-highlights-TEST"
            )
        }
        #expect(try await highlights(devices.a) == ["0-4 FFCC00", "0-4 FFCC00", "6-10 FFCC00"])

        try await devices.sync(from: devices.b, to: devices.a)

        #expect(try await highlights(devices.a) == ["0-4 FFCC00", "6-10 FFCC00"])
        #expect(try await devices.a.highlightSets(translationID: "TEST").map(\.id) == ["personal-highlights:TEST"])
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

        _ = try await devices.b.importPortableBackup(from: backup)
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
}
