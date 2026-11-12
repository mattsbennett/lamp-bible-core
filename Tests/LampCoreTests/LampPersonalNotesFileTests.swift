import CryptoKit
import Foundation
import GRDB
import LampModuleKit
@testable import LampCore
import Testing

/// The file the reader's own notes travel in.
///
/// Its bytes are the contract between two apps, not an implementation
/// detail: a file whose spelling depends on which device wrote it is
/// re-uploaded by the other device on every pass, for ever. So the writer
/// moved into `LampPersonalNotesFile`, where both apps can reach it, and
/// what it produces is pinned here by its digest.
struct LampPersonalNotesFileTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-notes-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// Two notes with everything in them — a title, references, a footnote
    /// with a kind, a slash in the text, a picture — exported the way a sync
    /// publishes them.
    private func export(from library: LampLibrary, at root: URL) async throws -> Data {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        try await library.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016", reference: 43_003_016,
            title: "Loved", content: "The whole world, and a / slash.",
            verseReferences: [43_003_017],
            footnotes: [LampVerseFootnote(id: "a", kind: "note", content: "Chrysostom.")],
            lastModified: moment
        ))
        try await library.saveVerseNote(LampVerseNote(
            id: "personal-notes:43011035", reference: 43_011_035,
            content: "He wept at the ![](media/8A1F) tomb.",
            mediaJSON: #"[{"id":"8A1F","type":"image","filename":"tomb.png","mimeType":"image/png"}]"#,
            lastModified: moment
        ))
        let out = root.appendingPathComponent("notes.lamp")
        try await library.exportPersonalModule(.notes, format: .lamp, to: out)
        return try Data(contentsOf: out)
    }

    /// The digest of that file, taken before the writer moved out of
    /// `LampLibrary` and unchanged by the move.
    ///
    /// It is not here to be precious about bytes. It is here because the
    /// move's whole promise is that the file did not change: a Mac that
    /// wrote a different file after an upgrade would publish every note
    /// again, and so would every device that received it.
    ///
    /// If a deliberate change to the format breaks this, read the new digest
    /// off the failure and say in the commit why the file changed — and tell
    /// the phone, because its copy must change with it.
    @Test func theFileIsTheSameOneTheLibraryUsedToWrite() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try await export(from: LampLibrary(rootURL: root), at: root)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == "0e47f547a11ce9d01b5a0b7b7494582e8313af61686a714694af54bd4faddf9b",
            "the notes file changed; see this test's note before accepting it"
        )
    }

    /// And the same notes give the same file twice, in two libraries that
    /// share nothing. Swift seeds a dictionary's order per process, so a
    /// digest taken twice in one run can agree while two devices disagree;
    /// what this can show is that nothing of the library's own — a path, a
    /// row id, a clock — reaches the bytes.
    @Test func twoLibrariesWriteTheSameBytes() async throws {
        let here = try scratch()
        let there = try scratch()
        defer {
            try? FileManager.default.removeItem(at: here)
            try? FileManager.default.removeItem(at: there)
        }
        let mine = try await export(from: LampLibrary(rootURL: here), at: here)
        let theirs = try await export(from: LampLibrary(rootURL: there), at: there)
        #expect(mine == theirs)
    }

    /// **The file that actually travels**, which is not the one above.
    ///
    /// A local export is `personal-notes`; what a sync publishes is the same
    /// content under the id the collection has on the server. That used to
    /// be made by writing the first file and then rewriting it —
    /// decompress, `UPDATE` three tables, compress again
    /// (`LampWebDAVPersonalArchiveAdapter`). Writing the id in from the
    /// start gives the same content in one pass, and gives the phone
    /// something it can call: the rewrite was the Mac's own step, so a file
    /// built any other way could never match it.
    ///
    /// ios-56 caught this: the first pin here was of the *exported* file,
    /// which no device ever receives.
    @Test func thePublishedFileCarriesTheNameItTravelsUnder() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        _ = try await export(from: library, at: root)

        let published = try await library.personalArchive(.notes, moduleID: "notes")
        let body = try (published as NSData).decompressed(using: .zlib) as Data
        let file = root.appendingPathComponent("published.sqlite")
        try body.write(to: file)

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        let named = try await queue.read { db in
            (
                format: try String.fetchOne(db, sql: "SELECT module_id FROM module_format"),
                meta: try String.fetchOne(db, sql: "SELECT id FROM module_meta"),
                rows: try String.fetchAll(db, sql: "SELECT DISTINCT module_id FROM note_entries"),
                name: try String.fetchOne(db, sql: "SELECT name FROM module_meta")
            )
        }
        #expect(named.format == "notes")
        #expect(named.meta == "notes")
        #expect(named.rows == ["notes"], "every row, not only the metadata")
        // And the name is still the reader's own: the old rewrite changed
        // ids and left this alone, and so does this.
        #expect(named.name == LampPersonalModule.notes.name)

        // Same notes, same name, same bytes — which is the whole point of
        // the phone being able to call this.
        let again = try await library.personalArchive(.notes, moduleID: "notes")
        #expect(published == again)

        let digest = SHA256.hash(data: published).map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == "2a07a6f0b2ebbe8ab26134f7e605289969e5a935a562eb98f55f0a0d675f8c32",
            "the published notes file changed; see this test's note before accepting it"
        )

        // It is **not** the old rewrite's bytes, and is not meant to be: a
        // file built in one pass and a file updated in place and compressed
        // again differ in their pages. So every device publishes its notes
        // once more after this lands — which is the agreed criterion, one
        // upload at most on the first pass and nothing on the next, rather
        // than a cost to be avoided. What must match is the *content*, so
        // that a device which already has these notes merges them and
        // writes nothing back.
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            try await library.exportedPersonalArchiveForTesting(.notes),
            replacingModuleIDWith: "notes",
            kind: .notes
        )
        #expect(published != rewritten, "a one-time republish, deliberately")
        let old = try (rewritten as NSData).decompressed(using: .zlib) as Data
        let oldFile = root.appendingPathComponent("rewritten.sqlite")
        try old.write(to: oldFile)
        let oldQueue = try DatabaseQueue(path: oldFile.path, configuration: configuration)
        let before = try await oldQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM note_entries ORDER BY id")
                .map { $0.description }
        }
        let after = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM note_entries ORDER BY id")
                .map { $0.description }
        }
        #expect(before == after, "same rows, differently packed")
    }
}
