import Foundation
import LampCore
import LampModuleKit
import Testing

struct LampDictionaryStyleTests {
    /// Offsets are Unicode scalars, as the module builders count them, and
    /// land on the text a sense shows: trimmed, and with its paragraphs
    /// joined. Pointed Hebrew is where the units part: כָּפַר is six scalars
    /// but three characters, so a count in characters would put "cover over"
    /// three places early.
    @Test func stylesLandOnTheWordsTheyName() async throws {
        let entry = try await sense(#"""
            {"definition": {"text": "  כָּפַר verb: cover over, pacify; make propitiation.",
              "annotations": [
                {"type": "hebrew", "start": 2, "end": 8, "text": "כָּפַר"},
                {"type": "emphasis", "start": 15, "end": 25, "text": "cover over", "data": {"style": "italic"}},
                {"type": "emphasis", "start": 0, "end": 6, "text": "pacify", "data": {"style": "italic"}},
                {"type": "emphasis", "start": 40, "end": 52, "data": {"style": "bold"}},
                {"type": "emphasis", "start": 2, "end": 8, "data": {"style": "underline"}},
                {"type": "lexicon-ref", "start": 2, "end": 8, "text": "כָּפַר"},
                {"type": "emphasis", "start": 15, "end": 25, "text": "not here", "data": {"style": "bold"}}
              ]},
             "derivation": [
               "First paragraph.",
               {"text": "Second, with ἱλασμός inside.",
                "annotations": [{"type": "greek", "start": 13, "end": 20, "text": "ἱλασμός"}]}
             ]}
            """#)

        let definition = try #require(entry.definition)
        #expect(definition == "כָּפַר verb: cover over, pacify; make propitiation.")
        let shown = entry.styles.filter { $0.field == .definition }
        #expect(shown.map(\.kind) == [.hebrew, .italic, .italic, .bold])
        #expect(shown.map { words(definition, $0) } == ["כָּפַר", "cover over", "pacify", "propitiation"])

        let derivation = try #require(entry.derivation)
        let greek = try #require(entry.styles.first { $0.field == .derivation })
        #expect(greek.kind == .greek)
        #expect(words(derivation, greek) == "ἱλασμός")
    }

    /// A word that recurs is styled where the offsets put it, not at its
    /// first appearance: here the second "love", after pointed Hebrew that
    /// a count in characters would shorten.
    @Test func aRecurringWordIsStyledWhereItWasMeant() async throws {
        let entry = try await sense(#"""
            {"definition": {"text": "כָּפַר: love, and again love.",
              "annotations": [{"type": "emphasis", "start": 24, "end": 28, "data": {"style": "bold"}}]}}
            """#)
        let definition = try #require(entry.definition)
        let bold = try #require(entry.styles.first)
        #expect(words(definition, bold) == "love")
        #expect(bold.start == Array(definition.unicodeScalars).count - 5)
    }

    @Test func aPlainSenseHasNoStyles() async throws {
        #expect(try await sense(#"{"shortDefinition": "love", "definition": {"text": "love, goodwill"}}"#).styles.isEmpty)
    }

    private func words(_ text: String, _ style: LampDictionaryStyle) -> String {
        let scalars = Array(text.unicodeScalars)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[style.start..<style.end])
        return String(view)
    }

    /// The first sense of a one-entry dictionary, compiled and installed as a
    /// module is, so the compiler's own handling of annotations is in the way.
    private func sense(_ senseJSON: String) async throws -> LampDictionarySense {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-dictionary-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let json = #"""
            {"meta": {"schemaVersion": "2.1", "id": "LEX", "type": "dictionary", "name": "Lexicon"},
             "entries": [{"key": "H3722", "lemma": "כָּפַר", "senses": [
            """# + senseJSON + "]}]}"
        let url = root.appendingPathComponent("LEX.lamp")
        _ = try LampModuleCompiler().compile(data: Data(json.utf8), sourceFilename: "LEX.json", destinationURL: url)
        _ = try await library.install(from: url)
        let entries = try await library.dictionaryEntries(keys: ["H3722"])
        return try #require(entries.first?.senses.first)
    }
}
