import Foundation
import GRDB
import LampModuleKit
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

    /// Equals within a kind take turns by module, each in its own order; the
    /// kinds keep the order they were found in, and a better match goes first.
    @Test func tiedResultsTakeTurnsByModuleWithinEachKind() {
        func result(_ id: String, _ kind: LampModuleKind, _ module: String, title: String = "Genesis 1:1") -> LampModuleSearchResult {
            LampModuleSearchResult(id: id, kind: kind, moduleID: module, moduleName: module, title: title, snippet: "of hope")
        }
        let merged = LampModuleSearch.ranked([
            result("a1", .commentary, "A"), result("a2", .commentary, "A"), result("a3", .commentary, "A"),
            result("b1", .commentary, "B"), result("b2", .commentary, "B"),
            result("c1", .book, "C"), result("b3", .commentary, "B", title: "Hope"),
        ], by: LampSearchQuery("hope"), limit: 10)
        #expect(merged.map(\.id) == ["b3", "a1", "b1", "a2", "b2", "a3", "c1"])
    }

    /// Sections of the books asked about, one named for the words before one
    /// whose text holds them, each keyed to its passage.
    @Test func bookSectionsAreTakenBestFirstFromTheBooksAskedAbout() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE book_sections (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT,
                    key_scriptures_json TEXT, search_text TEXT NOT NULL DEFAULT '');
                CREATE VIRTUAL TABLE book_sections_fts USING fts5(
                    title, search_text, content='book_sections', content_rowid='rowid');
                INSERT INTO book_sections (id, module_id, title, subtitle, key_scriptures_json, search_text) VALUES
                    ('x-text', 'X', 'Chapter 1', NULL, NULL, 'Waiting in hope here.'),
                    ('x-title', 'X', 'Hope', 'and patience', '[{"sv":45005005,"ev":45005006,"label":"Rom 5:5"}]', 'Waiting here.'),
                    ('y-text', 'Y', 'Chapter 1', NULL, NULL, 'Hope in another book.');
                INSERT INTO book_sections_fts(book_sections_fts) VALUES('rebuild');
                """)
        }
        let hits = try queue.read { db in
            try LampModuleSearch.books(
                in: db, modules: [LampSearchedModule(id: "X", name: "Ex")], query: LampSearchQuery("hope"), limit: 5
            )
        }
        #expect(hits.map(\.id) == ["book:X:x-title", "book:X:x-text"])
        #expect(hits.first?.subtitle == "and patience")
        #expect(hits.first?.startReference == 45_005_005)
        #expect(hits.first?.endReference == 45_005_006)
        #expect(hits.first?.moduleName == "Ex")
    }

    /// Results found without snippets and given them afterwards are the
    /// results found with them, for commentary and books alike.
    @Test func snippetsCutAfterTheMergeAreTheSnippetsCutAtOnce() throws {
        let queue = try database([
            Unit(id: "notes", module: "X", sv: 1_001_001, text: "Waiting here.", notes: "Hope here."),
            Unit(id: "text", module: "Y", sv: 1_001_002, text: "A long wait, and then hope here."),
            Unit(id: "title", module: "X", sv: 1_001_003, title: "Hope", text: "Waiting here."),
        ])
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE book_sections (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT,
                    key_scriptures_json TEXT, search_text TEXT NOT NULL DEFAULT '');
                CREATE VIRTUAL TABLE book_sections_fts USING fts5(
                    title, search_text, content='book_sections', content_rowid='rowid');
                INSERT INTO book_sections (id, module_id, title, search_text) VALUES
                    ('b1', 'B', 'One', 'They waited in hope a long while.'),
                    ('b2', 'B', 'Hope', 'Patience.');
                INSERT INTO book_sections_fts(book_sections_fts) VALUES('rebuild');
                """)
        }
        let commentaries = [LampSearchedModule(id: "X", name: "Ex"), LampSearchedModule(id: "Y", name: "Why")]
        let books = [LampSearchedModule(id: "B", name: "Bee")]
        let query = LampSearchQuery("hope")
        let (commentary, bare, filled) = try queue.read { db in
            let bare = try LampModuleSearch.commentary(in: db, modules: commentaries, query: query, limit: 5, snippets: false)
            return (
                try LampModuleSearch.commentary(in: db, modules: commentaries, query: query, limit: 5),
                bare,
                try LampModuleSearch.commentarySnippets(for: bare, in: db, query: query)
            )
        }
        #expect(commentary.count == 3)
        #expect(bare.allSatisfy { $0.snippet == LampModuleSearch.rankingSnippet(for: query) })
        #expect(filled == commentary)
        #expect(commentary.allSatisfy { $0.snippet.contains("<mark>") || $0.title == "Hope" })

        let (sections, bareSections, filledSections) = try queue.read { db in
            let bare = try LampModuleSearch.books(in: db, modules: books, query: query, limit: 5, snippets: false)
            return (
                try LampModuleSearch.books(in: db, modules: books, query: query, limit: 5),
                bare,
                try LampModuleSearch.bookSnippets(for: bare, in: db, query: query)
            )
        }
        #expect(bareSections.allSatisfy { $0.snippet == LampModuleSearch.rankingSnippet(for: query) })
        #expect(filledSections == sections)
        #expect(sections.map(\.id) == ["book:B:b2", "book:B:b1"])
    }

    /// A result found without its snippet ranks in the merge as it will
    /// with it, so that kinds whose snippets are cut at once and kinds whose
    /// snippets wait are ranked alike.
    @Test func aStandInRanksAsTheSnippetWill() throws {
        let queue = try database([
            Unit(id: "a", module: "X", sv: 1_001_001, text: "We wait in hope for the kingdom of God."),
            Unit(id: "b", module: "X", sv: 1_001_002, text: "Hope again, and the kingdom of our God."),
        ])
        for text in ["hope", "kingdom of god", "\"kingdom of\" god", "lov"] {
            let query = LampSearchQuery(text)
            let found = try queue.read { db in
                try LampModuleSearch.commentary(
                    in: db, modules: [LampSearchedModule(id: "X", name: "Ex")], query: query, limit: 5
                )
            }
            let standIn = query.textRank(in: [LampModuleSearch.rankingSnippet(for: query)])
            #expect(found.allSatisfy { query.textRank(in: [$0.snippet]) == standIn }, "\(text)")
        }
    }

    @Test func aQueryOfSeveralWordsHoldsThemTogetherOrNot() {
        let query = LampSearchQuery("kingdom of god")
        #expect(query.holdsPhrase("Seek first the Kingdom of God."))
        #expect(query.holdsPhrase("the kingdom\n of   God"), "across a line break")
        #expect(query.holdsPhrase("the kingdom of godliness"), "the last word typed, as a word's start")
        #expect(!query.holdsPhrase("a kingdom, and of God"))
        #expect(!query.holdsPhrase("the subkingdom of God"), "the first word starts a word")
        #expect(!LampSearchQuery("kingdom").holdsPhrase("kingdom"), "one word is no phrase")
        #expect(query.phraseFTS5Query == "\"kingdom of god\"*")
        #expect(LampSearchQuery("kingdom \"God\"").phraseFTS5Query == "\"kingdom God\"")
        #expect(LampSearchQuery("kingdom").phraseFTS5Query == nil)
    }

    /// A snippet stands where the words stand together, not where the first
    /// of them turns up.
    @Test func aSnippetIsCutWhereTheWordsStandTogether() {
        let text = "Of old the prophets spoke. " + String(repeating: "They waited long. ", count: 40)
            + "Then the kingdom of God came near."
        let snippet = LampSearchQuery("kingdom of god").markedSnippet(text, limit: 120)
        #expect(snippet.contains("<mark>kingdom</mark> <mark>of</mark> <mark>God</mark>"), "\(snippet)")
        #expect(!snippet.contains("Of old"))
        // One word: as before, its first place.
        #expect(LampSearchQuery("prophets").markedSnippet(text, limit: 120).hasPrefix("Of old the <mark>prophets</mark>"))
    }

    @Test func theMergeRanksNamesThenWordsTogether() {
        func result(_ id: String, title: String, together: Bool = false) -> LampModuleSearchResult {
            LampModuleSearchResult(
                id: id, kind: .book, moduleID: id, moduleName: id, title: title, snippet: "",
                holdsPhrase: together
            )
        }
        let merged = LampModuleSearch.ranked([
            result("queen", title: "The Queen of Sheba"),
            result("chapter", title: "Chapter 3", together: true),
            result("daniel", title: "Kingdoms and the God of Daniel"),
            result("kingdom", title: "The Kingdom of God", together: true),
        ], by: LampSearchQuery("kingdom of god"), limit: 10)
        #expect(merged.map(\.id) == ["kingdom", "daniel", "chapter", "queen"])
    }

    /// The index tells a unit or section holding the words together from one
    /// with them apart, and the merge puts it first.
    @Test func theIndexFindsTheWordsTogether() throws {
        let queue = try database([
            Unit(id: "apart", module: "X", sv: 1_001_001, text: "The kingdom is near, and of all things God knows."),
            Unit(id: "together", module: "X", sv: 1_001_002, text: "Seek the kingdom of God."),
        ])
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE book_sections (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT,
                    key_scriptures_json TEXT, search_text TEXT NOT NULL DEFAULT '');
                CREATE VIRTUAL TABLE book_sections_fts USING fts5(
                    title, search_text, content='book_sections', content_rowid='rowid');
                INSERT INTO book_sections (id, module_id, title, search_text) VALUES
                    ('apart', 'B', 'One', 'A kingdom stood, and of its kings God took no note.'),
                    ('together', 'B', 'Two', 'The kingdom of God is like a seed.');
                INSERT INTO book_sections_fts(book_sections_fts) VALUES('rebuild');
                """)
        }
        let query = LampSearchQuery("kingdom of god")
        let (units, sections) = try queue.read { db in
            (
                try LampModuleSearch.commentary(
                    in: db, modules: [LampSearchedModule(id: "X", name: "Ex")], query: query, limit: 5, snippets: false
                ),
                try LampModuleSearch.books(
                    in: db, modules: [LampSearchedModule(id: "B", name: "Bee")], query: query, limit: 5, snippets: false
                )
            )
        }
        #expect(Set(units.filter(\.holdsPhrase).map(\.id)) == ["commentary:X:together"])
        #expect(Set(sections.filter(\.holdsPhrase).map(\.id)) == ["book:B:together"])
        #expect(LampModuleSearch.ranked(units + sections, by: query, limit: 2).map(\.id)
            == ["commentary:X:together", "book:B:together"])
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
