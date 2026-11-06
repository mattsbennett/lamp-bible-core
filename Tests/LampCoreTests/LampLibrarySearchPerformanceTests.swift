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
