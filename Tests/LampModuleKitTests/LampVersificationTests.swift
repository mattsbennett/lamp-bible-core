import Foundation
import Testing
@testable import LampModuleKit

/// Translations number some verses differently: a psalm's title is verse 1 in
/// the Hebrew and unnumbered in English, Joel and Malachi divide their
/// chapters differently, the Vulgate joins Psalms 9 and 10. Reading two
/// translations side by side has to pair the same verse, whatever each
/// numbers it.
struct LampVersificationTests {
    private func ref(_ book: Int, _ chapter: Int, _ verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    private let english = LampVersification.standard(.english)
    private let original = LampVersification.standard(.original)
    private let vulgate = LampVersification.standard(.vulgate)

    @Test func numbersAPsalmsVersesAfterItsTitle() {
        // English Psalm 3:1 is the Hebrew's 3:2: the title is the Hebrew's 3:1.
        #expect(english.opens(ref(19, 3, 1), in: original) == ref(19, 3, 2))
        #expect(original.opens(ref(19, 3, 9), in: english) == ref(19, 3, 8))
    }

    /// A psalm's title is one verse in an English-numbered text and two in
    /// the Septuagint, so it is the case a single answer cannot carry.
    ///
    /// The English scheme's own file says it numbers titles verse 0 — "many
    /// of the subscripts that are part of verses 1,2 in the original text end
    /// up as verse #0 in English translations" — and maps Psalm 51:0 to both
    /// the original's 51:1 and 51:2. Before `counterparts`, only the first
    /// survived: a Hebrew word standing in "when Nathan the prophet came to
    /// him" was crossed against "To the choirmaster, a psalm of David", which
    /// is the wrong half of the title rather than a missing verse.
    @Test func givesBothHalvesOfAPsalmsTitle() {
        let septuagint = LampVersification.standard(.septuagint)
        #expect(english.counterparts(of: ref(19, 51, 0), in: septuagint)
            == [ref(19, 50, 1), ref(19, 50, 2)])
        // The verses after it are unmoved, and still one apiece.
        #expect(english.counterparts(of: ref(19, 51, 1), in: septuagint) == [ref(19, 50, 3)])
        #expect(english.opens(ref(19, 51, 1), in: septuagint) == ref(19, 50, 3))
        // A title the Septuagint numbers as one verse stays one.
        #expect(english.counterparts(of: ref(19, 3, 0), in: septuagint) == [ref(19, 3, 1)])
        // `opens` is the lossy question, and says so by answering with one.
        #expect(english.opens(ref(19, 51, 0), in: septuagint) == ref(19, 50, 1))
        // An ordinary verse is one counterpart, never an empty list.
        #expect(english.counterparts(of: ref(43, 3, 16), in: septuagint) == [ref(43, 3, 16)])
    }

    @Test func dividesJoelAndMalachiAsEachSchemeDoes() {
        #expect(english.opens(ref(29, 2, 28), in: original) == ref(29, 3, 1))
        #expect(english.opens(ref(29, 3, 1), in: original) == ref(29, 4, 1))
        #expect(english.opens(ref(39, 4, 1), in: original) == ref(39, 3, 19))
        #expect(original.opens(ref(39, 3, 24), in: english) == ref(39, 4, 6))
    }

    /// The Vulgate joins Psalms 9 and 10, so its 9:22 is the Hebrew's 10:1,
    /// and a verse whose number the Vulgate gives to something else has to
    /// come back as that, not as itself.
    @Test func followsTheVulgateThroughAPsalmItJoins() {
        #expect(english.opens(ref(19, 10, 1), in: vulgate) == ref(19, 9, 22))
        #expect(english.opens(ref(19, 10, 18), in: vulgate) == ref(19, 9, 39))
        #expect(vulgate.opens(ref(19, 9, 23), in: english) == ref(19, 10, 2))
    }

    @Test func leavesAVerseEveryoneNumbersAlikeAsItIs() {
        let john316 = ref(43, 3, 16)
        for scheme in LampVersification.Scheme.allCases {
            #expect(english.opens(john316, in: .standard(scheme)) == john316)
        }
    }

    /// The WEB ends Romans 14 with the doxology the English scheme numbers
    /// 16:25-27, and says so as a departure from the English scheme.
    @Test func takesATranslationsOwnDepartures() {
        let web = english.departing(by: ["ROM 14:24-26 = ROM 16:25-27"])
        #expect(web.opens(ref(45, 14, 24), in: english) == ref(45, 16, 25))
        #expect(english.opens(ref(45, 16, 27), in: web) == ref(45, 14, 26))
        #expect(web.opens(ref(45, 14, 23), in: english) == ref(45, 14, 23))
    }

    /// A lexicon keyed to the Hebrew's numbering cites verses English numbers
    /// differently, and some it miscites outright; a builder mapping them in
    /// has to tell the two apart and find a whole chapter's end.
    @Test func tellsAVerseASchemeNumbersFromOneItDoesNot() {
        #expect(original.numbers(ref(4, 17, 27)))
        #expect(!english.numbers(ref(4, 17, 27)))
        #expect(original.opens(ref(4, 17, 27), in: english) == ref(4, 17, 12))
        #expect(!original.numbers(ref(5, 42, 1)), "Deuteronomy has 34 chapters")
        #expect(!original.numbers(ref(5, 20, 22)), "Deuteronomy 20 has 20 verses")
        #expect(!original.numbers(ref(19, 3, 0)))
        #expect(original.lastVerse(ofChapterOf: ref(19, 119, 1)) == 176)
        #expect(original.lastVerse(ofChapterOf: ref(29, 4, 1)) == 21)
        #expect(english.lastVerse(ofChapterOf: ref(29, 4, 1)) == nil)
    }

    @Test func readsEverySchemeSILPublishes() {
        for scheme in LampVersification.Scheme.allCases {
            let counts = LampVersification.standard(scheme).verseCounts
            #expect(counts[1]?[1] == 31, "Genesis 1 in \(scheme)")
            // The Septuagint numbers Nehemiah as the end of Ezra.
            let missing = (1...66).filter { counts[$0] == nil }
            #expect(missing == (scheme == .septuagint ? [16] : []), "books Lamp numbers, in \(scheme)")
        }
        #expect(english.verseCounts[29]?.count == 3)
        #expect(original.verseCounts[29]?.count == 4)
    }

    @Test func recognisesASchemeFromItsChapterLengths() {
        let hebrewJoel: [Int: [Int: Int]] = [29: [1: 20, 2: 27, 3: 5, 4: 21], 19: [3: 9]]
        #expect(LampVersification.likeliestScheme(forVerseCounts: hebrewJoel) == .original)
        let englishJoel: [Int: [Int: Int]] = [29: [1: 20, 2: 32, 3: 21], 19: [3: 8]]
        #expect(LampVersification.likeliestScheme(forVerseCounts: englishJoel) == .english)
        #expect(LampVersification.likeliestScheme(forVerseCounts: [:]) == .english)
    }

    /// The Septuagint numbers Greek Esther and Daniel, which a Lamp
    /// translation keys as Esther and Daniel; its Daniel 3 runs on through
    /// the Prayer of Azariah, so its verse 91 is the Hebrew's 24.
    @Test func readsTheSeptuagintsDanielAsDaniel() {
        let septuagint = LampVersification.standard(.septuagint)
        #expect(septuagint.verseCounts[27]?[3] != nil)
        #expect(septuagint.opens(ref(27, 3, 91), in: english) == ref(27, 3, 24))
        // Elsewhere Greek Esther is a book of its own, not Esther.
        #expect(english.verseCounts[17]?[10] == 3)
    }

    @Test func readsTheNamesModuleSourcesGiveASchemes() {
        #expect(LampVersification.Scheme(moduleValue: nil) == .english)
        #expect(LampVersification.Scheme(moduleValue: "standard") == .english)
        #expect(LampVersification.Scheme(moduleValue: "kjv") == .english)
        #expect(LampVersification.Scheme(moduleValue: "Vulgate") == .vulgate)
        #expect(LampVersification.Scheme(moduleValue: "org") == .original)
        #expect(LampVersification.Scheme(moduleValue: "klingon") == nil)
    }
}
