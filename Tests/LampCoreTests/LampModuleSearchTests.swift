import Foundation
import GRDB
import Testing
@testable import LampCore

struct LampModuleSearchTests {
    private struct Unit {
        let id: String
        let module: String
        let sv: Int
        var title: String? = nil
        var text = ""
        var notes = ""
    }

    /// Commentary units in one database with a `module_id` on each, as the
    /// phone keeps every module it installs and the Mac its bundled ones.
    private func database(_ units: [Unit]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE commentary_units (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, book INTEGER NOT NULL, chapter INTEGER,
                    sv INTEGER NOT NULL, ev INTEGER, unit_type TEXT, level INTEGER, parent_id TEXT,
                    title TEXT, suffix TEXT, introduction_json TEXT, translation_json TEXT, commentary_json TEXT,
                    footnotes_json TEXT, search_text TEXT NOT NULL DEFAULT '', order_index INTEGER NOT NULL DEFAULT 0,
                    footnotes_text TEXT NOT NULL DEFAULT '');
                CREATE VIRTUAL TABLE commentary_units_fts USING fts5(
                    title, search_text, footnotes_text, content='commentary_units', content_rowid='rowid');
                """)
            for (index, unit) in units.enumerated() {
                try db.execute(sql: """
                    INSERT INTO commentary_units
                    (id, module_id, book, chapter, sv, title, commentary_json, search_text,
                     footnotes_json, footnotes_text, order_index)
                    VALUES (?, ?, 1, 1, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        unit.id, unit.module, unit.sv, unit.title,
                        unit.text.isEmpty ? nil : #"{"text":"\#(unit.text)"}"#,
                        [unit.title, unit.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                        unit.notes.isEmpty ? nil : #"[{"id":"1","content":{"text":"\#(unit.notes)"}}]"#,
                        unit.notes, index,
                    ])
            }
            try db.execute(sql: "INSERT INTO commentary_units_fts(commentary_units_fts) VALUES('rebuild')")
        }
        return queue
    }

    @Test func aDatabaseOfSeveralModulesAnswersForTheOnesAskedAbout() throws {
        let queue = try database([
            Unit(id: "x1", module: "X", sv: 1_001_001, text: "Hope in the morning."),
            Unit(id: "y1", module: "Y", sv: 1_001_002, text: "Hope at noon."),
            Unit(id: "z1", module: "Z", sv: 1_001_003, text: "Hope at night."),
        ])
        let hits = try queue.read { db in
            try LampModuleSearch.commentary(
                in: db, modules: [LampSearchedModule(id: "X", name: "Ex"), LampSearchedModule(id: "Z", name: "Zed")],
                query: LampSearchQuery("hope"), limit: 10
            )
        }
        #expect(Set(hits.map(\.id)) == ["commentary:X:x1", "commentary:Z:z1"])
        #expect(hits.first { $0.moduleID == "Z" }?.moduleName == "Zed")
        #expect(hits.allSatisfy { $0.snippet.contains("<mark>Hope</mark>") })
    }

    /// Against reading order: a unit named for the words, then one whose
    /// text holds them, then one whose notes do.
    @Test func unitsAreTakenBestFirstBeforeTheLimit() throws {
        let queue = try database([
            Unit(id: "notes", module: "X", sv: 1_001_001, text: "Waiting here.", notes: "Hope here."),
            Unit(id: "text", module: "X", sv: 1_001_002, text: "Hope here."),
            Unit(id: "title", module: "X", sv: 1_001_003, title: "Hope", text: "Waiting here."),
        ])
        func ids(_ limit: Int) throws -> [String] {
            try queue.read { db in
                try LampModuleSearch.commentary(
                    in: db, modules: [LampSearchedModule(id: "X", name: "Ex")],
                    query: LampSearchQuery("hope"), limit: limit
                )
            }.map(\.id)
        }
        #expect(try ids(1) == ["commentary:X:title"])
        #expect(try ids(3) == ["commentary:X:title", "commentary:X:text", "commentary:X:notes"])
        // The notes' unit shows its note, where the word is.
        let notes = try queue.read { db in
            try LampModuleSearch.commentary(
                in: db, modules: [LampSearchedModule(id: "X", name: "Ex")], query: LampSearchQuery("hope"), limit: 3
            )
        }.last
        #expect(notes?.snippet.contains("<mark>Hope</mark> here") == true)
    }

    @Test func theMergeRanksByWhatEachResultShowsAndKeepsOrderOtherwise() {
        func result(_ id: String, title: String) -> LampModuleSearchResult {
            LampModuleSearchResult(id: id, kind: .commentary, moduleID: "M", moduleName: "M", title: title, snippet: "of hope")
        }
        let merged = LampModuleSearch.ranked(
            [result("a", title: "Genesis 1:1"), result("b", title: "Genesis 1:2"), result("c", title: "Hope")],
            by: LampSearchQuery("hope"), limit: 2
        )
        #expect(merged.map(\.id) == ["c", "a"])
    }

    @Test func noModulesOrNoQueryFindNothing() throws {
        let queue = try database([Unit(id: "x1", module: "X", sv: 1_001_001, text: "Hope.")])
        let noModules = try queue.read { db in
            try LampModuleSearch.commentary(in: db, modules: [], query: LampSearchQuery("hope"), limit: 5)
        }
        let noQuery = try queue.read { db in
            try LampModuleSearch.commentary(
                in: db, modules: [LampSearchedModule(id: "X", name: "Ex")], query: LampSearchQuery(""), limit: 5
            )
        }
        #expect(noModules.isEmpty)
        #expect(noQuery.isEmpty)
    }
}
