import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

/// `LampModuleSearch.gather`: which kinds a request asks of an app's
/// sources, the Scripture choice, the merge and the snippets cut after it.
struct LampModuleSearchGatheringTests {
    /// What the sources were asked, in order.
    private final class Asked {
        var calls: [String] = []
    }

    private func result(_ id: String, _ kind: LampModuleKind, _ module: String, title: String = "") -> LampModuleSearchResult {
        LampModuleSearchResult(id: id, kind: kind, moduleID: module, moduleName: module, title: title, snippet: "")
    }

    /// Sources that answer nothing but say what they were asked, with
    /// `databases` and `verses` as given.
    private func sources(
        _ asked: Asked,
        databases: [LampModuleKind: [LampModuleSearchDatabase]] = [:],
        translations: [String] = ["A"],
        verses: @escaping ([String]?, Int) -> [LampModuleSearchResult] = { _, _ in [] },
        dictionaries: [LampModuleSearchResult] = [],
        plans: [LampModuleSearchResult] = []
    ) -> LampModuleSearchSources<LampModuleSearchResult> {
        LampModuleSearchSources(
            shape: .core,
            databases: { kind in
                asked.calls.append("databases \(kind.rawValue)")
                return databases[kind] ?? []
            },
            results: { hits, _, database, _ in
                asked.calls.append("results \(database.id)")
                return hits
            },
            translations: { translations },
            verses: { ids, limit in
                asked.calls.append("verses \(ids?.joined(separator: ",") ?? "all") \(limit)")
                return verses(ids, limit)
            },
            dictionaries: { limit in
                asked.calls.append("dictionaries \(limit)")
                return Array(dictionaries.prefix(limit))
            },
            plans: { limit in
                asked.calls.append("plans \(limit)")
                return Array(plans.prefix(limit))
            },
            highlights: { limit in
                asked.calls.append("highlights \(limit)")
                return []
            }
        )
    }

    @Test func eachKindIsAskedOnlyWhatItCanAnswer() throws {
        func asked(_ request: LampModuleSearchRequest) throws -> [String]? {
            let asked = Asked()
            guard try LampModuleSearch.gather(request, perKind: 5, from: sources(asked)) != nil else { return nil }
            return asked.calls
        }
        #expect(try asked(LampModuleSearchRequest(query: "hope")) == [
            "verses all 5", "dictionaries 5", "databases commentary", "databases book", "databases notes",
            "databases devotional", "databases quiz", "plans 5", "highlights 5",
        ])
        #expect(try asked(LampModuleSearchRequest(query: "", strongsKey: " G26 ")) == ["verses all 5", "dictionaries 5"])
        #expect(try asked(LampModuleSearchRequest(query: "", highlightColors: ["#FFEB3B"])) == ["highlights 5"])
        #expect(try asked(LampModuleSearchRequest(
            query: "", devotionalCriteria: LampDevotionalSearchCriteria(tags: ["Prayer"])
        )) == ["databases devotional"])
        #expect(try asked(LampModuleSearchRequest(query: "hope", kinds: [.book, .plan])) == ["databases book", "plans 5"])
        // Nothing to look for: no search at all.
        #expect(try asked(LampModuleSearchRequest(query: "  ", strongsKey: " ")) == nil)
        #expect(try asked(LampModuleSearchRequest(
            query: "", kinds: [.book], devotionalCriteria: LampDevotionalSearchCriteria(tags: ["Prayer"])
        )) == nil)
    }

    @Test func scriptureComesFromThePreferredTranslationAmongOthers() throws {
        let matches = ["A": 0, "B": 2, "C": 3]
        func verses(_ ids: [String]?, _ limit: Int) -> [LampModuleSearchResult] {
            (ids ?? ["A", "B", "C"]).flatMap { id in
                (0..<min(matches[id] ?? 0, limit)).map { self.result("\(id)\($0)", .translation, id) }
            }
        }
        func gathered(_ request: LampModuleSearchRequest) throws -> (LampModuleSearchGathering<LampModuleSearchResult>, [String]) {
            let asked = Asked()
            let found = try #require(try LampModuleSearch.gather(
                request, perKind: 10, from: sources(asked, translations: ["A", "B", "C"], verses: verses)
            ))
            return (found, asked.calls.filter { $0.hasPrefix("verses") })
        }

        // A has none: the fullest, C, and B named besides.
        let (fallen, fallenAsked) = try gathered(LampModuleSearchRequest(query: "hope", kinds: [.translation], preferredTranslationID: "A"))
        #expect(fallen.scripture == LampScriptureChoice(translationID: "C", alsoIn: ["B"]))
        #expect(fallen.results.map(\.id) == ["C0", "C1", "C2"])
        #expect(fallenAsked == ["verses A 10", "verses B 10", "verses C 10"])

        // None preferred: every translation, asked together.
        let (all, allAsked) = try gathered(LampModuleSearchRequest(query: "hope", kinds: [.translation]))
        #expect(all.scripture == nil)
        #expect(all.results.count == 5)
        #expect(allAsked == ["verses all 10"])

        // The modules named narrow the choice; one left, nothing to choose.
        let (narrowed, _) = try gathered(LampModuleSearchRequest(
            query: "hope", kinds: [.translation], moduleIDs: ["A", "B"], preferredTranslationID: "A"
        ))
        #expect(narrowed.scripture == LampScriptureChoice(translationID: "B", alsoIn: []))
        let (alone, aloneAsked) = try gathered(LampModuleSearchRequest(
            query: "hope", kinds: [.translation], moduleIDs: ["C", "X"], preferredTranslationID: "A"
        ))
        #expect(alone.scripture == nil)
        #expect(aloneAsked == ["verses C 10"])
    }

    /// Without words to rank by, every result ranks alike and the modules of
    /// a kind take turns, each in its own order: as the Mac has always
    /// ordered a search by key or colour alone, and the phone since core
    /// gathered its searches.
    @Test func withoutWordsTheModulesOfAKindTakeTurns() throws {
        let asked = Asked()
        let found = try #require(try LampModuleSearch.gather(
            LampModuleSearchRequest(query: "", kinds: [.dictionary], strongsKey: "G26"), perKind: 10,
            from: sources(asked, dictionaries: [
                result("a1", .dictionary, "A"), result("a2", .dictionary, "A"), result("a3", .dictionary, "A"),
                result("b1", .dictionary, "B"), result("b2", .dictionary, "B"),
            ])
        ))
        #expect(try found.rankedByKind(limit: 10).results.map(\.id) == ["a1", "b1", "a2", "b2", "a3"])
        #expect(try found.ranked(limit: 3).map(\.id) == ["a1", "b1", "a2"])
    }

    /// Each kind is asked for one past the page, so a kind alone on it still
    /// says it has more.
    @Test func aKindAloneOnThePageStillSaysItHasMore() throws {
        let plans = (1...5).map { result("p\($0)", .plan, "P", title: "Hope \($0)") }
        func page(_ size: Int) throws -> LampModuleSearchPage<LampModuleSearchResult> {
            let asked = Asked()
            let found = try #require(try LampModuleSearch.gather(
                LampModuleSearchRequest(query: "hope", kinds: [.plan]), perKind: size + 1, from: sources(asked, plans: plans)
            ))
            #expect(asked.calls == ["plans \(size + 1)"])
            return try found.rankedByKind(limit: size)
        }
        let cut = try page(3)
        #expect(cut.results.count == 3)
        #expect(cut.moreIn == [.plan])
        let whole = try page(5)
        #expect(whole.results.count == 5)
        #expect(whole.moreIn.isEmpty)
    }

    /// Commentary is found without its snippets, ranked by stand-ins, and
    /// the kept results' snippets are cut in the database each came from:
    /// the same as cutting them at once.
    @Test func snippetsAreCutAfterTheMergeInTheDatabaseFound() throws {
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
                INSERT INTO commentary_units (id, module_id, book, chapter, sv, title, commentary_json, search_text, order_index) VALUES
                    ('x1', 'X', 1, 1, 1001001, NULL, '{"text":"A long wait, and then hope here."}', 'A long wait, and then hope here.', 0),
                    ('x2', 'X', 1, 1, 1001002, 'Hope', '{"text":"Waiting here."}', 'Hope Waiting here.', 1),
                    ('y1', 'Y', 1, 1, 1001003, NULL, '{"text":"Hope at night."}', 'Hope at night.', 2);
                INSERT INTO commentary_units_fts(commentary_units_fts) VALUES('rebuild');
                """)
        }
        let modules = [LampSearchedModule(id: "X", name: "Ex"), LampSearchedModule(id: "Y", name: "Why")]
        let database = LampModuleSearchDatabase(id: "one", modules: modules) { body in try queue.read(body) }
        let asked = Asked()
        let request = LampModuleSearchRequest(query: "hope", kinds: [.commentary])
        let found = try #require(try LampModuleSearch.gather(
            request, perKind: 10, from: sources(asked, databases: [.commentary: [database]])
        ))
        #expect(asked.calls == ["databases commentary", "results one"])
        let standIn = LampModuleSearch.rankingSnippet(for: request.parsedQuery)
        #expect(found.results.allSatisfy { $0.snippet == standIn })

        let kept = try found.rankedByKind(limit: 2).results
        let atOnce = try queue.read { db in
            try LampModuleSearch.commentary(in: db, modules: modules, query: request.parsedQuery, limit: 10)
        }
        #expect(kept.count == 2)
        for result in kept {
            #expect(result.snippet == atOnce.first { $0.id == result.id }?.snippet)
        }
        #expect(try found.ranked(limit: 10).map(\.snippet).allSatisfy { $0 != standIn })

        // A result short of the hits would move every snippet after it.
        let short = LampModuleSearchSources<LampModuleSearchResult>(
            shape: .core,
            databases: { _ in [database] },
            results: { hits, _, _, _ in Array(hits.dropFirst()) },
            translations: { [] }, verses: nil, dictionaries: nil, plans: nil, highlights: nil
        )
        #expect(throws: LampModuleSearch.ResultsNotOneForEachHit(database: "one", kind: .commentary, hits: 3, results: 2)) {
            try LampModuleSearch.gather(request, perKind: 10, from: short)
        }
    }

    /// A request for nothing doesn't read the library: one not made yet
    /// isn't made, and one that can't be read doesn't fail.
    @Test func aRequestForNothingLeavesTheLibraryAlone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LampModuleSearchGatheringTests-\(UUID().uuidString)", isDirectory: true)
        let library = LampLibrary(rootURL: root)
        #expect(try await library.searchModules(query: "  ").isEmpty)
        #expect(try await library.searchModulesByKind(query: "", strongsKey: " ", highlightColors: []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
