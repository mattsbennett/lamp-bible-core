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

/// Anchoring every piece in the text being drawn changes nothing drawn.
struct LampWritingReviewAnchoredTests {
    @Test func anchoredDrawsWhatTheRecordDraws() {
        let empty = LampWritingReview(writingID: "w")
        // A draft written whole, then turns over it, then the writer's own
        // edit and a clear, so the pieces are anchored in several texts.
        let first = "One two three four.\n\nFive six seven eight.\n\nNine ten eleven."
        var review = empty.markingAssistantChange(from: "", to: first)
        let second = "One TWO three four.\n\nFive six SEVEN eight.\n\nNine ten eleven."
        review = review.markingAssistantChange(from: first, to: second)
        let third = "One TWO three, four.\n\nFive six SEVEN eight, nine.\n\nNine ten ELEVEN."
        review = review.markingAssistantChange(from: second, to: third)
        let typed = "One TWO three, four and more.\n\nFive six SEVEN eight, nine.\n\nNine ten ELEVEN."
        review = review.carryingWriterEdit(from: third, to: typed)
        let five = (typed as NSString).range(of: "Five")
        review = review.clearing(five, in: typed)
        let anchored = review.anchored(in: typed)
        #expect(anchored.located(in: typed) == review.located(in: typed))
        #expect(anchored.highlightedRanges(in: typed) == review.highlightedRanges(in: typed))
        #expect(anchored.passageCount(in: typed) == review.passageCount(in: typed))
        #expect(anchored.markedMarkdown(in: typed) == review.markedMarkdown(in: typed))
        #expect(anchored.restorable(in: typed) == review.restorable(in: typed))
        let ranges = review.highlightedRanges(in: typed)
        #expect(anchored.changes(in: typed, ranges: ranges) == anchored.changes(in: typed, ranges: ranges))
        #expect(anchored.changes(in: typed, ranges: ranges) == review.changes(in: typed, ranges: ranges))
        // Every piece found is anchored in this text now.
        let here = LampWritingReview.digest(of: typed)
        #expect(anchored.marks.flatMap(\.pieces).contains { $0.anchoredIn == here })
    }
}

/// The marks a range touches, found by position, are those trying each
/// mark finds, in the same order.
struct LampWritingReviewTouchIndexTests {
    @Test func theIndexFindsWhatTryingEveryMarkFinds() {
        var seed: UInt64 = 17
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<2000 {
            let located: [LampWritingReview.Located] = (0..<random(12)).map { _ in
                let ranges = (0..<(1 + random(3))).map { _ in NSRange(location: random(60), length: random(4) == 0 ? 0 : random(15)) }
                return LampWritingReview.Located(id: UUID(), ranges: ranges)
            }
            let index = LampWritingReview.TouchIndex(located)
            for _ in 0..<8 {
                let range = NSRange(location: random(70), length: random(3) == 0 ? 0 : random(20))
                let expected = located.filter { $0.ranges.contains { LampWritingReview.touches($0, range) } }
                #expect(index.touching(range).map(\.id) == expected.map(\.id))
            }
        }
    }
}

/// A drawing is what each call gives on its own.
struct LampWritingReviewDrawingTests {
    @Test func aDrawingIsEachCallsAnswer() {
        let empty = LampWritingReview(writingID: "w")
        let first = "One two three four.\n\nFive six seven eight.\n\nNine ten eleven."
        var review = empty.markingAssistantChange(from: "", to: first)
        let second = "One TWO three four.\n\nFive six SEVEN eight.\n\nNine ten eleven."
        review = review.markingAssistantChange(from: first, to: second)
        let typed = "One TWO three four, more.\n\nFive six SEVEN eight.\n\nNine ten eleven."
        review = review.carryingWriterEdit(from: second, to: typed)
        let drawing = review.drawing(in: typed)
        let ranges = review.highlightedRanges(in: typed)
        #expect(drawing.ranges == ranges)
        #expect(drawing.passageCount == review.passageCount(in: typed))
        #expect(drawing.markedMarkdown == review.markedMarkdown(in: typed))
        #expect(drawing.restorable == review.restorable(in: typed))
        #expect(drawing.changes == review.changes(in: typed, ranges: ranges))
        let bare = review.drawing(in: typed, forPlacing: false)
        #expect(bare.ranges == ranges && bare.markedMarkdown == nil && bare.changes.isEmpty)
    }
}
