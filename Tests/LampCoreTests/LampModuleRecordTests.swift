import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

/// What an info window shows of a module: the owner had ESV and ESVs both
/// listed as "ESV", and nothing on screen told them apart.
struct LampModuleRecordTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func anInstalledModuleShowsItsFileAndEveryColumn() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ESVs.lamp")
        _ = try LampModuleCompiler().compile(data: Data(#"""
            {"meta": {"schemaVersion": "1.0", "id": "ESVs", "type": "translation", "name": "English Standard Version",
                      "abbreviation": "ESV", "language": "en", "year": 2016},
             "books": [{"id": "John", "name": "John", "number": 43, "testament": "NT",
                        "chapters": [{"chapter": 1, "verses": [{"v": 1, "content": {"text": "In the beginning"}}]}]}]}
            """#.utf8), sourceFilename: "ESVs.json", destinationURL: source)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await library.install(from: source)

        let record = try #require(try await library.moduleRecord(kind: .translation, id: "ESVs"))

        #expect(record.module.id == "ESVs")
        guard case .installed(let moduleFile?, let database) = record.storage else {
            Issue.record("an installed module keeps its file: \(record.storage)")
            return
        }
        #expect(moduleFile.url.pathExtension == "lamp")
        #expect(moduleFile.sha256 == (try LampSyncContentRevision.digest(forFileAt: moduleFile.url)))
        #expect(moduleFile.byteCount == record.module.compressedByteCount)
        #expect(database.url.pathExtension == "sqlite")
        #expect(database.sha256 == nil)
        #expect(record.tables.map(\.name).contains("translation_meta"))
        #expect(record.value(of: "year") == .integer(2016))
        // Applicable and empty, against not applicable at all.
        #expect(record.value(of: "publisher") == .null)
        #expect(record.value(of: "isbn") == nil)
        // The text itself is not metadata.
        #expect(!record.tables.map(\.name).contains("verses"))

        #expect(try await library.moduleRecord(kind: .dictionary, id: "ESVs") == nil)
        #expect(try await library.moduleRecord(kind: .translation, id: "ESV") == nil)
    }

    @Test func aBundledModuleShowsItsOwnRowAndItsSeries() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("bundled.sqlite")
        try await DatabaseQueue(path: databaseURL.path).write { db in
            try db.execute(sql: """
                CREATE TABLE translations (
                    id TEXT PRIMARY KEY, name TEXT, abbreviation TEXT, language TEXT,
                    file_path TEXT, file_hash TEXT, publisher TEXT
                );
                INSERT INTO translations VALUES ('BSB', 'Berean Standard Bible', 'BSB', 'en', 'translations/BSB.json', 'abc123', NULL);
                INSERT INTO translations VALUES ('KJV', 'King James Version', 'KJV', 'en', 'translations/KJV.json', 'def456', NULL);
                CREATE TABLE modules (
                    id TEXT PRIMARY KEY, type TEXT, name TEXT, author TEXT, version TEXT,
                    file_path TEXT, file_hash TEXT, series_abbrev TEXT, series_id TEXT
                );
                INSERT INTO modules VALUES ('tske', 'commentary', 'Treasury of Scripture Knowledge', NULL, '1', 'tske.json', 'fff', 'TSK', 'tsk');
                INSERT INTO modules VALUES ('bdb', 'dictionary', 'Brown-Driver-Briggs', NULL, '2', 'bdb.json', 'bbb', NULL, NULL);
                INSERT INTO modules VALUES ('BSB', 'devotional', 'A devotional sharing an ID', NULL, '1', 'd.json', 'ddd', NULL, NULL);
                CREATE TABLE lexicons (id TEXT PRIMARY KEY, name TEXT, language TEXT, key_type TEXT);
                INSERT INTO lexicons VALUES ('bdb', 'Brown-Driver-Briggs', 'he', 'bdb');
                CREATE TABLE commentary_series (id TEXT PRIMARY KEY, name TEXT, editor TEXT, website TEXT);
                INSERT INTO commentary_series VALUES ('tsk', 'Treasury', 'R. A. Torrey', NULL);
                CREATE TABLE commentary_books (id TEXT PRIMARY KEY, module_id TEXT, book_number INTEGER, year INTEGER);
                INSERT INTO commentary_books VALUES ('tske-1', 'tske', 1, 1880);
                INSERT INTO commentary_books VALUES ('tske-2', 'tske', 2, 1880);
                INSERT INTO commentary_books VALUES ('crossrefs-1', 'crossrefs', 1, NULL);
                """)
        }
        let archiveURL = root.appendingPathComponent("bundled_modules.db.zlib")
        try ((Data(contentsOf: databaseURL) as NSData).compressed(using: .zlib) as Data).write(to: archiveURL)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"), bundledModulesArchiveURL: archiveURL)

        let bsb = try #require(try await library.moduleRecord(kind: .translation, id: "BSB"))
        guard case .bundled(let database) = bsb.storage else {
            Issue.record("a bundled module is read from the bundle: \(bsb.storage)")
            return
        }
        #expect(database.byteCount ?? 0 > 0)
        #expect(bsb.tables.map(\.name) == ["translations"])
        #expect(bsb.tables[0].rows.count == 1)
        #expect(bsb.value(of: "file_hash") == .text("abc123"))
        #expect(bsb.value(of: "file_path") == .text("translations/BSB.json"))
        #expect(bsb.value(of: "publisher") == .null)

        let tske = try #require(try await library.moduleRecord(kind: .commentary, id: "tske"))
        #expect(tske.tables.map(\.name) == ["modules", "commentary_series", "commentary_books"])
        #expect(tske.tables.last?.rows.count == 2)
        #expect(tske.value(of: "year") == .integer(1880))
        #expect(tske.value(of: "editor") == .text("R. A. Torrey"))
        #expect(tske.value(of: "author") == .null)
        #expect(tske.value(of: "isbn") == nil)

        // A kind's own row in the shared registry, never another kind's
        // under the same ID.
        let bdb = try #require(try await library.moduleRecord(kind: .dictionary, id: "bdb"))
        #expect(bdb.tables.map(\.name) == ["lexicons", "modules"])
        #expect(bdb.value(of: "key_type") == .text("bdb"))
        #expect(bsb.tables.allSatisfy { $0.name != "modules" })
    }

    /// The phone keeps every installed module in one database in the
    /// bundle's layout, with no library around it: the same read, called on
    /// its database, and a layout missing a column skips what needs it.
    @Test func aSharedDatabaseIsReadByTheSameRules() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE modules (id TEXT PRIMARY KEY, type TEXT, name TEXT, author TEXT);
                INSERT INTO modules VALUES ('my-highlights', 'highlights', 'My highlights', NULL);
                INSERT INTO modules VALUES ('nic', 'commentary', 'NIC', 'Various');
                CREATE TABLE highlight_sets (id TEXT PRIMARY KEY, module_id TEXT, name TEXT, translation_id TEXT);
                INSERT INTO highlight_sets VALUES ('s1', 'my-highlights', 'Study', 'BSBs');
                INSERT INTO highlight_sets VALUES ('s2', 'other', 'Not this one', 'KJV');
                CREATE TABLE commentary_series (id TEXT PRIMARY KEY, name TEXT);
                """)
        }
        try queue.read { db in
            let highlights = try LampModuleRecord.tables(sharedLayoutIn: db, kind: .highlights, id: "my-highlights")
            #expect(highlights.map(\.name) == ["modules", "highlight_sets"])
            #expect(highlights.last?.rows.count == 1)
            // No `series_id` in this layout: the series is skipped, not an error.
            let commentary = try LampModuleRecord.tables(sharedLayoutIn: db, kind: .commentary, id: "nic")
            #expect(commentary.map(\.name) == ["modules"])
            #expect(try LampModuleRecord.tables(sharedLayoutIn: db, kind: .translation, id: "BSB").isEmpty)
        }
        // A book's file and sync columns in the registry, a translation kept
        // as a view, column names in another case, and a registry with no `id`.
        let other = try DatabaseQueue()
        try other.write { db in
            try db.execute(sql: """
                CREATE TABLE book_modules (id TEXT PRIMARY KEY, title TEXT);
                INSERT INTO book_modules VALUES ('b', 'A Book');
                CREATE TABLE modules (id TEXT, type TEXT, file_hash TEXT);
                INSERT INTO modules VALUES ('b', 'book', 'abc');
                CREATE TABLE source (ID TEXT, name TEXT);
                INSERT INTO source VALUES ('T', 'Test');
                CREATE VIEW translations AS SELECT ID, name FROM source;
                """)
        }
        try other.read { db in
            let book = try LampModuleRecord.tables(sharedLayoutIn: db, kind: .book, id: "b")
            #expect(book.map(\.name) == ["book_modules", "modules"])
            #expect(try LampModuleRecord.tables(sharedLayoutIn: db, kind: .translation, id: "T").first?.rows.count == 1)
        }
        let unkeyed = try DatabaseQueue()
        try unkeyed.write { db in
            try db.execute(sql: "CREATE TABLE modules (type TEXT, name TEXT); INSERT INTO modules VALUES ('notes', 'N');")
        }
        let notes = try unkeyed.read { db in try LampModuleRecord.tables(sharedLayoutIn: db, kind: .notes, id: "N") }
        #expect(notes.isEmpty)
    }
}
