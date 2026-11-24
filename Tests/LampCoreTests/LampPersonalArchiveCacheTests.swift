import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// `Documentation/decisions/0002`: a collection is compiled once per change
/// rather than once per sync pass.
///
/// What these hold is the cache's key, which is the whole of that decision —
/// that a writing's edit compiles the writings again, that a note's edit
/// leaves them alone, and that a picture lost from this device still refuses
/// the collection rather than publishing bytes built when it was there.
struct LampPersonalArchiveCacheTests {
    private let moduleID = "writing"

    private func fixture() throws -> (library: LampLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-archive-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LampLibrary(rootURL: root.appendingPathComponent("Library")), root)
    }

    private func writing(_ index: Int, content: String? = nil) -> LampDevotional {
        LampDevotional(
            id: "writing-\(index)",
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: "Writing \(index)",
            content: content ?? "Grace and peace, number \(index).",
            isEditable: true
        )
    }

    @Test func compilesOnceWhileNothingChanges() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.savePersonalDevotional(writing(1))

        let first = try await library.personalArchive(.writing, moduleID: moduleID)
        let compiles = await library.personalArchiveCompiles
        let second = try await library.personalArchive(.writing, moduleID: moduleID)

        #expect(await library.personalArchiveCompiles == compiles)
        #expect(first == second)
        // The bytes are the file, not a copy of it: a cached archive has to be
        // the one a fresh compile would have produced.
        #expect(try first == LampPersonalWritingFile.archive(
            try await library.personalDevotionals(),
            moduleID: moduleID,
            normalizingMediaIn: library.rootURL
        ))
    }

    @Test func aSavedWritingIsCompiledAgain() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.savePersonalDevotional(writing(1))
        let before = try await library.personalArchive(.writing, moduleID: moduleID)
        let compiles = await library.personalArchiveCompiles

        _ = try await library.savePersonalDevotional(writing(2))
        let after = try await library.personalArchive(.writing, moduleID: moduleID)

        #expect(await library.personalArchiveCompiles == compiles + 1)
        #expect(after != before)
    }

    /// The reason the key is one kind's stamp and not the device's: a pass
    /// runs because *something* changed, and keyed on the device-wide stamp
    /// this cache would miss every time it was wanted.
    @Test func aNoteLeavesTheWritingsArchiveAlone() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.savePersonalDevotional(writing(1))
        let writings = try await library.personalArchive(.writing, moduleID: moduleID)
        _ = try await library.personalArchive(.notes, moduleID: "notes")
        let compiles = await library.personalArchiveCompiles

        _ = try await library.setPersonalVerseNote(reference: 1_001_001, content: "A note.")

        #expect(try await library.personalArchive(.writing, moduleID: moduleID) == writings)
        #expect(await library.personalArchiveCompiles == compiles)
        // And the notes, which did change, are built again.
        _ = try await library.personalArchive(.notes, moduleID: "notes")
        #expect(await library.personalArchiveCompiles == compiles + 1)
    }

    /// A picture can go without any row moving — deleted outside Lamp, or
    /// never installed on this device — and the collection is refused while
    /// it is missing. A cache that served the bytes built when the picture
    /// was there would publish a writing naming a picture no device has.
    @Test func aPictureLostAfterAnArchiveStillRefusesTheCollection() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("picture.png")
        try Data("not really a picture".utf8).write(to: source)
        let stored = try await library.storePersonalDevotionalMedia(
            from: source, devotionalID: "writing-1"
        )
        _ = try await library.savePersonalDevotional(writing(
            1,
            content: "Look: ![a picture](lamp-media://writing-1/\(stored.lastPathComponent))"
        ))

        let built = try await library.personalArchive(.writing, moduleID: moduleID)
        #expect(!built.isEmpty)

        try FileManager.default.removeItem(at: stored)
        await #expect(throws: (any Error).self) {
            try await library.personalArchive(.writing, moduleID: moduleID)
        }
    }

    /// And the other way: a picture arriving on its own — which sync does,
    /// a media file and the row that names it travelling separately — is
    /// noticed, so the collection stops being refused without waiting for
    /// the next edit.
    @Test func aPictureArrivingOnItsOwnIsNoticed() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.savePersonalDevotional(writing(
            1, content: "Look: ![a picture](lamp-media://writing-1/arrives.png)"
        ))
        await #expect(throws: (any Error).self) {
            try await library.personalArchive(.writing, moduleID: moduleID)
        }

        let folder = library.rootURL
            .appendingPathComponent("Media/Devotionals/writing-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("arrived".utf8).write(to: folder.appendingPathComponent("arrives.png"))

        #expect(try await !library.personalArchive(.writing, moduleID: moduleID).isEmpty)
    }

    /// The case the first version of this cache got wrong, and the reason the
    /// key is a revision the database keeps rather than the sync ledger's
    /// stamp: a copy carried in by sync writes rows **without** stamping the
    /// ledger, deliberately, so that an arriving copy cannot outrank a
    /// deletion recorded in between. Keyed on the ledger, the next export was
    /// this device's pre-merge bytes — published over the copy that had just
    /// been merged in.
    @Test func aWritingCarriedInBySyncIsInTheNextArchive() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.savePersonalDevotional(writing(1))
        let before = try await library.personalArchive(.writing, moduleID: moduleID)
        let compiles = await library.personalArchiveCompiles

        // What a pass installs: another device's collection, by value.
        let incoming = try LampPersonalWritingFile.archive(
            [writing(1), writing(2, content: "From the other device.")],
            moduleID: moduleID
        )
        let file = root.appendingPathComponent("incoming.lamp")
        try incoming.write(to: file)
        _ = try await library.importPersonalDevotional(from: file, forSync: true)

        let after = try await library.personalArchive(.writing, moduleID: moduleID)
        #expect(await library.personalArchiveCompiles == compiles + 1)
        #expect(after != before)
        #expect(try await library.personalDevotionals().count == 2)
    }

    /// And a conflict the reader resolved: the kept version is saved with the
    /// time it already had, so nothing in the ledger moves. Unpublished, the
    /// promise that the kept version wins everywhere is not kept at all.
    @Test func aResolvedConflictIsInTheNextArchive() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two devices, one writing, the same moment, different words: the
        // disagreement no merge rule can settle.
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ content: String) -> LampDevotional {
            LampDevotional(
                id: "w",
                moduleID: LampPersonalModule.writing.id,
                moduleName: LampPersonalModule.writing.name,
                title: "Shared",
                content: content,
                created: moment,
                lastModified: moment,
                isEditable: true
            )
        }
        _ = try await library.savePersonalDevotional(
            entry("Written here"), preserveLastModified: true
        )
        let file = root.appendingPathComponent("theirs.lamp")
        try LampPersonalWritingFile.archive(
            [entry("Written there")], moduleID: moduleID
        ).write(to: file)
        _ = try await library.importPersonalDevotional(from: file, forSync: true)
        let conflicts = try await library.pendingSyncConflicts()
        try #require(conflicts.count == 1)

        let before = try await library.personalArchive(.writing, moduleID: moduleID)
        let compiles = await library.personalArchiveCompiles
        _ = try await library.resolveSyncConflict(id: conflicts[0].id, keeping: .otherDevice)

        #expect(try await library.personalArchive(.writing, moduleID: moduleID) != before)
        #expect(await library.personalArchiveCompiles == compiles + 1)
        #expect(try await library.personalDevotionals().map(\.content) == ["Written there"])
    }

    /// The notes twin: a pass merges another device's notes without stamping
    /// the ledger either.
    @Test func notesCarriedInBySyncAreInTheNextArchive() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.setPersonalVerseNote(reference: 1_001_001, content: "Mine.")
        let before = try await library.personalArchive(.notes, moduleID: "notes")
        let compiles = await library.personalArchiveCompiles

        // Another device's collection, built the way that device would.
        let other = LampLibrary(rootURL: root.appendingPathComponent("Other"))
        _ = try await other.setPersonalVerseNote(reference: 1_001_002, content: "Theirs.")
        let file = root.appendingPathComponent("notes.lamp")
        try await other.personalArchive(.notes, moduleID: "notes").write(to: file)
        _ = try await library.importPersonalStudyData(from: file, forSync: true)

        #expect(try await library.personalArchive(.notes, moduleID: "notes") != before)
        #expect(await library.personalArchiveCompiles == compiles + 1)
        #expect(try await library.verseNotes(reference: 1_001_002).count == 1)
    }
}
