import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

/// Where a writing's review marks are kept, and how two writers of one file
/// share it.
struct LampWritingReviewFileTests {
    private func temporaryStore() throws -> LampWritingReviewStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LampWritingReviewStore(rootURL: root)
    }

    // MARK: Documents beside the writing

    /// A document's marks are their own file, and the writing's own file
    /// keeps the name it has always had — every record already on a server
    /// goes on being found.
    @Test func adocumentsMarksAreTheirOwnFileAndTheProsesKeepsItsName() throws {
        let id = "exhortation-2026-01-18"
        #expect(try LampSyncFolderLayout.writingReviewPath(writingID: id) == "WritingReview/\(id).json")
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: "outline.md")
        #expect(path == "WritingReview/\(id)__outline_2Emd.json")
        let target = try #require(LampSyncFolderLayout.reviewTarget(ofPath: path))
        #expect(target.writingID == id)
        #expect(LampSyncFolderLayout.documentName(fromReviewKey: try #require(target.documentKey)) == "outline.md")
        // And the writing's own file still answers with no document.
        let prose = try #require(
            LampSyncFolderLayout.reviewTarget(ofPath: "WritingReview/\(id).json")
        )
        #expect(prose.documentKey == nil)
    }

    /// A name too long to keep is written as a digest of itself rather than
    /// throwing: the writer that asks for the path does not look at the
    /// error, so the document would otherwise never have marks and nothing
    /// would say why. The record inside carries the name.
    @Test func adocumentNameTooLongToKeepIsADigestAndStillHasAFile() throws {
        let long = String(repeating: "\u{5D0}", count: 90) + ".md"
        let id = "exhortation-2026-01-18"
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: long)
        #expect(path.utf8.count <= LampSyncFolderLayout.maximumReviewFilenameBytes + "WritingReview/".utf8.count)
        let target = try #require(LampSyncFolderLayout.reviewTarget(ofPath: path))
        #expect(target.writingID == id)
        let key = try #require(target.documentKey)
        #expect(LampSyncFolderLayout.documentName(fromReviewKey: key) == nil)
        // The same name always makes the same key, so the file is found again.
        #expect(LampSyncFolderLayout.reviewDocumentKey(writingID: id, document: long) == key)
        // And the record says which document it is for.
        let store = try temporaryStore()
        try store.save(LampWritingReview(writingID: id, document: long))
        #expect(try store.review(writingID: id, document: long).document == long)
    }

    /// A record that says it is another document's is refused rather than
    /// merged: nothing in the merge compares identity, so a file that
    /// reached the wrong place would take its marks into this one.
    @Test func arecordOfAnotherDocumentIsRefusedRatherThanMerged() throws {
        let store = try temporaryStore()
        let id = "exhortation-2026-01-18"
        let theirs = LampWritingReview(writingID: id, document: "notes.md")
        #expect(throws: LampWritingReviewStore.StoreError.notThisDocument) {
            try store.takeIn(downloaded: try theirs.encoded(), writingID: id, document: "outline.md")
        }
        #expect(throws: LampWritingReviewStore.StoreError.notThisDocument) {
            try store.takeIn(downloaded: try theirs.encoded(), writingID: id)
        }
        // Its own file takes it.
        #expect(try store.takeIn(downloaded: try theirs.encoded(), writingID: id, document: "notes.md") == false)
    }

    /// A deleted writing takes its documents' records with it. One left
    /// here is fetched from the server for ever, by a device that will
    /// never hold the document.
    @Test func adeletedWritingSweepsItsDocumentsRecordsToo() throws {
        let store = try temporaryStore()
        let id = "exhortation-2026-01-18"
        try store.save(LampWritingReview(writingID: id))
        try store.save(LampWritingReview(writingID: id, document: "outline.md"))
        try store.save(LampWritingReview(writingID: "kept", document: "outline.md"))
        let prose = try LampSyncFolderLayout.writingReviewPath(writingID: id)
        let document = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: "outline.md")

        let deletions = try store.deletions(
            deleted: [id], held: [], members: [prose: 10, document: 10], now: 100
        )
        #expect(Set(deletions.keys) == [prose, document])
        #expect(try store.reviewed().map(\.writingID) == ["kept"])
    }

    /// A document's marks are carried onto the text each save writes, or
    /// the first keystroke after a mark strays every one of them.
    @Test func adocumentsMarksAreCarriedOntoWhatItsSaveWrote() throws {
        let store = try temporaryStore()
        let id = "exhortation-2026-01-18"
        let name = "outline.md"
        let old = "The flood came suddenly. Noah was ready."
        // The writer types into the marked sentence.
        let new = "The flood came very suddenly. Noah was ready."

        try store.save(
            LampWritingReview(writingID: id, document: name)
                .markingAssistantChange(from: "Noah was ready.", to: old)
        )
        let marked = try store.review(writingID: id, document: name)
        #expect(marked.highlightedRanges(in: old).count == 1)
        #expect(marked.marks.count == 1)

        #expect(try LampWritingDocumentReview.carry(
            new, ofDocument: name, writingID: id, from: [old], in: store
        ))
        // The words the mark was made of are gone, so the mark is retired
        // rather than left to be found in whatever text comes next.
        // The record moved with the text: the mark is anchored in what
        // the save wrote, not in the body before it.
        let carried = try store.review(writingID: id, document: name)
        #expect(carried != marked)
        #expect(carried.marks.first?.pieces.first?.anchoredIn
            != marked.marks.first?.pieces.first?.anchoredIn)
        // Again moves nothing, so a save has nothing to send.
        #expect(try LampWritingDocumentReview.carry(
            new, ofDocument: name, writingID: id, from: [old, new], in: store
        ) == false)
    }

    /// A document nobody marked has no file, and a save of it writes none:
    /// a record read in and written back would date a file every save, and
    /// a pass would send it.
    @Test func asaveOfAnUnmarkedDocumentWritesNoRecord() throws {
        let store = try temporaryStore()
        #expect(try LampWritingDocumentReview.carry(
            "Anything.", ofDocument: "outline.md", writingID: "w", from: [], in: store
        ) == false)
        #expect(try store.reviewed().isEmpty)
    }

    /// Every id a writing can have has a file, named so it reads back as
    /// exactly that id; the ids Lamp makes itself are their own names.
    @Test func everyWritingIdHasAReviewFileThatReadsBackAsIt() throws {
        let made = "3F2A9C10-1B2C-5D3E-8F40-0123456789AB"
        #expect(try LampSyncFolderLayout.writingReviewPath(writingID: made) == "WritingReview/\(made).json")
        let composed = "G\u{E9}nesis", decomposed = "Ge\u{301}nesis"
        for id in [made, ".sermon", "advent 2026", "a/b", "a\\b", "w_1", "on.grace", composed, decomposed, "_41"] {
            let path = try LampSyncFolderLayout.writingReviewPath(writingID: id)
            #expect(LampSyncFolderLayout.kind(of: path) == .writingReview, "\(id)")
            #expect(LampSyncFolderLayout.writingID(ofReviewPath: path) == id, "\(id)")
            #expect(path.split(separator: "/").count == 2 && !path.split(separator: "/")[1].hasPrefix("."), "\(id)")
        }
        #expect(try LampSyncFolderLayout.writingReviewPath(writingID: composed)
            != LampSyncFolderLayout.writingReviewPath(writingID: decomposed))
        // A name no id makes is no review file.
        for name in ["_41.json", "_2e.json", "_4.json", "a.JSON", ".json", "_FF.json"] {
            #expect(LampSyncFolderLayout.writingID(ofReviewPath: "WritingReview/\(name)") == nil, "\(name)")
            #expect(LampSyncFolderLayout.kind(of: "WritingReview/\(name)") == nil, "\(name)")
        }
        #expect(throws: LampSyncFolderLayout.PathError.self) {
            try LampSyncFolderLayout.writingReviewPath(writingID: String(repeating: " ", count: 100))
        }
    }

    @Test func awritingWhoseIdIsNoFileNameStillKeepsItsMarks() throws {
        let store = try temporaryStore()
        try store.save(LampWritingReview(writingID: ".sermon").markingAssistantChange(from: "a", to: "b"))
        #expect(try store.review(writingID: ".sermon").marks.count == 1)
        #expect(try store.writingIDs() == [".sermon"])
    }

    /// Changes made at once through two stores, as the reconciler and a
    /// pass make them, each land: none is written over by a copy read
    /// before it.
    @Test func changesAtOnceThroughTwoStoresAllLand() throws {
        let store = try temporaryStore()
        let other = LampWritingReviewStore(rootURL: store.rootURL)
        let rounds = 60
        DispatchQueue.concurrentPerform(iterations: rounds * 2) { round in
            let words = "w\(round)"
            if round.isMultiple(of: 2) {
                _ = try? store.update(writingID: "w") { $0.markingAssistantChange(from: "", to: words) }
            } else {
                let incoming = LampWritingReview(writingID: "w").markingAssistantChange(from: "", to: words)
                _ = try? other.takeIn(downloaded: try incoming.encoded(), writingID: "w")
            }
        }
        #expect(try store.review(writingID: "w").marks.count == rounds * 2)
    }

    /// A deleted writing's review is deleted after the write the manifest
    /// holds, however far ahead the clock of the device that wrote it ran.
    @Test func aDeletionIsNeverDatedBeforeTheWriteItDeletes() throws {
        let store = try temporaryStore()
        try store.save(LampWritingReview(writingID: "gone").markingAssistantChange(from: "a", to: "b"))
        let deletions = try store.deletions(
            deleted: ["gone", "far"], held: [],
            members: ["WritingReview/gone.json": 500, "WritingReview/far.json": 50],
            now: 100
        )
        #expect(deletions == ["WritingReview/gone.json": 501, "WritingReview/far.json": 100])
    }

    /// A clear's offsets are UTF-16 ones, so text equal only by Unicode's
    /// rules is not taken offset for offset: the range is placed word by
    /// word in the text held, on the same words.
    @Test func amarkedRangeIsOnlyTakenFromTheSameUnits() {
        let marked = "e\u{301} \(LampWritingReview.markStart)A\(LampWritingReview.markEnd)B"
        #expect(LampWritingReview.markedRange(in: marked, of: "\u{E9} AB") == NSRange(location: 2, length: 1))
        #expect(LampWritingReview.markedRange(in: marked, of: "e\u{301} AB") == NSRange(location: 3, length: 1))
    }

    /// A cleared word found again without its context is found as a word,
    /// never inside another: two devices, one clearing "a beta" and the
    /// other taking those words out, leave "lamp" marked whole.
    @Test func acleardWordIsNeverFoundInsideAnother() {
        let shown = "One a beta lamp end."
        let marked = LampWritingReview(writingID: "w").markingAssistantChange(from: "One two end.", to: shown)
        #expect(marked.highlightedRanges(in: shown).map { (shown as NSString).substring(with: $0) } == ["a beta lamp"])
        let cleared = marked.clearing((shown as NSString).range(of: "a beta"), in: shown)
        let edited = "One lamp end."
        let elsewhere = marked.carryingWriterEdit(from: shown, to: edited)
        let merged = cleared.merged(with: elsewhere)
        #expect(merged.highlightedRanges(in: edited).map { (edited as NSString).substring(with: $0) } == ["lamp"])
    }

    /// A mark keeps whatever of it still stands, and goes when none of it
    /// does.
    ///
    /// Not a judgement about whether the passage was rewritten. Carrying
    /// asks the alignment for every run that stayed the same, so a writer
    /// who rewrites a marked sentence can leave a word or a full stop
    /// standing by coincidence, and the mark survives as those — their own
    /// words drawn as the assistant's, in scraps.
    ///
    /// Three rules were tried to tell that apart and all three were wrong,
    /// each retiring marks on unread work the writer could plainly see:
    /// how much of the marked text is left retires an honest deletion; how
    /// thinly it is spread retires an honest insertion; neither can tell
    /// an insertion, a deletion and a replacement apart, which is what the
    /// question actually asks. Answering it needs what the alignment knows
    /// about the gaps between the runs, not arithmetic on the runs. Until
    /// then a scrap left marked is the lesser harm: the writer sees it and
    /// can clear it, where a mark quietly retired is work they never read.
    @Test func amarkKeepsWhateverOfItStillStands() {
        let before = "Noah was ready."
        let shown = "The flood came suddenly. Noah was ready."
        let marked = LampWritingReview(writingID: "w").markingAssistantChange(from: before, to: shown)

        // Typed into, and deleted from: still the assistant's passage.
        for edited in ["The flood came very suddenly. Noah was ready.",
                       "The flood came. Noah was ready."] {
            #expect(!marked.carryingWriterEdit(from: shown, to: edited)
                .highlightedRanges(in: edited).isEmpty)
        }

        // Taken out altogether: nothing of it stands, and it is retired.
        let gone = "Noah was ready."
        let after = marked.carryingWriterEdit(from: shown, to: gone)
        #expect(after.highlightedRanges(in: gone).isEmpty)
        #expect(after.retired.count == 1)
    }

    /// A piece that began or ended inside a word is still found there.
    @Test func apieceInsideAWordIsFoundInsideOne() {
        let piece = LampWritingReview.Piece(text: "our", before: "col", after: "", hint: 3)
        #expect(LampWritingReview.find(piece, in: "A colour." as NSString) == NSRange(location: 5, length: 3))
    }

    /// A record and the date of the file it came from are taken together,
    /// whatever writes around them.
    @Test func asnapshotsDateIsTheDateOfItsRecord() throws {
        let store = try temporaryStore()
        #expect(try store.snapshot(writingID: "w") == .init(review: LampWritingReview(writingID: "w"), modified: nil))
        let made = try store.updating(writingID: "w") { $0.markingAssistantChange(from: "a", to: "b") }
        let url = try store.url(writingID: "w")
        #expect(made.modified == (try FileManager.default.attributesOfItem(atPath: url.path))[.modificationDate] as? Date)
        #expect(try store.snapshot(writingID: "w") == made)

        // Written over and over from elsewhere, every snapshot's record is
        // the one on disk at its date: none is paired with a later write.
        let other = LampWritingReviewStore(rootURL: store.rootURL)
        var mismatches = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 80) { round in
            if round.isMultiple(of: 2) {
                _ = try? other.update(writingID: "w") { $0.markingAssistantChange(from: "", to: "w\(round)") }
            } else if let seen = try? store.snapshot(writingID: "w"),
                      let again = try? store.snapshot(writingID: "w"),
                      seen.modified == again.modified, seen.review != again.review {
                lock.lock(); mismatches += 1; lock.unlock()
            }
        }
        #expect(mismatches == 0)
    }

    /// A writing deleted and saved again under its id is not deleted, so its
    /// marks are not swept.
    @Test func awritingSavedAgainAfterItsDeletionIsNotDeleted() {
        var ledger = LampPersonalDeletionLedger()
        ledger.set(.init(presentSince: 100, deletedAt: 200), kind: .devotional, key: "gone")
        ledger.set(.init(presentSince: 300, deletedAt: 200), kind: .devotional, key: "back")
        ledger.set(.init(presentSince: 100), kind: .devotional, key: "never")
        #expect(LampWritingReviewStore.deletedWritings(in: ledger) == ["gone"])
    }
}

/// When a document's review record goes with it, which the Mac got wrong
/// three times before this was one rule.
struct WritingDocumentReviewFateTests {
    private typealias Fate = LampWritingDocumentReview.Fate

    /// Absence is not deletion. A device whose document upload failed
    /// while its review upload succeeded leaves a record the library
    /// names and a document it does not — and another device must not
    /// read that as the document having been deleted.
    @Test func arecordIsNotSweptBecauseItsDocumentIsNotUploadedYet() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: nil, document: nil, documentWritten: 100, asked: nil, now: 500
        ) == .none)
    }

    /// The document is here, so its marks are its own — and a deletion
    /// asked for earlier is taken back.
    @Test func adocumentThatIsHereKeepsItsMarksAndCancelsAnyDeletion() {
        #expect(LampWritingDocumentReview.fate(
            held: true, deletedHere: nil, document: nil, documentWritten: nil, asked: nil, now: 500
        ) == .none)
        #expect(LampWritingDocumentReview.fate(
            held: true, deletedHere: (at: 200, revision: "r1"),
            document: nil, documentWritten: nil, asked: 200, now: 500
        ) == .cancelled)
    }

    /// A deletion made here stands, and takes the marks with it.
    @Test func adeletionMadeHereTakesTheMarksWithIt() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: (at: 200, revision: "r1"),
            document: (revision: "r1", isMember: true), documentWritten: 100, asked: nil, now: 500
        ) == .deleted(at: 200))
    }

    /// Unless another device saved the document since: then the document
    /// comes back, and its marks must not have been swept out from under
    /// it. This is the case that cost the marks of a live document twice.
    @Test func adeletionThatAnotherDevicesSaveBeatsTakesNothing() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: (at: 200, revision: "r1"),
            document: (revision: "r2", isMember: true), documentWritten: 300, asked: nil, now: 500
        ) == .none)
        // And one already asked for is taken back rather than left to win.
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: (at: 200, revision: "r1"),
            document: (revision: "r2", isMember: true), documentWritten: 300, asked: 200, now: 500
        ) == .cancelled)
    }

    /// The library naming a document it no longer holds is the one case
    /// where absence is evidence: it let the document go.
    @Test func thelibraryLettingADocumentGoTakesItsMarks() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: nil,
            document: (revision: "r1", isMember: false), documentWritten: 100, asked: nil, now: 500
        ) == .deleted(at: 500))
    }

    /// A document alive on the server that this device has not fetched
    /// yet keeps its marks: nothing here says anything about it.
    @Test func adocumentNotFetchedYetKeepsItsMarks() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: nil,
            document: (revision: "r1", isMember: true), documentWritten: 100, asked: nil, now: 500
        ) == .none)
    }
}

/// Which writing and document a review file is for, which both apps
/// worked out for themselves and both got wrong once.
struct WritingDocumentReviewPlaceTests {
    private let id = "exhortation-2026-11-21"

    @Test func theprosesFileAnswersWithNoDocument() throws {
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id)
        let place = try #require(LampWritingDocumentReview.place(of: path, record: nil))
        #expect(place.writingID == id)
        #expect(place.document == nil)
    }

    @Test func adocumentsFileAnswersWithItsName() throws {
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: "outline.md")
        let place = try #require(LampWritingDocumentReview.place(of: path, record: nil))
        #expect(place.document == "outline.md")
    }

    /// A name too long to keep is a digest, so the record is asked — and
    /// then checked, or a file put at another document's path would be
    /// read as the document it names rather than refused.
    @Test func anameFromTheRecordMustBeTheNameThatMakesThisFilesName() throws {
        let long = String(repeating: "\u{5D0}", count: 90) + ".md"
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: long)

        #expect(LampWritingDocumentReview.place(of: path, record: nil) == nil)
        let its = LampWritingReview(writingID: id, document: long)
        #expect(LampWritingDocumentReview.place(of: path, record: its)?.document == long)
        // Another document's record at this path is refused.
        let another = LampWritingReview(writingID: id, document: "notes.md")
        #expect(LampWritingDocumentReview.place(of: path, record: another) == nil)
    }

    @Test func apathThatIsNoReviewFileAnswersWithNothing() {
        #expect(LampWritingDocumentReview.place(of: "Workspaces/Writing/x/y.md", record: nil) == nil)
    }
}

/// The time that decides whether a deletion still stands is the
/// document's, never its record's.
///
/// Handed the record's, a document deleted here at 200 and saved by
/// another device at 300 lost every mark on it: the record had not been
/// touched since 100, so the deletion looked unopposed. The document
/// came back and its marks did not. The model said the same thing in the
/// same wrong words, so its table agreed — which is why this is a test
/// about the two times and not another row.
struct WritingDocumentReviewFateTimeTests {
    @Test func adeletionIsBeatenByAnewerDocumentNotAnewerRecord() {
        // The record last seen at 100, the document saved at 300, the
        // deletion made here at 200: the document wins and keeps its marks.
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: (at: 200, revision: "r1"),
            document: (revision: "r2", isMember: true),
            documentWritten: 300, asked: nil, now: 500
        ) == .none)
        // The same deletion against a document nobody has saved since.
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: (at: 200, revision: "r1"),
            document: (revision: "r1", isMember: true),
            documentWritten: 100, asked: nil, now: 500
        ) == .deleted(at: 200))
    }
}

/// Where a marker lands in Markdown that is not plain prose.
///
/// `markedMarkdown` puts a marker at each edge of a marked passage, on
/// the stated grounds that a private-use character is a letter to every
/// Markdown rule. A letter is exactly the problem: inside a link's
/// address it is part of the address, and between the stars of an
/// emphasis run it stops the run being one.
struct WritingMarkedMarkdownPlacementTests {
    private let start = LampWritingReview.markStart
    private let end = LampWritingReview.markEnd

    private func marked(_ old: String, _ new: String) -> String? {
        LampWritingReview(writingID: "w")
            .markingAssistantChange(from: old, to: new)
            .markedMarkdown(in: new)
    }

    @Test func amarkerCanLandInsideALinksAddress() throws {
        let old = "See the note."
        let new = "See [the note](https://example.com/a)."
        let out = try #require(marked(old, new))
        let address = try #require(out.range(of: "https://example.com/a"))
        let inside = out[address].contains(start) || out[address].contains(end)
        #expect(
            !inside,
            """
            A marker inside the address makes it a different address. \
            Marked Markdown: \(out.debugDescription)
            """
        )
    }

    @Test func amarkerCanSplitAnEmphasisRun() throws {
        let old = "A plain word."
        let new = "A *stressed* word."
        let out = try #require(marked(old, new))
        #expect(
            !out.contains("*\(start)") && !out.contains("\(end)*"),
            """
            A marker between the star and the word stops the pair reading as \
            emphasis, so the page draws the stars. Marked Markdown: \(out.debugDescription)
            """
        )
    }
}
