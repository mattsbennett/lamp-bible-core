import Foundation
import LampCore
import LampModuleKit
import Testing

/// Annotations that carry no text of their own are cut out of the parent text by
/// character offset. The entries that exercise this hardest are the long ones —
/// a lexicon definition citing scores of references — which is also where the
/// cutting used to walk the whole string once per annotation.
struct LampDictionaryAnnotationOffsetTests {
    private func install(entries: String) async throws -> (LampLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-annotation-offsets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let archiveURL = root.appendingPathComponent("TEST_OFFSETS.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data("""
            {
              "meta": {
                "schemaVersion": "2.1", "id": "TEST_OFFSETS",
                "type": "dictionary", "name": "Offset Dictionary"
              },
              "entries": \(entries)
            }
            """.utf8),
            sourceFilename: "TEST_OFFSETS.json",
            destinationURL: archiveURL
        )
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await library.install(from: archiveURL)
        return (library, root)
    }

    @Test func anAnnotationWithoutTextIsCutFromTheParentByCharacterOffset() async throws {
        let (library, root) = try await install(entries: """
        [{
          "key": "G1", "lemma": "alpha", "transliteration": "a",
          "senses": [{
            "shortDefinition": "first",
            "definition": [{
              "type": "paragraph",
              "text": "The first letter. See John 1:1 and Mark 2:3.",
              "annotations": [
                {"type": "scripture", "start": 22, "end": 30, "data": {"sv": 43001001}},
                {"type": "scripture", "start": 35, "end": 43, "data": {"sv": 41002003}}
              ]
            }]
          }]
        }]
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let sense = try #require(
            try await library.searchDictionaries(query: "alpha").first?.senses.first
        )
        #expect(sense.scriptureLinks.map(\.text) == ["John 1:1", "Mark 2:3"])
        #expect(sense.scriptureLinks.map(\.startReference) == [43_001_001, 41_002_003])
    }

    /// Offsets count characters, not scalars or bytes. Hebrew carries its vowels
    /// and cantillation as combining marks, so a text with them has far more
    /// scalars than characters, and counting the wrong unit silently slices the
    /// wrong words out of the definition.
    @Test func offsetsCountCharactersThroughCombiningMarksAndAstralScalars() async throws {
        // "רֵאשִׁית means head. See Gen 1:1." — the Hebrew word is 5 characters
        // built from 10 scalars.
        let text = "רֵאשִׁית means head. See Gen 1:1."
        let hebrew = "רֵאשִׁית"
        #expect(hebrew.count == 5)
        #expect(hebrew.unicodeScalars.count > hebrew.count)
        let start = text.distance(from: text.startIndex, to: text.range(of: "Gen 1:1")!.lowerBound)
        let (library, root) = try await install(entries: """
        [{
          "key": "H7225", "lemma": "beginning", "transliteration": "re'shith",
          "senses": [{
            "shortDefinition": "beginning",
            "definition": [{
              "type": "paragraph",
              "text": "\(text)",
              "annotations": [
                {"type": "scripture", "start": \(start), "end": \(start + 7), "data": {"sv": 1001001}},
                {"type": "strongs", "start": 0, "end": 5, "data": {"strongs": "H7225"}}
              ]
            }]
          }]
        }]
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let sense = try #require(
            try await library.searchDictionaries(query: "beginning").first?.senses.first
        )
        #expect(sense.scriptureLinks.map(\.text) == ["Gen 1:1"])
        #expect(sense.dictionaryLinks == [LampDictionaryLink(text: hebrew, key: "H7225")])
    }

    @Test func anAnnotationKeepsItsOwnTextAndOutOfRangeOffsetsYieldNone() async throws {
        let (library, root) = try await install(entries: """
        [{
          "key": "G2", "lemma": "beta", "transliteration": "b",
          "senses": [{
            "shortDefinition": "second",
            "definition": [{
              "type": "paragraph",
              "text": "Short.",
              "annotations": [
                {"type": "scripture", "start": 0, "end": 5, "text": "Given", "data": {"sv": 43001001}},
                {"type": "scripture", "start": 3, "end": 900, "data": {"sv": 43001002}},
                {"type": "scripture", "start": 4, "end": 4, "data": {"sv": 43001003}}
              ]
            }]
          }]
        }]
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let sense = try #require(
            try await library.searchDictionaries(query: "beta").first?.senses.first
        )
        #expect(sense.scriptureLinks.map(\.text) == ["Given", nil, nil])
        #expect(sense.scriptureLinks.map(\.startReference) == [43_001_001, 43_001_002, 43_001_003])
    }

    /// The shape that used to cost seconds: one long definition carrying scores
    /// of annotations.
    ///
    /// Hebrew on purpose. `JSONSerialization` hands back lazily bridged
    /// `NSString`s, and for non-ASCII text those stay in foreign UTF-16 storage,
    /// where stepping one character means an Objective-C call and a grapheme
    /// break. Walking the text from its start once per annotation over storage
    /// like that is what made a lexicon search take seconds; an ASCII fixture
    /// runs the same code in a millisecond and proves nothing.
    @Test func manyAnnotationsOnOneLongDefinitionStayCheap() async throws {
        let sentence = "אוֹר light as diffused in nature, the light of day, from רֵאשִׁית onward;"
        let body = Array(repeating: sentence, count: 450).joined(separator: " ")
        let characters = Array(body)
        let annotations = (0..<750).map { index -> String in
            let start = index * 40
            // A distinct reference each, so none of them are folded together.
            return """
            {"type": "scripture", "start": \(start), "end": \(start + 4), "data": {"sv": \(43_001_001 + index)}}
            """
        }.joined(separator: ",")
        let (library, root) = try await install(entries: """
        [{
          "key": "G3", "lemma": "gamma", "transliteration": "g",
          "senses": [{
            "shortDefinition": "third",
            "definition": [{
              "type": "paragraph",
              "text": "\(body)",
              "annotations": [\(annotations)]
            }]
          }]
        }]
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        let sense = try #require(
            try await library.searchDictionaries(query: "gamma").first?.senses.first
        )
        let elapsed = Date().timeIntervalSince(started)

        // Every cut matches what walking the string by hand would have produced.
        // Compared as a bag rather than in order: the links come back in
        // whatever order the sense's keys were visited in.
        let expected = (0..<750).map { String(characters[($0 * 40)..<($0 * 40 + 4)]) }.sorted()
        #expect(sense.scriptureLinks.compactMap(\.text).sorted() == expected)
        #expect(elapsed < 0.5, "resolving 750 annotations took \(elapsed)s")
    }
}
