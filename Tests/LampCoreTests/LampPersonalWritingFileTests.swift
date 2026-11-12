import CryptoKit
import Foundation
import GRDB
import LampModuleKit
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

    /// **Changed once, deliberately, when `search_text` stopped being taken
    /// from the sender.** It is a derived column that each app rebuilds for
    /// its own index, and the one column two apps can spell differently
    /// while holding identical content — enough, by itself, to make each
    /// publish its file in reply to the other for ever. It is derived from
    /// the row now, structured summaries and footnotes read for their text.
    /// Before that it was taken from the old writer and unchanged by the
    /// move. If a deliberate format change breaks this again, read the new
    /// digest off the failure, say in the commit why, and tell the phone.
    @Test func theFileIsTheSameOneTheLibraryUsedToWrite() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try await export(from: LampLibrary(rootURL: root), at: root)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == "e1225cfc85f9750d792a8126cf3bc53b5c3e48afda163448af89e1f3310c5a7d",
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

    /// A writing with a picture in it, and the picture on disk.
    private func withAPicture(in root: URL) async throws -> LampLibrary {
        let library = LampLibrary(rootURL: root)
        let folder = root.appendingPathComponent("Media/Devotionals/writing-2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a picture".utf8).write(to: folder.appendingPathComponent("tomb.png"))
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "writing-2", moduleID: "personal-writing", moduleName: "My Writing",
            title: "At the tomb",
            content: "He wept.\n\n![the tomb](lamp-media://writing-2/tomb.png)\n",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_000)
        ), preserveLastModified: true)
        return library
    }

    private func rows(
        of archive: Data, at url: URL, without ignored: Swift.Set<String> = []
    ) async throws -> [String] {
        let body = try (archive as NSData).decompressed(using: .zlib) as Data
        try body.write(to: url)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devotional_entries ORDER BY id")
                .map { row in
                    row.columnNames
                        .filter { !ignored.contains($0) }
                        .map { "\($0)=\(row[$0] ?? "nil")" }
                        .joined(separator: "|")
                }
        }
    }

    /// Publishing used to mean exporting the file and then rewriting it in
    /// place: unwrap a plain-text content wrapper to the Markdown the other
    /// app reads, gather the media that Markdown names, refuse the lot if a
    /// picture is missing. Core does it on the way out now, and this holds
    /// the two to the same rows — which is what lets a device that already
    /// has these writings take the new file and write nothing back.
    @Test func whatIsPublishedSaysTheSameAsTheOldRewriteDid() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await withAPicture(in: root)

        let published = try await library.personalArchive(.writing, moduleID: "devotionals")
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            try await library.exportedPersonalArchiveForTesting(.writing),
            replacingModuleIDWith: "devotionals",
            kind: .devotionals,
            mediaRootURL: root
        )
        // Every column but `search_text`, which is deliberately not what
        // the old route wrote: it is derived here now, and from the row's
        // structured fields rather than this app's flattened ones. Nothing
        // reads the sender's copy of it — each app rebuilds the column for
        // its own index — so a difference there is not a difference about
        // the writing.
        #expect(
            try await rows(
                of: published, at: root.appendingPathComponent("new.sqlite"),
                without: ["search_text"]
            ) == (try await rows(
                of: rewritten, at: root.appendingPathComponent("old.sqlite"),
                without: ["search_text"]
            ))
        )

        // The unwrapping is the point of it: the column carries Markdown.
        let body = try (published as NSData).decompressed(using: .zlib) as Data
        let file = root.appendingPathComponent("read.sqlite")
        try body.write(to: file)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        let carried = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT content_json, media_json FROM devotional_entries").map {
                (content: $0["content_json"] as String, media: $0["media_json"] as String?)
            }
        }
        let entry = try #require(carried)
        #expect(entry.content.hasPrefix("He wept."), "Markdown, not a JSON box around it")
        #expect(entry.media?.contains("tomb.png") == true, "and the picture it names is listed")
    }

    /// A writing whose picture this device does not hold is refused rather
    /// than published. The other device would otherwise be handed a
    /// reference to bytes nobody has sent it.
    @Test func aWritingWithAMissingPictureIsNotPublished() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await withAPicture(in: root)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Media/Devotionals/writing-2/tomb.png")
        )

        await #expect(throws: (any Error).self) {
            _ = try await library.personalArchive(.writing, moduleID: "devotionals")
        }
        // A local backup is still written: it is this device's own copy of
        // its own writings, not something another device will go looking
        // for files for.
        _ = try await library.exportedPersonalArchiveForTesting(.writing)
    }

    /// Rows in and the model in give the same file.
    ///
    /// The phone writes from rows because this app's model cannot hold
    /// everything the file does. That only helps if the two routes go
    /// through one sequence — the metadata row, the rows, the container, in
    /// that order — so this holds them byte for byte.
    @Test func rowsAndTheModelProduceOneFile() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        _ = try await export(from: library, at: root)

        let writings = try await library.personalDevotionals()
        let fromModel = try LampPersonalWritingFile.archive(writings)
        let fromRows = try LampPersonalWritingFile.archive(
            rows: try writings.map { try LampPersonalWritingFile.row(for: $0) }
        )
        #expect(fromModel == fromRows)
    }

    /// A row is written as given. Everything this app's model flattens —
    /// a structured summary, structured footnotes, a real series id,
    /// `related_ids`, a subscription — survives when an app that has them
    /// hands over a row.
    @Test func aRowIsWrittenWordForWord() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try LampPersonalWritingFile.archive(rows: [
            LampPersonalWritingFile.Row(
                id: "w1", moduleID: "devotionals", title: "Kept whole",
                seriesID: "series-7", seriesName: "Lent", seriesOrder: 2,
                summaryJSON: #"{"text":"A summary","spans":[{"start":0}]}"#,
                contentJSON: "Body.",
                footnotesJSON: #"[{"id":"a","content":"Chrysostom"}]"#,
                relatedIDs: "w2,w3",
                created: 1_700_000_000, lastModified: 1_700_000_001,
                subscriptionID: "sub-1", isReadOnly: 1
            ),
        ], moduleID: "devotionals")

        let body = try (archive as NSData).decompressed(using: .zlib) as Data
        let file = root.appendingPathComponent("rows.sqlite")
        try body.write(to: file)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        let row = try #require(try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM devotional_entries")
        })
        #expect(row["series_id"] as String? == "series-7", "a real id, not the name")
        #expect(row["summary_json"] as String? == #"{"text":"A summary","spans":[{"start":0}]}"#)
        #expect(row["footnotes_json"] as String? == #"[{"id":"a","content":"Chrysostom"}]"#)
        #expect(row["related_ids"] as String? == "w2,w3")
        #expect(row["subscription_id"] as String? == "sub-1")
        #expect(row["is_read_only"] as Int? == 1)
    }
}
