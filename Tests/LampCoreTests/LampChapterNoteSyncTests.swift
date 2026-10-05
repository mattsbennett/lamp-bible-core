import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

struct LampChapterNoteSyncTests {
    /// Genesis 1, verse 0: a note on the chapter as a whole.
    private let chapter = 1_001_000

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-chapter-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func sync(_ source: LampLibrary, _ destination: LampLibrary, in root: URL) async throws {
        let backup = root.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        _ = try await source.exportPortableBackup(to: backup)
        _ = try await destination.importPortableBackup(from: backup)
    }

    @Test func aChapterNoteKeepsItsOwnTitleThroughSync() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LampLibrary(rootURL: root.appendingPathComponent("A"))
        let b = LampLibrary(rootURL: root.appendingPathComponent("B"))
        _ = try await a.setPersonalVerseNote(reference: chapter, title: "General Notes", content: "Overview")

        // Each sync imports what was last published, so a title that changed in
        // transit would stop every later sync with a conflict.
        try await sync(a, b, in: root)
        try await sync(b, a, in: root)
        try await sync(a, b, in: root)

        #expect(try await a.verseNotes(reference: chapter).map(\.title) == ["General Notes"])
        #expect(try await b.verseNotes(reference: chapter).map(\.title) == ["General Notes"])
    }

    @Test func anOlderDevicesUntitledCopyNeitherConflictsNorRenames() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LampLibrary(rootURL: root.appendingPathComponent("A"))
        let b = LampLibrary(rootURL: root.appendingPathComponent("B"))
        _ = try await a.setPersonalVerseNote(reference: chapter, title: "General Notes", content: "Overview")
        try await sync(a, b, in: root)

        // What a version that predates chapter titles publishes.
        let backup = root.appendingPathComponent("older", isDirectory: true)
        _ = try await b.exportPortableBackup(to: backup)
        let notesFolder = backup.appendingPathComponent(LampPortableBackupLayout.notesDirectory)
        for file in try FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stripped = text.replacingOccurrences(
                of: #"\s*"introductionTitle"\s*:\s*"[^"]*",?"#,
                with: "",
                options: .regularExpression
            )
            #expect(stripped != text)
            try stripped.write(to: file, atomically: true, encoding: .utf8)
        }

        _ = try await a.importPortableBackup(from: backup)
        #expect(try await a.verseNotes(reference: chapter).map(\.title) == ["General Notes"])
    }

    @Test func writingWithEmptyFieldsMatchesItsOwnCopy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("A"))
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "w", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Beta Writing", content: "Body"
        ))
        // Writing from earlier versions stored empty fields as "", which saving
        // no longer does, so it is set directly.
        let database = try DatabaseQueue(path: root.appendingPathComponent("A/UserData.sqlite").path)
        try await database.write { db in
            try db.execute(sql: "UPDATE personal_devotionals SET series_name = '', footnotes = '' WHERE id = 'w'")
        }
        // Its own export coming back must not read as a conflicting edit.
        try await sync(library, library, in: root)
        try await sync(library, library, in: root)
        #expect(try await library.personalDevotionals().map(\.title) == ["Beta Writing"])
    }
}

