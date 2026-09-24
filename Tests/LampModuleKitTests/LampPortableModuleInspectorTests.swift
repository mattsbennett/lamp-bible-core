import Foundation
import GRDB
import Testing
@testable import LampModuleKit

struct LampPortableModuleInspectorTests {
    @Test func archivePreflightChecksEveryModuleKind() throws {
        let missing: [(LampModuleKind, String)] = [
            (.translation, "translation_meta"),
            (.dictionary, "dictionary_entries"),
            (.commentary, "commentary_books"),
            (.book, "book_modules"),
            (.devotional, "devotional_entries"),
            (.notes, "note_entries"),
            (.plan, "plans"),
            (.highlights, "highlight_sets"),
            (.quiz, "quiz_modules")
        ]
        for (kind, table) in missing {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES ('selected', ?)",
                    arguments: [kind.rawValue]
                )
            }
            let body = try Data(contentsOf: url)
            #expect(try LampPortableModuleInspector.inspect(databaseData: body).kind == kind)
            #expect(throws: LampPortableModuleInspector.InspectionError.missingImportSchema(table)) {
                try LampPortableModuleInspector.inspect(
                    databaseData: body, requireImportSchema: true
                )
            }
        }
    }

    @Test func dictionaryPreflightChecksCopiedColumns() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('selected', 'dictionary')")
            try db.execute(sql: """
                CREATE TABLE dictionary_entries (
                    id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                    transliteration TEXT, pronunciation TEXT, senses_json TEXT
                )
                """)
        }
        let body = try Data(contentsOf: url)
        #expect(throws: LampPortableModuleInspector.InspectionError.missingImportSchema("dictionary_entries")) {
            try LampPortableModuleInspector.inspect(
                databaseData: body, requireImportSchema: true
            )
        }
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE dictionary_entries ADD COLUMN metadata_json TEXT")
        }
        #expect(try LampPortableModuleInspector.inspect(
            databaseData: Data(contentsOf: url), requireImportSchema: true
        ).kind == .dictionary)
    }

    @Test func highlightSetIDIsSeparateFromModuleIdentity() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('highlight-module', 'highlights')")
            try db.execute(sql: "CREATE TABLE highlight_meta (id TEXT, name TEXT, translation_id TEXT)")
            try db.execute(sql: "INSERT INTO highlight_meta VALUES ('set-uuid', 'Set', 'ESV')")
            try db.execute(sql: "CREATE TABLE highlights (ref INTEGER, sc INTEGER, ec INTEGER, style INTEGER, color TEXT)")
        }
        let data = try Data(contentsOf: url)
        #expect(try LampPortableModuleInspector.inspect(
            databaseData: data, requireImportSchema: true
        ) == LampPortableModuleDescriptor(id: "highlight-module", kind: .highlights))
        try queue.write { db in
            try db.execute(sql: "DROP TABLE module_format")
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.missingIdentity) {
            try LampPortableModuleInspector.inspect(databaseData: Data(contentsOf: url))
        }
        let legacyArchive = try (Data(contentsOf: url) as NSData)
            .compressed(using: .zlib) as Data
        #expect(try LampPortableModuleInspector.inspectRemote(
            data: legacyArchive, filename: "highlight-module.lamp",
            fallbackID: "highlight-module", expectedKind: .highlights
        ).id == "highlight-module")
        #expect(throws: LampPortableModuleInspector.InspectionError.missingIdentity) {
            try LampPortableModuleInspector.inspectRemote(
                data: legacyArchive, filename: "highlight-module.lamp",
                fallbackID: "highlight-module", expectedKind: .notes
            )
        }
        try LampPortableModuleInspector.validateOwnership(
            databaseURL: url, expectedID: "highlight-module", kind: .highlights
        )
    }

    @Test func remoteInspectionRejectsWrongKindAndDamagedBody() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('selected', 'notes')")
        }
        let archive = try (Data(contentsOf: url) as NSData).compressed(using: .zlib) as Data
        #expect(throws: LampPortableModuleInspector.InspectionError.wrongKind(
            expected: .highlights, actual: .notes
        )) {
            try LampPortableModuleInspector.inspectRemote(
                data: archive, filename: "selected.lamp",
                fallbackID: "selected", expectedKind: .highlights
            )
        }
        try queue.write { db in
            try db.execute(sql: "DROP TABLE module_format")
            try db.execute(sql: "CREATE TABLE note_entries (id TEXT)")
        }
        let headerlessNote = try (Data(contentsOf: url) as NSData).compressed(using: .zlib) as Data
        #expect(throws: LampPortableModuleInspector.InspectionError.missingImportSchema("highlight_sets")) {
            try LampPortableModuleInspector.inspectRemote(
                data: headerlessNote, filename: "selected.lamp",
                fallbackID: "selected", expectedKind: .highlights
            )
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.invalidArchive) {
            try LampPortableModuleInspector.inspectRemote(
                data: Data("broken".utf8), filename: "selected.lamp",
                fallbackID: "selected", expectedKind: .highlights
            )
        }
    }

    @Test func fullLegacyHighlightsUseModuleMetadataIdentity() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_meta (id TEXT)")
            try db.execute(sql: "INSERT INTO module_meta VALUES ('highlight-module')")
            try db.execute(sql: "CREATE TABLE highlight_sets (id TEXT, module_id TEXT)")
            try db.execute(sql: "INSERT INTO highlight_sets VALUES ('set-uuid', 'highlight-module')")
            try db.execute(sql: "CREATE TABLE highlights (set_id TEXT)")
            try db.execute(sql: "INSERT INTO highlights VALUES ('set-uuid')")
        }
        #expect(try LampPortableModuleInspector.inspect(databaseData: Data(contentsOf: url))
            == LampPortableModuleDescriptor(id: "highlight-module", kind: .highlights))
        try queue.write { db in
            try db.execute(sql: "UPDATE module_meta SET id = 'foreign'")
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.foreignRows("highlight_sets")) {
            try LampPortableModuleInspector.inspect(databaseData: Data(contentsOf: url))
        }
    }


    @Test func rejectsBookWithMissingCopiedParentColumns() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE book_modules (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO book_modules VALUES ('book')")
        }
        let body = try Data(contentsOf: url)
        #expect(try LampPortableModuleInspector.inspect(databaseData: body).id == "book")
        #expect(throws: LampPortableModuleInspector.InspectionError.missingImportSchema("book_modules")) {
            try LampPortableModuleInspector.inspect(
                databaseData: body, requireImportSchema: true
            )
        }
    }

    @Test func rejectsBookWithoutSectionsTable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let columns = LampPortableModuleInspector.bookModuleColumns
            .map { "\($0) TEXT" }.joined(separator: ", ")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE book_modules (\(columns))")
            try db.execute(sql: "INSERT INTO book_modules (id) VALUES ('book')")
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.missingImportSchema("book_sections")) {
            try LampPortableModuleInspector.inspect(
                databaseData: Data(contentsOf: url), requireImportSchema: true
            )
        }
    }

    @Test func readsIdentityFromPayloadInsteadOfArchiveFilename() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format (module_id, module_type) VALUES (?, ?)",
                arguments: ["real-module-id", "dictionary"]
            )
        }
        let data = try Data(contentsOf: databaseURL)
        #expect(try LampPortableModuleInspector.inspect(databaseData: data).id == "real-module-id")
        let archive = try (data as NSData).compressed(using: .zlib) as Data
        let descriptor = try LampPortableModuleInspector.inspect(compressedData: archive)
        #expect(descriptor.id == "real-module-id")
        #expect(descriptor.kind == .dictionary)
    }

    @Test func rejectsDamagedModule() {
        #expect(throws: LampPortableModuleInspector.InspectionError.self) {
            try LampPortableModuleInspector.inspect(compressedData: Data("broken".utf8))
        }
    }

    @Test func rejectsForeignDictionaryRowDespiteMatchingHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('selected', 'dictionary')")
            try db.execute(sql: "CREATE TABLE dictionary_entries (id TEXT, module_id TEXT)")
            try db.execute(sql: "INSERT INTO dictionary_entries VALUES ('foreign:key', 'foreign')")
        }
        let body = try Data(contentsOf: url)
        #expect(throws: LampPortableModuleInspector.InspectionError.self) {
            try LampPortableModuleInspector.inspect(databaseData: body)
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.self) {
            try LampPortableModuleInspector.validateOwnership(
                databaseURL: url, expectedID: "selected", kind: .dictionary
            )
        }
    }

    @Test func rejectsForeignPlanDayWithoutParentRow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('selected', 'plan')")
            try db.execute(sql: "CREATE TABLE plan_days (plan_id TEXT, day INTEGER)")
            try db.execute(sql: "INSERT INTO plan_days VALUES ('foreign', 1)")
        }
        #expect(throws: LampPortableModuleInspector.InspectionError.self) {
            try LampPortableModuleInspector.inspect(databaseData: Data(contentsOf: url))
        }
    }

    @Test func acceptsCanonicalNotesAliasForOwnedRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-inspector-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('notes', 'notes')")
            try db.execute(sql: "CREATE TABLE note_entries (id TEXT, module_id TEXT)")
            try db.execute(sql: "INSERT INTO note_entries VALUES ('one', 'bible-notes')")
        }
        try LampPortableModuleInspector.validateOwnership(
            databaseURL: url, expectedID: "bible-notes", kind: .notes
        )
    }
}
