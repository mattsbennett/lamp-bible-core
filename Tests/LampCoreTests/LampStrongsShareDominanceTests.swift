import Testing
@testable import LampCore

/// When a share figure opens as a list, and how a companion's strength is
/// shown. Both apps read these, so they decide alike.
struct LampStrongsShareDominanceTests {
    @Test func oneCountOfNearlyAllIsDominated() {
        // G26 in the BSB: "love" 112 of 116.
        #expect(LampStrongsShare.isDominated([112, 1, 1, 1, 1]))
    }

    @Test func exactlyNinetyPercentIsDominated() {
        #expect(LampStrongsShare.isDominated([9, 1]))
    }

    @Test func aSpreadIsNotDominated() {
        // G26's forms: 35, 31, 28, 18, 1.
        #expect(!LampStrongsShare.isDominated([35, 31, 28, 18, 1]))
    }

    @Test func nothingCountedIsNotDominated() {
        #expect(!LampStrongsShare.isDominated([]))
        #expect(!LampStrongsShare.isDominated([0, 0]))
    }

    @Test func aSingleCountIsDominated() {
        #expect(LampStrongsShare.isDominated([4]))
    }

    @Test func strengthIsAShareOfTheStrongest() {
        let companions = [
            LampStrongsAnalysis.Companion(key: "G4102", sharedVerseCount: 24, verseCount: 227, lift: 7.9, keyness: 80),
            LampStrongsAnalysis.Companion(key: "G1343", sharedVerseCount: 18, verseCount: 86, lift: 7.3, keyness: 40),
            LampStrongsAnalysis.Companion(key: "G1223", sharedVerseCount: 42, verseCount: 560, lift: 2.6, keyness: 20),
        ]
        #expect(LampStrongsCompanionStrength.fraction(of: companions[0], among: companions) == 1)
        #expect(LampStrongsCompanionStrength.fraction(of: companions[1], among: companions) == 0.5)
        #expect(LampStrongsCompanionStrength.fraction(of: companions[2], among: companions) == 0.25)
    }

    @Test func strengthWithNothingStrongIsZero() {
        let weak = LampStrongsAnalysis.Companion(key: "G1", sharedVerseCount: 1, verseCount: 1, lift: 1, keyness: 0)
        #expect(LampStrongsCompanionStrength.fraction(of: weak, among: [weak]) == 0)
    }
}

/// What a Greek text "translates as" is its own Greek, said in Latin letters
/// as its forms are; English and Hebrew are left as they are.
struct LampGreekRenderingTransliterationTests {
    @Test func greekIsSaidInLatinLetters() {
        #expect(LampGreekTransliteration.latinIfGreek("ἀγάπην") == "agapēn")
        #expect(LampGreekTransliteration.latinIfGreek("ἀγάπῃ") == "agapēi")
    }

    @Test func englishAndHebrewAreLeftAlone() {
        #expect(LampGreekTransliteration.latinIfGreek("love") == nil)
        #expect(LampGreekTransliteration.latinIfGreek("אַהֲבָה") == nil)
        #expect(LampGreekTransliteration.latinIfGreek("") == nil)
    }

    @Test func theCompareLineSaysGreekAndLeavesEnglish() {
        let greek = LampStrongsAnalysis.Rendering(id: "a", text: "ἀγάπη", count: 36, variants: [])
        let english = LampStrongsAnalysis.Rendering(id: "b", text: "love", count: 112, variants: [])
        let blank = LampStrongsAnalysis.Rendering(id: "c", text: "", count: 2, variants: [])
        let analysis = LampStrongsAnalysis(
            key: "G26", translationID: "t", translationName: "T", translationAbbreviation: nil,
            wordCount: 0, taggedVerseCount: 0, occurrences: [], references: [],
            renderings: [greek, english, blank], forms: [], parsings: [], grammar: [],
            books: [], sections: [], companions: []
        )
        #expect(LampStrongsRenderingSummary.line(of: analysis) == "ἀγάπη agapē (36), love (112), — (2)")
    }
}

/// A text in the key's own language has no Translated As of its own: its
/// renderings are its spellings, the forms again.
struct LampStrongsOwnLanguageTests {
    private func analysis(_ key: String, _ renderings: [(String, Int)]) -> LampStrongsAnalysis {
        LampStrongsAnalysis(
            key: key, translationID: "t", translationName: "T", translationAbbreviation: nil,
            wordCount: 0, taggedVerseCount: 0, occurrences: [], references: [],
            renderings: renderings.enumerated().map {
                .init(id: String($0.offset), text: $0.element.0, count: $0.element.1, variants: [])
            },
            forms: [], parsings: [], grammar: [], books: [], sections: [], companions: []
        )
    }

    @Test func greekTextForAGreekKeyIsInItsOwnLanguage() {
        #expect(analysis("G26", [("ἀγάπη", 36), ("ἀγάπην", 33)]).isInKeysOwnLanguage)
    }

    @Test func hebrewTextForAHebrewKeyIsInItsOwnLanguage() {
        #expect(analysis("H160", [("אַהֲבָה", 30)]).isInKeysOwnLanguage)
    }

    @Test func anEnglishTranslationIsNot() {
        #expect(!analysis("G26", [("love", 112), ("beloved", 1)]).isInKeysOwnLanguage)
    }

    @Test func greekWordsInAHebrewKeysTextDoNotCount() {
        // The Septuagint tags Hebrew keys with Greek: a translation of them.
        #expect(!analysis("H160", [("ἀγάπη", 10)]).isInKeysOwnLanguage)
    }

    @Test func theCardOffersNoTranslatedAsChartForIt() {
        #expect(!LampStrongsGrouping.renderings.canDraw(analysis("G26", [("ἀγάπη", 36), ("ἀγάπην", 33)])))
        #expect(LampStrongsGrouping.renderings.canDraw(analysis("G26", [("love", 112), ("beloved", 1)])))
    }
}
