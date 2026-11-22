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

/// Markers placed so the Markdown still reads as what it is.
///
/// Every case here was a round of review on the iOS app, where this
/// came from. The Mac's editor page fails differently — it compares
/// what it parsed against the document it holds and refuses the marks
/// when they differ — so there the cost is a passage with no mark on it
/// rather than a mangled one. Both are the feature not working.
struct WritingReviewMarkdownPlacementTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let start = String(LampWritingReview.markStart)
    private let end = String(LampWritingReview.markEnd)

    /// What a renderer is given must read as what the writing says once
    /// the markers come out: that is the whole contract.
    private func readsTheSame(_ marked: String) -> Bool {
        let drawn = Markdown.drawable(marked, numbering: false)
        return Markdown.unmarked(drawn) == Markdown.unmarked(marked)
    }

    @Test func amarkerInsideALinksAddressComesOut() {
        let marked = "See [the note](https://example.com/\(start)a\(end))."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(!drawn.contains("example.com/\(start)"))
        #expect(drawn.contains("(https://example.com/a)"))
        #expect(readsTheSame(marked))
    }

    /// A marker inside an emphasis is harmless — both stars still flank
    /// a letter, so it is still an emphasis — and is left alone.
    @Test func amarkerInsideAnEmphasisIsLeftWhereItIs() {
        let marked = "A *\(start)stressed\(end)* word."
        #expect(readsTheSame(marked))
        #expect(Markdown.drawable(marked, numbering: false).contains("*\(start)stressed"))
    }

    /// A marker that splits a run of delimiters is the one that breaks:
    /// `**` with something between the stars is two runs of one, and the
    /// stars are drawn instead of the strength. It is moved out.
    @Test func amarkerSplittingADelimiterRunIsMovedOut() {
        let marked = "A *\(start)*strong*\(end)* word."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("**"), "the run came apart: \(drawn.debugDescription)")
        #expect(readsTheSame(marked))
    }

    @Test func amarkerBeforeAHeadingsHashMovesAfterIt() {
        let marked = "\(start)# A heading\(end)"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.hasPrefix("# "))
        #expect(readsTheSame(marked))
    }

    @Test func amarkerBetweenABackslashAndWhatItEscapesMovesPastIt() {
        let marked = "A \\\(start)*not emphasis\(end)*"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("\\*"))
        #expect(readsTheSame(marked))
    }

    /// Two gaps the iOS rounds left, taken with the lift.
    /// An entity is one token: a marker anywhere inside it leaves `&lt;`
    /// showing as itself. A change from `&lt;` to `&gt;` marks the name,
    /// not the `&` or the `;`, which is the case rules looking only at
    /// those two ends never caught.
    @Test func markersAnywhereInAnEntityMovePastIt() {
        for (entity, marked) in [
            ("&lt;", "&lt\(start);"),
            ("&gt;", "&\(start)gt\(end);"),
            ("&#65;", "&#6\(start)5\(end);"),
            ("&#x41;", "&\(start)#x41;"),
        ] {
            let drawn = Markdown.drawable(marked, numbering: false)
            #expect(drawn.hasPrefix(entity), "\(marked.debugDescription) came out as \(drawn.debugDescription)")
            #expect(Markdown.unmarked(drawn) == entity)
        }
    }

    /// A marked rule is left as it is.
    ///
    /// There is no place on a rule's line for a marker, and every place
    /// off it belongs to another line: appended to the one before, the
    /// markers end a fence that was closing, break a rule already
    /// placed, or stand before a list's dash and make it a paragraph.
    /// Each breaks a line that was correct to save one that cannot be,
    /// and a surface that checks what it parsed then refuses every mark
    /// in the writing — so a marked rule took the lot down with it.
    @Test func amarkedRuleIsLeftAloneRatherThanBreakingItsNeighbours() {
        for neighbour in ["- item", "```", "| a |", "---"] {
            let marked = "\(start)---\(end)\n\(neighbour)"
            let drawn = Markdown.drawable(marked, numbering: false)
            let lines = drawn.components(separatedBy: "\n")
            #expect(
                lines.last == neighbour,
                "the rule's markers broke \(neighbour.debugDescription): \(drawn.debugDescription)"
            )
            #expect(Markdown.unmarked(drawn) == "---\n\(neighbour)")
        }
    }

    /// The block pass runs before the inline one. An italic heading
    /// arrives as a marker before the `#` and another inside the closing
    /// underscore; moving the first after the `#` last would leave the
    /// opening underscore between two letters, opening nothing.
    @Test func amarkedItalicHeadingStillOpensItsEmphasis() {
        let marked = "\(start)# _new_\(end)"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.hasPrefix("# "))
        let body = drawn.dropFirst(2)
        #expect(body.hasPrefix("_") || body.dropFirst().hasPrefix("_"),
                "the emphasis cannot open: \(drawn.debugDescription)")
        #expect(Markdown.unmarked(drawn) == "# _new_")
    }

    /// Numbering is for a surface that draws whatever it parses; one that
    /// refuses marks it cannot place needs none, and the markers it is
    /// given are the three it knows.
    @Test func withoutNumberingNoNewCharactersAreAdded() {
        let marked = "A \(start)changed\(end) word."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(!drawn.contains(where: { Markdown.placeDigit($0) != nil }))
        #expect(!drawn.contains(LampWritingReviewMarkdown.placeEnd))
        #expect(Markdown.drawable(marked).contains(LampWritingReviewMarkdown.placeEnd))
    }
}

/// What every marker move must leave alone, over the shapes the rules
/// exist for.
///
/// The rules are about a Markdown parser neither app owns, so they are
/// not modelled; what is (`Verification/SyncMerge.lean`:
/// `movingAMarkerLeavesTheWritingAlone`, `movingAMarkerLosesNoPassage`)
/// is what must hold however they move a marker — the writing itself
/// untouched, and no passage left without something for the writer to
/// reach. A rule that dropped a marker, or took a character with it,
/// would be a change the writer can never see or never clear.
struct WritingReviewMarkdownContractTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)
    private let p = String(LampWritingReview.markPoint)

    private var shapes: [String] {
        [
            "A \(s)changed\(e) word.",
            "See [the note](https://example.com/\(s)a\(e)).",
            "See \(s)[the note](https://example.com/a)\(e).",
            "An image ![alt](pic\(s)ture\(e).png) here.",
            "An autolink <https://exa\(s)mple\(e).com/x> here.",
            "Bare https://exa\(s)mple\(e).com/x here.",
            "A *\(s)stressed\(e)* word.",
            "A *\(s)*strong*\(e)* word.",
            "A `co\(s)de\(e)` span.",
            "An escape \\\(s)*not emphasis\(e)*.",
            "\(s)# A heading\(e)",
            "\(s)- A list item\(e)",
            "\(s)> A quotation\(e)",
            "\(s)1. A numbered item\(e)",
            "\(s)---\(e)",
            "An entity &l\(s)t\(e); here.",
            "A point\(p) where words went.",
            "| a | b |\n|\(s)---\(e)|---|\n| 1 | 2 |",
            "Two \(s)one\(e) and \(s)two\(e) in a line.",
            "\(s)Across\nlines\(e) here.",
            "Nothing marked at all.",
        ]
    }

    /// The writing itself is what it was: the markers moved, and nothing
    /// of the writer's words went with them.
    @Test func everyShapeKeepsTheWritingItself() {
        for shape in shapes {
            for numbering in [false, true] {
                let drawn = Markdown.drawable(shape, numbering: numbering)
                #expect(
                    Markdown.unmarked(drawn) == Markdown.unmarked(shape),
                    """
                    The writing changed. From \(shape.debugDescription) \
                    came \(drawn.debugDescription)
                    """
                )
            }
        }
    }

    /// And every passage still has something the writer can reach: a
    /// start or a point for each one there was.
    @Test func everyShapeKeepsEveryPassageReachable() {
        func reachable(_ text: String) -> Int {
            text.filter { $0 == LampWritingReview.markStart || $0 == LampWritingReview.markPoint }
                .count
        }
        for shape in shapes {
            for numbering in [false, true] {
                let drawn = Markdown.drawable(shape, numbering: numbering)
                #expect(
                    reachable(drawn) == reachable(shape),
                    """
                    A passage lost what the writer reaches for. From \
                    \(shape.debugDescription) came \(drawn.debugDescription)
                    """
                )
            }
        }
    }
}

/// Placing markers can reorder passages, and a surface that pairs by
/// order must be handed its things in the new one.
struct WritingReviewMarkdownOrderTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    /// A change to a link's words and a change to where it points. The
    /// second one's markers come out of the address and go before the
    /// first, so the passages swap: a surface pairing in order would
    /// give the label the destination's change, and a writer putting one
    /// back would get the other.
    @Test func alinksLabelAndDestinationComeBackInTheOtherOrder() {
        let marked = "[\(s)later\(e)](https://host/\(s)newpath\(e))"
        let placed = Markdown.placed(marked)
        #expect(!placed.markdown.contains(where: { Markdown.placeDigit($0) != nil }))
        #expect(placed.order == [1, 0], "came out \(placed.order)")
        // So what the surface is handed goes over in that order.
        #expect(Markdown.reordered(["label", "destination"], by: placed.order)
            == ["destination", "label"])
    }

    /// Where nothing moved, nothing is reordered.
    @Test func plainProseKeepsItsOrder() {
        let marked = "One \(s)alpha\(e) and two \(s)beta\(e) here."
        let placed = Markdown.placed(marked)
        #expect(placed.order == [0, 1])
        #expect(Markdown.reordered(["a", "b"], by: placed.order) == ["a", "b"])
        #expect(Markdown.unmarked(placed.markdown) == Markdown.unmarked(marked))
    }

    /// The placed text is the same as the unnumbered placement, so a
    /// surface sees exactly what it saw before.
    @Test func whatTheSurfaceSeesCarriesNoPlaces() {
        for marked in [
            "[\(s)later\(e)](https://host/\(s)newpath\(e))",
            "A \(s)changed\(e) word.",
            "Before.\n\(s)---\(e)\nAfter.",
        ] {
            let placed = Markdown.placed(marked)
            #expect(placed.markdown == Markdown.drawable(marked, numbering: false))
        }
    }

    /// A caller whose things do not match its passages is left alone
    /// rather than paired by a guess.
    @Test func alistThatDoesNotMatchIsLeftAsItIs() {
        #expect(Markdown.reordered(["only"], by: [1, 0]) == ["only"])
        #expect(Markdown.reordered(["a", "b"], by: [0, 0]) == ["a", "b"])
    }
}

/// An entity's name has no length anyone can guess.
struct WritingReviewMarkdownEntityTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    @Test func alongEntityNameIsStillAnEntity() {
        for (entity, marked) in [
            ("&LeftRightArrow;", "&\(s)LeftRightArrow\(e);"),
            ("&LeftRightArrow;", "&LeftRightArrow\(e);"),
            ("&CounterClockwiseContourIntegral;", "&Counter\(s)ClockwiseContourIntegral;"),
        ] {
            let drawn = Markdown.drawable(marked, numbering: false)
            #expect(
                drawn.hasPrefix(entity),
                "\(marked.debugDescription) came out as \(drawn.debugDescription)"
            )
        }
    }
}

/// A document the library holds takes back a deletion of its marks.
///
/// Another device making the document again after a deletion this one
/// acknowledged brings its marks with it. The tombstone queued for
/// those marks would delete them while the same pass fetches the
/// document — found by the iOS session's review of its adoption.
struct WritingDocumentReviewFateRevivalTests {
    @Test func alivingDocumentCancelsTheDeletionOfItsMarks() {
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: nil,
            document: (revision: "r1", isMember: true),
            documentWritten: 300, asked: 200, now: 500
        ) == .cancelled)
        // With nothing asked for, there is nothing to take back.
        #expect(LampWritingDocumentReview.fate(
            held: false, deletedHere: nil,
            document: (revision: "r1", isMember: true),
            documentWritten: 300, asked: nil, now: 500
        ) == .none)
    }
}

/// Code is drawn as it is written, so no marker is moved inside it.
///
/// A link in a code span is text, not a link. Moving a marker out of
/// its "address" leaves the changed word unmarked and a point beside
/// the line — and on the page Next Change then lands on that point,
/// where Mark Selection as Reviewed clears nothing. Found by the iOS
/// session's review of its adoption.
struct WritingReviewMarkdownCodeTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    @Test func amarkInACodeSpanStaysOnTheWord() {
        let marked = "Run `curl https://x.com/\(s)new\(e)` first."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(
            drawn.contains("x.com/\(s)new\(e)"),
            "the mark left the word: \(drawn.debugDescription)"
        )
        #expect(Markdown.unmarked(drawn) == "Run `curl https://x.com/new` first.")
    }

    @Test func amarkInAFencedBlockStaysWhereItIs() {
        let marked = "```sh\ncurl https://x.com/\(s)new\(e)\n```"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("x.com/\(s)new\(e)"), "\(drawn.debugDescription)")
        #expect(Markdown.unmarked(drawn) == "```sh\ncurl https://x.com/new\n```")
    }

    /// A list marker inside a fence is code, not a list, so nothing is
    /// moved past it either.
    @Test func blockSyntaxInsideAFenceIsLeftAlone() {
        let marked = "```\n\(s)- not a list\(e)\n```"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("\(s)- not a list"), "\(drawn.debugDescription)")
    }

    /// And a real link outside the code on the same line is still moved.
    @Test func alinkBesideCodeIsStillPutRight() {
        let marked = "`code` and [a](https://x.com/\(s)y\(e))."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("(https://x.com/y)"), "\(drawn.debugDescription)")
        #expect(Markdown.unmarked(drawn) == "`code` and [a](https://x.com/y).")
    }
}

/// Fences matched to their opener, code spans masked rather than cut,
/// and the point a syntax-only change leaves behind.
///
/// Round nine and the iOS session's own review, which found the fence
/// fault from opposite directions on the same hour.
struct WritingReviewMarkdownCodeFencesTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    /// A fence is closed only by its own character, at least as long.
    /// Toggling on any fence-looking line left the prose after a block
    /// holding a literal fence thinking it was still inside one, so its
    /// markers stayed where they broke the parse.
    @Test func aliteralFenceInsideABlockDoesNotCloseIt() {
        let marked = "````\n~~~\n```\n````\n\(s)# After\(e)"
        let drawn = Markdown.drawable(marked, numbering: false)
        let lines = drawn.components(separatedBy: "\n")
        #expect(lines.last?.hasPrefix("# ") == true, "\(drawn.debugDescription)")
        // And what is inside is untouched.
        #expect(lines[1] == "~~~" && lines[2] == "```")
    }

    /// A link whose label holds a code span is still put right. Cutting
    /// the line at the span left no rule able to see the link whole, so
    /// a marker in its address stayed there.
    @Test func alinkWhoseLabelHoldsCodeIsStillPutRight() {
        let marked = "See [the `curl` note](https://x.com/\(s)a\(e))."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("(https://x.com/a)"), "\(drawn.debugDescription)")
        #expect(drawn.contains("`curl`"))
        #expect(Markdown.unmarked(drawn) == "See [the `curl` note](https://x.com/a).")
    }

    /// An escaped backtick opens nothing. Pairing it with a real span
    /// later in the line swallowed the link between them.
    @Test func anEscapedBacktickOpensNoCodeSpan() {
        let marked = "\\` [l](https://x.com/\(s)new\(e)) `code`"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("(https://x.com/new)"), "\(drawn.debugDescription)")
        #expect(drawn.contains("`code`"))
    }

    /// A change to block syntax alone is drawn as a point after the
    /// syntax, while the mark is on the syntax: a range from there
    /// reaches back, or clearing and restoring do nothing at all.
    @Test func arangeAfterBlockSyntaxReachesBackToIt() {
        let text = "# Title\n\nBody."
        let afterHash = NSRange(location: 2, length: 0)
        #expect(Markdown.takingInSyntax(afterHash, of: text) == NSRange(location: 0, length: 2))
        // A range already at the line's start is left alone, and so is
        // one inside ordinary prose.
        #expect(Markdown.takingInSyntax(NSRange(location: 0, length: 0), of: text)
            == NSRange(location: 0, length: 0))
        #expect(Markdown.takingInSyntax(NSRange(location: 11, length: 2), of: text)
            == NSRange(location: 11, length: 2))
    }
}

/// A bare URL stops at a table's pipe.
///
/// The markers go on before any table is split, so a bare-URL run that
/// crossed a pipe swallowed the next cell and carried its markers out
/// in front of this cell's address: the changed word lost its highlight
/// and a stray caret appeared beside a URL nobody had touched. Found by
/// the iOS session.
struct WritingReviewMarkdownTableTests {
    private typealias Markdown = LampWritingReviewMarkdown
    private let s = String(LampWritingReview.markStart)
    private let e = String(LampWritingReview.markEnd)

    @Test func abareUrlDoesNotReachIntoTheNextCell() {
        let marked = "|https://example.com|\(s)new\(e)|"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(drawn.contains("|\(s)new\(e)|"), "\(drawn.debugDescription)")
        #expect(Markdown.unmarked(drawn) == "|https://example.com|new|")
    }

    /// A marked bare URL in its own cell is still put right.
    @Test func amarkedBareUrlInACellIsStillPutRight() {
        let marked = "|https://example.com/\(s)a\(e)|next|"
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(Markdown.unmarked(drawn) == "|https://example.com/a|next|")
        #expect(drawn.contains("|next|"), "\(drawn.debugDescription)")
    }

    /// And outside a table a bare URL is unchanged by this.
    @Test func abareUrlInProseIsUnaffected() {
        let marked = "See https://example.com/\(s)a\(e) for more."
        let drawn = Markdown.drawable(marked, numbering: false)
        #expect(Markdown.unmarked(drawn) == "See https://example.com/a for more.")
    }
}

/// Reaching outward over emphasis delimiters, and an undone restore
/// that stays owed. Both from the iOS session's review.
struct WritingReviewDelimiterReachTests {
    private typealias Markdown = LampWritingReviewMarkdown

    /// `red dog` becoming `**red dog**`: the marks are on the two `**`,
    /// placement puts them at the words' edges, and a clear of the words
    /// alone left the delimiters marked with the count unmoved.
    @Test func aclearOfTheWordsReachesTheEmphasisAroundThem() {
        let text = "Her **red dog** barked."
        // "red dog" alone.
        let words = NSRange(location: 6, length: 7)
        #expect((text as NSString).substring(with: words) == "red dog")
        let reached = Markdown.takingInDelimiters(words, of: text)
        #expect((text as NSString).substring(with: reached) == "**red dog**")
    }

    @Test func otherDelimitersReachTheSameWay() {
        for (text, inner) in [
            ("a *it* b", "it"), ("a _it_ b", "it"), ("a ~~it~~ b", "it"), ("a `it` b", "it"),
        ] {
            let source = text as NSString
            let at = source.range(of: inner)
            let reached = Markdown.takingInDelimiters(at, of: text)
            #expect(
                source.substring(with: reached).contains(inner),
                "\(text): reached \(source.substring(with: reached).debugDescription)"
            )
            #expect(reached.length > at.length, "\(text)")
        }
    }

    /// It never reaches past the line, which would take in text the
    /// writer never selected.
    @Test func itneverReachesPastTheLine() {
        let text = "*\nword\n*"
        let word = (text as NSString).range(of: "word")
        #expect(Markdown.takingInDelimiters(word, of: text) == word)
    }

    /// Plain prose is left exactly as it was.
    @Test func plainProseIsUntouched() {
        let text = "Nothing to reach here."
        let at = NSRange(location: 8, length: 2)
        #expect(Markdown.takingInDelimiters(at, of: text) == at)
    }

    /// A heading whose words are emphasised wants both reaches.
    @Test func bothReachesTogether() {
        let text = "# **Title** here"
        let title = (text as NSString).range(of: "Title")
        let reached = Markdown.takingInSyntaxAndDelimiters(title, of: text)
        #expect((text as NSString).substring(with: reached) == "# **Title**")
    }
}

/// An undone restore stays owed rather than being dropped.
struct WritingRestoreDormantTests {
    private typealias Plan = LampWritingReview.RestorePlan

    /// Redo puts the restored wording back without the surface asking
    /// anything, so a passage gone from both texts is not finished with:
    /// dropped, it is owed by nobody, and the save that then holds it
    /// records nothing — no restoration reaches the assistant and its
    /// unread words carry no mark.
    @Test func anundonePassageIsDormantRatherThanDropped() {
        let a = UUID()
        let out = Plan.settlement(
            pending: [a], inSaved: [a: .gone], inCurrent: [a: .gone]
        )
        #expect(out.record.isEmpty)
        #expect(out.waiting.isEmpty, "it must not hold up the queue")
        #expect(out.dormant == [a], "it must still be owed")
    }

    /// And a later save that holds the restored wording records it.
    @Test func alaterSaveRecordsWhatWasDormant() {
        let a = UUID()
        let out = Plan.settlement(
            pending: [a], inSaved: [a: .stands], inCurrent: [a: .stands]
        )
        #expect(out.record == [a])
        #expect(out.dormant.isEmpty)
    }

    /// A passage still standing in the writer's text waits as before.
    @Test func apassageStillInTheWritersTextWaits() {
        let a = UUID()
        let out = Plan.settlement(
            pending: [a], inSaved: [a: .gone], inCurrent: [a: .stands]
        )
        #expect(out.waiting == [a])
        #expect(out.dormant.isEmpty)
    }
}

/// A delimiter run is taken in only where its emphasis encloses the
/// selection. Found by the iOS session, against the first version.
struct WritingReviewDelimiterEnclosureTests {
    private typealias Markdown = LampWritingReviewMarkdown

    /// The writer selects the unchanged words before a bolded one. The
    /// selection's end touches the opening `**`, but that emphasis does
    /// not enclose it, so nothing is taken in — reaching over it partly
    /// cleared the mark on a word they never selected, and Restore
    /// Original Wording then answered `notExact` for it.
    @Test func arunTouchedFromOutsideIsLeftAlone() {
        let text = "intro **word** after"
        let intro = NSRange(location: 0, length: 6)
        #expect((text as NSString).substring(with: intro) == "intro ")
        #expect(Markdown.takingInDelimiters(intro, of: text) == intro)
    }

    /// The mirror: selecting what follows the closing run.
    @Test func arunTouchedFromTheOtherSideIsLeftAlone() {
        let text = "intro **word** after"
        let after = NSRange(location: 14, length: 6)
        #expect((text as NSString).substring(with: after) == " after")
        #expect(Markdown.takingInDelimiters(after, of: text) == after)
    }

    /// And the enclosing case still reaches, which is the whole point.
    @Test func anenclosingEmphasisIsStillTakenIn() {
        let text = "intro **word** after"
        let word = (text as NSString).range(of: "word")
        let reached = Markdown.takingInDelimiters(word, of: text)
        #expect((text as NSString).substring(with: reached) == "**word**")
    }

    /// A selection enclosed by emphasis but wider than one word.
    @Test func awiderEnclosedSelectionReaches() {
        let text = "Her **red dog** barked."
        let words = (text as NSString).range(of: "red dog")
        let reached = Markdown.takingInDelimiters(words, of: text)
        #expect((text as NSString).substring(with: reached) == "**red dog**")
    }
}

/// Delimiters are taken in by pairing, not by matching.
///
/// The iOS session's second finding on this: looking for a run that
/// merely matches finds the wrong one when a line holds two emphases.
struct WritingReviewDelimiterPairingTests {
    private typealias Markdown = LampWritingReviewMarkdown

    /// The assistant bolds two words; the writer clears only what lies
    /// between them. The end touches the second's opening run, and a
    /// matching run does stand earlier on the line — the first's
    /// closing one — so the old check accepted it and partly cleared
    /// the untouched second word's mark.
    @Test func thewordsBetweenTwoEmphasesTakeNothingIn() {
        let text = "**one** middle **two**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// And the second word still takes in its own pair.
    @Test func thesecondWordTakesInItsOwnPair() {
        let text = "**one** middle **two**"
        let two = (text as NSString).range(of: "two")
        let reached = Markdown.takingInDelimiters(two, of: text)
        #expect((text as NSString).substring(with: reached) == "**two**")
    }

    @Test func thefirstWordTakesInItsOwnPair() {
        let text = "**one** middle **two**"
        let one = (text as NSString).range(of: "one")
        let reached = Markdown.takingInDelimiters(one, of: text)
        #expect((text as NSString).substring(with: reached) == "**one**")
    }

    /// Mixed kinds pair within their own character.
    @Test func mixedKindsPairWithinTheirOwnCharacter() {
        let text = "a *it* and `code` here"
        let it = (text as NSString).range(of: "it")
        #expect((text as NSString).substring(with: Markdown.takingInDelimiters(it, of: text)) == "*it*")
        let code = (text as NSString).range(of: "code")
        #expect(
            (text as NSString).substring(with: Markdown.takingInDelimiters(code, of: text))
                == "`code`"
        )
    }

    /// An unpaired run encloses nothing.
    @Test func anunpairedRunTakesNothingIn() {
        let text = "a * lonely star"
        let lonely = (text as NSString).range(of: "lonely")
        #expect(Markdown.takingInDelimiters(lonely, of: text) == lonely)
    }
}

/// Delimiters that are not delimiters, and carets.
///
/// The iOS session's third and fourth findings on `takingInDelimiters`.
struct WritingReviewDelimiterLiteralsTests {
    private typealias Markdown = LampWritingReviewMarkdown

    /// Stars inside a code span are letters. Paired with a real run
    /// they made the code span's opener the partner of a real word's,
    /// so a clear between them reached over that word's opener and
    /// partly cleared its mark.
    @Test func starsInsideACodeSpanPairWithNothing() {
        let text = "`**` middle **word**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// And the real pair on that line still works.
    @Test func therealPairBesideCodeStillReaches() {
        let text = "`**` middle **word**"
        let word = (text as NSString).range(of: "word")
        let reached = Markdown.takingInDelimiters(word, of: text)
        #expect((text as NSString).substring(with: reached) == "**word**")
    }

    /// An escaped delimiter is the character itself.
    @Test func anescapedDelimiterPairsWithNothing() {
        let text = "\\** middle **word**"
        let middle = (text as NSString).range(of: "middle ")
        #expect(Markdown.takingInDelimiters(middle, of: text) == middle)
    }

    /// A caret is left where it is. Widened to the delimiters beside
    /// it, Mark Selection as Reviewed became a partial clear of them
    /// rather than a clear of the whole mark under the caret.
    @Test func acaretIsLeftExactlyWhereItIs() {
        let text = "Her **red dog** barked."
        let beforeRed = NSRange(location: 6, length: 0)
        #expect((text as NSString).substring(with: NSRange(location: 6, length: 3)) == "red")
        #expect(Markdown.takingInDelimiters(beforeRed, of: text) == beforeRed)
        let afterDog = NSRange(location: 13, length: 0)
        #expect(Markdown.takingInDelimiters(afterDog, of: text) == afterDog)
    }

    /// A caret is left alone by the combined form too.
    @Test func thecombinedFormLeavesACaretToTheBlockRule() {
        let text = "# **Title** here"
        let caret = NSRange(location: 2, length: 0)
        // The block rule still reaches back over the `# `.
        #expect(
            Markdown.takingInSyntaxAndDelimiters(caret, of: text)
                == NSRange(location: 0, length: 2)
        )
    }
}

/// An escaped run of one kind does not swallow the next kind.
struct WritingReviewEscapedRunBoundaryTests {
    @Test func anescapedRunStopsAtItsOwnCharacter() {
        // `\*` is literal; the `_it_` beside it still pairs.
        let text = "\\* _it_ here"
        let it = (text as NSString).range(of: "it")
        let reached = LampWritingReviewMarkdown.takingInDelimiters(it, of: text)
        #expect((text as NSString).substring(with: reached) == "_it_")
    }
}
