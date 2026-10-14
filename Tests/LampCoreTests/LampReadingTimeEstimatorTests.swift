import Testing
@testable import LampCore

struct LampReadingTimeEstimatorTests {
    @Test func roundsNonemptyReadingsUpToWholeMinutes() {
        #expect(LampReadingTimeEstimator.minutes(wordCount: 451, wordsPerMinute: 225) == 3)
        #expect(LampReadingTimeEstimator.minutes(wordCount: 100, wordsPerMinute: 183.5) == 1)
        #expect(LampReadingTimeEstimator.description(wordCount: 100, wordsPerMinute: 225) == "1 min")
        #expect(LampReadingTimeEstimator.description(wordCount: 0, wordsPerMinute: 225) == "0 min")
        #expect(LampReadingTimeEstimator.minutes(wordCount: -1, wordsPerMinute: 225) == 0)
    }

    @Test(arguments: [0.0, -100.0, Double.nan, Double.infinity, -Double.infinity])
    func malformedSyncedRatesCannotCrashOrProduceAnEmptyEstimate(rate: Double) {
        #expect(LampReadingTimeEstimator.minutes(wordCount: 12, wordsPerMinute: rate) == 12)
        #expect(LampReadingTimeEstimator.minutes(wordCount: 0, wordsPerMinute: rate) == 0)
        #expect(LampReadingTimeEstimator.minutes(wordCount: Int.max, wordsPerMinute: rate) == Int.max)
    }

    @Test func countsWordsAcrossWhitespaceWithoutCountingEmptyComponents() {
        #expect(LampReadingTimeEstimator.wordCount(in: "  Faith\tand\nhope\u{00A0}remain. ") == 4)
        #expect(LampReadingTimeEstimator.wordCount(in: " \n\t") == 0)
    }
}
