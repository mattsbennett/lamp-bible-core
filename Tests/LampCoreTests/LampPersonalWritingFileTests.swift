import CryptoKit
import Foundation
@testable import LampCore
import Testing

/// The file the reader's own writings travel in.
///
/// As with notes, its bytes are the contract between two apps rather than
/// an implementation detail, so the move into `LampPersonalWritingFile` is
/// held to producing exactly what `LampLibrary` produced before it.
struct LampPersonalWritingFileTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-writing-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// One writing with every field filled: a series, key scriptures, a
    /// summary holding a slash, footnotes, a picture.
    private func export(from library: LampLibrary, at root: URL) async throws -> Data {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "writing-1", moduleID: "personal-writing", moduleName: "My Writing",
            title: "The Weight", subtitle: "A talk", author: "A Reader",
            date: "2026-11-11", tags: ["talk", "john"], category: "talk",
            seriesName: "Lent", seriesOrder: 2,
            keyScriptures: [LampScriptureLink(
                text: "John 3:16-17", startReference: 43_003_016, endReference: 43_003_017
            )],
            summary: "A summary with a / slash.",
            content: "The body, with *emphasis*.",
            footnotes: "[^a]: Chrysostom.",
            mediaJSON: #"[{"id":"8A1F","type":"image","filename":"tomb.png","mimeType":"image/png"}]"#,
            created: moment, lastModified: moment
        ), preserveLastModified: true)
        let out = root.appendingPathComponent("devotionals.lamp")
        try await library.exportPersonalModule(.writing, format: .lamp, to: out)
        return try Data(contentsOf: out)
    }

    /// Taken from the old writer before the move, and unchanged by it. If a
    /// deliberate format change breaks this, read the new digest off the
    /// failure, say in the commit why the file changed, and tell the phone —
    /// its copy must change with it.
    @Test func theFileIsTheSameOneTheLibraryUsedToWrite() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try await export(from: LampLibrary(rootURL: root), at: root)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == "41bfe0a7673c7982e2043080d40cf47b0ce1082ffbdccfa87297928c4464e1b7",
            "the writings file changed; see this test's note before accepting it"
        )
    }

    @Test func twoLibrariesWriteTheSameBytes() async throws {
        let here = try scratch()
        let there = try scratch()
        defer {
            try? FileManager.default.removeItem(at: here)
            try? FileManager.default.removeItem(at: there)
        }
        #expect(
            try await export(from: LampLibrary(rootURL: here), at: here)
                == (try await export(from: LampLibrary(rootURL: there), at: there))
        )
    }

    /// A writing with no date of its own would be stamped with the clock,
    /// making the file different every time it was written — every device
    /// downloading every writing again, for ever. The reader's own table
    /// forbids nil, so a sync cannot reach it; this says so out loud,
    /// because the next record type with optional dates will not have a
    /// NOT NULL column to save it.
    @Test func everyWritingASyncPublishesCarriesItsOwnDates() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "undated", moduleID: "personal-writing", moduleName: "My Writing",
            title: "No dates given", content: "Body."
        ))
        for writing in try await library.personalDevotionals() {
            #expect(writing.created != nil, "\(writing.id) would be stamped with the clock")
            #expect(writing.lastModified != nil, "\(writing.id) would be stamped with the clock")
        }
    }
}
