import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

struct LampLibrarySearchPerformanceTests {
    @Test func longRepeatedWordsOnlyProduceABoundedMarkedWindow() {
        let text = String(repeating: "God gives hope. ", count: 20_000)
        let snippet = LampSearchQuery("God hope").markedSnippet(text, limit: 120)
        #expect(snippet.hasPrefix("<mark>God</mark>"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count < 480)
        #expect(snippet.components(separatedBy: "<mark>").count < 20)
        #expect(LampSearchQuery("God").markedSnippet(text, limit: 0).isEmpty)
        #expect(LampSearchQuery("God").markedSnippet(text, limit: -1).isEmpty)
    }

    @Test func aLateUnicodeOrMultilinePhraseStillAnchorsTheWindow() {
        let prefix = String(repeating: "שָׁלוֹם 👩🏽‍💻 filler ", count: 2_000)
        let text = prefix + "living\n\twater brings hope " + String(repeating: "tail ", count: 100)
        let snippet = LampSearchQuery("\"living water\"").markedSnippet(text, limit: 100)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("<mark>living water</mark>"))
        #expect(snippet.hasSuffix("…"))
        #expect(LampSearchQuery("λογος").markedSnippet(prefix + "λόγος").contains("<mark>λόγος</mark>"))
        #expect(LampSearchQuery("holy \"Holy Spirit\"").markedSnippet("Holy Spirit gives hope")
            == "<mark>Holy Spirit</mark> gives hope")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-search-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func install(_ json: String, id: String, in root: URL, library: LampLibrary) async throws -> URL {
        let archive = root.appendingPathComponent(id + ".lamp")
        _ = try LampModuleCompiler().compile(data: Data(json.utf8), sourceFilename: id + ".json", destinationURL: archive)
        _ = try await library.install(from: archive)
        let files = try FileManager.default.contentsOfDirectory(at: library.rootURL.appendingPathComponent("Databases"), includingPropertiesForKeys: nil)
        return try #require(files.first { $0.pathExtension == "sqlite" })
    }

    @Test func booksUseTheSearchProjectionAndKeepPrefixPhraseAndLimitSemanticsWithoutFTS() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let database = try await install(#"""
            {"meta":{"schemaVersion":"1.0","id":"B","type":"book","title":"Book","language":"en"},
             "sections":[
               {"id":"infix","type":"chapter","title":"First","content":[{"type":"paragraph","content":{"text":"The beloved keeps faith without works."}}]},
               {"id":"prefix","type":"chapter","title":"Second","content":[{"type":"paragraph","content":{"text":"Love joins faith and works."}}]},
               {"id":"phrase","type":"chapter","title":"Third","content":[{"type":"paragraph","content":{"text":"Loving action: faith works through love."}}]}
             ]}
            """#, id: "B", in: root, library: library)
        let queue = try DatabaseQueue(path: database.path)
        // Searching must not decode a chapter when its text projection exists.
        try await queue.write { db in
            try db.execute(sql: "UPDATE book_sections SET content_json = 'not JSON; do not decode this preview'")
        }
        for indexed in [true, false] {
            if !indexed { try await queue.write { try $0.execute(sql: "DROP TABLE book_sections_fts") } }
            // "beloved" holds "lov" but starts no word with it. With the index
            // the section using the word most is taken first; without it,
            // the first in reading order.
            let prefix = try await library.searchModules(query: "lov", kinds: [.book], limit: 1)
            #expect(prefix.map(\.title) == [indexed ? "Third" : "Second"])
            #expect(prefix.first?.snippet.contains(indexed ? "<mark>Lov</mark>ing" : "<mark>Lov</mark>e") == true)
            #expect(try await library.searchModules(query: "\"faith works\"", kinds: [.book]).map(\.title) == ["Third"])
            #expect(try await library.searchModules(query: "faith works", kinds: [.book]).count == 3)
            #expect(try await library.searchModules(query: "neverpresent", kinds: [.book]).isEmpty)
        }
    }

    /// Each commentary is asked for the whole limit before the merge cuts it,
    /// so the first by name can't take every place: the second's unit named
    /// for the word comes first, though there is room for one result.
    @Test func eachCommentaryIsAskedForTheWholeLimitBeforeTheMerge() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await install(#"""
            {"meta":{"schemaVersion":"2.1","id":"A","title":"A Commentary","seriesAbbrev":"A","seriesFull":"A Commentary"},
             "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"verses":[
               {"sv":1001001,"commentary":{"text":"Faith and hope."}},
               {"sv":1001002,"commentary":{"text":"Hope again."}}
             ]}]}
            """#, id: "A", in: root, library: library)
        _ = try await install(#"""
            {"meta":{"schemaVersion":"2.1","id":"B","title":"B Commentary","seriesAbbrev":"B","seriesFull":"B Commentary"},
             "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"pericopae":[
               {"sv":1001003,"title":"Hope","introduction":{"text":"On what is waited for."}}
             ]}]}
            """#, id: "B", in: root, library: library)
        // Searched in this order, so the first could have taken the place.
        #expect(try await library.installedModules().filter { $0.kind == .commentary }.map(\.id) == ["A", "B"])
        let hits = try await library.searchModules(query: "hope", kinds: [.commentary], limit: 1)
        #expect(hits.map(\.moduleID) == ["B"])
        #expect(hits.first?.title == "Hope")
    }

    /// Results that tie in the merge take turns by commentary, so the first
    /// searched can't fill a limit that has room for both.
    @Test func tiedCommentariesTakeTurnsInTheMerge() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for id in ["A", "B"] {
            _ = try await install(#"""
                {"meta":{"schemaVersion":"2.1","id":"\#(id)","title":"\#(id) Commentary","seriesAbbrev":"\#(id)","seriesFull":"\#(id) Commentary"},
                 "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"verses":[
                   {"sv":1001001,"commentary":{"text":"Faith and hope."}},
                   {"sv":1001002,"commentary":{"text":"Hope again."}},
                   {"sv":1001003,"commentary":{"text":"Hope at last."}}
                 ]}]}
                """#, id: id, in: root, library: library)
        }
        let hits = try await library.searchModules(query: "hope", kinds: [.commentary], limit: 2)
        #expect(Set(hits.map(\.moduleID)) == ["A", "B"])
    }

    /// My Notes and a notes module are each asked for the whole limit: my own
    /// notes holding the word can't keep out the module's note titled with it.
    @Test func myNotesAndANotesModuleEachGetTheWholeLimit() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for verse in 1...3 {
            try await library.saveVerseNote(LampVerseNote(reference: 1_001_000 + verse, content: "I hope so, verse \(verse)."))
        }
        _ = try await install(#"""
            {"meta":{"schemaVersion":"1.1","id":"N","type":"notes","name":"Study Notes"},
             "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"verses":[
               {"sv":1001004,"title":"Hope","commentary":{"text":"Waiting with patience."}}
             ]}]}
            """#, id: "N", in: root, library: library)
        #expect(try await library.searchModules(query: "hope", kinds: [.notes], limit: 10).count == 4)
        let hits = try await library.searchModules(query: "hope", kinds: [.notes], limit: 1)
        #expect(hits.map(\.moduleID) == ["N"])
        #expect(hits.first?.snippet.contains("Waiting with patience") == true, "its snippet cut once kept")
    }

    /// A search by a tag alone, with no words, finds the writings of every
    /// devotional module holding it, each module taking its turn.
    @Test func aSearchByFacetsAloneCoversEveryDevotionalModule() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for (id, title) in [("D1", "Morning Prayer"), ("D2", "Evening Prayer")] {
            _ = try await install(#"""
                {"meta":{"schemaVersion":"1.0","id":"\#(id)","type":"devotional","title":"\#(title)",
                         "tags":["Prayer"],"date":"2026-01-01","category":"Reflection"},
                 "content":[{"type":"paragraph","content":{"text":"Pray without ceasing."}}]}
                """#, id: id, in: root, library: library)
        }
        let byTag = try await library.searchModules(
            query: "", kinds: [.devotional], devotionalCriteria: .init(tags: ["prayer"])
        )
        #expect(Set(byTag.map(\.moduleID)) == ["D1", "D2"])
        #expect(byTag.allSatisfy { $0.snippet == "Pray without ceasing." })
        let byKind = try await library.searchModules(
            query: "", kinds: [.devotional], devotionalCriteria: .init(categories: ["reflection"]), limit: 1
        )
        #expect(byKind.count == 1)
        #expect(try await library.searchModules(
            query: "", kinds: [.devotional], devotionalCriteria: .init(tags: ["fasting"])
        ).isEmpty)
    }

    /// My writing is searched through an index derived from it: deleted, it
    /// is built again and finds the same; a writing changed or removed shows
    /// at the next search; a summary, and text that is itself JSON, read as
    /// written.
    @Test func myWritingIsSearchedThroughAnIndexBuiltFromIt() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        func save(
            _ id: String, title: String, summary: String? = nil, content: String,
            tags: [String] = [], author: String? = nil, modified: Int
        ) async throws {
            _ = try await library.savePersonalDevotional(LampDevotional(
                id: id, moduleID: "personal-devotionals", moduleName: "My Writing", title: title,
                author: author, date: "2026-01-01", tags: tags, category: "Study", summary: summary,
                content: content, lastModified: Date(timeIntervalSince1970: TimeInterval(modified)), isEditable: true
            ), preserveLastModified: true)
        }
        try await save("kingdom", title: "The Kingdom of God", summary: "Seek it first.",
                       content: "The kingdom is near.", tags: ["Gospels"], modified: 1_000)
        try await save("brackets", title: "Brackets", content: "[1]", tags: ["odd"], author: "Lydia", modified: 1_000)
        try await save("braces", title: "Braces", content: "{}", tags: ["odd"], modified: 1_000)
        try await save("morning", title: "Morning", content: "Waiting in hope for the kingdom of God.", modified: 1_000)
        func search(_ text: String, _ criteria: LampDevotionalSearchCriteria = .init()) async throws -> [LampModuleSearchResult] {
            try await library.searchModules(query: text, kinds: [.devotional], devotionalCriteria: criteria)
        }

        let kingdom = try await search("kingdom of god")
        #expect(kingdom.first?.id == "devotional:personal-devotionals:kingdom", "titled with the words")
        #expect(Set(kingdom.map(\.id)) == ["devotional:personal-devotionals:kingdom", "devotional:personal-devotionals:morning"])
        #expect(kingdom.allSatisfy { $0.holdsPhrase })
        let seek = try await search("seek")
        #expect(seek.first?.snippet == "<mark>Seek</mark> it first.", "its summary holds the word")
        let odd = try await search("", .init(tags: ["odd"]))
        #expect(Set(odd.map(\.snippet)) == ["[1]", "{}"], "text that is itself JSON, as written")
        #expect(try await search("gospels").map(\.id) == ["devotional:personal-devotionals:kingdom"], "by its tag")
        #expect(try await search("lydia").map(\.id) == ["devotional:personal-devotionals:brackets"], "by its author")

        // Deleted, it is built again, and finds the same.
        let index = root.appendingPathComponent("Library/Indexes/PersonalDevotionals.sqlite")
        #expect(FileManager.default.fileExists(atPath: index.path))
        try FileManager.default.removeItem(at: index)
        #expect(try await search("kingdom of god") == kingdom)
        #expect(try await search("seek") == seek)
        #expect(try await search("", .init(tags: ["odd"])) == odd)

        // Of another version, or damaged, it is built again.
        let other = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await DatabaseQueue(path: index.path).writeWithoutTransaction { try $0.execute(sql: "PRAGMA user_version = 99") }
        let rebuilt = try await other.searchModules(query: "kingdom of god", kinds: [.devotional])
        #expect(rebuilt == kingdom)
        let version = try await DatabaseQueue(path: index.path).read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        #expect(version == 2)
        try Data("not a database".utf8).write(to: index)
        let repaired = try await other.searchModules(query: "seek", kinds: [.devotional])
        #expect(repaired == seek)
        #expect(try await search("seek") == seek, "and one opened before sees it built again")

        // Changed and removed, at the next search.
        try await save("morning", title: "Morning", content: "Waiting in faith.", modified: 2_000)
        #expect(try await search("hope").isEmpty)
        #expect(try await search("faith").map(\.id) == ["devotional:personal-devotionals:morning"])
        try await library.deletePersonalDevotional(id: "kingdom")
        #expect(try await search("kingdom").isEmpty)
    }

    /// My Notes are searched as the phone searches its notes, through an
    /// index derived from them: by word starts, their footnotes too, best
    /// first; deleted, it is built again; an edit, even in the second it was
    /// last read, shows at the next search.
    @Test func myNotesAreSearchedThroughAnIndexBuiltFromThem() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        func save(_ id: String, title: String? = nil, _ content: String, footnote: String? = nil, at modified: Date = Date()) async throws {
            try await library.saveVerseNote(LampVerseNote(
                id: id, reference: 43_013_034, title: title, content: content,
                footnotes: footnote.map { [LampVerseFootnote(id: "1", content: $0)] } ?? [], lastModified: modified
            ))
        }
        try await save("beloved", "The beloved disciple.")
        try await save("command", "Love one another, as I have loved you.")
        try await save("hoping", "Waiting in hope.")
        try await save("titled", title: "Hope", "Abiding.")
        try await save("cited", "As the fathers read it.", footnote: "See Augustine, Tractates 65.")
        func search(_ text: String) async throws -> [LampModuleSearchResult] {
            try await library.searchModules(query: text, kinds: [.notes])
        }

        #expect(try await search("love").map(\.id) == ["notes:personal-notes:command"], "not inside beloved")
        #expect(try await search("hope").map(\.id) == ["notes:personal-notes:titled", "notes:personal-notes:hoping"])
        let cited = try await search("augustine")
        #expect(cited.map(\.id) == ["notes:personal-notes:cited"])
        #expect(cited.first?.snippet.contains("<mark>Augustine</mark>") == true, "cut from its footnote")
        #expect(try await search("love one another").first?.holdsPhrase == true)

        let index = root.appendingPathComponent("Library/Indexes/PersonalNotes.sqlite")
        let hope = try await search("hope")
        try FileManager.default.removeItem(at: index)
        #expect(try await search("hope") == hope)

        // Read in the second it changed, as a time to come always is, it is
        // read again until a later one, so a second edit in it isn't missed.
        let later = Date(timeIntervalSinceNow: 3_600)
        try await save("quick", "Grace first.", at: later)
        #expect(try await search("grace").count == 1)
        try await save("quick", "Mercy now.", at: later)
        #expect(try await search("mercy").map(\.id) == ["notes:personal-notes:quick"])
        #expect(try await search("grace").isEmpty)
        try await library.deleteVerseNote(id: "quick")
        #expect(try await search("mercy").isEmpty)
    }

    /// `*faith` finds "unfaithful" in every kind with an index, through the
    /// list of its words each compiled module keeps, and finds the same by
    /// reading the text where a module has no list, or one older than its
    /// index; "faith" finds only words it starts.
    @Test func aStarFindsPartOfAWordInEveryKind() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await install(#"""
            {"meta":{"schemaVersion":"2.2","id":"C","seriesAbbrev":"C","seriesFull":"Commentary","title":"John"},
             "book":"John","bookNumber":43,
             "chapters":[{"chapter":1,"pericopae":[
               {"title":"Steward","sv":43001001,"ev":43001001,"content":[{"type":"commentary","content":{"text":"The unfaithful steward is warned."}}]},
               {"title":"Works","sv":43001002,"ev":43001002,"content":[{"type":"commentary","content":{"text":"Faith works through love."}}]},
               {"title":"Rest","sv":43001003,"ev":43001003,"content":[{"type":"commentary","content":{"text":"Hope only."}}]}
             ]}]}
            """#, id: "C", in: root, library: library)
        _ = try await install(#"""
            {"meta":{"schemaVersion":"1.0","id":"B","type":"book","title":"Book","language":"en"},
             "sections":[
               {"id":"steward","type":"chapter","title":"First","content":[{"type":"paragraph","content":{"text":"The unfaithful steward."}}]},
               {"id":"works","type":"chapter","title":"Second","content":[{"type":"paragraph","content":{"text":"Faith works."}}]}
             ]}
            """#, id: "B", in: root, library: library)
        _ = try await install(#"""
            {"meta":{"schemaVersion":"1.1","id":"N","type":"notes","name":"Study Notes"},
             "book":"John","bookNumber":43,"chapters":[{"chapter":1,"verses":[
               {"sv":43001001,"title":"One","commentary":{"text":"An unfaithful servant."}},
               {"sv":43001002,"title":"Two","commentary":{"text":"Faith alone."}}
             ]}]}
            """#, id: "N", in: root, library: library)
        for (id, text) in [("D1", "The unfaithful steward."), ("D2", "Faith alone.")] {
            _ = try await install(#"""
                {"meta":{"schemaVersion":"1.0","id":"\#(id)","type":"devotional","title":"\#(id)",
                         "tags":[],"date":"2026-01-01","category":"Reflection"},
                 "content":[{"type":"paragraph","content":{"text":"\#(text)"}}]}
                """#, id: id, in: root, library: library)
        }
        let kinds: [LampModuleKind] = [.commentary, .book, .notes, .devotional]
        func found(_ query: String, _ kind: LampModuleKind) async throws -> Set<String> {
            Set(try await library.searchModules(query: query, kinds: [kind]).map(\.snippet))
        }
        let databases = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Library/Databases"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "sqlite" }
        #expect(databases.count == 5)
        for database in databases {
            let listed = try await DatabaseQueue(path: database.path).read { db in
                try String.fetchAll(db, sql: "SELECT fts FROM search_word_lists")
                    .allSatisfy { try LampSearchWords.isCurrent(index: $0, in: db) }
            }
            #expect(listed, "each compiled module keeps its index's words")
        }

        var throughTheLists: [LampModuleKind: Set<String>] = [:]
        for kind in kinds {
            let within = try await found("*faith", kind)
            #expect(within.count == 2, "\(kind)")
            #expect(within.contains { $0.contains("un<mark>faith</mark>ful") }, "\(kind)")
            #expect(try await found("faith", kind).count == 1, "\(kind): a typed word starts one")
            #expect(try await found("*faith works", kind).count == (kind == .commentary || kind == .book ? 1 : 0))
            #expect(try await found("*zzq", kind).isEmpty)
            throughTheLists[kind] = within
        }

        // Without a list, or with one older than its index, the text is read.
        for (offset, database) in databases.enumerated() {
            try await DatabaseQueue(path: database.path).write { db in
                if offset.isMultiple(of: 2) {
                    try db.execute(sql: "DROP TABLE search_word_lists")
                } else {
                    try db.execute(sql: "UPDATE search_word_lists SET structure = x'00'")
                }
            }
        }
        for kind in kinds {
            #expect(try await found("*faith", kind) == throughTheLists[kind], "\(kind)")
        }
    }

    /// My writing's and My Notes' indexes keep their words too, folded as
    /// they fold them, Greek and accents alike.
    @Test func aStarFindsPartOfAWordInMyWritingAndNotes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for (id, content) in [("word", "Ἐν ἀρχῇ ἦν ὁ λόγος"), ("dispute", "Without ἀντιλογία."), ("study", "An Étude in faith.")] {
            _ = try await library.savePersonalDevotional(LampDevotional(
                id: id, moduleID: "personal-devotionals", moduleName: "My Writing", title: id,
                tags: [], content: content, isEditable: true
            ))
        }
        try await library.saveVerseNote(LampVerseNote(id: "note", reference: 43_001_001, content: "An unfaithful word."))
        func found(_ query: String, _ kind: LampModuleKind) async throws -> [String] {
            try await library.searchModules(query: query, kinds: [kind]).map(\.id).sorted()
        }
        #expect(try await found("*λογ", .devotional) == ["devotional:personal-devotionals:dispute", "devotional:personal-devotionals:word"])
        #expect(try await found("*τυδ", .devotional).isEmpty)
        #expect(try await found("*tud", .devotional) == ["devotional:personal-devotionals:study"])
        #expect(try await found("*étud", .devotional) == ["devotional:personal-devotionals:study"])
        #expect(try await found("*faith", .notes) == ["notes:personal-notes:note"])

        let writings = root.appendingPathComponent("Library/Indexes/PersonalDevotionals.sqlite")
        let words = try await DatabaseQueue(path: writings.path).read { db in
            try LampSearchWords.words(holding: "λογ", index: "devotional_entries_fts", in: db)
        }
        #expect(words?.sorted() == ["λόγοσ", "ἀντιλογία"], "the list answered, the words as the index holds them")
    }

    /// Exercise a newly compiled complete index, a shipped two-column index,
    /// and the oldest JSON-only schema. Mixed body/note queries must survive.
    @Test func commentaryFindsBodyAndFootnoteTermsAcrossAllIndexGenerations() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let database = try await install(#"""
            {"meta":{"schemaVersion":"2.1","id":"C","title":"Commentary","seriesAbbrev":"C","seriesFull":"Commentary"},
             "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"verses":[
               {"sv":1001001,"commentary":{"text":"Faith without works."},"footnotes":[{"id":"metadataOnlyNeedle","content":{"text":"Hope is living water."}}]},
               {"sv":1001002,"commentary":{"text":"The beloved."}},
               {"sv":1001003,"commentary":{"text":"Love wins."}},
               {"sv":1001004,"commentary":{"text":"The oJ lo/gos lives.","annotations":[{"type":"greek","start":4,"end":13,"text":"oJ lo/gos","data":{"sourceEncoding":"legacy","unicode":"ὁ λόγος"}}]},
                "footnotes":[{"content":{"text":"Note oJ lo/gos","annotations":[{"type":"greek","start":5,"end":14,"text":"oJ lo/gos","data":{"sourceEncoding":"legacy","unicode":"ὁ λόγος"}}]}}]}
             ]}]}
            """#, id: "C", in: root, library: library)
        let queue = try DatabaseQueue(path: database.path)
        for generation in 0...2 {
            if generation == 1 {
                try await queue.write { db in
                    try db.execute(sql: """
                        DROP TABLE commentary_units_fts;
                        ALTER TABLE commentary_units DROP COLUMN footnotes_text;
                        CREATE VIRTUAL TABLE commentary_units_fts USING fts5(title, search_text, content='commentary_units', content_rowid='rowid');
                        INSERT INTO commentary_units_fts(commentary_units_fts) VALUES('rebuild');
                        """)
                }
            } else if generation == 2 {
                try await queue.write { db in
                    try db.execute(sql: "DROP TABLE commentary_units_fts; ALTER TABLE commentary_units DROP COLUMN search_text;")
                }
            }
            for query in ["hope", "faith hope", "\"living water\""] {
                let hits = try await library.searchModules(query: query, kinds: [.commentary])
                #expect(hits.map(\.startReference) == [1_001_001], "generation \(generation), query \(query)")
                #expect(hits.first?.snippet.contains("<mark>") == true)
            }
            #expect(try await library.searchModules(query: "lov", kinds: [.commentary], limit: 1).map(\.startReference) == [1_001_003])
            for query in ["lives", "note"] {
                let hits = try await library.searchModules(query: query, kinds: [.commentary])
                #expect(hits.map(\.startReference) == [1_001_004])
                #expect(hits.first?.snippet.contains("ὁ λόγος") == true)
                #expect(hits.first?.snippet.contains("oJ lo/gos") == false)
            }
            #expect(try await library.searchModules(query: "metadataOnlyNeedle", kinds: [.commentary]).isEmpty)
            #expect(try await library.searchModules(query: "annotations", kinds: [.commentary]).isEmpty)
        }
    }
}
