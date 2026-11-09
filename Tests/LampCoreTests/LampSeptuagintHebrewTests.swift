import Foundation
import Testing
@testable import LampCore

/// The Hebrew a Greek word renders in the Septuagint, as TBESG carries it.
///
/// Read straight from the lexicon's JSON, because what the apps show hangs on
/// three distinctions the shape makes quietly: a word with a number can be
/// followed to an entry, a word with only a stem cannot, and a word with
/// neither is not a word at all.
struct LampSeptuagintHebrewTests {
    private func read(_ json: String) -> [LampSeptuagintHebrew] {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return LampSeptuagintHebrew.list(from: object)
    }

    @Test func aWordIsReadWithItsNumberAndItsStem() {
        let hebrew = read("""
            [{"text": "\u{05D2}\u{05D9}\u{05DC}", "strongs": "H1523"},
             {"text": "\u{05E8}\u{05E0}\u{05DF}", "stem": "pi."}]
            """)
        #expect(hebrew.count == 2)
        #expect(hebrew[0].strongs == "H1523")
        #expect(hebrew[0].stem == nil)
        #expect(hebrew[1].stem == "pi.")
        // No number: the word is shown, and nothing can be followed from it.
        #expect(hebrew[1].strongs == nil)
    }

    /// The lexicon's numbers are padded in places, and a padded number finds
    /// no entry: H07941 is H7941. The same normalizing its links get.
    @Test func aPaddedNumberIsTheSameNumber() {
        #expect(read("""
            [{"text": "\u{05E9}\u{05DB}\u{05E8}", "strongs": "H07941"}]
            """).first?.strongs == "H7941")
    }

    @Test func anEntryWithNoWordToPrintIsNotOne() {
        let hebrew = read("""
            [{"strongs": "H160"}, {"text": "  "}, {"text": "\u{05D0}\u{05D4}\u{05D1}\u{05D4}"}]
            """)
        #expect(hebrew.map(\.text) == ["\u{05D0}\u{05D4}\u{05D1}\u{05D4}"])
        #expect(read("[]").isEmpty)
        #expect(LampSeptuagintHebrew.list(from: nil).isEmpty)
        #expect(LampSeptuagintHebrew.list(from: "not a list").isEmpty)
    }

    /// Every other dictionary carries no such note, and must decode as having
    /// none rather than failing to decode.
    @Test func aSenseWithoutTheNoteHasNoHebrew() {
        #expect(LampDictionarySense(definition: "a word").septuagintHebrew.isEmpty)
    }
}
