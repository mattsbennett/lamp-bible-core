import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

/// A translation says how it numbers its verses, so another can be read
/// beside it verse for verse: an imported one in its own metadata, a bundled
/// one in the bundle's table of translations, with any verses it places
/// differently from its scheme.
struct LampLibraryVersificationTests {
    private func ref(_ book: Int, _ chapter: Int, _ verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    @Test func readsTheSchemeAnImportedTranslationNames() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-versification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let moduleURL = fixtureURL.appendingPathComponent("HEB.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "HEB", "type": "translation",
                "name": "Hebrew-numbered", "abbreviation": "HEB", "language": "en",
                "versification": "org"
              },
              "books": [{
                "id": "Joel", "name": "Joel", "number": 29, "testament": "OT",
                "chapters": [{"chapter": 3, "verses": [
                  {"v": 1, "ref": 29003001, "content": {"text": "I will pour out my Spirit"}}
                ]}]
              }]
            }
            """#.utf8),
            sourceFilename: "HEB.json",
            destinationURL: moduleURL
        )
        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)

        let hebrew = try await library.versification(moduleID: "HEB")
        #expect(hebrew.scheme == .original)
        // Its Joel 3:1 is the English 2:28.
        #expect(hebrew.convert(ref(29, 3, 1), to: .standard(.english)) == ref(29, 2, 28))
    }

    @Test func readsABundledTranslationsSchemeAndItsDepartures() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-versification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let databaseURL = fixtureURL.appendingPathComponent("bundled.sqlite")
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try await queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
                try db.execute(sql: #"""
                    CREATE TABLE translations (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, abbreviation TEXT,
                        language TEXT, description TEXT, versification TEXT,
                        versification_mappings TEXT
                    );
                    CREATE TABLE translation_books (
                        id INTEGER PRIMARY KEY, translation_id TEXT, book_number INTEGER,
                        book_id TEXT, name TEXT, testament TEXT, chapter_count INTEGER
                    );
                    CREATE TABLE translation_verses (
                        id INTEGER PRIMARY KEY, translation_id TEXT, ref INTEGER,
                        book INTEGER, chapter INTEGER, verse INTEGER, text TEXT,
                        paragraph INTEGER, annotations_json TEXT, footnotes_json TEXT,
                        footnote_refs_json TEXT, poetry_json TEXT
                    );
                    INSERT INTO translations VALUES
                        ('WEB', 'Web-like', 'WEB', 'en', NULL, 'standard', '["ROM 14:24-26 = ROM 16:25-27"]'),
                        ('KJV', 'Kjv-like', 'KJV', 'en', NULL, 'kjv', NULL);
                    INSERT INTO translation_books VALUES
                        (1, 'WEB', 45, 'Rom', 'Romans', 'NT', 16),
                        (2, 'KJV', 45, 'Rom', 'Romans', 'NT', 16);
                    INSERT INTO translation_verses VALUES
                        (1, 'WEB', 45014024, 45, 14, 24, 'Now to him who is able', 0, NULL, NULL, NULL, NULL),
                        (2, 'KJV', 45016025, 45, 16, 25, 'Now to him that is of power', 0, NULL, NULL, NULL, NULL);
                    """#)
            }
        }
        let archiveURL = fixtureURL.appendingPathComponent("bundled_modules.db.zlib")
        let compressed = try (Data(contentsOf: databaseURL) as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: archiveURL)
        let library = LampLibrary(
            rootURL: fixtureURL.appendingPathComponent("Library"),
            bundledModulesArchiveURL: archiveURL
        )

        let web = try await library.versification(moduleID: "WEB")
        let kjv = try await library.versification(moduleID: "KJV")
        #expect(web.scheme == .english)
        #expect(kjv.scheme == .english)
        // The WEB's 14:24 is the doxology the KJV numbers 16:25.
        #expect(web.convert(ref(45, 14, 24), to: kjv) == ref(45, 16, 25))
        #expect(kjv.convert(ref(45, 16, 27), to: web) == ref(45, 14, 26))
    }
}
