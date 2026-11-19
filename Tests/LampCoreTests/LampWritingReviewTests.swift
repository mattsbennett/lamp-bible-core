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
        // Untouched by the edit: the record does not change, and syncs nothing.
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
        #expect(cleared.retired.isEmpty)
        #expect(cleared.clearances.count == 1)
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
        // Its context moved, so it was carried to a later version.
        #expect(next.marks.first { $0.id == id }?.version == 2)
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

    @Test func undoingATurnTakesItsMarksAndLeavesTheRest() {
        let start = "Alpha beta.\n\nGamma delta."
        let first = "Alpha BETA.\n\nGamma delta."
        let firstTurn = UUID()
        let secondTurn = UUID()
        var review = empty.markingAssistantChange(from: start, to: first, turnID: firstTurn)
        let second = "Alpha BETA.\n\nGamma DELTA."
        review = review.markingAssistantChange(from: first, to: second, turnID: secondTurn)
        let undone = review.undoingTurns([secondTurn], from: second, to: first)
        #expect(marked(undone, in: first) == ["BETA"])
    }

    // MARK: What review found

    @Test func twoSpellingsOfOneCharacterDoNotThrowOffsetsOut() {
        let review = empty.markingAssistantChange(from: "Cafe\u{301} beta x.", to: "Cafe\u{301} BETA x.")
        let typed = "Caf\u{e9} BETA"
        let carried = review.carryingWriterEdit(from: "Cafe\u{301} BETA x.", to: typed)
        #expect(marked(carried, in: typed) == ["BETA"])
    }

    @Test func twoDevicesClearingDifferentPartsLeaveOnlyWhatNeitherCleared() {
        let new = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: new)
        let phone = review.clearing((new as NSString).range(of: "alpha"), in: new)
        let mac = review.clearing((new as NSString).range(of: "gamma"), in: new)
        #expect(marked(phone.merged(with: mac), in: new) == ["beta"])
        #expect(marked(mac.merged(with: phone), in: new) == ["beta"])
    }

    @Test func aClearHoldsAgainstATurnThatOnlyMovedItsContext() {
        let old = "Alpha beta gamma delta."
        let agent = "Alpha BETA gamma delta."
        let review = empty.markingAssistantChange(from: old, to: agent)
        let phone = review.clearing((agent as NSString).range(of: "BETA"), in: agent)
        let later = "Alpha BETA gamma DELTA."
        let mac = review.markingAssistantChange(from: agent, to: later)
        #expect(marked(phone.merged(with: mac), in: later) == ["DELTA"])
    }

    @Test func repeatedWordsMarkTheCopyTheAssistantWrote() {
        let review = empty.markingAssistantChange(from: "Echo.\nOther.", to: "Echo.\nEcho.")
        let ranges = review.highlightedRanges(in: "Echo.\nEcho.")
        #expect(ranges == [NSRange(location: 6, length: 4)])
    }

    @Test func aLineEmptiedOfItsWordsKeepsAPointThatCanBeCleared() {
        let old = "Intro.\nRemove me.\nEnd."
        let new = "Intro.\n\nEnd."
        let review = empty.markingAssistantChange(from: old, to: new)
        let ranges = review.highlightedRanges(in: new)
        #expect(ranges.count == 1)
        #expect(ranges.first?.length == 0)
        let line = (new as NSString).paragraphRange(for: NSRange(location: 7, length: 0))
        #expect(review.clearing(line, in: new).isEmpty)
    }

    @Test func writingWhereWordsWereTakenOutClearsThePoint() {
        let agent = "A C."
        let review = empty.markingAssistantChange(from: "A B C.", to: agent)
        #expect(review.highlightedRanges(in: agent).count == 1)
        let typed = "A mine C."
        #expect(review.carryingWriterEdit(from: agent, to: typed).isEmpty)
    }

    @Test func carryingAcrossTheChangeThatMadeAMarkLeavesItWhereItIs() {
        // An assistant's draft is marked as it is taken, then saved like
        // any edit: carrying across that same change must not move the new
        // mark onto the one other copy of its word in the old text.
        let old = "Say grace here.\n\nOther words."
        let new = "Say grace here.\n\nOther grace words."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(marked(review, in: new) == ["grace"])
        let saved = review.carryingWriterEdit(from: old, to: new)
        #expect(saved == review)
    }

    @Test func aClearanceFollowsItsWordsSoALaterCopyCannotShowThemAgain() {
        let start = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: start)
        // This device clears "alpha beta", then edits "alpha".
        var here = review.clearing((start as NSString).range(of: "alpha beta"), in: start)
        let edited = "One ALPHA beta gamma three."
        here = here.carryingWriterEdit(from: start, to: edited)
        // The other edits the same word, then moves the mark on twice more.
        var there = review.carryingWriterEdit(from: start, to: edited)
        there = there.carryingWriterEdit(from: edited, to: "Once ALPHA beta gamma three.")
        there = there.carryingWriterEdit(from: "Once ALPHA beta gamma three.", to: edited)
        #expect(marked(here.merged(with: there), in: edited) == ["gamma"])
    }

    @Test func aMarkOnRepeatedWordsStaysOnItsCopyAsTextIsAddedAbove() {
        let block = String(repeating: "p", count: 24) + " Echo " + String(repeating: "q", count: 24) + "\n"
        let other = String(repeating: "p", count: 24) + " Other " + String(repeating: "q", count: 24) + "\n"
        let old = block + other
        let new = block + block
        let review = empty.markingAssistantChange(from: old, to: new)
        let assistants = NSRange(location: (block as NSString).length + 25, length: 4)
        #expect(review.highlightedRanges(in: new) == [assistants])
        let prefix = String(repeating: "z", count: 100) + "\n"
        let carried = review.carryingWriterEdit(from: new, to: prefix + new)
        #expect(carried.highlightedRanges(in: prefix + new)
            == [NSRange(location: assistants.location + (prefix as NSString).length, length: 4)])
    }

    @Test func pruningNeverShowsWhatWasClearedAgain() {
        let new = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: new)
        let merged = review.clearing((new as NSString).range(of: "alpha"), in: new)
            .merged(with: review.clearing((new as NSString).range(of: "gamma"), in: new))
        #expect(marked(merged.pruning(before: Date().addingTimeInterval(3_600)), in: new) == ["beta"])
    }

    @Test func marksCrossIntoAWebEditorAndAClearComesBack() {
        let old = "One two three.\n\nFour five six."
        let new = "One deux three.\n\nFour six."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.markedMarkdown(in: new) == "One \u{E000}deux\u{E001} three.\n\nFour\u{E002} six.")
        #expect(empty.markedMarkdown(in: new) == nil)

        let sent = "One \u{E000}deux three.\u{E001}\n\nFour six."
        let range = LampWritingReview.markedRange(in: sent, of: new)
        #expect(range == NSRange(location: 4, length: 11))
        #expect(LampWritingReview.markedRange(in: "One \u{E002}deux three.\n\nFour six.", of: new) == NSRange(location: 4, length: 0))
        // From an editor showing something else, nothing is cleared.
        #expect(LampWritingReview.markedRange(in: "Other \u{E000}text\u{E001}", of: new) == nil)
        #expect(LampWritingReview.markedRange(in: "One deux three.\n\nFour six.", of: new) == nil)
    }

    @Test func aSmallWordKeptInsideARemovalIsOneChange() {
        let old = "The word he chooses is not a promise of comfort but a call to wake."
        let new = "The word he chooses is a call to wake."
        let review = empty.markingAssistantChange(from: old, to: new)
        #expect(review.highlightedRanges(in: new).count == 1)
    }

    @Test func aPartialClearHoldsWhenAnotherDeviceEditsOneOfItsWords() {
        let start = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: start)
        // A clears "alpha beta"; B, never seeing it, types over "beta".
        let here = review.clearing((start as NSString).range(of: "alpha beta"), in: start)
        let edited = "One alpha BETA gamma three."
        let there = review.carryingWriterEdit(from: start, to: edited)
        #expect(marked(here.merged(with: there), in: edited) == ["gamma"])
    }

    @Test func savingTheChangeThatMadeAMarkLeavesItOnTheCopyTheAssistantWrote() {
        // Review's case: two blocks whose words differ only in the middle,
        // with a full line of context either side. The assistant turns the
        // second into the first; its mark is made as the draft is taken in,
        // then the save carries the same change again.
        func block(_ word: String) -> String {
            String(repeating: "p", count: 24) + " " + word + " " + String(repeating: "q", count: 24) + "\n"
        }
        let old = block("Echo") + block("Other")
        let new = block("Echo") + block("Echo")
        let review = empty.markingAssistantChange(from: old, to: new)
        let assistants = NSRange(location: (block("Echo") as NSString).length + 25, length: 4)
        #expect(review.highlightedRanges(in: new) == [assistants])
        let saved = review.carryingWriterEdit(from: old, to: new)
        #expect(saved.highlightedRanges(in: new) == [assistants])
    }

    /// A save's carry from text A to B, with the text a turn marked since
    /// (C) among those known: the new mark is anchored in C and is taken
    /// from C, never from a copy of its words in A. (A carry that would take
    /// marks back to a text older than one already marked is the caller's
    /// to skip; the Mac skips a save's carry once a newer save is in.)
    @Test func aLateCarryLeavesAMarkMadeAgainstALaterTextAlone() {
        let passage = "The same words stand here.\n\n"
        let other = "Something else stood here.\n\n"
        let a = passage + passage + passage + other + passage + passage + "Tail."
        let b = passage + passage + passage + other + passage + passage + "Tail, edited."
        let c = passage + passage + passage + passage + passage + passage + "Tail, edited."
        let marked = empty.markingAssistantChange(from: b, to: c)
        let drawn = marked.highlightedRanges(in: c)
        #expect(marked.carryingToText(c, from: [a, b, c]) == marked)
        #expect(marked.carryingToText(c, from: [a, b]).highlightedRanges(in: c) == drawn)
    }

    @Test func aClearFromAnEditorThatTidiedTheMarkdownStillLands() {
        let text = "* one\n* two deux\n\nAfter."
        let review = empty.markingAssistantChange(from: "* one\n* two\n\nAfter.", to: text)
        #expect(review.highlightedRanges(in: text).count == 1)
        // The page writes the list with dashes, and marks the second item.
        let sent = "- one\n- \u{E000}two deux\u{E001}\n\nAfter."
        let range = LampWritingReview.markedRange(in: sent, of: text)
        #expect(range.map { (text as NSString).substring(with: $0) } == "two deux")
        // A page showing other words clears nothing.
        #expect(LampWritingReview.markedRange(in: "- one\n- \u{E000}three\u{E001}\n\nAfter.", of: text) == nil)
    }

    // MARK: Anchors

    /// Review's case: A has Echo/Other/Third, B Echo/Echo/Third, C
    /// Echo/Echo/Echo. A late A→B carry must leave C's new mark alone.
    @Test func aCarryMovesOnlyWhatIsAnchoredInTheTextItCarriesFrom() {
        let a = "Echo.\n\nOther.\n\nThird."
        let b = "Echo.\n\nEcho.\n\nThird."
        let c = "Echo.\n\nEcho.\n\nEcho."
        let marked = empty.markingAssistantChange(from: b, to: c)
        let drawn = marked.highlightedRanges(in: c)
        #expect(drawn == [NSRange(location: 14, length: 4)])
        #expect(marked.carryingWriterEdit(from: a, to: b) == marked)
        #expect(marked.carryingWriterEdit(from: a, to: b).highlightedRanges(in: c) == drawn)
    }

    @Test func aClearInUnsavedTextIsCarriedFromThatTextOnSave() {
        let saved = "One alpha beta gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: saved)
        // Cleared while "mine" was typed and not yet saved.
        let unsaved = "One alpha mine beta gamma three."
        let cleared = review
            .carryingToText(unsaved, from: [saved])
            .clearing((unsaved as NSString).range(of: "gamma"), in: unsaved)
        #expect(marked(cleared, in: unsaved) == ["alpha", "beta"])
        // The save carries from the last saved text; the editor knows the
        // unsaved one too, so what the clear left is carried from there.
        let later = "One alpha mine beta gamma three, and more."
        let carried = cleared.carryingToText(later, from: [saved, unsaved])
        #expect(marked(carried, in: later) == ["alpha", "beta"])
    }

    @Test func aCaretIsNeverPlacedAcrossAChangeOfWords() {
        let text = "One omega."
        #expect(LampWritingReview.markedRange(in: "One \u{E002}alpha.", of: text) == nil)
    }

    @Test func aLongListWrittenBackWithDashesStillPlacesAClear() {
        let items = (1...20).map { "item \($0)" }
        let text = items.map { "* \($0)" }.joined(separator: "\n")
        let sent = items.enumerated().map { index, item in
            index == 9 ? "- \u{E000}\(item)\u{E001}" : "- \(item)"
        }.joined(separator: "\n")
        let range = LampWritingReview.markedRange(in: sent, of: text)
        #expect(range.map { (text as NSString).substring(with: $0) } == "item 10")
    }

    @Test func emphasisWrittenBackAnotherWayStillPlacesAWord() {
        let text = "_one_ _two_ three"
        let range = LampWritingReview.markedRange(in: "*\u{E000}one\u{E001}* *two* three", of: text)
        #expect(range.map { (text as NSString).substring(with: $0) } == "one")
    }

    @Test func aMarkAnchoredInATextThisDeviceNeverHadIsStillCarried() {
        // Made on another device, or in a text since forgotten: found whole
        // and once in the old text, and carried from there.
        let old = "One alpha beta gamma three.\n\nSecond line."
        var review = empty.markingAssistantChange(from: "One two three.\n\nSecond line.", to: old)
        review.marks = review.marks.map { mark in
            .init(id: mark.id, pieces: mark.pieces.map {
                .init(text: $0.text, before: $0.before, after: $0.after, hint: $0.hint, anchoredIn: "elsewhere")
            }, version: mark.version, markedAt: mark.markedAt, turnID: nil)
        }
        let typed = "One alpha mine beta gamma three.\n\nSecond line."
        let carried = review.carryingWriterEdit(from: old, to: typed)
        #expect(marked(carried, in: typed) == ["alpha", "beta gamma"])
        #expect(carried.marks.flatMap(\.pieces).allSatisfy { $0.anchoredIn == LampWritingReview.digest(of: typed) })
    }

    @Test func carryingThroughTidiedMarkdownKeepsAShortWordMarked() {
        // Review's case: "one" marked in _one_ _two_ three; the visual editor
        // writes it back as *one* *two* three! and the mark must survive.
        let before = "_uno_ _two_ three"
        let marked0 = empty.markingAssistantChange(from: before, to: "_one_ _two_ three")
        let written = "*one* *two* three!"
        let carried = marked0.carryingWriterEdit(from: "_one_ _two_ three", to: written)
        #expect(marked(carried, in: written) == ["one"])
    }

    @Test func aRenumberedListIsSpellingButAChapterNumberIsNot() {
        let text = "1. one\n1. two"
        let range = LampWritingReview.markedRange(in: "1. one\n2. \u{E000}two\u{E001}", of: text)
        #expect(range.map { (text as NSString).substring(with: $0) } == "two")
        #expect(LampWritingReview.markedRange(in: "see chapter 2. \u{E002}Then", of: "see chapter 1. Then") == nil)
    }

    // MARK: From the third review of the anchors

    private func padded(_ word: String) -> String {
        String(repeating: "p", count: 24) + " " + word + " " + String(repeating: "q", count: 24) + "\n"
    }

    /// C: what a clear left in a text since forgotten is carried from the
    /// newest known text that holds it, and splits around new typing.
    @Test func aClearsRemainderSplitsAroundTypingAfterItsTextIsForgotten() {
        let unsaved = "One alpha beta mine gamma three."
        let review = empty.markingAssistantChange(from: "One two three.", to: "One alpha beta gamma three.")
            .carryingToText(unsaved, from: ["One alpha beta gamma three."])
            .clearing((unsaved as NSString).range(of: "gamma"), in: unsaved)
        // The unsaved text is forgotten; a later one that still holds the
        // passage is known, and the writer types between alpha and beta.
        let later = "One alpha beta mine gamma three. More."
        let typed = "One alpha yours beta mine gamma three. More."
        let carried = review.carryingToText(typed, from: [later])
        #expect(marked(carried, in: typed) == ["alpha", "beta"])
    }

    /// H1: a piece with its own known text is taken from it, not from an
    /// older text where its words happen to stand once.
    @Test func aPieceIsTakenFromItsOwnTextBeforeAnyOther() {
        let a = padded("Echo") + padded("Other")
        let b = padded("Echo") + padded("Echo")
        let review = empty.markingAssistantChange(from: a, to: b)
        let drawn = review.highlightedRanges(in: b)
        let carried = review.carryingToText(b + "Tail.", from: [a, b])
        #expect(carried.highlightedRanges(in: b + "Tail.") == drawn)
    }

    /// H2: a piece whose place moved is anchored again, so a later carry
    /// from the older text cannot match the other copy and retire it.
    @Test func aPieceWhosePlaceMovedIsAnchoredAgain() {
        let a = "FIRST\n" + padded("Echo") + "SECOND\n" + padded("Echo") + "TAIL"
        let marked0 = empty.markingAssistantChange(from: a.replacingOccurrences(of: "SECOND\n" + padded("Echo"), with: "SECOND\n" + padded("Ekko")), to: a)
        let b = String(a.dropFirst("FIRST\n".count))
        let moved = marked0.carryingWriterEdit(from: a, to: b)
        #expect(moved.marks.flatMap(\.pieces).allSatisfy { $0.anchoredIn == LampWritingReview.digest(of: b) })
        let c = b + "!"
        let later = moved.carryingToText(c, from: [a, b])
        #expect(later.highlightedRanges(in: c) == moved.highlightedRanges(in: b))
    }

    /// H3: a piece anchored in another text is never drawn on whichever
    /// copy of its words lies nearest a place recorded there.
    @Test func aForeignPieceIsNotDrawnOnTheNearestCopy() {
        let text = padded("Echo") + padded("Echo")
        let foreign = LampWritingReview.Piece(
            text: "Echo", before: String(repeating: "p", count: 24) + " ",
            after: " " + String(repeating: "q", count: 24), hint: 70, anchoredIn: "elsewhere"
        )
        let review = LampWritingReview(writingID: "w", marks: [.init(pieces: [foreign], markedAt: Date(), turnID: nil)])
        #expect(review.highlightedRanges(in: text).isEmpty)
    }

    @Test func numbersInCodeOrSuperscriptsAreNeverSpelling() {
        #expect(LampWritingReview.markedRange(in: "```\n2. \u{E002}x\n```", of: "```\n1. x\n```") == nil)
        #expect(LampWritingReview.markedRange(in: "    2. \u{E002}x", of: "    1. x") == nil)
        #expect(LampWritingReview.markedRange(in: "x\u{B3} \u{E002}y", of: "x\u{B2} y") == nil)
        let quoted = "> 1. one\n> 1. two"
        let range = LampWritingReview.markedRange(in: "> 1. one\n> 2. \u{E000}two\u{E001}", of: quoted)
        #expect(range.map { (quoted as NSString).substring(with: $0) } == "two")
    }

    /// H3, at the hint: a foreign piece is not drawn on a copy that now
    /// sits where its hint points, after an identical block above was cut.
    @Test func aForeignPieceIsNotDrawnAtItsHintWhereItsWordsRepeat() {
        let text = padded("Echo") + padded("Echo")
        let foreign = LampWritingReview.Piece(
            text: "Echo", before: String(repeating: "p", count: 24) + " ",
            after: " " + String(repeating: "q", count: 24), hint: 25, anchoredIn: "elsewhere"
        )
        let review = LampWritingReview(writingID: "w", marks: [.init(pieces: [foreign], markedAt: Date(), turnID: nil)])
        #expect(review.highlightedRanges(in: text).isEmpty)
    }

    @Test func aRepeatedPieceIsAnchoredByEveryCarry() {
        let b = padded("Echo") + padded("Echo")
        let review = empty.markingAssistantChange(from: padded("Echo") + padded("Other"), to: b)
        let c = b + "Tail."
        let carried = review.carryingWriterEdit(from: b, to: c)
        #expect(carried.marks.flatMap(\.pieces).allSatisfy { $0.anchoredIn == LampWritingReview.digest(of: c) })
        #expect(carried.highlightedRanges(in: c) == review.highlightedRanges(in: b))
    }

    @Test func aLongerFenceIsClosedOnlyByOneAsLong() {
        let held = "````\n```\n1. x\n````"
        let sent = "````\n```\n2. \u{E002}x\n````"
        #expect(LampWritingReview.markedRange(in: sent, of: held) == nil)
    }

    @Test func theFileIsTheSameBytesForTheSameRecord() throws {
        let review = empty.markingAssistantChange(from: "a b c", to: "a x c", at: Date(timeIntervalSince1970: 1))
        let shuffled = LampWritingReview(
            writingID: "w", marks: review.marks.reversed(), retired: review.retired.reversed(),
            clearances: review.clearances.reversed()
        )
        #expect(try review.encoded() == shuffled.encoded())
        #expect(try LampWritingReview.decoded(from: review.encoded()) == review)
    }

    @Test func pruningDropsOnlyOldRetirements() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 1_000)
        let review = LampWritingReview(writingID: "w", retired: [
            .init(id: UUID(), retiredAt: old), .init(id: UUID(), retiredAt: recent),
        ])
        #expect(review.pruning(before: Date(timeIntervalSince1970: 500)).retired.count == 1)
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

struct LampWritingReviewStoreTests {
    private func temporaryStore() throws -> LampWritingReviewStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LampWritingReviewStore(rootURL: root)
    }

    @Test func aFileIsAtItsServerPathAndSavesOnlyWhatChanged() throws {
        let store = try temporaryStore()
        let review = LampWritingReview(writingID: "w-1")
            .markingAssistantChange(from: "a b", to: "a c", at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try store.save(review))
        #expect(try !store.save(review))
        #expect(try store.url(writingID: "w-1").path.hasSuffix("WritingReview/w-1.json"))
        #expect(try store.review(writingID: "w-1") == review)
        #expect(try store.writingIDs() == ["w-1"])
    }

    @Test func aDownloadedCopyIsMergedNotPutOver() throws {
        let store = try temporaryStore()
        let text = "Alpha BETA gamma.\n\nDelta EPSILON zeta."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(
            from: "Alpha beta gamma.\n\nDelta epsilon zeta.", to: text
        )
        let here = review.clearing((text as NSString).range(of: "BETA"), in: text)
        let there = review.clearing((text as NSString).range(of: "EPSILON"), in: text)
        try store.save(here)
        #expect(try store.takeIn(downloaded: there.encoded(), writingID: "w"))
        #expect(try store.review(writingID: "w").isEmpty)
        // Taking in the same copy again leaves nothing to send.
        let merged = try store.review(writingID: "w")
        #expect(try !store.takeIn(downloaded: merged.encoded(), writingID: "w"))

        // An older copy, which still has a mark cleared here: nothing to
        // write, but news to send, so the file is dated now.
        let file = try store.url(writingID: "w").path
        let past = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)
        #expect(try store.takeIn(downloaded: review.encoded(), writingID: "w"))
        let dated = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect((dated ?? past) > past)
    }

    @Test func anUnreadableFileIsAnErrorNotAnEmptyRecord() throws {
        let store = try temporaryStore()
        let url = try store.url(writingID: "w")
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.review(writingID: "w") }
    }

    @Test func aDeletedWritingsMarksAreDeletedWhereverThereIsAFile() throws {
        let store = try temporaryStore()
        try store.save(LampWritingReview(writingID: "Gone").markingAssistantChange(from: "a", to: "b"))
        try store.save(LampWritingReview(writingID: "kept").markingAssistantChange(from: "a", to: "b"))
        let deletions = try store.deletions(
            deleted: ["gone", "kept", "never-reviewed", "elsewhere"],
            held: ["KEPT"],
            members: ["WritingReview/elsewhere.json": 3, "Writing/writing.lamp": 3],
            now: 9
        )
        #expect(deletions == ["WritingReview/Gone.json": 9, "WritingReview/elsewhere.json": 9])
        #expect(try store.writingIDs() == ["kept"])
    }
}
