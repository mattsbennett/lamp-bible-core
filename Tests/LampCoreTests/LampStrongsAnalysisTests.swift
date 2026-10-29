import Foundation
import LampModuleKit
import Testing
@testable import LampCore

struct LampStrongsAnalysisTests {
    /// A verse built from tagged words, so offsets are counted rather than typed.
    /// A word whose key is nil is untagged; `extra` is merged into its annotation.
    private func verse(_ words: [(String, String?)], extra: [Int: String] = [:]) -> (text: String, json: String) {
        var text = ""
        var annotations: [String] = []
        for (index, (word, key)) in words.enumerated() {
            if !text.isEmpty, word != "," { text += " " }
            let start = text.count
            text += word
            guard let key else { continue }
            let more = extra[index].map { "," + $0 } ?? ""
            annotations.append(#"{"type":"strongs","start":\#(start),"end":\#(text.count),"data":{"strongs":"\#(key)"\#(more)}}"#)
        }
        return (text, "[" + annotations.joined(separator: ",") + "]")
    }

    private func analysis(
        _ key: String,
        _ verses: [(Int, (text: String, json: String))],
        language: String? = "en"
    ) -> LampStrongsAnalysis {
        var analyzer = LampStrongsAnalyzer(key: key, translationID: "T", translationName: "Test", language: language)
        for (reference, verse) in verses {
            analyzer.add(reference: reference, text: verse.text, annotationsJSON: verse.json)
        }
        return analyzer.analysis()
    }

    @Test func robinsonCodesReadAsTheirFeatures() {
        #expect(LampGreekMorphology.describe("V-AAI-3S")
            == "Verb · Aorist · Active · Indicative · 3rd person · Singular")
        #expect(LampGreekMorphology.describe("V-2AAP-NSM")
            == "Verb · Aorist · Active · Participle · Nominative · Singular · Masculine")
        #expect(LampGreekMorphology.describe("V-PAN") == "Verb · Present · Active · Infinitive")
        #expect(LampGreekMorphology.describe("N-GSF") == "Noun · Genitive · Singular · Feminine")
        #expect(LampGreekMorphology.describe("P-1NS") == "Personal pronoun · 1st person · Nominative · Singular")
        #expect(LampGreekMorphology.describe("S-1SNSF")
            == "Possessive pronoun · 1st person · Nominative · Singular · Feminine")
        #expect(LampGreekMorphology.describe("A-NUI") == "Adjective")
        #expect(LampGreekMorphology.describe("CONJ") == "Conjunction")
        #expect(LampGreekMorphology.describe("TH8799") == nil)
        #expect(LampGreekMorphology.describe("V-QQQ") == nil)
    }

    @Test func everyStrongsValueIsReadFromTheBytesHoweverItIsSpaced() {
        var tags: [String] = []
        LampStrongsAnalyzer.forEachTag(in: #"""
            [{"data":{"strongs":"G3588,G2316","morphology":"T-NSM,N-NSM"}},
             {"strongs" : "H853 H430"},{"data":{"strongs":"TH8799"}},{"data":{"strongs":null}},
             {"text":"strongs"},{"data":{"strongs":"G25|G26;G27"}}]
            """#) { tags.append($0) }
        #expect(tags == ["G3588", "G2316", "H853", "H430", "TH8799", "G25", "G26", "G27"])
    }

    @Test func englishRenderingsGatherUnderTheWordThatCarriesThem() {
        #expect(LampStrongsAnalyzer.renderingHead(of: "of God,", isEnglish: true) == "God")
        #expect(LampStrongsAnalyzer.renderingHead(of: "God’s", isEnglish: true) == "God")
        #expect(LampStrongsAnalyzer.renderingHead(of: "He that loveth", isEnglish: true) == "loveth")
        #expect(LampStrongsAnalyzer.renderingHead(of: "for his mercy", isEnglish: true) == "mercy")
        #expect(LampStrongsAnalyzer.renderingHead(of: "brothers’", isEnglish: true) == "brothers")
        #expect(LampStrongsAnalyzer.renderingHead(of: "him", isEnglish: true) == "him")
        #expect(LampStrongsAnalyzer.renderingHead(of: "of the", isEnglish: true) == "the")
        #expect(LampStrongsAnalyzer.renderingHead(of: "de Dios", isEnglish: false) == "de Dios")

        let result = analysis("G2316", [
            (43_001_001, verse([("the", nil), ("Word", "G3056"), ("was", nil), ("with", nil), ("God", "G2316")])),
            (43_001_012, verse([("children", "G5043"), ("of God", "G2316")])),
            (43_001_013, verse([("God’s", "G2316"), ("will", "G2307")])),
            (43_001_014, verse([("the", nil), ("glory", "G1391"), ("of God", "G2316")])),
        ])
        #expect(result.renderings.map(\.text) == ["God"])
        #expect(result.renderings.first?.count == 4)
        #expect(result.renderings.first?.variants.map(\.text) == ["of God", "God", "God’s"])
        #expect(Set(result.occurrences.map(\.renderingID)) == ["god"])
    }

    /// The ASV renders μονογενής as two tagged words, "only" and "begotten".
    /// That is one word of Greek, so it is one occurrence and one tagged word,
    /// rendered "only begotten". Two tags with a comma between, or with
    /// different forms, are two words.
    @Test func aWordTaggedInTwoPiecesIsOneOccurrence() {
        let result = analysis("G3439", [
            (43_003_016, verse([("his", "G846"), ("only", "G3439"), ("begotten", "G3439"), ("Son", "G5207")])),
        ])
        #expect(result.occurrenceCount == 1)
        #expect(result.occurrences.first?.text == "only begotten")
        #expect(result.renderings.first?.text == "only begotten")
        #expect(result.books.first { $0.id == 43 }?.wordCount == 3)

        let holy = analysis("G40", [(66_004_008, verse([("Holy", "G40"), (",", nil), ("holy", "G40")]))])
        #expect(holy.occurrenceCount == 2)
        let forms = analysis("G25", [(43_003_016, verse(
            [("loved", "G25"), ("loved", "G25")],
            extra: [0: #""lemma":"ἠγάπησεν""#, 1: #""lemma":"ἀγαπᾷ""#]
        ))])
        #expect(forms.occurrenceCount == 2)
    }

    /// The KJV tags "God" with the article and the noun, and gives one form:
    /// the article's. The noun has no form of its own there, and its parsing
    /// is the second of the two.
    @Test func aFieldUnderSeveralKeysIsReadInStepWithThem() {
        let tagged = verse([("God", "G3588,G2316"), ("loved", "G25")], extra: [
            0: #""lemma":"ο","morphology":"T-NSM,N-NSM""#,
            1: #""lemma":"ηγαπησεν","morphology":"V-AAI-3S""#,
        ])
        let god = analysis("G2316", [(43_003_016, tagged)])
        #expect(god.occurrences.first?.form == nil)
        #expect(god.occurrences.first?.morphology == "N-NSM")
        #expect(god.grammar.contains { $0.feature == .grammaticalCase && $0.value == "Nominative" })
        let article = analysis("G3588", [(43_003_016, tagged)])
        #expect(article.occurrences.first?.form == "ο")
        let loved = analysis("G25", [(43_003_016, tagged)])
        #expect(loved.forms.map(\.text) == ["ηγαπησεν"])
        #expect(loved.parsings.first?.description == "Verb · Aorist · Active · Indicative · 3rd person · Singular")
    }

    @Test func formsDifferingOnlyInCaseOrRestingAccentAreOne() {
        let result = analysis("G2316", [
            (43_001_001, verse([("God", "G2316")], extra: [0: #""lemma":"θεός""#])),
            (43_001_002, verse([("God", "G2316")], extra: [0: #""lemma":"θεὸς""#])),
            (43_001_003, verse([("God", "G2316")], extra: [0: #""lemma":"θεὸς""#])),
            (43_001_004, verse([("God", "G2316")], extra: [0: #""lemma":"Θεὸς""#])),
            (43_001_005, verse([("God", "G2316")], extra: [0: #""lemma":"θεοῦ""#])),
        ])
        #expect(result.forms.map(\.count) == [4, 1])
        #expect(result.forms.first?.text == "θεὸς")
    }

    /// One hit in a book of twenty words is a rate fifty times the whole's,
    /// and means nothing. A book holding most of the hits in a tenth of the
    /// words does. Only the second is called out.
    @Test func aBookIsCalledOutOnlyWhenChanceCannotExplainIt() {
        // At most one hit a verse, so no two run together into one word.
        func words(_ count: Int, hits: Int) -> [(Int, (text: String, json: String))] {
            (0..<count / 10).map { index in
                let tags = (0..<10).map { word in ("w", index < hits && word == 0 ? "G26" : "G1") }
                return (index + 1, verse(tags))
            }
        }
        let books: [(Int, [(Int, (text: String, json: String))])] = [
            (40, words(5_000, hits: 2)), (62, words(500, hits: 25)), (65, words(20, hits: 1)),
            (66, words(4_480, hits: 12)),
        ]
        let result = analysis("G26", books.flatMap { book, verses in
            verses.map { (book * 1_000_000 + 1_000 + $0.0, $0.1) }
        })
        let byBook = Dictionary(uniqueKeysWithValues: result.books.map { ($0.id, $0) })
        #expect(result.wordCount == 10_000)
        #expect(byBook[65]?.ratePerThousandWords == 50)
        #expect(byBook[65]?.expectation == .asExpected)
        #expect(byBook[62]?.expectation == .more)
        #expect(byBook[40]?.expectation == .fewer)
        #expect(byBook[66]?.expectation == .asExpected)
        #expect(result.sections.map(\.name) == ["Gospels", "General Letters", "Revelation"])
        #expect(byBook[40]?.chapters.map(\.number) == [1])
    }

    /// A Greek key is weighed against Greek tags only, and a TVM code is not a word.
    @Test func aKeyIsWeighedAgainstItsOwnLanguage() {
        let result = analysis("G26", [
            (1_001_001, verse([("God", "H430"), ("created", "H1254"), ("said", "TH8799")])),
            (62_004_008, verse([("God", "G2316"), ("is", nil), ("love", "G26")])),
        ])
        #expect(result.wordCount == 2)
        #expect(result.taggedVerseCount == 1)
        #expect(result.books.map(\.id) == [62])
        #expect(result.sections.map(\.name) == ["General Letters"])
    }

    /// Faith shares love's verses far beyond chance; the article shares
    /// nearly all of them only by being everywhere, and is left out.
    @Test func companionsAreTheKeysThatKeepItCompany() {
        var verses: [(Int, (text: String, json: String))] = []
        for index in 0..<200 {
            var words: [(String, String?)] = [("the", "G3588"), ("word", "G\(1_000 + index)")]
            if index < 20 { words += [("love", "G26")] }
            if index < 12 || (100..<104).contains(index) { words += [("faith", "G4102")] }
            verses.append((45_001_001 + index, verse(words)))
        }
        let result = analysis("G26", verses)
        #expect(result.verseCount == 20)
        #expect(result.companions.map(\.key) == ["G4102"])
        #expect(result.companions.first?.sharedVerseCount == 12)
        #expect(result.companions.first?.verseCount == 16)
        #expect((result.companions.first?.lift ?? 0) > 7)
    }

    @Test func keynessIsSignedLogLikelihood() {
        #expect(LampStrongsAnalysis.keyness(hits: 10, words: 100, otherHits: 10, otherWords: 100) == 0)
        let more = LampStrongsAnalysis.keyness(hits: 30, words: 100, otherHits: 10, otherWords: 900)
        let fewer = LampStrongsAnalysis.keyness(hits: 0, words: 900, otherHits: 40, otherWords: 100)
        #expect(more > LampStrongsAnalysis.notableKeyness)
        #expect(fewer < -LampStrongsAnalysis.notableKeyness)
        #expect(LampStrongsAnalysis.keyness(hits: 0, words: 0, otherHits: 0, otherWords: 0) == 0)
    }

    @Test func theLibraryAnalysesEachTranslationThatTagsTheKeysLanguage() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-strongs-analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))

        // Six verses where love and faith meet, and twenty-four of neither.
        let corinthians = (1...30).map { number -> String in
            let tagged = number <= 6
                ? verse([("love", "G26"), ("and", nil), ("faith", "G4102")])
                : verse([("the", "G3588"), ("word", "G\(2_000 + number)")])
            return #"{"v": \#(number), "content": {"text": "\#(tagged.text)", "annotations": \#(tagged.json)}}"#
        }
        let genesis = verse([("God", "H430"), ("created", "H1254")])
        for (id, tagged) in [("TAG", true), ("BARE", false)] {
            let books = tagged
                ? #"""
                    {"id": "Gen", "name": "Genesis", "number": 1, "testament": "OT", "chapters": [{"chapter": 1, "verses": [
                      {"v": 1, "content": {"text": "\#(genesis.text)", "annotations": \#(genesis.json)}}]}]},
                    {"id": "1Cor", "name": "1 Corinthians", "number": 46, "testament": "NT", "chapters": [{"chapter": 13, "verses": [
                      \#(corinthians.joined(separator: ","))]}]}
                    """#
                : #"""
                    {"id": "1Cor", "name": "1 Corinthians", "number": 46, "testament": "NT", "chapters": [{"chapter": 13, "verses": [
                      {"v": 1, "content": {"text": "love and faith"}}]}]}
                    """#
            let moduleURL = fixture.appendingPathComponent("\(id).lamp")
            _ = try LampModuleCompiler().compile(
                data: Data(#"""
                {"meta": {"schemaVersion": "1.0", "id": "\#(id)", "type": "translation", "name": "\#(id)", "abbreviation": "\#(id)", "language": "en"},
                 "books": [\#(books)]}
                """#.utf8),
                sourceFilename: "\(id).json",
                destinationURL: moduleURL
            )
            _ = try await library.install(from: moduleURL)
        }
        let lexiconURL = fixture.appendingPathComponent("LEX.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {"meta": {"schemaVersion": "2.1", "id": "LEX", "type": "dictionary", "name": "Lexicon"},
             "entries": [
               {"key": "G26", "lemma": "ἀγάπη", "transliteration": "agapē", "senses": [{"shortDefinition": "love"}]},
               {"key": "G4102", "lemma": "πίστις", "senses": [{"shortDefinition": "faith"}]}
             ]}
            """#.utf8),
            sourceFilename: "LEX.json",
            destinationURL: lexiconURL
        )
        _ = try await library.install(from: lexiconURL)

        let analyses = try await library.strongsAnalyses(key: " g0026 ")
        #expect(analyses.map(\.translationID) == ["TAG"])
        #expect(analyses.first?.key == "G26")
        #expect(analyses.first?.occurrenceCount == 6)
        #expect(analyses.first?.references.first == 46_013_001)
        #expect(analyses.first?.wordCount == 60)
        #expect(try await library.strongsAnalyses(key: "G26", bookRange: 1...39).isEmpty)
        #expect(try await library.strongsAnalyses(key: "H430").first?.wordCount == 2)

        let agent = LampAgentLibrary(library: library)
        let report = try #require(try await agent.analyzeStrongs(key: "G26", range: "NT").first)
        #expect(report.entry == .init(key: "G26", lemma: "ἀγάπη", transliteration: "agapē", gloss: "love"))
        #expect(report.renderings.map(\.text) == ["love"])
        #expect(report.companions.map(\.entry.gloss) == ["faith"])
        #expect(report.companions.first?.timesChance == 5)
        #expect(report.books.map(\.name) == ["1 Corinthians"])
        #expect(report.references.first == "1 Corinthians 13:1")

        let narrowed = LampAgentLibrary(library: library, policy: .init(allowedModuleIDs: ["BARE"]))
        await #expect(throws: LampAgentError.moduleNotAllowed("TAG")) {
            try await narrowed.analyzeStrongs(key: "G26", translationIDs: ["TAG"])
        }
        #expect(try await narrowed.analyzeStrongs(key: "G26").isEmpty)
    }

    @Test func anAgentNamesARangeByItsBooks() throws {
        #expect(try LampReferenceParser.books("NT") == 40...66)
        #expect(try LampReferenceParser.books("old testament") == 1...39)
        #expect(try LampReferenceParser.books("Matthew–John") == 40...43)
        #expect(try LampReferenceParser.books("1 Cor") == 46...46)
        #expect(try LampReferenceParser.books("Romans 8:28") == 45...45)
        #expect(throws: LampAgentError.self) { try LampReferenceParser.books("John-Matthew") }
        #expect(throws: LampAgentError.self) { try LampReferenceParser.books("Nowhere") }
    }
}
