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
        #expect(english.convert(ref(19, 3, 1), to: original) == ref(19, 3, 2))
        #expect(original.convert(ref(19, 3, 9), to: english) == ref(19, 3, 8))
    }

    @Test func dividesJoelAndMalachiAsEachSchemeDoes() {
        #expect(english.convert(ref(29, 2, 28), to: original) == ref(29, 3, 1))
        #expect(english.convert(ref(29, 3, 1), to: original) == ref(29, 4, 1))
        #expect(english.convert(ref(39, 4, 1), to: original) == ref(39, 3, 19))
        #expect(original.convert(ref(39, 3, 24), to: english) == ref(39, 4, 6))
    }

    /// The Vulgate joins Psalms 9 and 10, so its 9:22 is the Hebrew's 10:1,
    /// and a verse whose number the Vulgate gives to something else has to
    /// come back as that, not as itself.
    @Test func followsTheVulgateThroughAPsalmItJoins() {
        #expect(english.convert(ref(19, 10, 1), to: vulgate) == ref(19, 9, 22))
        #expect(english.convert(ref(19, 10, 18), to: vulgate) == ref(19, 9, 39))
        #expect(vulgate.convert(ref(19, 9, 23), to: english) == ref(19, 10, 2))
    }

    @Test func leavesAVerseEveryoneNumbersAlikeAsItIs() {
        let john316 = ref(43, 3, 16)
        for scheme in LampVersification.Scheme.allCases {
            #expect(english.convert(john316, to: .standard(scheme)) == john316)
        }
    }

    /// The WEB ends Romans 14 with the doxology the English scheme numbers
    /// 16:25-27, and says so as a departure from the English scheme.
    @Test func takesATranslationsOwnDepartures() {
        let web = english.departing(by: ["ROM 14:24-26 = ROM 16:25-27"])
        #expect(web.convert(ref(45, 14, 24), to: english) == ref(45, 16, 25))
        #expect(english.convert(ref(45, 16, 27), to: web) == ref(45, 14, 26))
        #expect(web.convert(ref(45, 14, 23), to: english) == ref(45, 14, 23))
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
        #expect(septuagint.convert(ref(27, 3, 91), to: english) == ref(27, 3, 24))
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
