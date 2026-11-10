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
