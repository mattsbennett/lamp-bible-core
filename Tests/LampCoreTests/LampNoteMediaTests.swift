import Foundation
import GRDB
@testable import LampCore
import LampModuleKit
import Testing

/// A note's own media.
///
/// Notes shared the writing editor from the start but had nowhere to keep an
/// attachment: `personal_notes` carried no media column, and the Mac's note
/// editor passed a media scope that resolved to no folder, with a comment
/// saying so. Asked for by the owner 2026-11-11.
struct LampNoteMediaTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-note-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private let mediaJSON = """
        [{"id":"8A1F","type":"image","filename":"tomb.png","mimeType":"image/png","alt":"The empty tomb"}]
        """

    @Test func aNoteKeepsItsMediaAcrossASave() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        try await library.saveVerseNote(LampVerseNote(
            id: "note-1", reference: 43_011_035, content: "![](media/8A1F) He wept.",
            mediaJSON: mediaJSON
        ))

        let notes = try await library.verseNotes(reference: 43_011_035)
        let note = try #require(notes.first { $0.id == "note-1" })
        #expect(note.mediaJSON == mediaJSON)
        #expect(note.content.contains("media/8A1F"))
    }

    /// Stored as written, not decoded and re-encoded. A reference from a
    /// newer Lamp carries fields this one has no name for, and a save that
    /// rebuilt the JSON would drop them — the rule the bundle parts follow.
    @Test func aFieldThisLampDoesNotKnowSurvivesASave() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        let fromTheFuture = """
            [{"id":"8A1F","type":"image","filename":"tomb.png","mimeType":"image/png",\
            "focalPoint":{"x":0.4,"y":0.7},"palette":["#112233"]}]
            """
        try await library.saveVerseNote(LampVerseNote(
            id: "note-2", reference: 43_011_035, content: "Kept.", mediaJSON: fromTheFuture
        ))

        let notes = try await library.verseNotes(reference: 43_011_035)
        let note = try #require(notes.first { $0.id == "note-2" })
        #expect(note.mediaJSON?.contains("focalPoint") == true)
        #expect(note.mediaJSON?.contains("#112233") == true)
    }

    /// A library written before notes had media opens, gains the column, and
    /// its notes still read — the ones already there having none.
    @Test func aLibraryFromBeforeNoteMediaIsMigrated() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        // A library made and used by this Lamp, then taken back to the shape
        // it had before the column existed.
        let before = LampLibrary(rootURL: root)
        try await before.saveVerseNote(LampVerseNote(
            id: "old", reference: 1_001_001, content: "In the beginning."
        ))
        // The library's own file, as the other suites reach it.
        let userData = root.appendingPathComponent("UserData.sqlite")
        let queue = try DatabaseQueue(path: userData.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE personal_notes_old AS
                    SELECT id, module_id, verse_id, book, chapter, verse, title,
                           content, verse_refs_json, footnotes_json, last_modified
                    FROM personal_notes
                """)
            try db.execute(sql: "DROP TABLE personal_notes")
            try db.execute(sql: "ALTER TABLE personal_notes_old RENAME TO personal_notes")
        }
        let columns = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(personal_notes)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columns.contains("media_json"), "the fixture must be the older shape")
        try queue.close()

        let library = LampLibrary(rootURL: root)
        let notes = try await library.verseNotes(reference: 1_001_001)
        let old = try #require(notes.first { $0.id == "old" })
        #expect(old.content == "In the beginning.")
        #expect(old.mediaJSON == nil)

        // And a note saved now keeps its media, so the column really arrived.
        try await library.saveVerseNote(LampVerseNote(
            id: "new", reference: 1_001_001, content: "![](media/8A1F)", mediaJSON: mediaJSON
        ))
        let after = try await library.verseNotes(reference: 1_001_001)
        #expect(after.first { $0.id == "new" }?.mediaJSON == mediaJSON)
    }

    /// Where a note's media is kept, and where it syncs to. Devotionals had
    /// both to themselves, spelled into the layout as literals.
    @Test func aNotesMediaHasAFolderAndARemotePathOfItsOwn() throws {
        #expect(LampMediaScope.note.folder == "Notes")
        #expect(LampMediaScope.devotional.folder == "Devotionals")

        let root = URL(fileURLWithPath: "/tmp/library")
        let folder = try #require(LampPortableDevotionalMedia.folderURL(
            rootURL: root, scope: .note, ownerID: "note-1"
        ))
        #expect(folder.path == "/tmp/library/Media/Notes/note-1")

        #expect(try LampPortableDevotionalMedia.remotePath(
            scope: .note, moduleID: "personal-notes", ownerID: "note-1", filename: "tomb.png"
        ) == "NoteMedia/personal-notes/note-1/tomb.png")
        // Unchanged for devotionals, which sync under the path they always did.
        #expect(try LampPortableDevotionalMedia.iOSRemotePath(
            moduleID: "personal-devotionals", devotionalID: "d-1", filename: "tomb.png"
        ) == "DevotionalMedia/personal-devotionals/d-1/tomb.png")

        // A name that would climb out of the folder is refused, for a note as
        // for a devotional.
        #expect(throws: (any Error).self) {
            try LampPortableDevotionalMedia.remotePath(
                scope: .note, moduleID: "personal-notes", ownerID: "note-1", filename: "../escape.png"
            )
        }
        #expect(LampPortableDevotionalMedia.folderURL(
            rootURL: root, scope: .note, ownerID: "../elsewhere"
        ) == nil)
    }

    /// A note's link resolves inside the note's own folder, not a
    /// devotional's — the scope is what tells them apart.
    @Test func aNotesLinkResolvesInTheNotesFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/library")
        let reference = LampMediaReference(
            id: "8A1F", type: .image, filename: "tomb.png", mimeType: "image/png"
        )
        let resolved = LampPortableDevotionalMedia.libraryURL(
            for: URL(string: "media/8A1F")!,
            rootURL: root,
            devotionalID: "note-1",
            references: [reference],
            scope: .note
        )
        #expect(resolved.path == "/tmp/library/Media/Notes/note-1/tomb.png")
    }

    /// A note's attachments are not taken off it by a sync.
    ///
    /// The import writes a note with INSERT OR REPLACE, so a column left out
    /// of that statement is a column emptied. A study document carries no
    /// media, so before this the first sync after attaching an image would
    /// have quietly removed it.
    @Test func syncingANoteDoesNotTakeItsMediaOff() async throws {
        let sourceRoot = try scratch()
        let targetRoot = try scratch()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = LampLibrary(rootURL: sourceRoot)
        let target = LampLibrary(rootURL: targetRoot)

        // The note as it stands here, with an image attached to it.
        try await target.saveVerseNote(LampVerseNote(
            id: "personal-notes:43011035", reference: 43_011_035,
            content: "![](media/8A1F) He wept.",
            mediaJSON: mediaJSON, lastModified: Date(timeIntervalSince1970: 1_000)
        ))
        // The same note arriving from another device, newer, and — as a
        // study document always is — with no media of its own.
        try await source.saveVerseNote(LampVerseNote(
            id: "personal-notes:43011035", reference: 43_011_035,
            content: "He wept, and the tomb was opened.",
            lastModified: Date(timeIntervalSince1970: 2_000)
        ))

        let document = try await source.personalNotesDocument(bookNumber: 43)
        let documentURL = sourceRoot.appendingPathComponent(document.suggestedJSONFilename)
        try document.jsonData.write(to: documentURL)
        _ = try await target.importPersonalStudyData(from: documentURL, forSync: true)

        let note = try #require(
            try await target.verseNotes(reference: 43_011_035)
                .first { $0.id == "personal-notes:43011035" }
        )
        #expect(note.content == "He wept, and the tomb was opened.", "the newer text is taken")
        #expect(note.mediaJSON == mediaJSON, "and the media it had is still on it")
    }

    /// Editing a note's text does not take its attachments off it.
    ///
    /// `setPersonalVerseNote` rebuilds the note rather than updating the
    /// text in place, and carried `verseReferences` and `footnotes` forward
    /// but not media — so the first word typed after attaching an image
    /// would have removed it.
    @Test func editingANotesTextKeepsItsMedia() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "He wept.", mediaJSON: mediaJSON
        )
        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "He wept, and the tomb was opened."
        )

        let note = try #require(try await library.verseNotes(reference: 43_011_035).first { $0.moduleID == "personal-notes" })
        #expect(note.content == "He wept, and the tomb was opened.")
        #expect(note.mediaJSON == mediaJSON)

        // And it can be cleared on purpose, as the other fields are.
        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "No pictures.", mediaJSON: "[]"
        )
        #expect(try await library.verseNotes(reference: 43_011_035).first { $0.moduleID == "personal-notes" }?.mediaJSON == "[]")
    }

    /// A deleted note takes its files with it, rather than leaving a folder
    /// nothing points at.
    @Test func aDeletedNoteTakesItsMediaFolder() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "![](media/8A1F)", mediaJSON: mediaJSON
        )
        let folder = try #require(
            LampLibrary.noteMediaFolderURL(rootURL: root, reference: 43_011_035)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: folder.appendingPathComponent("tomb.png"))
        #expect(FileManager.default.fileExists(atPath: folder.path))

        // Emptying the note deletes it, as it always has.
        _ = try await library.setPersonalVerseNote(reference: 43_011_035, content: "   ")
        #expect(try await library.verseNotes(reference: 43_011_035).first { $0.moduleID == "personal-notes" } == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "its files went with it")
    }

    /// The folder is named for the verse, not the note's id: the id holds a
    /// colon, which has no business in a path.
    @Test func theMediaFolderIsNamedForTheVerse() {
        #expect(LampLibrary.noteMediaOwnerID(43_011_035) == "43011035")
        let folder = LampLibrary.noteMediaFolderURL(
            rootURL: URL(fileURLWithPath: "/tmp/library"), reference: 43_011_035
        )
        #expect(folder?.path == "/tmp/library/Media/Notes/43011035")
    }

    /// Deleting one note must not take another's pictures. The folder is
    /// named for the verse, and `saveVerseNote` takes any id, so two rows on
    /// one verse share it.
    @Test func deletingOneNoteLeavesAnothersMediaAlone() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "![](media/8A1F) Kept.", mediaJSON: mediaJSON
        )
        // A second row on the same verse, as the public API allows.
        try await library.saveVerseNote(LampVerseNote(
            id: "another-note", reference: 43_011_035, content: "Also here."
        ))
        let folder = try #require(
            LampLibrary.noteMediaFolderURL(rootURL: root, reference: 43_011_035)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: folder.appendingPathComponent("tomb.png"))

        try await library.deleteVerseNote(id: "another-note")
        #expect(FileManager.default.fileExists(atPath: folder.path),
                "the surviving note still has its pictures")

        // Once the last note on the verse goes, so do they.
        _ = try await library.setPersonalVerseNote(reference: 43_011_035, content: "  ")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Resolving a conflict re-dates a note and saves it, so anything the
    /// re-dating drops is deleted by the act of choosing.
    @Test func reDatingANoteKeepsItsMedia() {
        let note = LampVerseNote(
            id: "n", reference: 43_011_035, content: "He wept.", mediaJSON: mediaJSON
        )
        #expect(note.withLastModified(Date(timeIntervalSince1970: 9_000)).mediaJSON == mediaJSON)
        // And a note set aside as a conflict comes back with its media, so
        // choosing it later restores the note rather than a stripped copy.
        let payload = try? LampSyncConflictPayload.encode(note)
        let restored = payload.flatMap { LampSyncConflictPayload.note(from: $0) }
        #expect(restored?.mediaJSON == mediaJSON)
    }

    /// What a study document does *not* carry, written down so the gap is
    /// deliberate rather than forgotten: a backup keeps a note's files and
    /// nothing pointing at them. Closing it is a module format change, and
    /// belongs with module-notes media.
    @Test func aStudyDocumentCarriesNoMedia() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "He wept.", mediaJSON: mediaJSON
        )
        let document = try await library.personalNotesDocument(bookNumber: 43)
        let text = String(decoding: document.jsonData, as: UTF8.self)
        #expect(!text.contains("tomb.png"), "no media list in a shared document")
    }

    /// A note's picture goes up and comes down again, under a path of its
    /// own rather than among the writings'.
    @Test func aNotesPictureSyncsBothWays() async throws {
        let root = try scratch()
        let other = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }

        // A note with a picture on disk, as attaching leaves it.
        let folder = try #require(
            LampLibrary.noteMediaFolderURL(rootURL: root, reference: 43_011_035)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a picture".utf8).write(to: folder.appendingPathComponent("tomb.png"))
        let owner = LampSyncDevotionalMedia.Owner(
            id: LampLibrary.noteMediaOwnerID(43_011_035), mediaJSON: mediaJSON
        )

        let outgoing = try LampSyncDevotionalMedia.outgoingFileURLs(
            scope: .note, owners: [owner], to: "notes", from: root
        )
        #expect(outgoing.map(\.remotePath) == ["NoteMedia/notes/43011035/tomb.png"])
        #expect(LampSyncFolderLayout.kind(of: outgoing[0].remotePath) == .noteMedia)
        #expect(LampSyncFolderLayout.kind(of: outgoing[0].remotePath)?.isMedia == true)

        // And the same path brings it down into another library.
        var asked: [String] = []
        try await LampSyncDevotionalMedia.downloadToLibrary(
            scope: .note, owners: [owner], from: "notes", into: other
        ) { path in
            asked.append(path)
            return try Data(contentsOf: outgoing[0].localURL)
        }
        #expect(asked == ["NoteMedia/notes/43011035/tomb.png"])
        let arrived = try #require(
            LampLibrary.noteMediaFolderURL(rootURL: other, reference: 43_011_035)
        ).appendingPathComponent("tomb.png")
        #expect(FileManager.default.fileExists(atPath: arrived.path))
        #expect(try Data(contentsOf: arrived) == Data("a picture".utf8))
    }

    /// A writing's attachments still go where they always did, and the two
    /// never land in each other's folders.
    @Test func aWritingsMediaIsUnmovedByTheNoteScope() throws {
        #expect(try LampSyncFolderLayout.devotionalMediaPath(
            moduleID: "devotionals", devotionalID: "d-1", filename: "tomb.png"
        ) == "DevotionalMedia/devotionals/d-1/tomb.png")
        #expect(try LampSyncFolderLayout.noteMediaPath(
            moduleID: "notes", noteOwnerID: "43011035", filename: "tomb.png"
        ) == "NoteMedia/notes/43011035/tomb.png")
        #expect(LampSyncFolderLayout.kind(of: "DevotionalMedia/d/1/x.png") == .devotionalMedia)
        #expect(LampSyncFolderLayout.remoteModuleID(of: "NoteMedia/notes/43011035/x.png") == "notes")
        // Three segments is a notes *module's* picture, not an invalid
        // personal one: the count is what tells the two apart, and this
        // assertion read the other way until modules gained pictures.
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/notes/x.png") == .noteMedia)
        // Two is neither.
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/x.png") == nil)
    }

    /// A note's picture reaches a second device.
    ///
    /// The file carries the media list now, so the receiving device knows
    /// the note has a picture and which file it is. Before, the text arrived
    /// holding `media/<id>` and nothing said what that was, so the download
    /// — which asks only about notes that have media here — asked for
    /// nothing and the picture stayed on the device it was attached on.
    @Test func aNotesMediaReachesADeviceThatNeverHadIt() async throws {
        let here = try scratch()
        let there = try scratch()
        defer {
            try? FileManager.default.removeItem(at: here)
            try? FileManager.default.removeItem(at: there)
        }
        let source = LampLibrary(rootURL: here)
        let target = LampLibrary(rootURL: there)

        _ = try await source.setPersonalVerseNote(
            reference: 43_011_035, content: "![](media/8A1F) He wept.", mediaJSON: mediaJSON
        )
        let exported = here.appendingPathComponent("notes.lamp")
        try await source.exportPersonalModule(.notes, format: .lamp, to: exported)
        _ = try await target.importPersonalStudyData(from: exported, forSync: true)

        let arrived = try #require(
            try await target.verseNotes(reference: 43_011_035)
                .first { $0.moduleID == "personal-notes" }
        )
        #expect(arrived.mediaJSON == mediaJSON, "the other device knows which file it wants")
        // Which is what lets it ask for the file at all.
        #expect(try await target.personalNotesWithMedia().count == 1)
    }

    /// A file that predates the column says nothing about pictures, which is
    /// not the same as saying there are none: this device keeps its own.
    @Test func aFileWithoutTheColumnLeavesLocalMediaAlone() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "Mine.", mediaJSON: mediaJSON
        )

        // A document, which carries no media column at all.
        let document = try await library.personalNotesDocument(bookNumber: 43)
        let documentURL = root.appendingPathComponent(document.suggestedJSONFilename)
        try document.jsonData.write(to: documentURL)
        _ = try await library.importPersonalStudyData(from: documentURL, forSync: true)

        let note = try #require(
            try await library.verseNotes(reference: 43_011_035)
                .first { $0.moduleID == "personal-notes" }
        )
        #expect(note.mediaJSON == mediaJSON, "silence is not an empty list")
    }

    /// Renaming a highlight set here is not undone by a device that never
    /// touched the name.
    ///
    /// The upsert took the incoming name always, so a phone syncing a set
    /// it had only added a highlight to put the old name back — and this Mac
    /// then published it, losing the rename on both devices (ios-56's
    /// scenario). The newer side's name wins now, as the phone already does.
    @Test func theNewerSidesSetNameWins() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        // A set of the reader's own: the default set's id holds a colon,
        // which saveHighlightSet refuses.
        let created = try await library.saveHighlightSet(LampHighlightSet(
            id: "promises", name: "Promises", translationID: "KJV",
            lastModified: Date(timeIntervalSince1970: 1_000)
        ))
        _ = try await library.saveVerseHighlight(
            translationID: "KJV", reference: 43_003_016,
            startOffset: 0, endOffset: 5, color: "#ffcc00", setID: created.id
        )

        // A copy from elsewhere, older, carrying the name it always had.
        let document = try await library.personalHighlightsDocument(
            translationID: "KJV", moduleID: "promises",
            name: "Promises", setID: created.id
        )
        let url = root.appendingPathComponent(document.suggestedJSONFilename)
        try document.jsonData.write(to: url)

        // Renamed here afterwards, so this is the later edit.
        _ = try await library.saveHighlightSet(LampHighlightSet(
            id: created.id, name: "Promises of God", translationID: "KJV",
            created: created.created, lastModified: Date(timeIntervalSince1970: 9_000)
        ))

        _ = try await library.importPersonalStudyData(from: url, forSync: true)

        let after = try #require(
            try await library.highlightSets().first { $0.id == created.id }
        )
        #expect(after.name == "Promises of God", "the rename stands")
    }

    /// Where a picture is depends on whose note it is.
    ///
    /// The reader's own notes are one per verse and keyed by it; a module's
    /// pictures belong to the module, which declares them once and whose
    /// notes point at them by id.
    @Test func aNotesPictureIsFoundWhereItsOwnerKeepsIt() {
        let root = URL(fileURLWithPath: "/tmp/library")
        let link = URL(string: "media/8A1F")!

        let mine = LampVerseNote(
            id: "personal-notes:43011035", reference: 43_011_035,
            content: "![](media/8A1F)", mediaJSON: mediaJSON
        )
        #expect(LampLibrary.noteMediaOwnerID(of: mine) == "43011035")
        #expect(
            LampLibrary.noteMediaURL(for: link, in: mine, rootURL: root)?.path
                == "/tmp/library/Media/Notes/43011035/tomb.png"
        )

        let theirs = LampVerseNote(
            id: "tske:43011035", moduleID: "tske", reference: 43_011_035,
            content: "![](media/8A1F)", mediaJSON: mediaJSON
        )
        #expect(LampLibrary.noteMediaOwnerID(of: theirs) == "tske")
        #expect(
            LampLibrary.noteMediaURL(for: link, in: theirs, rootURL: root)?.path
                == "/tmp/library/Media/Notes/tske/tomb.png"
        )

        // A link to something the note does not carry resolves to nothing
        // rather than to an invented filename.
        #expect(LampLibrary.noteMediaURL(
            for: URL(string: "media/NOPE")!, in: mine, rootURL: root
        ) == nil)
        let bare = LampVerseNote(reference: 43_011_035, content: "No pictures.")
        #expect(LampLibrary.noteMediaURL(for: link, in: bare, rootURL: root) == nil)
    }

    /// One unreadable entry costs its own picture and no others — the fault
    /// we shipped once already, now in the shared decoder.
    @Test func oneBadMediaEntryDoesNotBlankTheRest() {
        let mixed = """
            [{"id":"A","type":"image","filename":"a.png","mimeType":"image/png"},
             {"id":"B","type":"hologram","filename":"b.xyz","mimeType":"x/y"},
             {"id":"C","type":"image","filename":"c.png","mimeType":"image/png"}]
            """
        let list = LampMediaReference.list(fromJSON: mixed)
        #expect(list.map(\.id) == ["A", "C"])
        #expect(LampMediaReference.list(fromJSON: nil).isEmpty)
        #expect(LampMediaReference.list(fromJSON: "not json").isEmpty)
    }

    /// Where a notes module's picture travels, and that the two shapes under
    /// NoteMedia stay apart.
    @Test func aNotesModulesPictureHasAPathOfItsOwn() throws {
        #expect(try LampSyncFolderLayout.noteModuleMediaPath(
            moduleID: "tske", filename: "tomb.png"
        ) == "NoteMedia/tske/tomb.png")
        #expect(try LampSyncFolderLayout.noteMediaPath(
            moduleID: "notes", noteOwnerID: "43011035", filename: "tomb.png"
        ) == "NoteMedia/notes/43011035/tomb.png")

        // Both are note media, and both are media: never merged, uploaded
        // only where absent, a different copy on the server a conflict.
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/tske/tomb.png") == .noteMedia)
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/notes/43011035/tomb.png") == .noteMedia)
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/tske/tomb.png")?.isMedia == true)
        // And neither is a path with nothing but a module in it.
        #expect(LampSyncFolderLayout.kind(of: "NoteMedia/tske") == nil)

        #expect(LampSyncFolderLayout.remoteModuleID(of: "NoteMedia/tske/tomb.png") == "tske")

        // A name that would climb out of the folder is refused.
        #expect(throws: (any Error).self) {
            try LampSyncFolderLayout.noteModuleMediaPath(
                moduleID: "tske", filename: "../escape.png"
            )
        }
    }
}
