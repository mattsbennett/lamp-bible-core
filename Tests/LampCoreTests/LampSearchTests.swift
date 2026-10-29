import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

struct LampSearchTests {
    // MARK: - The query

    /// An apostrophe inside a word is part of it, in either form, and a single
    /// quote around a phrase still quotes it.
    @Test func anApostropheInAWordIsPartOfIt() {
        #expect(LampSearchQuery("God's love").terms == [
            LampSearchTerm(text: "God's", isExact: false),
            LampSearchTerm(text: "love", isExact: false),
        ])
        #expect(LampSearchQuery("'God's love'").terms == [LampSearchTerm(text: "God's love", isExact: true)])
        #expect(LampSearchQuery("Lord’s day").terms.first == LampSearchTerm(text: "Lord’s", isExact: false))
        // FTS5 reads "Lord’s" as `lord` and `s`, so that is what is asked for.
        #expect(LampSearchQuery("Lord’s").fts5Query == #""Lord s"*"#)
        #expect(LampSearchQuery("God's love").fts5Query == #""God s"* "love"*"#)
    }

    @Test func aTermMatchesWhateverItsCaseAccentsAndApostrophes() {
        #expect(LampSearchTerm(text: "lord's", isExact: false).matches("the Lord’s day"))
        #expect(LampSearchTerm(text: "λογος", isExact: false).matches("Ἐν ἀρχῇ ἦν ὁ λόγος"))
        #expect(LampSearchTerm(text: "חסד", isExact: false).matches("חֵסֵד"))
        #expect(LampSearchTerm(text: "love", isExact: true).matches("God is love."))
        #expect(!LampSearchTerm(text: "love", isExact: true).matches("my beloved"))
        #expect(LampSearchTerm(text: "love", isExact: false).matches("my beloved"))
    }

    @Test func aLikePredicateMatchesTermsAsTyped() {
        let percent = LampSearchQuery("50%_off").sqlLikePredicate(columns: ["title"])
        #expect(percent.arguments == [#"%50\%\_off%"#])
        #expect(percent.condition == #"(COALESCE(title, '') LIKE ? ESCAPE '\')"#)
        let apostrophe = LampSearchQuery("Lord's").sqlLikePredicate(columns: ["title"])
        #expect(apostrophe.arguments == ["%Lord's%", "%Lord’s%"])
        let json = LampSearchQuery("love").sqlLikePredicate(columns: [], jsonColumns: ["senses_json"])
        #expect(json.arguments == ["%love%", "%love%"])
        #expect(json.condition.contains("json_tree"))
    }

    /// The words the search found are marked as it found them: a typed word
    /// where a word starts with it, each term on its own.
    @Test func aSnippetMarksWhatTheSearchFound() {
        #expect(LampSearchQuery("faith works").markedSnippet("faith without works is dead")
            == "<mark>faith</mark> without <mark>works</mark> is dead")
        #expect(LampSearchQuery("lov").markedSnippet("a glove of love")
            == "a glove of <mark>lov</mark>e")
        #expect(LampSearchQuery("ove").markedSnippet("a glove") == "a gl<mark>ove</mark>")
        #expect(LampSearchQuery("\"in the beginning\"").markedSnippet("In the beginning God")
            == "<mark>In the beginning</mark> God")

        let long = (1...80).map { "word\($0)" }.joined(separator: " ") + " grace " + (1...80).map { "tail\($0)" }.joined(separator: " ")
        let snippet = LampSearchQuery("grace").markedSnippet(long, limit: 120)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.contains("<mark>grace</mark>"))
        #expect(snippet.count < 140)
    }

    @Test func aStrongsKeyIsKnownWhenItIsTheWholeQuery() {
        #expect(LampStrongsKey.typedKey(" g0026 ") == "G26")
        #expect(LampStrongsKey.typedKey("H1234a") == "H1234A")
        #expect(LampStrongsKey.typedKey("TH8799") == "TH8799")
        #expect(LampStrongsKey.typedKey("Galatians") == nil)
        #expect(LampStrongsKey.typedKey("G26 love") == nil)
        #expect(LampStrongsKey.typedKey("G") == nil)
    }

    /// The KJV tags "God" with the article and the noun under one word; a
    /// verse tagging either is found, the key written however it is.
    @Test func aVerseHoldsEveryKeyItsTagsList() {
        let json = #"[{"type":"strongs","start":0,"end":3,"data":{"strongs":"G3588,G2316"}},{"type":"strongs","start":8,"end":12,"data":{"strongs":"G0026"}}]"#
        #expect(LampStrongsSearch.holdsKey(json, key: "G2316"))
        #expect(LampStrongsSearch.holdsKey(json, key: "g3588"))
        #expect(LampStrongsSearch.holdsKey(json, key: "G26"))
        #expect(!LampStrongsSearch.holdsKey(json, key: "G2"))
        #expect(LampStrongsSearch.sqlPrefilterPattern(for: "G0026") == "%26%")
        #expect(LampStrongsSearch.markedText("God is love", annotationsJSON: json, key: "G2316")
            == "<mark>God</mark> is love")
    }

    // MARK: - The library

    private func installed(_ json: String, id: String, in fixture: URL, library: LampLibrary) async throws {
        let url = fixture.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(data: Data(json.utf8), sourceFilename: "\(id).json", destinationURL: url)
        _ = try await library.install(from: url)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Every commentary unit's JSON holds "text", and every lexicon entry's
    /// "definition". Those are its keys, not its words, and find nothing.
    @Test func aModulesJSONIsSearchedInItsWordsNotItsKeys() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await installed(#"""
            {"meta": {"schemaVersion": "2.1", "id": "LEX", "type": "dictionary", "name": "Lexicon"},
             "entries": [
               {"key": "G26", "lemma": "ἀγάπη", "transliteration": "agapē",
                "senses": [{"shortDefinition": "love", "definition": {"text": "love, goodwill"},
                            "derivation": {"text": "from G25"}}]},
               {"key": "G4102", "lemma": "πίστις", "senses": [{"shortDefinition": "faith"}]}
             ]}
            """#, id: "LEX", in: root, library: library)
        try await installed(#"""
            {"meta": {"schemaVersion": "2.1", "id": "COMM", "seriesAbbrev": "C", "seriesFull": "Commentary", "title": "Genesis"},
             "book": "Gen", "bookNumber": 1,
             "chapters": [{"chapter": 1, "verses": [
               {"sv": 1001001, "commentary": {"text": "A comment on creation.",
                 "annotations": [{"type": "scripture", "start": 0, "end": 1, "text": "A", "data": {"sv": 43001001}}]}},
               {"sv": 1001002, "commentary": {"text": "The earth was formless until the end of the day."}}
             ]}]}
            """#, id: "COMM", in: root, library: library)

        #expect(try await library.searchDictionaries(query: "definition").isEmpty)
        #expect(try await library.searchDictionaries(query: "goodwill").map(\.key) == ["G26"])
        #expect(try await library.searchDictionaries(query: "from G25").map(\.key) == ["G26"])
        #expect(try await library.searchModules(query: "text", kinds: [.commentary]).isEmpty)
        #expect(try await library.searchModules(query: "annotations", kinds: [.commentary]).isEmpty)
        let ending = try await library.searchModules(query: "end", kinds: [.commentary])
        #expect(ending.map(\.startReference) == [1_001_002])
        #expect(ending.first?.snippet == "The earth was formless until the <mark>end</mark> of the day.")

        // Greek typed without its accents finds the headword; a key given
        // padded finds the entry kept unpadded.
        #expect(try await library.searchDictionaries(query: "αγαπη").map(\.key) == ["G26"])
        #expect(try await library.searchModules(query: "πιστις", kinds: [.dictionary]).map(\.title) == ["πίστις"])
        #expect(try await library.dictionaryEntries(keys: ["g0026"]).map(\.key) == ["G26"])
        #expect(try await library.searchModules(query: "\"love, goodwill\"", kinds: [.dictionary]).count == 1)
    }

    @Test func aStrongsSearchFindsAKeyListedWithOthers() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await installed(#"""
            {"meta": {"schemaVersion": "1.0", "id": "KJV", "type": "translation", "name": "KJV", "abbreviation": "KJV", "language": "en"},
             "books": [{"id": "John", "name": "John", "number": 43, "testament": "NT", "chapters": [{"chapter": 3, "verses": [
               {"v": 16, "content": {"text": "God so loved the world", "annotations": [
                 {"type": "strongs", "start": 0, "end": 3, "data": {"strongs": "G3588,G2316"}},
                 {"type": "strongs", "start": 7, "end": 12, "data": {"strongs": "G0025"}}]}},
               {"v": 17, "content": {"text": "For God sent not his Son", "annotations": [
                 {"type": "strongs", "start": 4, "end": 7, "data": {"strongs": "G2316"}},
                 {"type": "strongs", "start": 0, "end": 3, "data": {"strongs": "G1063"}}]}},
               {"v": 18, "content": {"text": "He that believeth on him", "annotations": [
                 {"type": "strongs", "start": 8, "end": 17, "data": {"strongs": "G4100"}}]}}
             ]}]}]}
            """#, id: "KJV", in: root, library: library)

        #expect(try await library.searchTranslationsByStrongs(key: "G2316").map(\.reference) == [43_003_016, 43_003_017])
        #expect(try await library.searchTranslationsByStrongs(key: "g02316").count == 2)
        #expect(try await library.searchTranslationsByStrongs(key: "G25").map(\.reference) == [43_003_016])
        let marked = try await library.searchModules(query: "", kinds: [.translation], strongsKey: "G2316")
        #expect(marked.map(\.snippet) == ["<mark>God</mark> so loved the world", "For <mark>God</mark> sent not his Son"])
        let text = try await library.searchModules(query: "loved world", kinds: [.translation])
        #expect(text.first?.snippet == "God so <mark>loved</mark> the <mark>world</mark>")
    }

    /// A translation without a full-text index still asks for every term,
    /// wherever each falls, as the index would.
    @Test func aTranslationWithoutAnIndexFindsEveryTermApart() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("BARE.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translations (id TEXT PRIMARY KEY, name TEXT NOT NULL, abbreviation TEXT, language TEXT);
                CREATE TABLE translation_books (
                    id TEXT PRIMARY KEY, translation_id TEXT NOT NULL, book_number INTEGER NOT NULL,
                    book_id TEXT NOT NULL, name TEXT NOT NULL, testament TEXT NOT NULL, chapter_count INTEGER NOT NULL
                );
                CREATE TABLE translation_verses (
                    id INTEGER PRIMARY KEY, translation_id TEXT NOT NULL, ref INTEGER NOT NULL,
                    book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, paragraph INTEGER DEFAULT 0, annotations_json TEXT
                );
                INSERT INTO translations VALUES ('BARE', 'Bare', 'BAR', 'en');
                INSERT INTO translation_books VALUES ('BARE:43', 'BARE', 43, 'John', 'John', 'NT', 21);
                INSERT INTO translation_verses VALUES (1, 'BARE', 43001005, 43, 1, 5, 'The light shines in the darkness', 1, NULL);
                """)
        }
        let moduleURL = root.appendingPathComponent("BARE.lamp")
        try ((Data(contentsOf: databaseURL) as NSData).compressed(using: .zlib) as Data).write(to: moduleURL)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)

        #expect(try await library.searchTranslations(query: "light darkness").count == 1)
        #expect(try await library.searchTranslations(query: "light dawn").isEmpty)
    }
}
