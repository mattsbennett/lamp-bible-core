import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

/// The reads an app hands the analysis reader, over databases laid out as the
/// phone keeps its translations: several in one `translation_verses` table.
struct LampStrongsAnalysisReaderTests {
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

    /// Two translations in one table, the second holding no G25, and a
    /// verse of Genesis to fall outside a New Testament range.
    private func sharedTable() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_verses (
                    translation_id TEXT, ref INTEGER, book INTEGER, text TEXT, annotations_json TEXT
                )
                """)
            let verses: [(String, Int, (text: String, json: String))] = [
                ("T", 43_003_016, tags([("God", "G2316"), ("loved", "G25")])),
                ("T", 43_003_017, tags([("and", "G2532"), ("God", "G2316")])),
                ("T", 62_004_008, tags([("love", "G26"), ("God", "G2316"), ("loves", "G25")])),
                ("T", 1_001_001, tags([("God", "H430")])),
                ("U", 43_003_016, tags([("God", "G2316"), ("so", "G3779")])),
            ]
            for (translation, reference, verse) in verses {
                try db.execute(
                    sql: "INSERT INTO translation_verses VALUES (?, ?, ?, ?, ?)",
                    arguments: [translation, reference, reference / 1_000_000, verse.text, verse.json]
                )
            }
        }
        return queue
    }

    private func index(of verses: DatabaseQueue, translationID: String) throws -> DatabaseQueue {
        let index = try DatabaseQueue()
        let rows = try verses.read { db in
            try Row.fetchAll(db, sql: "SELECT ref, annotations_json FROM translation_verses WHERE translation_id = ?",
                             arguments: [translationID])
                .map { ($0["ref"] as Int, $0["annotations_json"] as String?) }
        }
        try index.write { db in
            try LampStrongsIndex.createTables(in: db)
            for (reference, json) in rows {
                try LampStrongsIndex.add(reference: reference, annotationsJSON: json, translationID: translationID, in: db)
            }
            try LampStrongsIndex.finish(translationID: translationID, fingerprint: "now", in: db)
        }
        return index
    }

    private func analyzer(corpus: LampStrongsCorpus? = nil, includingVerseText: Bool = false) -> LampStrongsAnalyzer {
        LampStrongsAnalyzer(
            key: "G25", translationID: "T", translationName: "Test", language: "en",
            includingVerseText: includingVerseText, corpus: corpus
        )
    }

    @Test func aSharedTableIsReadByTheTranslationsRowsAndAModuleByItsOwn() throws {
        let shared = try sharedTable()
        #expect(try shared.read { try LampStrongsAnalysisReader.VerseSource.find(in: $0, translationID: "T") }
            == .init(table: "translation_verses", translationID: "T"))

        let module = try DatabaseQueue()
        try module.write { db in
            try db.execute(sql: "CREATE TABLE books (id INTEGER)")
            try db.execute(sql: "CREATE TABLE verses (ref INTEGER, book INTEGER, text TEXT, annotations_json TEXT)")
        }
        #expect(try module.read { try LampStrongsAnalysisReader.VerseSource.find(in: $0, translationID: "M") }
            == .init(table: "verses", translationID: nil))

        let untagged = try DatabaseQueue()
        try untagged.write { try $0.execute(sql: "CREATE TABLE translation_verses (ref INTEGER, text TEXT)") }
        #expect(try untagged.read { try LampStrongsAnalysisReader.VerseSource.find(in: $0, translationID: "T") } == nil)
    }

    /// The index's way and the reading of every verse give one analysis, over
    /// the same range, and neither strays into another translation's rows.
    @Test func theIndexAndEveryVerseGiveTheSameAnalysisInRange() throws {
        let verses = try sharedTable()
        let index = try index(of: verses, translationID: "T")
        let source = LampStrongsAnalysisReader.VerseSource(table: "translation_verses", translationID: "T")

        for range in [nil, 40...66, 43...43] as [ClosedRange<Int>?] {
            var everyVerse = analyzer()
            try verses.read {
                try LampStrongsAnalysisReader.addEveryVerse(to: &everyVerse, bookRange: range, from: source, in: $0)
            }
            let read = everyVerse.analysis()

            let indexed = try #require(try index.read {
                try LampStrongsAnalysisReader.indexed(
                    key: "G25", translationID: "T", fingerprint: "now", bookRange: range, in: $0
                )
            })
            var fromIndex = analyzer(corpus: indexed.corpus)
            try verses.read {
                try LampStrongsAnalysisReader.addVerses(indexed.references, to: &fromIndex, from: source, in: $0)
            }
            let looked = try fromIndex.analysis { keys in
                try index.read { try LampStrongsIndex.verseCounts(of: keys, translationID: "T", bookRange: range, in: $0) }
            }
            #expect(looked == read)
        }

        var johnOnly = analyzer()
        try verses.read { try LampStrongsAnalysisReader.addEveryVerse(to: &johnOnly, bookRange: 43...43, from: source, in: $0) }
        #expect(johnOnly.analysis().references == [43_003_016])
    }

    @Test func anIndexBuiltFromOtherTagsIsNotUsed() throws {
        let index = try index(of: try sharedTable(), translationID: "T")
        #expect(try index.read {
            try LampStrongsAnalysisReader.indexed(key: "G25", translationID: "T", fingerprint: "then", in: $0)
        } == nil)
    }

    @Test func verseTextIsKeptOnlyWhenAsked() throws {
        let verses = try sharedTable()
        let source = LampStrongsAnalysisReader.VerseSource(table: "translation_verses", translationID: "T")
        var counting = analyzer()
        var showing = analyzer(includingVerseText: true)
        try verses.read { db in
            try LampStrongsAnalysisReader.addEveryVerse(to: &counting, from: source, in: db)
            try LampStrongsAnalysisReader.addEveryVerse(to: &showing, from: source, in: db)
        }
        #expect(counting.analysis().verseTexts.isEmpty)
        #expect(showing.analysis().verseTexts[62_004_008] == "love God loves")
    }

    /// A shared table's row names its scheme and departures; a module's own
    /// meta names its scheme; a translation that names none is English.
    @Test func aTranslationsNumberingIsReadFromWhereItDeclaresIt() throws {
        let shared = try DatabaseQueue()
        try shared.write { db in
            try db.execute(sql: "CREATE TABLE translations (id TEXT, versification TEXT, versification_mappings TEXT)")
            try db.execute(sql: "INSERT INTO translations VALUES ('LXX', 'lxx', NULL), ('W', 'standard', ?)",
                           arguments: [#"["ROM 14:24-26 = ROM 16:25-27"]"#])
        }
        #expect(try shared.read { try LampVersification.declared(in: $0, translationID: "LXX") }.scheme == .septuagint)
        let departing = try shared.read { try LampVersification.declared(in: $0, translationID: "W") }
        #expect(departing.scheme == .english)
        #expect(departing.original(of: 45_014_024) == 45_016_025)
        #expect(try shared.read { try LampVersification.declared(in: $0, translationID: "missing") }.scheme == .english)

        let module = try DatabaseQueue()
        try module.write { db in
            try db.execute(sql: "CREATE TABLE translation_meta (versification TEXT)")
            try db.execute(sql: "INSERT INTO translation_meta VALUES ('vulgate')")
        }
        #expect(try module.read { try LampVersification.declared(in: $0, translationID: "V") }.scheme == .vulgate)
    }

    /// Read as the library reads a dictionary it opens.
    @Test func sensesAreReadForAnAppAsTheLibraryReadsThem() {
        let senses = LampDictionarySense.senses(fromJSON: """
            [{"gloss": "love", "part_of_speech": "noun",
              "septuagintHebrew": [{"text": "אַהֲבָה", "strongs": "H0160"}, {"text": " "}]},
             {"definition": {"text": "see G25", "annotations": [{"type": "strongs", "start": 4, "end": 7, "data": {"strongs": "G25"}}]}}]
            """)
        #expect(senses.count == 2)
        #expect(senses.first?.gloss == "love")
        #expect(senses.first?.partOfSpeech == "noun")
        #expect(senses.first?.septuagintHebrew == [LampSeptuagintHebrew(text: "אַהֲבָה", strongs: "H160")])
        #expect(senses.last?.definition == "see G25")
        #expect(senses.last?.dictionaryLinks.map(\.key) == ["G25"])
        #expect(LampDictionarySense.senses(fromJSON: nil).isEmpty)
        #expect(LampDictionarySense.senses(fromJSON: "{").isEmpty)
    }
}
