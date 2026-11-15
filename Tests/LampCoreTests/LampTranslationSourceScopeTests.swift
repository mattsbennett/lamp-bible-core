import Testing
@testable import LampCore

/// A source that covers only some of a text's words says which first, so
/// the tagged Septuagint's second source reads as the names' rather than as
/// a second account of every word.
struct TranslationSourceScopeTests {
    @Test func aScopeIsReadAndLeadsItsSourcesLine() {
        let json = #"""
            { "annotations": [
              { "part": "strongs", "source": "STEPBible’s TAGNT", "method": "matched to each word by machine", "scope": "most words" },
              { "part": "strongs", "source": "STEPBible’s TAHOT", "method": "each taking the Hebrew name’s number", "scope": " names the New Testament does not use " },
              { "part": "forms", "source": "an earlier module", "scope": "" } ] }
            """#
        let sources = LampTranslationSource.parsed(json)
        #expect(sources.map(\.scope) == ["most words", "names the New Testament does not use", nil])
        #expect(LampTranslationSource.disclosures(sources, translationName: "LXX", strongsKey: "G26") == [
            "Strong’s numbers in LXX come from two sources:\n"
                + "• Most words: STEPBible’s TAGNT, matched to each word by machine.\n"
                + "• Names the New Testament does not use: STEPBible’s TAHOT, each taking the Hebrew name’s number.",
            "Greek spellings in LXX come from an earlier module.",
        ])
    }

    /// A lone source with a scope says it in its sentence.
    @Test func aLoneSourcesScopeIsInItsSentence() {
        let source = LampTranslationSource(part: .strongs, source: "STEPBible’s TAHOT", scope: "names")
        #expect(source.disclosure(translationName: "LXX", strongsKey: "G26")
            == "Strong’s numbers in LXX for names come from STEPBible’s TAHOT.")
    }
}
