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
    /// kinds go in kindOrder, and a better match goes first.
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

    /// The rule both apps take Scripture by: the preferred translation where
    /// it matched, else the one with the most, ties to the earlier, with the
    /// others named. Only whether the others matched is asked of them.
    @Test func scriptureChoiceTakesThePreferredElseTheFullest() throws {
        let hits = ["AAA": [1, 2], "BBB": [1, 2, 3], "CCC": [Int](), "DDD": [7, 8, 9]]
        var asked: [String: Int] = [:]
        func verses(_ id: String, _ limit: Int) -> [Int] {
            asked[id] = limit
            return Array((hits[id] ?? []).prefix(limit))
        }
        let order = ["AAA", "BBB", "CCC", "DDD"]

        let own = try #require(LampScriptureChoice.choose(preferred: "AAA", order: order, limit: 50, verses: verses))
        #expect(own.choice == LampScriptureChoice(translationID: "AAA", alsoIn: ["BBB", "DDD"]))
        #expect(own.matches == [1, 2])
        #expect(asked == ["AAA": 50, "BBB": 1, "CCC": 1, "DDD": 1], "the others only asked whether they matched")

        // None in the preferred: the fullest, and BBB and DDD tie at three,
        // so the earlier.
        asked = [:]
        let fallback = try #require(LampScriptureChoice.choose(preferred: "CCC", order: order, limit: 50, verses: verses))
        #expect(fallback.choice == LampScriptureChoice(translationID: "BBB", alsoIn: ["AAA", "DDD"]))
        #expect(fallback.matches == [1, 2, 3])
        #expect(asked["CCC"] == 50)

        // A preferred translation not searched counts as having none.
        let absent = try #require(LampScriptureChoice.choose(preferred: "ZZZ", order: ["AAA", "DDD"], limit: 50, verses: verses))
        #expect(absent.choice == LampScriptureChoice(translationID: "DDD", alsoIn: ["AAA"]))

        // Nothing matched anywhere.
        #expect(LampScriptureChoice.choose(preferred: "AAA", order: ["CCC"], limit: 50, verses: verses) == nil)
    }

    /// Shared by kind, a page goes evenly to the kinds that matched, each
    /// kind's first in the order given, room a kind can't use going to the
    /// rest, and the kinds cut are named. Seven tied commentaries can't keep
    /// the book's one match off a page of two, as they do in a merged list.
    @Test func sharedByKindGivesEveryKindItsShareAndNamesTheCut() {
        func result(_ id: String, _ kind: LampModuleKind, _ module: String, title: String = "Genesis 1:1") -> LampModuleSearchResult {
            LampModuleSearchResult(id: id, kind: kind, moduleID: module, moduleName: module, title: title, snippet: "of hope")
        }
        let results = [
            result("a1", .commentary, "A"), result("a2", .commentary, "A"), result("a3", .commentary, "A"),
            result("b1", .commentary, "B"), result("b2", .commentary, "B"), result("b3", .commentary, "B", title: "Hope"),
            result("b4", .commentary, "B"), result("c1", .book, "C"),
        ]
        let query = LampSearchQuery("hope")
        #expect(LampModuleSearch.ranked(results, by: query, limit: 2).map(\.kind) == [.commentary, .commentary])

        let shared = LampModuleSearch.rankedByKind(results, by: query, limit: 2)
        #expect(shared.results.map(\.id) == ["b3", "c1"])
        #expect(shared.moreIn == ["commentary"])
        let roomy = LampModuleSearch.rankedByKind(results, by: query, limit: 4)
        #expect(roomy.results.map(\.id) == ["b3", "a1", "b1", "c1"])
        #expect(roomy.moreIn == ["commentary"])

        // On its own, for results with nothing to rank by: kept in the order
        // given, the kinds in kindOrder whatever order they came in, a kind
        // core doesn't know after them.
        let plain = LampModuleSearch.sharedByKind(
            ["x:book", "y:translation", "z:mine", "w:translation"], limit: 3, kind: { String($0.split(separator: ":")[1]) }
        )
        #expect(plain.results == ["y:translation", "x:book", "z:mine"])
        #expect(plain.moreIn == ["translation"])
        #expect(LampModuleSearch.sharedByKind(results, limit: 0, kind: \.kind.rawValue).results.isEmpty)
    }

    /// A page at least as long as the kinds that matched gives every kind a
    /// place, however lopsided their counts: what's left after the fewest
    /// take theirs never falls below the kinds still to come.
    @Test func aPageAsLongAsTheKindsStarvesNone() {
        let kinds = LampModuleSearch.kindOrder.map(\.rawValue)
        for counts in [[1, 1, 1, 1, 1, 1, 1, 1, 40], [40, 1, 40, 1, 40, 1, 40, 1, 40], [2, 3, 5, 7, 11, 13, 17, 19, 23]] {
            let results = zip(kinds, counts).flatMap { kind, count in (0..<count).map { "\(kind):\($0)" } }
            for limit in [kinds.count, kinds.count + 1, 20, 36] {
                let kept = LampModuleSearch.sharedByKind(results, limit: limit, kind: { String($0.split(separator: ":")[0]) })
                #expect(Set(kept.results.map { $0.split(separator: ":")[0] }).count == kinds.count, "\(counts) at \(limit)")
                #expect(kept.results.count == min(limit, results.count), "no room left unused while rows remain")
            }
        }
        // Below that, kinds are left out without a word: a page of one among
        // three kinds keeps one kind. A compact list asking fewer than the
        // kinds it may show must say so itself.
        let short = LampModuleSearch.sharedByKind(["a:1", "a:2", "b:1", "b:2", "c:1", "c:2"], limit: 1) {
            String($0.split(separator: ":")[0])
        }
        #expect(short.results.count == 1)
        #expect(short.moreIn == ["a", "b", "c"])
    }

    /// Ties between kinds go by kindOrder, whatever order an app searched
    /// them in, so the same search leads with the same kind everywhere.
    @Test func tiesBetweenKindsFollowKindOrderNotTheOrderSearched() {
        func result(_ id: String, _ kind: LampModuleKind) -> LampModuleSearchResult {
            LampModuleSearchResult(id: id, kind: kind, moduleID: "M", moduleName: "M", title: "Genesis 1:1", snippet: "of hope")
        }
        let merged = LampModuleSearch.ranked(
            [result("d", .dictionary), result("n", .notes), result("t", .translation)],
            by: LampSearchQuery("hope"), limit: 3
        )
        #expect(merged.map(\.id) == ["t", "d", "n"])
    }

    /// Both orders cover every kind once: one decides ties, one shelves.
    @Test func kindAndShelfOrdersArePinned() {
        #expect(LampModuleSearch.kindOrder == [
            .translation, .dictionary, .commentary, .book, .notes, .devotional, .plan, .quiz, .highlights,
        ])
        #expect(LampModuleSearch.shelfOrder == [
            .translation, .highlights, .notes, .devotional, .commentary, .dictionary, .book, .plan, .quiz,
        ])
        #expect(Set(LampModuleSearch.kindOrder) == Set(LampModuleSearch.shelfOrder))
        #expect(LampModuleSearch.kindOrder.count == 9)
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

    /// Found in the text as it is, across any whitespace, without
    /// single-spacing it first.
    @Test func theWordsAreFoundTogetherAcrossAnyWhitespace() {
        let query = LampSearchQuery("kingdom of god")
        let text = "Of old the prophets spoke and waited.\n\nThe kingdom\t of\n\n   God is near."
        #expect(query.phraseOffset(in: text) == 43)
        #expect(LampSearchQuery("kingdom \"of god\"").holdsPhrase("the kingdom of God."))
        #expect(!LampSearchQuery("kingdom \"of god\"").holdsPhrase("the kingdom of Godliness"), "a quoted last word ends a word")
        #expect(LampSearchQuery("lord's prayer").holdsPhrase("The Lord’s  prayer"), "either apostrophe")
        let snippet = query.markedSnippet(text, limit: 40)
        #expect(snippet.hasPrefix("…"), "cut where the words stand together: \(snippet)")
        #expect(snippet.contains("<mark>kingdom</mark> <mark>of</mark> <mark>God</mark>"), "\(snippet)")
        // Told the words aren't together, it doesn't look: the first of them.
        #expect(query.markedSnippet(text, limit: 40, findingPhrase: false).hasPrefix("<mark>Of</mark> old"))
    }

    /// A quiz's title is its question: a sentence holding every word isn't a
    /// heading named for them.
    @Test func aQuizQuestionHoldingEveryWordIsNoHeading() {
        let quiz = LampModuleSearchResult(
            id: "quiz", kind: .quiz, moduleID: "Q", moduleName: "Q",
            title: "How does Daniel outline God's kingdom purpose from creation?", subtitle: "Day 3 • Adult",
            snippet: "From creation to consummation."
        )
        // Its words marked apart, so its snippet alone doesn't rank it.
        let verse = LampModuleSearchResult(
            id: "verse", kind: .translation, moduleID: "T", moduleName: "T",
            title: "Luke 17:20", snippet: "The <mark>kingdom</mark> <mark>of</mark> <mark>God</mark> cometh",
            holdsPhrase: true
        )
        #expect(LampModuleSearch.ranked([quiz, verse], by: LampSearchQuery("kingdom of god"), limit: 2).map(\.id)
            == ["verse", "quiz"])
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

    /// Notes in a database of several modules, as the phone keeps them, with
    /// and without their index.
    private func notesDatabase(indexed: Bool) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE note_entries (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, verse_id INTEGER NOT NULL,
                    book INTEGER NOT NULL DEFAULT 1, chapter INTEGER NOT NULL DEFAULT 1, verse INTEGER NOT NULL DEFAULT 1,
                    title TEXT, content TEXT NOT NULL, search_text TEXT);
                INSERT INTO note_entries (id, module_id, verse_id, title, content, search_text) VALUES
                    ('content', 'M', 1001001, NULL, 'We wait in hope here.', 'We wait in hope here.'),
                    ('footnote', 'M', 1001002, NULL, 'Waiting here.', 'Waiting here. See Zuntz on hope.'),
                    ('title', 'M', 1001003, 'Hope', 'Waiting here.', 'Waiting here.'),
                    ('together', 'M', 1001004, 'The Kingdom of God', 'Patience.', 'Patience.'),
                    ('other', 'O', 1001001, NULL, 'Hope elsewhere.', 'Hope elsewhere.');
                """)
            if indexed {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE note_fts USING fts5(
                        title, search_text, content='note_entries', content_rowid='rowid');
                    INSERT INTO note_fts(note_fts) VALUES('rebuild');
                    """)
            }
        }
        return queue
    }

    @Test func notesAreFoundInTheirTitleTextAndFootnotes() throws {
        for indexed in [true, false] {
            let queue = try notesDatabase(indexed: indexed)
            let modules = [LampSearchedModule(id: "M", name: "My Study")]
            let (hope, zuntz, kingdom) = try queue.read { db in
                (
                    try LampModuleSearch.notes(in: db, modules: modules, query: LampSearchQuery("hope"), limit: 10),
                    try LampModuleSearch.notes(in: db, modules: modules, query: LampSearchQuery("zuntz"), limit: 10),
                    try LampModuleSearch.notes(in: db, modules: modules, query: LampSearchQuery("kingdom of god"), limit: 10)
                )
            }
            // The other module's isn't asked; a note found by its footnote
            // shows the footnote.
            #expect(Set(hope.map(\.id)) == ["notes:M:content", "notes:M:footnote", "notes:M:title"], "indexed \(indexed)")
            #expect(zuntz.map(\.id) == ["notes:M:footnote"], "indexed \(indexed)")
            #expect(zuntz.first?.snippet.contains("<mark>Zuntz</mark>") == true, "indexed \(indexed)")
            #expect(hope.first { $0.id == "notes:M:title" }?.title == "Hope")
            #expect(hope.first { $0.id == "notes:M:content" }?.title == "Genesis 1:1")
            #expect(hope.allSatisfy { $0.moduleName == "My Study" })
            // A note titled with the words holds them together.
            #expect(kingdom.map(\.id) == ["notes:M:together"], "indexed \(indexed)")
            #expect(kingdom.first?.holdsPhrase == true, "indexed \(indexed)")
            if indexed {
                #expect(hope.first?.id == "notes:M:title", "titled with the word, so first")
            } else {
                #expect(hope.map(\.id) == ["notes:M:content", "notes:M:footnote", "notes:M:title"], "verse order")
            }
            let deferred = try queue.read { db in
                let bare = try LampModuleSearch.notes(
                    in: db, modules: modules, query: LampSearchQuery("hope"), limit: 10, snippets: false
                )
                return try LampModuleSearch.noteSnippets(for: bare, in: db, query: LampSearchQuery("hope"))
            }
            #expect(deferred == hope, "indexed \(indexed)")
        }
    }

    /// Questions of the quizzes asked about, the first in reading order
    /// though not stored in it, by their words rather than their JSON.
    @Test func quizQuestionsComeInReadingOrderFromTheQuizzesAskedAbout() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE quiz_questions (
                    id INTEGER PRIMARY KEY, quiz_module_id TEXT NOT NULL, day INTEGER NOT NULL, sv INTEGER NOT NULL,
                    ev INTEGER NOT NULL, age_group TEXT NOT NULL, question_index INTEGER NOT NULL,
                    question_json TEXT NOT NULL, answer_json TEXT NOT NULL, theme TEXT);
                INSERT INTO quiz_questions (id, quiz_module_id, day, sv, ev, age_group, question_index, question_json, answer_json) VALUES
                    (1, 'Q', 2, 1001003, 1001004, 'adult', 0, '{"text":"Who walked with God?"}', '{"text":"Enoch, in hope."}'),
                    (2, 'Q', 1, 1002001, 1002003, 'adult', 0, '{"text":"What was finished?"}', '{"text":"The heavens and the earth, and hope."}'),
                    (3, 'Q', 1, 1001001, 1001002, 'child', 0, '{"text":"Who made the world?"}', '{"text":"God, our hope."}'),
                    (4, 'Q', 1, 1001001, 1001002, 'adult', 1, '{"text":"What came first?"}', '{"text":"Light, and hope with it."}'),
                    (5, 'R', 1, 1001001, 1001002, 'adult', 0, '{"text":"Another quiz"}', '{"text":"hope"}'),
                    (6, 'Q', 3, 1003001, 1003001, 'adult', 0, '{"text":"Who spoke?"}', '{"text":"The serpent."}');
                """)
        }
        let quiz = [LampSearchedModule(id: "Q", name: "Daily Quiz")]
        let (all, first, field) = try queue.read { db in
            (
                try LampModuleSearch.quizzes(in: db, modules: quiz, query: LampSearchQuery("hope"), limit: 10),
                try LampModuleSearch.quizzes(in: db, modules: quiz, query: LampSearchQuery("hope"), limit: 2),
                try LampModuleSearch.quizzes(in: db, modules: quiz, query: LampSearchQuery("text"), limit: 10)
            )
        }
        #expect(all.map(\.id) == ["quiz:Q:4", "quiz:Q:3", "quiz:Q:2", "quiz:Q:1"], "day, passage, age group, place")
        #expect(first.map(\.id) == ["quiz:Q:4", "quiz:Q:3"], "the first in reading order, not in the table")
        #expect(all.first?.title == "What came first?")
        #expect(all.first?.subtitle == "Day 1 • adult")
        #expect(all.first?.snippet == "Light, and <mark>hope</mark> with it.")
        #expect(all.first?.startReference == 1_001_001)
        #expect(all.first?.endReference == 1_001_002)
        #expect(all.first?.moduleName == "Daily Quiz")
        #expect(field.isEmpty, "a JSON field's name isn't a word in it")
    }

    @Test func plansAreFoundByTheirWordsInTheOrderGiven() {
        let plans = [
            LampSearchedPlan(id: "b", name: "Bible in a Year", description: "Every book in hope", author: "Someone", duration: 365),
            LampSearchedPlan(id: "a", name: "Psalms of Hope", duration: 30),
            LampSearchedPlan(id: "c", name: "Gospels", description: "The four accounts"),
        ]
        let found = LampModuleSearch.plans(plans, query: LampSearchQuery("hope"), limit: 10)
        #expect(found.map(\.id) == ["plan:b", "plan:a"])
        #expect(found[0].subtitle == "Someone")
        #expect(found[0].snippet == "Every book in <mark>hope</mark>")
        #expect(found[1].snippet == "30 days", "no description: its length")
        #expect(LampModuleSearch.plans(plans, query: LampSearchQuery("someone"), limit: 10).map(\.id) == ["plan:b"])
        #expect(LampModuleSearch.plans(plans, query: LampSearchQuery("hope"), limit: 1).map(\.id) == ["plan:b"])
    }

    private struct Writing {
        let id: String
        var module = "D"
        let title: String
        var subtitle: String? = nil
        let date: String
        let tags: String
        let category: String
        var summary: String? = nil
        let content: String
        var series: String? = nil
        var order: Int? = nil
        var searchText: String { [title, subtitle, summary, content].compactMap { $0 }.joined(separator: " ") }
    }

    private static let writings = [
        Writing(id: "kingdom", title: "The Kingdom of God", date: "2026-01-01", tags: "Holy Spirit,Prayer",
                category: "Reflection", content: "Seek it first."),
        Writing(id: "etude", title: "A Study", date: "2026-12-31", tags: "étude", category: "Étude",
                content: "The kingdom is near, and of all this God is the author."),
        Writing(id: "morning", title: "Morning", date: "2025-12-31", tags: "prayer", category: "reflection",
                summary: "Hope in the morning.", content: "Waiting for the kingdom."),
        Writing(id: "series2", title: "Second", date: "2026-03-01", tags: "series", category: "Study",
                content: "A kingdom of priests.", series: "Exodus", order: 2),
        Writing(id: "series1", title: "First", date: "2026-03-02", tags: "series", category: "Study",
                content: "Out of Egypt.", series: "Exodus", order: 1),
        Writing(id: "other", module: "E", title: "Kingdom elsewhere", date: "2026-01-01", tags: "Prayer",
                category: "Reflection", content: "The kingdom of God."),
    ]

    /// Writings in a database of several modules, as the phone keeps them:
    /// with its index, keyed by id; an index over the table, keyed by rowid;
    /// or none, as a module's file has.
    private func devotionalsDatabase(index: String?) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE devotional_entries (
                    id TEXT PRIMARY KEY, module_id TEXT NOT NULL, title TEXT NOT NULL, subtitle TEXT, author TEXT,
                    date TEXT, tags TEXT, category TEXT, series_name TEXT, series_order INTEGER,
                    key_scriptures_json TEXT, summary_json TEXT, content_json TEXT NOT NULL, search_text TEXT);
                """)
            for writing in Self.writings {
                let content = try String(decoding: JSONSerialization.data(withJSONObject: [
                    ["type": "paragraph", "content": ["text": writing.content]],
                ]), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO devotional_entries
                    (id, module_id, title, subtitle, date, tags, category, series_name, series_order,
                     summary_json, content_json, search_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        writing.id, writing.module, writing.title, writing.subtitle, writing.date, writing.tags,
                        writing.category, writing.series, writing.order,
                        writing.summary.map { #"{"text":"\#($0)"}"# }, content, writing.searchText,
                    ])
            }
            switch index {
            case "phone":
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE devotional_entries_fts USING fts5(id UNINDEXED, title, search_text);
                    INSERT INTO devotional_entries_fts(id, title, search_text) SELECT id, title, search_text FROM devotional_entries;
                    """)
            case "content":
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE devotional_entries_fts USING fts5(
                        title, search_text, content='devotional_entries', content_rowid='rowid');
                    INSERT INTO devotional_entries_fts(devotional_entries_fts) VALUES('rebuild');
                    """)
            default: break
            }
        }
        return queue
    }

    /// Whatever the index, a search by date, tags or kind keeps exactly the
    /// writings the facets' own Swift test keeps, case and accents as it folds
    /// them, at either end of a year, with words or without.
    @Test func devotionalFacetsKeepWhatTheirOwnTestKeeps() throws {
        let criteria: [LampDevotionalSearchCriteria] = [
            .init(date: "2026-01-01"), .init(monthDay: "12-31"), .init(monthDay: "01-01"),
            .init(tags: ["holy spirit"]), .init(tags: ["Prayer"]), .init(tags: ["ÉTUDE"]), .init(tags: ["etude"]),
            .init(categories: ["reflection"]), .init(categories: ["REFLECTION"]),
            .init(categories: ["etude"]), .init(categories: ["étude"]),
            .init(monthDay: "12-31", categories: ["Étude"]),
        ]
        let modules = [LampSearchedModule(id: "D", name: "My Writing")]
        for index in [nil, "phone", "content"] as [String?] {
            let queue = try devotionalsDatabase(index: index)
            for facets in criteria {
                for text in ["", "kingdom"] {
                    let query = LampSearchQuery(text)
                    let found = try queue.read { db in
                        try LampModuleSearch.devotionals(in: db, modules: modules, query: query, criteria: facets, limit: 50)
                    }
                    let expected = Self.writings.filter { writing in
                        writing.module == "D"
                            && facets.matches(
                                date: writing.date,
                                tags: writing.tags.split(separator: ",").map(String.init),
                                category: writing.category
                            )
                            && (text.isEmpty || query.matches(writing.searchText + " " + writing.tags))
                    }.map { "devotional:D:\($0.id)" }
                    #expect(Set(found.map(\.id)) == Set(expected), "index \(index ?? "none"), \(facets), \"\(text)\"")
                }
            }
        }
    }

    @Test func devotionalsComeBestFirstOrInTheirSeriesOrder() throws {
        let modules = [LampSearchedModule(id: "D", name: "My Writing")]
        // A search by facets alone, or without an index: series, place, date,
        // title.
        let bare = try devotionalsDatabase(index: nil)
        let series = try bare.read { db in
            try LampModuleSearch.devotionals(
                in: db, modules: modules, query: LampSearchQuery(""), criteria: .init(tags: ["series"]), limit: 10
            )
        }
        #expect(series.map(\.id) == ["devotional:D:series1", "devotional:D:series2"])
        #expect(series.first?.snippet == "Out of Egypt.", "no words asked for: its opening")

        for index in ["phone", "content"] {
            let queue = try devotionalsDatabase(index: index)
            let (kingdom, hope) = try queue.read { db in
                (
                    try LampModuleSearch.devotionals(in: db, modules: modules, query: LampSearchQuery("kingdom of god"), limit: 10),
                    try LampModuleSearch.devotionals(in: db, modules: modules, query: LampSearchQuery("hope"), limit: 10)
                )
            }
            #expect(kingdom.first?.id == "devotional:D:kingdom", "titled with the words: \(index)")
            #expect(kingdom.first(where: { $0.holdsPhrase })?.id == "devotional:D:kingdom", "\(index)")
            #expect(kingdom.filter(\.holdsPhrase).count == 1, "the study's words stand apart: \(index)")
            #expect(hope.map(\.id) == ["devotional:D:morning"], "\(index)")
            #expect(hope.first?.snippet == "<mark>Hope</mark> in the morning.", "its summary holds the word: \(index)")
            let deferred = try queue.read { db in
                let bare = try LampModuleSearch.devotionals(
                    in: db, modules: modules, query: LampSearchQuery("kingdom of god"), limit: 10, snippets: false
                )
                return try LampModuleSearch.devotionalSnippets(for: bare, in: db, query: LampSearchQuery("kingdom of god"))
            }
            #expect(deferred == kingdom, "\(index)")
        }
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

    // MARK: - Verses

    /// The phone's and the bundle's shape: several translations in one
    /// table, each ranked within itself and kept to the limit, so that one
    /// using the words more often can't crowd out another.
    private func translations(indexed: Bool, listed: Bool = false) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_verses (
                    id INTEGER PRIMARY KEY, translation_id TEXT NOT NULL, ref INTEGER NOT NULL,
                    book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL, text TEXT NOT NULL);
                CREATE TABLE translation_books (translation_id TEXT NOT NULL, book_number INTEGER NOT NULL, name TEXT NOT NULL);
                INSERT INTO translation_books VALUES ('A', 43, 'John'), ('B', 43, 'Jean');
                """)
            let verses: [(String, Int, String)] = [
                ("A", 43_001_001, "Faith, faith and faith again."),
                ("A", 43_001_002, "By faith we stand."),
                ("A", 43_001_003, "Unfaithful servants."),
                ("A", 43_001_004, "Hope endures."),
                ("B", 43_001_001, "Faith comes by hearing."),
                ("B", 43_001_002, "The faithful one."),
            ]
            for (index, verse) in verses.enumerated() {
                try db.execute(sql: "INSERT INTO translation_verses VALUES (?, ?, ?, 43, 1, ?, ?)", arguments: [
                    index + 1, verse.0, verse.1, verse.1 % 1_000, verse.2,
                ])
            }
            if indexed {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE translation_verses_fts USING fts5(text, content='translation_verses', content_rowid='id');
                    INSERT INTO translation_verses_fts(translation_verses_fts) VALUES('rebuild');
                    """)
                if listed { try LampSearchWords.rebuildAll(in: db) }
            }
        }
        return queue
    }

    @Test func eachTranslationKeepsItsOwnBestVerses() throws {
        for (indexed, listed) in [(true, true), (true, false), (false, false)] {
            let queue = try translations(indexed: indexed, listed: listed)
            let hits = try queue.read { db in
                try LampModuleSearch.verses(in: db, translations: nil, query: LampSearchQuery("faith"), limit: 1)
            }
            #expect(Set(hits.map(\.translationID)) == ["A", "B"], "each heard from")
            #expect(hits.count == 2)
            if indexed { #expect(hits.first { $0.translationID == "A" }?.reference == 43_001_001, "its best ranked") }
            #expect(hits.first { $0.translationID == "B" }?.bookName == "Jean", "named as it names the book")

            let within = try queue.read { db in
                try LampModuleSearch.verses(in: db, translations: ["A"], query: LampSearchQuery("*faith"), limit: 10)
            }
            #expect(within.map(\.reference).sorted() == [43_001_001, 43_001_002, 43_001_003], "listed \(listed), indexed \(indexed)")
            let plain = try queue.read { db in
                try LampModuleSearch.verses(in: db, translations: ["A"], query: LampSearchQuery("faith"), limit: 10)
            }
            #expect(plain.map(\.reference).sorted() == [43_001_001, 43_001_002], "a typed word starts one")
            let together = try queue.read { db in
                try LampModuleSearch.verses(in: db, translations: ["B"], query: LampSearchQuery("faith comes"), limit: 10)
            }
            #expect(together.map(\.holdsPhrase) == [true])
        }
    }

    /// A range of books is searched through the index first. With an index
    /// on the books, SQLite took the verses in range first and asked the
    /// index about each in turn, reading every match of the query again for
    /// each verse: minutes on the phone for "the" in the New Testament.
    @Test func aRangeOfBooksIsSearchedThroughTheIndexFirst() throws {
        let queue = try translations(indexed: true)
        try queue.write { db in
            try db.execute(sql: "CREATE INDEX verses_by_book ON translation_verses(translation_id, book, chapter)")
        }
        final class Searched: @unchecked Sendable { var sql: String? }
        let searched = Searched()
        let plan = try queue.writeWithoutTransaction { db -> [String] in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event, statement.sql.contains("bm25") {
                    searched.sql = statement.expandedSQL
                }
            }
            let hits = try LampModuleSearch.verses(
                in: db, translations: ["A"], query: LampSearchQuery("faith"), bookRange: 40...66, limit: 10
            )
            db.trace(options: .statement, nil)
            #expect(hits.map(\.reference).sorted() == [43_001_001, 43_001_002])
            let sql = try #require(searched.sql)
            return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        }
        let first = plan.first { $0.hasPrefix("SCAN") || $0.hasPrefix("SEARCH") }
        #expect(first?.contains("translation_verses_fts") == true, "\(plan)")
    }

    /// A shared database's words are read apart from the write that keeps
    /// them, and kept only if the index is still as they were read from.
    @Test func wordsReadFromAnIndexWrittenSinceAreNotKept() throws {
        let queue = try translations(indexed: true)
        let vocabulary = try #require(try queue.writeWithoutTransaction { db in
            try LampSearchWords.vocabulary(of: "translation_verses_fts", in: db)
        })
        try queue.write { db in
            try db.execute(sql: "INSERT INTO translation_verses VALUES (7, 'A', 43001005, 43, 1, 5, 'Steadfast.')")
            try db.execute(sql: "INSERT INTO translation_verses_fts(rowid, text) VALUES (7, 'Steadfast.')")
        }
        #expect(try queue.write { try LampSearchWords.write(vocabulary, in: $0) } == false)
        #expect(try queue.read { try LampSearchWords.isCurrent(index: "translation_verses_fts", in: $0) } == false)
        let fresh = try #require(try queue.writeWithoutTransaction { db in
            try LampSearchWords.vocabulary(of: "translation_verses_fts", in: db)
        })
        #expect(try queue.write { try LampSearchWords.write(fresh, in: $0) })
        let words = try queue.read { db in
            try LampSearchWords.words(holding: "stead", index: "translation_verses_fts", in: db)
        }
        #expect(words == ["steadfast"])
        #expect(try queue.writeWithoutTransaction { try LampSearchWords.vocabulary(of: "no_such_fts", in: $0) } == nil)
    }

    // MARK: - Highlights

    /// Each set's highlights newest first, of the colours, books and words
    /// asked for, the room shared and the sets taking turns.
    @Test func highlightsAreTakenNewestFirstEachSetInTurn() throws {
        func highlight(_ id: Int64, _ set: String, _ reference: Int, _ color: String = "FFFF00") -> LampVerseHighlight {
            LampVerseHighlight(id: id, setID: set, translationID: "KJV", reference: reference,
                               startOffset: 0, endOffset: 3, style: .highlight, color: color)
        }
        let sets: [(id: String, highlights: [LampVerseHighlight])] = [
            ("mine", [highlight(1, "mine", 40_001_001), highlight(4, "mine", 40_001_002), highlight(5, "mine", 40_001_003),
                      highlight(6, "mine", 1_001_001), highlight(7, "mine", 40_001_004, "#00ff00")]),
            ("module", [highlight(2, "inner", 40_001_005)]),
        ]
        let texts: [Int: String] = [
            40_001_001: "Faith first.", 40_001_002: "Faith works.", 40_001_003: "Hope.",
            1_001_001: "In the beginning, faith.", 40_001_004: "Faith in green.", 40_001_005: "Faith works by love.",
        ]
        var asked: [Set<Int>] = []
        func search(_ query: String?, _ colors: Set<String>? = nil, limit: Int = 10) -> [String] {
            LampModuleSearch.highlights(
                in: sets, query: query.map(LampSearchQuery.init), colors: colors, bookRange: 40...40, limit: limit
            ) { _, references in
                asked.append(references)
                return texts.filter { references.contains($0.key) }
            }.map { "\($0.setID):\($0.highlight.id)" }
        }
        #expect(search(nil, ["ffff00"]) == ["mine:5", "module:2", "mine:4", "mine:1"], "newest first, in turn")
        #expect(!asked.joined().contains(1_001_001), "a book not asked for isn't read")
        #expect(search("faith", ["FFFF00"]) == ["mine:4", "module:2", "mine:1"])
        #expect(search("faith works") == ["mine:4", "module:2"])
        #expect(search(nil, limit: 2) == ["mine:7", "module:2"], "each set heard from")
        let together = LampModuleSearch.highlights(
            in: sets, query: LampSearchQuery("faith works"), colors: nil, bookRange: nil, limit: 10
        ) { _, references in texts.filter { references.contains($0.key) } }
        #expect(together.count == 2 && together.allSatisfy { $0.holdsPhrase })
    }
}
