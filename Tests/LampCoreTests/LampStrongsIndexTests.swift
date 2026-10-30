import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

struct LampStrongsIndexTests {
    private func tags(_ words: [(String, String)]) -> (text: String, json: String) {
        var text = ""
        var annotations: [String] = []
        for (word, key) in words {
            if !text.isEmpty { text += " " }
            let start = text.count
            text += word
            annotations.append(#"{"type":"strongs","start":\#(start),"end":\#(text.count),"data":{"strongs":"\#(key)"}}"#)
        }
        return (text, "[" + annotations.joined(separator: ",") + "]")
    }

    /// G25 begins G2532, and the index tells them apart; a bare number in the
    /// tags answers the key with its language, as the reader reads it.
    @Test func anIndexFindsTheVersesThatTagAKey() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try LampStrongsIndex.createTables(in: db)
            let verses: [(Int, (text: String, json: String))] = [
                (43_003_016, tags([("God", "G3588,G2316"), ("loved", "G25"), ("loved", "G25")])),
                (43_003_017, tags([("and", "G2532"), ("God", "G2316")])),
                (43_003_018, tags([("love", "25")])),
                (1_001_001, tags([("God", "H430"), ("said", "TH8799")])),
            ]
            for (reference, verse) in verses {
                try LampStrongsIndex.add(reference: reference, annotationsJSON: verse.json, translationID: "T", in: db)
            }
            try LampStrongsIndex.finish(translationID: "T", fingerprint: "one", in: db)
        }
        func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
        #expect(try read { try LampStrongsIndex.isCurrent(translationID: "T", fingerprint: "one", in: $0) })
        #expect(try !read { try LampStrongsIndex.isCurrent(translationID: "T", fingerprint: "two", in: $0) })
        #expect(try read { try LampStrongsIndex.references(of: "g0025", translationID: "T", in: $0) } == [43_003_016, 43_003_018])
        #expect(try read { try LampStrongsIndex.references(of: "G2532", translationID: "T", in: $0) } == [43_003_017])
        #expect(try read { try LampStrongsIndex.references(of: "G2316", translationID: "T", bookRange: 1...39, in: $0) }.isEmpty)
        #expect(try read { try LampStrongsIndex.references(of: "G2316", translationID: "T", limit: 1, in: $0) } == [43_003_016])
        #expect(try read { try LampStrongsIndex.count(of: "G2316", translationID: "T", in: $0) } == 2)
        #expect(try read { try LampStrongsIndex.verseCounts(of: ["G2316", "G3588", "G9999"], translationID: "T", in: $0) }
            == ["G2316": 2, "G3588": 1])
        // Greek is counted against Greek tags, each time written, and a TVM
        // code is not a word.
        #expect(try read { try LampStrongsIndex.corpus(for: "G25", translationID: "T", in: $0) }
            == LampStrongsCorpus(chapterWords: [43: [3: 6]], taggedVerseCount: 2))
        #expect(try read { try LampStrongsIndex.corpus(for: "H430", translationID: "T", in: $0) }
            == LampStrongsCorpus(chapterWords: [1: [1: 1]], taggedVerseCount: 1))
        try queue.write { try LampStrongsIndex.remove(translationID: "T", in: $0) }
        #expect(try read { try LampStrongsIndex.references(of: "G25", translationID: "T", in: $0) }.isEmpty)
        #expect(try !read { try LampStrongsIndex.isCurrent(translationID: "T", fingerprint: "one", in: $0) })
    }

    private func translation(id: String, loveKey: String) -> String {
        let love = (1...30).map { verse -> String in
            let words: [(String, String)] = verse <= 8
                ? [("love", loveKey), ("and", "G2532"), ("faith", "G4102")]
                : [("the", "G3588"), ("and", "G2532"), ("word", "G\(3_000 + verse)")]
            let tagged = tags(words)
            return #"{"v": \#(verse), "content": {"text": "\#(tagged.text)", "annotations": \#(tagged.json)}}"#
        }.joined(separator: ",")
        let genesis = tags([("God", "H430"), ("created", "H1254")])
        return #"""
            {"meta": {"schemaVersion": "1.0", "id": "\#(id)", "type": "translation", "name": "\#(id)", "abbreviation": "\#(id)", "language": "en"},
             "books": [
               {"id": "Gen", "name": "Genesis", "number": 1, "testament": "OT", "chapters": [{"chapter": 1, "verses": [
                 {"v": 1, "content": {"text": "\#(genesis.text)", "annotations": \#(genesis.json)}}]}]},
               {"id": "1Cor", "name": "1 Corinthians", "number": 46, "testament": "NT", "chapters": [{"chapter": 13, "verses": [\#(love)]}]}
             ]}
            """#
    }

    private func install(_ json: String, id: String, in root: URL, library: LampLibrary) async throws {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(data: Data(json.utf8), sourceFilename: "\(id).json", destinationURL: url)
        _ = try await library.install(from: url)
    }

    /// An index changes how fast an analysis or a search answers, never what
    /// it answers; and one gone stale, its module installed again with other
    /// tags, is not read until it is built again.
    @Test func theIndexAnswersAsReadingEveryVerseDoes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-strongs-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await install(translation(id: "T", loveKey: "G26"), id: "T", in: root, library: library)

        struct Answers: Equatable {
            var analyses: [[LampStrongsAnalysis]]
            var verses: [LampTranslationSearchResult]
            var results: [LampModuleSearchResult]
        }
        func answers() async throws -> Answers {
            Answers(
                analyses: [
                    try await library.strongsAnalyses(key: "G26", includingVerseText: true),
                    try await library.strongsAnalyses(key: "G2532", bookRange: 40...66),
                    try await library.strongsAnalyses(key: "H430"),
                ],
                verses: try await library.searchTranslationsByStrongs(key: "G26"),
                results: try await library.searchModules(query: "", kinds: [.translation], strongsKey: "G2532")
            )
        }
        let read = try await answers()
        try await library.buildStrongsIndexes()
        let indexURL = root.appendingPathComponent("Library/Indexes/StrongsIndex.sqlite")
        let indexed = try DatabaseQueue(path: indexURL.path)
        func stored<T>(_ body: (Database) throws -> T) throws -> T { try indexed.read(body) }
        #expect(try stored { try String.fetchAll($0, sql: "SELECT translation_id FROM strongs_index_translations") } == ["T"])
        #expect(try await answers() == read)
        #expect(try await library.strongsAnalyses(key: "G26").first?.companions.map(\.key) == ["G4102"])

        // The same module again, its love now tagged G25.
        try await install(translation(id: "T", loveKey: "G25"), id: "T", in: root, library: library)
        #expect(try await library.searchTranslationsByStrongs(key: "G26").isEmpty)
        #expect(try await library.searchTranslationsByStrongs(key: "G25").count == 8)
        try await library.buildStrongsIndexes()
        #expect(try await library.strongsAnalyses(key: "G25").first?.occurrenceCount == 8)
        #expect(try await library.searchTranslationsByStrongs(key: "G26").isEmpty)

        try await library.remove(moduleID: "T")
        try await library.buildStrongsIndexes()
        #expect(try stored { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM strongs_verses") } == 0)
    }
}
