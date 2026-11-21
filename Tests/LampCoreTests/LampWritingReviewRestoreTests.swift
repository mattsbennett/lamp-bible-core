import Foundation
import Testing
@testable import LampCore

/// Putting the assistant's wording back.
///
/// Every test here is a round trip: mark a change, put it back, and compare
/// the text with the one the writer started from. That is the only check
/// that catches the thing the record makes easy to get wrong — a mark covers
/// the words a *reader* sees changed, trimmed of the spaces around them, so
/// a restore that replaces only the mark leaves the space the assistant put
/// in and reads "One  two", or leaves an empty paragraph behind. Nothing
/// that only inspects the record would have noticed.
struct LampWritingReviewRestoreTests {
    private let empty = LampWritingReview(writingID: "w")

    private func marked(_ review: LampWritingReview, in text: String) -> [String] {
        let source = text as NSString
        return review.highlightedRanges(in: text).map { source.substring(with: $0) }
    }

    /// A surface applying a plan. The edits arrive last first, so each
    /// range still means in the text what it meant when the plan was made.
    private func applying(_ plan: LampWritingReview.RestorePlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func whole(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    /// Restores everything marked in `text`, as a surface and its host would
    /// between them; nil where the record refuses.
    private func restoring(
        _ review: LampWritingReview, in text: String, selecting range: NSRange? = nil
    ) -> (review: LampWritingReview, text: String)? {
        guard let plan = review.restorePlan(for: range ?? whole(text), in: text) else { return nil }
        let after = applying(plan, to: text)
        return (review.restoringWording(plan, from: text, to: after), after)
    }

    // MARK: The round trip

    @Test func wordsPutInComeBackOutWithTheSpaceTheyCameWith() throws {
        let old = "One two."
        let new = "One alpha two."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(marked(review, in: new) == ["alpha"])
        let put = try #require(restoring(review, in: new))
        // Not "One  two.": the mark covers "alpha", the restore takes the
        // space the assistant put in with it.
        #expect(put.text == old)
        #expect(put.review.marks.isEmpty)
    }

    @Test func aParagraphPutInComesBackOutWithoutLeavingAnEmptyOne() throws {
        let old = "Alpha stands here.\n\nBeta stands here."
        let new = "Alpha stands here.\n\nMiddle stands here.\n\nBeta stands here."
        let review = empty.markingAssistantChange(from: old, to: new)
        let put = try #require(restoring(review, in: new))
        #expect(put.text == old)
    }

    @Test func wordsReplacedComeBackAndTheMarkIsRetired() throws {
        let old = "The quick brown fox jumps."
        let new = "The slow red fox jumps."
        let review = empty.markingAssistantChange(from: old, to: new)
        let id = try #require(review.marks.first?.id)
        let put = try #require(restoring(review, in: new))
        #expect(put.text == old)
        #expect(put.review.marks.isEmpty)
        #expect(put.review.retired.map(\.id) == [id])
        #expect(put.review.wordings.isEmpty, "the mark is gone, so what stood in its place is nothing")
    }

    @Test func wordsTakenOutComeBackWhereTheyStood() throws {
        let old = "First sentence. Second sentence. Third sentence."
        let new = "First sentence. Third sentence."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.highlightedRanges(in: new).first?.length == 0, "a point: nothing was put in")
        let put = try #require(restoring(review, in: new))
        #expect(put.text == old)
    }

    @Test func aRestoreIsRecordedForTheAssistantToBeToldOf() throws {
        let turn = UUID()
        let old = "The quick brown fox."
        let new = "The slow red fox."
        let review = empty.markingAssistantChange(from: old, to: new, turnID: turn)
        let put = try #require(restoring(review, in: new))
        let restoration = try #require(put.review.restorations.first)
        #expect(restoration.turnID == turn)
        #expect(restoration.restored == "quick brown")
        #expect(restoration.discarded == "slow red")
    }

    // MARK: What is not offered

    @Test func aPassageTheWriterHasTypedIntoIsNotOffered() throws {
        let old = "One two three."
        let new = "One alpha beta three."
        let review = empty.markingAssistantChange(from: old, to: new)
        let typed = "One alpha mine beta three."
        let carried = review.carryingWriterEdit(from: new, to: typed)
        #expect(marked(carried, in: typed) == ["alpha", "beta"], "their words are not marked")
        // Inside it nothing can tell their words from the assistant's, so a
        // restore would take both.
        #expect(carried.restorable(in: typed).isEmpty)
        #expect(restoring(carried, in: typed) == nil)
    }

    @Test func aMarkPartlyReadIsNotOffered() throws {
        let old = "One two three."
        let new = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: old, to: new)
        let cleared = review.clearing((new as NSString).range(of: "beta"), in: new)
        #expect(!cleared.clearances.isEmpty)
        #expect(cleared.restorable(in: new).isEmpty)
    }

    @Test func aSelectionHoldingOneMarkThatCannotComeBackIsRefusedWhole() throws {
        let old = "Alpha stands here.\n\nBeta stands here."
        let new = "Alpha sits here.\n\nBeta rests quietly here."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.restorable(in: new).count == 2)
        // Typed *into* the second mark, which splits it: a word of it is
        // now the writer's and a restore cannot tell which. Typing after a
        // mark would leave it exactly as it was, and still offered.
        let typed = "Alpha sits here.\n\nBeta rests very quietly here."
        let carried = review.carryingWriterEdit(from: new, to: typed)
        #expect(marked(carried, in: typed) == ["sits", "rests", "quietly"])
        #expect(carried.restorable(in: typed).count == 1)
        // Neither is offered together, rather than one quietly left behind.
        #expect(carried.restorePlan(for: whole(typed), in: typed) == nil)
        // The one that still stands as it was comes back on its own.
        let sits = (typed as NSString).range(of: "sits")
        let put = try #require(restoring(carried, in: typed, selecting: sits))
        #expect(put.text == "Alpha stands here.\n\nBeta rests very quietly here.")
    }

    @Test func aMarkMadeBeforeWordingsWereKeptIsNotOffered() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        var review = empty.markingAssistantChange(from: old, to: new)
        // What a record made by a core that knew nothing of them looks like.
        review.wordings = []
        #expect(review.restorable(in: new).isEmpty)
        #expect(marked(review, in: new) == ["slow red"], "still to be read, only not to be undone")
    }

    // MARK: Words put back that were never read

    @Test func wordsPutBackThatWereNeverReadAreMarkedAgain() throws {
        let start = "A sentence stands here."
        let first = "A changed sentence stands here."
        var review = empty.markingAssistantChange(from: start, to: first)
        // A second turn writing over the first turn's unread word: what a
        // restore puts back is the assistant's own work, never read.
        let second = "A rewritten sentence stands here."
        review = review.markingAssistantChange(from: first, to: second)
        #expect(marked(review, in: second) == ["rewritten"])
        #expect(review.wordings.contains { $0.wasUnread })
        let put = try #require(restoring(review, in: second))
        #expect(put.text == first)
        #expect(marked(put.review, in: put.text) == ["changed"], "nobody has read it yet")
    }

    @Test func wordsPutBackThatWereReadStayRead() throws {
        let start = "A sentence stands here."
        let first = "A changed sentence stands here."
        var review = empty.markingAssistantChange(from: start, to: first).clearingAll()
        let second = "A rewritten sentence stands here."
        review = review.markingAssistantChange(from: first, to: second)
        #expect(review.wordings.allSatisfy { !$0.wasUnread })
        let put = try #require(restoring(review, in: second))
        #expect(put.text == first)
        #expect(marked(put.review, in: put.text).isEmpty, "it was read before, and it is read now")
    }

    // MARK: Crossing devices and versions

    @Test func aCopyWrittenByACoreThatKnowsNothingOfWordingsDoesNotStripThem() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(!review.wordings.isEmpty)
        // Exactly what an older writer leaves: the same marks, at the same
        // version, with the keys it does not know dropped.
        var stripped = review
        stripped.wordings = []
        stripped.restorations = []
        // A union, so neither side can lose it. On a field of the mark this
        // would turn on `later(_:_:)`, which at an equal version takes the
        // greater encoding — and the copy carrying one more key is always
        // the smaller, so the stripped copy would win both ways round.
        #expect(review.merged(with: stripped).wordings == review.wordings)
        #expect(stripped.merged(with: review).wordings == review.wordings)
    }

    @Test func aRecordWithNothingToSayHereIsTheBytesItAlwaysWas() throws {
        let review = empty.markingAssistantChange(from: "One two.", to: "One alpha two.")
        var bare = review
        bare.wordings = []
        bare.restorations = []
        let json = try #require(String(data: try bare.encoded(), encoding: .utf8))
        #expect(!json.contains("wordings"))
        #expect(!json.contains("restorations"))
    }

    @Test func aRecordWrittenBeforeWordingsStillReads() throws {
        let json = """
            {"clearances":[],"formatVersion":1,"marks":[],"retired":[],"writingID":"w"}
            """
        let review = try LampWritingReview.decoded(from: Data(json.utf8))
        #expect(review.wordings.isEmpty)
        #expect(review.restorations.isEmpty)
        #expect(review.writingID == "w")
    }

    @Test func aRestoreSurvivesTheTripThroughTheFile() throws {
        let review = empty.markingAssistantChange(from: "The quick brown fox.", to: "The slow red fox.")
        let read = try LampWritingReview.decoded(from: try review.encoded())
        #expect(read == review)
        #expect(read.restorable(in: "The slow red fox.").map(\.restored) == ["quick brown"])
    }

    @Test func aRestoreDropsRestorationsThatHaveHadTheirDay() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        var review = empty.markingAssistantChange(from: old, to: new)
        // More than are kept, and one from long enough ago to go.
        let stale = Date().addingTimeInterval(-LampWritingReview.restorationWindow - 60)
        review.restorations = (0..<LampWritingReview.restorationsKept + 5).map {
            .init(markID: UUID(), turnID: nil, restored: "a", discarded: "b",
                  restoredAt: Date().addingTimeInterval(-Double($0)))
        } + [.init(markID: UUID(), turnID: nil, restored: "old", discarded: "older", restoredAt: stale)]
        let put = try #require(restoring(review, in: new))
        #expect(put.review.restorations.count == LampWritingReview.restorationsKept)
        #expect(!put.review.restorations.contains { $0.restored == "old" })
        // The one just made is among them, which is the point of keeping any.
        #expect(put.review.restorations.contains { $0.restored == "quick brown" })
    }

    @Test func restorationsAreNotKeptForEver() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        let review = empty.markingAssistantChange(from: old, to: new)
        let put = try #require(restoring(review, in: new))
        #expect(!put.review.restorations.isEmpty)
        #expect(put.review.pruning(before: Date().addingTimeInterval(60)).restorations.isEmpty)
    }
}
