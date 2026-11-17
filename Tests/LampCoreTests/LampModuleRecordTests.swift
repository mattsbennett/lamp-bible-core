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
                CREATE TABLE commentary_series (id TEXT PRIMARY KEY, name TEXT, editor TEXT, website TEXT);
                INSERT INTO commentary_series VALUES ('tsk', 'Treasury', 'R. A. Torrey', NULL);
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
        #expect(tske.tables.map(\.name) == ["modules", "commentary_series"])
        #expect(tske.value(of: "editor") == .text("R. A. Torrey"))
        #expect(tske.value(of: "author") == .null)
        #expect(tske.value(of: "isbn") == nil)
    }
}
