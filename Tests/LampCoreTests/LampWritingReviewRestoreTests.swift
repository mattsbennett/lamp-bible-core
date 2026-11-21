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

    /// A restore touches only what it puts back.
    ///
    /// The text it is made in can be a moment older or newer than the
    /// latest marks — the visual page's, pressed before a turn's draft
    /// reached it — and a mark with no words in that text would otherwise
    /// be carried to text that has gone, or retired outright, by a restore
    /// of some other passage.
    @Test func aRestoreLeavesEveryOtherMarkExactlyAsItWas() throws {
        let start = "Alpha stands here.\n\nBeta stands here."
        let first = "Alpha sits here.\n\nBeta stands here."
        var review = empty.markingAssistantChange(from: start, to: first)
        // A second turn the page has not been shown: its mark is anchored
        // in text the restore below is not made in.
        let second = "Alpha sits here.\n\nBeta rests here."
        review = review.markingAssistantChange(from: first, to: second)
        let untouched = try #require(review.marks.first { $0.pieces[0].text == "rests" })
        // The restore is made in the older text, as the page would.
        let sits = (first as NSString).range(of: "sits")
        let plan = try #require(review.restorePlan(for: sits, in: first))
        let after = applying(plan, to: first)
        let put = review.restoringWording(plan, from: first, to: after)
        #expect(put.marks.contains(untouched), "the mark the restore never touched is byte for byte as it was")
        #expect(put.retired.count == 1)
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

    /// A writer told no is owed which no it was.
    @Test func thereAreTwoWaysToBeToldNoAndTheyAreNotTheSame() throws {
        let old = "One two three."
        let new = "One alpha beta three."
        let review = empty.markingAssistantChange(from: old, to: new)
        // A caret standing where the assistant changed nothing.
        #expect(review.restoring(NSRange(location: 0, length: 0), in: new) == .nothingTouched)
        // A caret standing in the passage it changed.
        let inside = NSRange(location: ((new as NSString).range(of: "alpha")).location + 1, length: 0)
        guard case .plan = review.restoring(inside, in: new) else {
            Issue.record("a caret in a marked passage offers it")
            return
        }
        // The same caret once the writer has typed into that passage.
        let typed = "One alpha mine beta three."
        let carried = review.carryingWriterEdit(from: new, to: typed)
        #expect(carried.restoring(inside, in: typed) == .notExact)
        // And a passage whose wording was never kept is a different no: the
        // writer did nothing to it, so they are not told that they did.
        var stripped = review
        stripped.wordings = []
        #expect(stripped.restoring(inside, in: new) == .notKept)
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

    // MARK: Asked about many at once, and asked by id

    @Test func askingAboutEveryPassageGivesTheSameAnswersAsAskingOneByOne() throws {
        let old = "Alpha stands here.\n\nBeta stands here.\n\nGamma stands here."
        let new = "Alpha sits here.\n\nBeta stands here.\n\nGamma rests here."
        var review = empty.markingAssistantChange(from: old, to: new)
        // One of them typed into, one with its wording gone: all three
        // answers in one text.
        let typed = "Alpha sits calmly here.\n\nBeta stands here.\n\nGamma rests here."
        review = review.carryingWriterEdit(from: new, to: typed)
        let ranges = review.highlightedRanges(in: typed)
        let together = review.restoring(ranges, in: typed)
        #expect(together.map(\.outcome) == ranges.map { review.restoring($0, in: typed) })
        #expect(together.allSatisfy { !$0.marks.isEmpty }, "each names the marks its range stands in")
    }

    @Test func aRangeThatStandsInNoMarkNamesNoMarks() throws {
        let review = empty.markingAssistantChange(from: "One two.", to: "One alpha two.")
        let answers = review.restoring([NSRange(location: 0, length: 1)], in: "One alpha two.")
        #expect(answers[0].marks.isEmpty)
        #expect(answers[0].outcome == .nothingTouched)
    }

    /// A surface that cannot hand a range back exactly — the visual page
    /// widens one to a whole link — asks for the passages by id instead.
    @Test func marksCanBeAskedForByIDRatherThanByRange() throws {
        let old = "The quick brown fox jumps."
        let new = "The slow red fox jumps."
        let review = empty.markingAssistantChange(from: old, to: new)
        let id = try #require(review.marks.first?.id)
        guard case .plan(let plan) = review.restoring(marks: [id], in: new) else {
            Issue.record("the mark can be put back")
            return
        }
        #expect(plan.marks == [id])
        #expect(applying(plan, to: new) == old)
    }

    /// Everything between the marks named goes back with them, so a stretch
    /// that holds a third marked passage is refused: what the writer was
    /// shown would not be what they got.
    @Test func askingByIDRefusesWhenTheStretchHoldsAnotherMark() throws {
        let old = "Alpha one here. Beta two here. Gamma three here."
        let new = "Alpha ONE here. Beta TWO here. Gamma THREE here."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.marks.count == 3)
        let ends = review.located(in: new)
        let first = try #require(ends.first?.id)
        let last = try #require(ends.last?.id)
        #expect(review.restoring(marks: [first, last], in: new) == .notExact)
        // The pair either side of nothing else is fine.
        let middle = ends[1].id
        guard case .plan = review.restoring(marks: [first, middle], in: new) else {
            Issue.record("two marks with nothing marked between them go back together")
            return
        }
    }

    @Test func askingByIDForAMarkThatHasGoneIsRefused() throws {
        let review = empty.markingAssistantChange(from: "One two.", to: "One alpha two.")
        #expect(review.restoring(marks: [UUID()], in: "One alpha two.") == .notExact)
        #expect(review.restoring(marks: [], in: "One alpha two.") == .nothingTouched)
    }

    // MARK: Passages against each other

    /// Two devices can mark one removal under their own ids. Merged, both
    /// are points at the same place, and both hold the words that were
    /// taken out — so putting them back put them back twice.
    @Test func twoMarksForOneRemovalDoNotPutTheWordsBackTwice() throws {
        let old = "One two three."
        let new = "One three."
        let mine = empty.markingAssistantChange(from: old, to: new)
        let theirs = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let merged = mine.merged(with: theirs)
        #expect(merged.marks.count == 2, "one removal, marked by each device under its own id")
        #expect(merged.restorable(in: new).count == 2, "and each can be put back on its own")
        // Together they cannot: "One two two three." is not a restore.
        #expect(merged.restorePlan(for: whole(new), in: new) == nil)
        #expect(merged.restoring(whole(new), in: new) == .notExact)
    }

    /// Two passages that overlap stop each other, which is neither the
    /// writer's doing nor a wording that was never kept — and `notKept` is
    /// the answer said silently, so it would hide this altogether.
    @Test func passagesThatOverlapAreRefusedAsNotExactRatherThanSilently() throws {
        let text = "The slow red fox."
        let wide = empty.markingAssistantChange(from: "The quick brown fox.", to: text)
        let narrow = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "The slow brown fox.", to: text)
        let merged = wide.merged(with: narrow)
        #expect(merged.marks.count == 2)
        #expect(merged.restorable(in: text).count == 2, "each is offered on its own")
        #expect(merged.restorePlan(for: whole(text), in: text) == nil, "together they overlap")
        #expect(merged.restoring(whole(text), in: text) == .notExact)
    }

    /// The words put back are marked again where they landed, not where
    /// they stood before the edits.
    ///
    /// Two passages put back at once: the first changes length, so
    /// everything after it moves, and a position taken from before the
    /// edits names the wrong place in the finished text. The position is
    /// worked out from the plan rather than searched for — searching finds
    /// the same words wherever they stand, and the nearest to a stale
    /// position is not the one just put back. (A second, identical copy of
    /// a mark's words is a different matter, settled by `survivingCopy`
    /// when the mark is carried, before any of this.)
    @Test func wordsPutBackAreMarkedWhereTheyLandedNotWhereTheyStood() throws {
        let start = "Alpha one here. Beta two here."
        let first = "Alpha ONEONEONE here. Beta TWO here."
        var review = empty.markingAssistantChange(from: start, to: first)
        // A second turn over both unread passages, so what a restore puts
        // back is the assistant's own unread work, and is marked again.
        let second = "Alpha x here. Beta y here."
        review = review.markingAssistantChange(from: first, to: second)
        let standing = Set(review.marks.map(\.id))
        #expect(review.wordings.filter { standing.contains($0.markID) }.allSatisfy { $0.wasUnread })

        let put = try #require(restoring(review, in: second))
        #expect(put.text == first)
        let source = put.text as NSString
        let marked = put.review.highlightedRanges(in: put.text)
        #expect(marked.map { source.substring(with: $0) } == ["ONEONEONE", "TWO"])
        // Both at their own places in the text the restore made: the first
        // grew by eight, and the second is marked past that, not short of it.
        #expect(marked.first?.location == (first as NSString).range(of: "ONEONEONE").location)
        #expect(marked.last?.location == (first as NSString).range(of: "TWO").location)
    }

    /// A mark kept alive by the same words standing somewhere else is no
    /// longer the passage the assistant changed, so it cannot be put back:
    /// doing so would rewrite a sentence nobody touched.
    @Test func aMarkMovedOntoACopyOfItsWordsIsNoLongerOffered() throws {
        let start = "Alpha old here. Beta blue there."
        let agent = "Alpha blue here. Beta blue there."
        let review = empty.markingAssistantChange(from: start, to: agent)
        #expect(marked(review, in: agent) == ["blue"])
        #expect(review.restorable(in: agent).count == 1)
        // The writer rewrites the passage the assistant changed. Its words
        // are gone, and the carry keeps the mark by finding them in Beta's
        // untouched sentence — right for reading, wrong for restoring.
        let typed = "Alpha mine here. Beta blue there."
        let carried = review.carryingWriterEdit(from: agent, to: typed)
        #expect(marked(carried, in: typed) == ["blue"], "still marked, so it is still read")
        #expect(
            carried.restorable(in: typed).isEmpty,
            "but restoring it would turn Beta's sentence into \"Beta old there.\""
        )
    }

    /// Two copies of one restoration are settled by when, which is how the
    /// cap orders them too: settling by bytes and capping by date let the
    /// two disagree, and then a merge of three copies depended on the
    /// order they were merged in.
    @Test func aMergeOfThreeCopiesDoesNotDependOnTheOrder() throws {
        func copy(_ entries: [(String, Double)]) -> LampWritingReview {
            var review = LampWritingReview(writingID: "w")
            review.restorations = entries.map { id, at in
                .init(
                    markID: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", abs(id.hashValue % 999999)))")!,
                    turnID: nil, restored: "r", discarded: "d",
                    restoredAt: Date(timeIntervalSince1970: at)
                )
            }
            return review
        }
        let x = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        func withX(_ at: Double) -> LampWritingReview {
            var review = LampWritingReview(writingID: "w")
            review.restorations = [
                .init(markID: x, turnID: nil, restored: "r", discarded: "d",
                      restoredAt: Date(timeIntervalSince1970: at)),
            ]
            return review
        }
        let a = withX(100)
        let b = withX(9)
        var c = LampWritingReview(writingID: "w")
        c.restorations = (0..<20).map {
            .init(markID: UUID(), turnID: nil, restored: "c", discarded: "d",
                  restoredAt: Date(timeIntervalSince1970: Double(50 + $0)))
        }
        let left = a.merged(with: b).merged(with: c)
        let right = a.merged(with: b.merged(with: c))
        #expect(Set(left.restorations) == Set(right.restorations))
        _ = copy
    }

    /// Taking the wording out is not enough on its own: a copy that has
    /// not carried the edit still holds it, and the merge would hand it
    /// back — so Beta's untouched sentence would become restorable again
    /// to a wording that was never Beta's.
    @Test func aWordingThatStrayedStaysVoidAcrossAMerge() throws {
        let start = "Alpha old here. Beta blue there."
        let agent = "Alpha blue here. Beta blue there."
        let before = empty.markingAssistantChange(from: start, to: agent)
        let typed = "Alpha mine here. Beta blue there."
        let carried = before.carryingWriterEdit(from: agent, to: typed)
        #expect(carried.restorable(in: typed).isEmpty)
        #expect(!carried.voidedWordings.isEmpty)
        // The other device still holds the record as it was.
        #expect(!before.wordings.isEmpty)
        #expect(carried.merged(with: before).restorable(in: typed).isEmpty)
        #expect(before.merged(with: carried).restorable(in: typed).isEmpty)
        // And it survives the file.
        let read = try LampWritingReview.decoded(from: try carried.encoded())
        #expect(read.voidedWordings == carried.voidedWordings)
        #expect(read.restorable(in: typed).isEmpty)
    }

    /// Restored words are marked again only where they are. The same
    /// words standing elsewhere are another passage, at any distance.
    @Test func restoredWordsAreNotMarkedSomewhereElse() throws {
        let start = "One old here."
        let agent = "One new here."
        var review = empty.markingAssistantChange(from: start, to: agent)
        let second = "One newer here."
        review = review.markingAssistantChange(from: agent, to: second)
        #expect(review.wordings.contains { $0.wasUnread })
        let plan = try #require(review.restorePlan(for: whole(second), in: second))
        // Where the plan says: the words are marked again.
        let asPlanned = applying(plan, to: second)
        let kept = review.restoringWording(plan, from: second, to: asPlanned)
        #expect(marked(kept, in: asPlanned) == ["new"])

        // And where a surface wrote its own text, moving them and leaving
        // the same word standing in a sentence nobody restored: nothing is
        // marked, rather than the wrong sentence.
        let surfaceWrote = "A note saying new in passing. One new here."
        let strayed = review.restoringWording(plan, from: second, to: surfaceWrote)
        #expect(marked(strayed, in: surfaceWrote).isEmpty)
    }

    /// The same words in the same place, wearing different markup, are
    /// the words that were put back: a surface writes its own Markdown,
    /// and `_x_` comes back as `*x*`.
    @Test func wordsPutBackAreMarkedThroughTheSurfacesOwnMarkup() throws {
        let start = "Before original after."
        let agent = "Before _unread_ after."
        var review = empty.markingAssistantChange(from: start, to: agent)
        let second = "Before revised after."
        review = review.markingAssistantChange(from: agent, to: second)
        #expect(review.wordings.contains { $0.wasUnread })
        let plan = try #require(review.restorePlan(for: whole(second), in: second))
        // What the page gives back: the same words, spelled its way.
        let surfaceWrote = "Before *unread* after."
        let put = review.restoringWording(plan, from: second, to: surfaceWrote)
        #expect(marked(put, in: surfaceWrote) == ["*unread*"])
    }

    /// A carry that moves a mark onto a copy of its words must keep that
    /// fact even when the copy happens to stand exactly where the original
    /// did: the marks, retirements and clearances then all match, and
    /// "nothing changed" threw the record of it away.
    @Test func aStrayedWordingSurvivesACarryThatLooksLikeNoChange() throws {
        let line = "A sufficiently long prefix for the word blue followed by a suffix."
        let start = "A \(line)\n\n\(line)"
        let agent = start.replacingOccurrences(of: "blue", with: "red", options: [], range: start.range(of: "blue"))
        // Marked where the assistant changed it: the first copy.
        let review = empty.markingAssistantChange(from: agent, to: start)
        #expect(review.restorable(in: start).count == 1)
        let typed = "B \(line)"
        let carried = review.carryingWriterEdit(from: start, to: typed)
        #expect(
            carried.restorable(in: typed).isEmpty,
            "whatever the mark is on now, it is not the passage the assistant changed"
        )
    }

    /// The span taken for restored words is whole words, whole
    /// characters, and one block: the same letters at the start of a
    /// longer word, or running on into the next paragraph's marker, are
    /// not the passage that was put back.
    @Test func theSpanTakenForRestoredWordsIsNotAFragmentOrTwoBlocks() throws {
        func found(_ replacement: String, in text: String) -> String? {
            let plan = LampWritingReview.RestorePlan(edits: [
                .init(markID: UUID(), range: NSRange(location: 0, length: 0),
                      replacement: replacement, discarded: "", unread: true),
            ])
            var review = LampWritingReview(writingID: "w")
            review.marks = []
            let put = review.restoringWording(plan, from: "", to: text)
            let source = text as NSString
            return put.highlightedRanges(in: text).first.map { source.substring(with: $0) }
        }
        // The same letters beginning a longer word are not those words,
        // whether they are spelled as the plan had them or not.
        #expect(found("_new_", in: "newspaper") == nil)
        #expect(found("new", in: "newspaper") == nil)
        #expect(found("new", in: "new paper") == "new")
        // Nor the letter in front of the accent that belongs to it.
        #expect(found("e", in: "e\u{301}tude") == nil)
        // A list item comes back in the page's own markers, and stops at
        // the end of its own block rather than taking the next one's.
        #expect(found("*    foo", in: "- foo\n\n- bar") == "- foo")
        // The same words in the surface's own markup are.
        #expect(found("_unread_", in: "*unread* after") == "*unread*")
    }

    // MARK: What an editor's page is told

    @Test func aPageIsToldWhatEachPassageWouldComeTo() throws {
        let review = empty.markingAssistantChange(from: "The quick brown fox.", to: "The slow red fox.")
        let text = "The slow red fox."
        let told = review.changes(in: text, ranges: review.highlightedRanges(in: text))
        #expect(told.count == 1)
        #expect(told[0]?.now == "slow red")
        #expect(told[0]?.before == "quick brown")
        #expect(told[0]?.reason == nil)
        #expect(told[0]?.id == review.marks.first?.id.uuidString)
    }

    @Test func aPassageTypedIntoSaysWhyAndOneNeverKeptSaysNothing() throws {
        let review = empty.markingAssistantChange(from: "One two three.", to: "One alpha beta three.")
        let typed = "One alpha mine beta three."
        let carried = review.carryingWriterEdit(from: "One alpha beta three.", to: typed)
        let told = carried.changes(in: typed, ranges: carried.highlightedRanges(in: typed))
        #expect(told.contains { $0?.reason == "edited" })
        #expect(told.allSatisfy { $0?.before == nil })

        var stripped = review
        stripped.wordings = []
        let text = "One alpha beta three."
        #expect(stripped.changes(in: text, ranges: stripped.highlightedRanges(in: text)) == [nil])
    }

    @Test func severalMarksInOnePassageAreNamedTogetherAndSorted() throws {
        let one = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let two = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(LampWritingReview.Change.id(of: [one, two]) == "\(two.uuidString),\(one.uuidString)")
    }

    @Test func aPlanAppliesItselfToTheText() throws {
        let review = empty.markingAssistantChange(from: "One two.", to: "One alpha two.")
        let plan = try #require(review.restorePlan(for: whole("One alpha two."), in: "One alpha two."))
        #expect(plan.applied(to: "One alpha two.") == "One two.")
    }

    /// A restore retires the mark it put back; the save that follows
    /// carries the marks into the new text, where that mark's words have
    /// gone, and retired it again.
    @Test func aMarkIsRetiredOnceHoweverManyTimesItIsRetired() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        let review = empty.markingAssistantChange(from: old, to: new)
        let put = try #require(restoring(review, in: new))
        let after = put.review.carryingWriterEdit(from: new, to: put.text)
        #expect(after.retired.count == 1)
        #expect(Set(after.retired.map(\.id)).count == after.retired.count)
    }

    /// What became of a restore, asked of the text rather than of a
    /// generation the writer can undo without touching.
    @Test func whetherARestoreStandsIsAskedOfTheWordsThemselves() throws {
        let old = "The quick brown fox."
        let new = "The slow red fox."
        let review = empty.markingAssistantChange(from: old, to: new)
        let plan = try #require(review.restorePlan(for: whole(new), in: new))
        // Put back, and still there after the writer typed around it.
        #expect(review.restoreStands(plan, in: old))
        #expect(review.restoreStands(plan, in: "The quick brown fox jumps."))
        // Undone, or never made: the assistant's words are back, and so
        // is the mark.
        #expect(!review.restoreStands(plan, in: new))
        #expect(!review.restoreStands(plan, in: "Before. The slow red fox."))
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

    /// A device that only syncs never restores, so it never prunes; it
    /// would otherwise hand back everything the restoring device dropped,
    /// and the two would grow the list for ever between them.
    @Test func aMergeKeepsOnlyTheNewestRestorations() throws {
        var mine = LampWritingReview(writingID: "w")
        var theirs = LampWritingReview(writingID: "w")
        let now = Date()
        mine.restorations = (0..<15).map {
            .init(markID: UUID(), turnID: nil, restored: "a", discarded: "b",
                  restoredAt: now.addingTimeInterval(-Double($0)))
        }
        theirs.restorations = (20..<40).map {
            .init(markID: UUID(), turnID: nil, restored: "c", discarded: "d",
                  restoredAt: now.addingTimeInterval(-Double($0)))
        }
        let merged = mine.merged(with: theirs)
        #expect(merged.restorations.count == LampWritingReview.restorationsKept)
        // The newest of the two sides, whichever side merges.
        #expect(merged.restorations.allSatisfy { $0.restored == "a" || $0.restored == "c" })
        #expect(theirs.merged(with: mine).restorations == merged.restorations)
        // And nothing one side has alone is lost while it is among the newest.
        #expect(merged.restorations.contains { $0.restored == "a" })
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
