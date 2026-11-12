import CryptoKit
import Foundation
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
}
