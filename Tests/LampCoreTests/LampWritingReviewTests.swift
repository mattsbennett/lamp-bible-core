import Foundation
import Testing
@testable import LampCore

struct LampWritingReviewTests {
    private let empty = LampWritingReview(writingID: "w")

    private func marked(_ review: LampWritingReview, in text: String) -> [String] {
        let source = text as NSString
        return review.highlightedRanges(in: text).map { source.substring(with: $0) }
    }

    @Test func whatTheAssistantPutInIsMarked() {
        let old = "The quick brown fox jumps over the lazy dog."
        let new = "The slow red fox jumps over the lazy dog."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(marked(review, in: new) == ["slow red"])
    }

    @Test func aPlaceWordsWereOnlyTakenOutIsAPoint() {
        let old = "First sentence. Second sentence. Third sentence."
        let new = "First sentence. Third sentence."
        let review = empty.markingAssistantChange(from: old, to: new)
        let ranges = review.highlightedRanges(in: new)
        #expect(ranges.count == 1)
        #expect(ranges.first?.length == 0)
    }

    @Test func typingElsewhereMovesNoMarkAndChangesNothing() {
        let old = "Alpha beta gamma.\n\nDelta epsilon zeta."
        let agent = "Alpha BETA gamma.\n\nDelta epsilon zeta."
        let review = empty.markingAssistantChange(from: old, to: agent)
        let typed = "Alpha BETA gamma.\n\nDelta epsilon zeta eta theta."
        let carried = review.carryingWriterEdit(from: agent, to: typed)
        #expect(carried == review)
        #expect(marked(carried, in: typed) == ["BETA"])
    }

    @Test func whatTheWriterTypesInsideAMarkIsTheirs() {
        let old = "One two three."
        let agent = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: old, to: agent)
        #expect(marked(review, in: agent) == ["alpha beta gamma"])
        let typed = "One alpha mine beta gamma three."
        let carried = review.carryingWriterEdit(from: agent, to: typed)
        #expect(marked(carried, in: typed) == ["alpha", "beta gamma"])
    }

    @Test func clearingPartOfAMarkKeepsTheRest() {
        let old = "One two three."
        let new = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: old, to: new)
        let beta = (new as NSString).range(of: "beta")
        let cleared = review.clearing(beta, in: new)
        #expect(marked(cleared, in: new) == ["alpha", "gamma"])
        #expect(cleared.retired.count == 1)
    }

    @Test func aClearedPassageChangedAgainIsMarkedAgain() {
        let start = "A cleared sentence stands here."
        let first = "A reviewed sentence stands here."
        var review = empty.markingAssistantChange(from: start, to: first)
        review = review.clearingAll()
        #expect(review.isEmpty)
        let second = "A checked sentence stands here."
        review = review.markingAssistantChange(from: first, to: second)
        #expect(marked(review, in: second) == ["checked"])
        let reverted = review.clearingAll().markingAssistantChange(from: second, to: first)
        // The same words as a mark already retired, yet marked: a fresh id.
        #expect(marked(reverted, in: first) == ["reviewed"])
    }

    @Test func aLaterTurnCarriesStandingMarksAndJoinsOnesItRunsInto() {
        let start = "Paragraph one is here.\n\nParagraph two is here."
        let first = "Paragraph one is there.\n\nParagraph two is here."
        var review = empty.markingAssistantChange(from: start, to: first)
        let second = "Paragraph one is there.\n\nParagraph two was here."
        review = review.markingAssistantChange(from: first, to: second)
        #expect(marked(review, in: second) == ["there", "was"])
    }

    @Test func aStandingMarkKeepsItsIDWhenATurnLeavesItAlone() {
        let start = "Alpha beta.\n\nGamma delta."
        let first = "Alpha BETA.\n\nGamma delta."
        let review = empty.markingAssistantChange(from: start, to: first)
        let id = review.marks.first?.id
        let second = "Alpha BETA.\n\nGamma DELTA."
        let next = review.markingAssistantChange(from: first, to: second)
        #expect(next.marks.contains { $0.id == id })
        #expect(next.retired.isEmpty)
    }

    @Test func twoDevicesClearingDifferentPassagesBothKeepTheirClears() {
        let old = "Alpha beta gamma.\n\nDelta epsilon zeta."
        let new = "Alpha BETA gamma.\n\nDelta EPSILON zeta."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.marks.count == 2)
        let phone = review.clearing((new as NSString).range(of: "BETA"), in: new)
        let mac = review.clearing((new as NSString).range(of: "EPSILON"), in: new)
        let merged = phone.merged(with: mac)
        #expect(merged.isEmpty)
        #expect(merged == mac.merged(with: phone))
    }

    @Test func aClearRacingANewTurnKeepsBoth() {
        let old = "Alpha beta gamma.\n\nDelta epsilon zeta."
        let new = "Alpha BETA gamma.\n\nDelta epsilon zeta."
        let review = empty.markingAssistantChange(from: old, to: new)
        let phone = review.clearing((new as NSString).range(of: "BETA"), in: new)
        let later = "Alpha BETA gamma.\n\nDelta EPSILON zeta."
        let mac = review.markingAssistantChange(from: new, to: later)
        let merged = phone.merged(with: mac)
        #expect(marked(merged, in: later) == ["EPSILON"])
    }

    @Test func theFileIsTheSameBytesForTheSameRecord() throws {
        let review = empty.markingAssistantChange(from: "a b c", to: "a x c", at: Date(timeIntervalSince1970: 1))
        let shuffled = LampWritingReview(writingID: "w", marks: review.marks.reversed(), retired: review.retired.reversed())
        #expect(try review.encoded() == shuffled.encoded())
        #expect(try LampWritingReview.decoded(from: review.encoded()) == review)
    }

    @Test func pruningDropsOnlyOldRetirements() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 1_000)
        let review = LampWritingReview(writingID: "w", retired: [
            .init(id: UUID(), retiredAt: old), .init(id: UUID(), retiredAt: recent),
        ])
        #expect(review.pruningRetirements(before: Date(timeIntervalSince1970: 500)).retired.count == 1)
    }

    @Test func aMarkWhoseWordsWereRewrittenIsNotDrawn() {
        let review = empty.markingAssistantChange(from: "Keep this one.", to: "Keep that one.")
        #expect(marked(review, in: "Something else entirely.").isEmpty)
    }

    @Test func aPointKeepsItsPlaceWhileTheWriterTypesElsewhere() {
        let old = "Keep this. Drop this. Keep that."
        let agent = "Keep this. Keep that."
        let review = empty.markingAssistantChange(from: old, to: agent)
        let typed = "Intro. Keep this. Keep that."
        let carried = review.carryingWriterEdit(from: agent, to: typed)
        let point = carried.highlightedRanges(in: typed)
        #expect(point.count == 1)
        #expect(point.first?.length == 0)
        #expect(point.first.map { (typed as NSString).substring(to: $0.location) }?.hasSuffix("Intro. Keep this. ") == true)
    }

    @Test func clearingAParagraphClearsItsPointsToo() {
        let old = "Keep this. Drop this. Keep that.\n\nNext paragraph."
        let agent = "Keep this. Keep that.\n\nNext paragraph."
        let review = empty.markingAssistantChange(from: old, to: agent)
        let paragraph = (agent as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        #expect(review.clearing(paragraph, in: agent).isEmpty)
    }

    @Test func aWholeRewriteOfALongDraftIsQuick() {
        let words = (0..<6_000).map { "word\($0 % 997)" }
        let old = words.joined(separator: " ")
        let new = words.reversed().joined(separator: " ")
        let start = Date()
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(!review.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
