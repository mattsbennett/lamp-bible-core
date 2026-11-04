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

    /// The Septuagint's numbering, which the bundled `LXX` and `Brenton`
    /// declare and which the skills shipped with Lamp describe to a reader.
    /// It is not a constant offset: the two traditions join and split psalms
    /// in different places, and the Septuagint has no Nehemiah of its own.
    @Test func mapsTheSeptuagintsOwnNumbering() {
        let english = LampVersification.standard(.english)
        let septuagint = LampVersification.standard(.septuagint)
        func asSeptuagint(_ book: Int, _ chapter: Int, _ verse: Int) -> Int? {
            english.convert(ref(book, chapter, verse), to: septuagint)
        }

        // A psalm's title is the Septuagint's verse 1, not an unnumbered line.
        #expect(asSeptuagint(19, 22, 0) == ref(19, 21, 1))
        #expect(asSeptuagint(19, 22, 1) == ref(19, 21, 2))
        #expect(septuagint.convert(ref(19, 21, 2), to: english) == ref(19, 22, 1))

        // One lower through the middle of the book, and the joins and splits
        // that stop it being an offset.
        #expect(asSeptuagint(19, 1, 1) == ref(19, 1, 1))
        #expect(asSeptuagint(19, 10, 1) == ref(19, 9, 22))
        #expect(asSeptuagint(19, 11, 1) == ref(19, 10, 1))
        #expect(asSeptuagint(19, 114, 1) == ref(19, 113, 1))
        #expect(asSeptuagint(19, 115, 1) == ref(19, 113, 9))
        #expect(asSeptuagint(19, 116, 1) == ref(19, 114, 1))
        #expect(asSeptuagint(19, 117, 1) == ref(19, 116, 1))
        #expect(asSeptuagint(19, 147, 1) == ref(19, 146, 1))
        #expect(asSeptuagint(19, 148, 1) == ref(19, 148, 1))
        #expect(septuagint.verseCounts[19]?[151] == 7)

        // Nehemiah is numbered as Ezra 11-23, and Ezra's own chapters are not
        // moved: a module of this scheme carries no Nehemiah book at all.
        #expect(asSeptuagint(16, 1, 1) == ref(15, 11, 1))
        #expect(asSeptuagint(16, 13, 31) == ref(15, 23, 31))
        #expect(asSeptuagint(15, 10, 44) == ref(15, 10, 44))
        #expect(septuagint.verseCounts[16] == nil)
        #expect(septuagint.verseCounts[15]?[23] == 31)
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
