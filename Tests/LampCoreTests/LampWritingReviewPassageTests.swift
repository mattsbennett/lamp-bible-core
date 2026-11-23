import Foundation
import Testing
@testable import LampCore

/// The count a writer is shown: passages they can see, not marks stored.
struct LampWritingReviewPassageTests {
    private let empty = LampWritingReview(writingID: "w")

    @Test func turnsOverMarkedTextAddNoPassages() {
        // A draft written from nothing is marked whole; turns that then
        // change words inside it add marks, and nothing to read.
        let first = "One two three four five six.\n\nSeven eight nine ten."
        var review = empty.markingAssistantChange(from: "", to: first)
        #expect(review.passageCount(in: first) == 2)
        let second = "One TWO three four FIVE six.\n\nSeven eight NINE ten."
        review = review.markingAssistantChange(from: first, to: second)
        let third = "One TWO three, four FIVE six.\n\nSeven EIGHT NINE ten."
        review = review.markingAssistantChange(from: second, to: third)
        #expect(review.marks.count > 2)
        #expect(review.passageCount(in: third) == 2)
    }

    @Test func unmarkedWordsPartPassagesAndPunctuationDoesNot() {
        let old = "The cat sat on the mat today."
        // Two changes with "on the" between them: two passages.
        let apart = "The dog sat on the rug today."
        #expect(empty.markingAssistantChange(from: old, to: apart).passageCount(in: apart) == 2)
        // Two drawn ranges with only ", " between them: one.
        let near = "Alpha BETA, GAMMA delta." as NSString
        let ranges = [near.range(of: "BETA"), near.range(of: "GAMMA")]
        #expect(LampWritingReview.passages(ranges, in: near).count == 1)
        // With a word between them: two.
        let words = "Alpha BETA and GAMMA delta." as NSString
        #expect(LampWritingReview.passages([words.range(of: "BETA"), words.range(of: "GAMMA")], in: words).count == 2)
    }

    @Test func aMarkAcrossParagraphsIsOnePassageInEach() {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\n  \nThird."
        let ranges = [NSRange(location: 0, length: (text as NSString).length)]
        #expect(LampWritingReview.passages(ranges, in: text as NSString).count == 3)
    }

    @Test func aPlaceWordsWereTakenOutCountsOnlyApartFromAPassage() {
        let old = "Keep this. Drop this. Keep that."
        let new = "Keep this. Keep that."
        #expect(empty.markingAssistantChange(from: old, to: new).passageCount(in: new) == 1)
        let ranges = [NSRange(location: 0, length: 4), NSRange(location: 4, length: 0)]
        #expect(LampWritingReview.passages(ranges, in: "Keep this." as NSString).count == 1)
    }

    @Test func aPointDoesNotCarryAPassageOverABlankLine() {
        // From Codex's review: "A", a point on the blank line, "B".
        let ranges = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 0), NSRange(location: 3, length: 1)]
        #expect(LampWritingReview.passages(ranges, in: "A\n\nB" as NSString).count == 2)
    }

    @Test func paragraphsPartWhateverTheLineEndings() {
        for text in ["First.\r\n\r\nSecond.", "First.\r\rSecond.", "First.\n\nSecond."] {
            let ranges = [NSRange(location: 0, length: (text as NSString).length)]
            #expect(LampWritingReview.passages(ranges, in: text as NSString).count == 2, "\(text.debugDescription)")
        }
        // A single line ending is not a paragraph's end.
        #expect(LampWritingReview.passages([NSRange(location: 0, length: 14)], in: "First.\r\nSecond" as NSString).count == 1)
    }

    @Test func nothingMarkedIsNothingToRead() {
        #expect(empty.passageCount(in: "Anything at all.") == 0)
    }
}
