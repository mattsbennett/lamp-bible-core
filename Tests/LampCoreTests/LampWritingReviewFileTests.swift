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
        // The writer rewrites the marked sentence and keeps the other.
        let new = "The rain fell for days. Noah was ready."

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
        // The words the mark was made of are gone, so the mark is retired
        // rather than surviving as whatever scraps of it happen to stand.
        let carried = try store.review(writingID: id, document: name)
        #expect(carried.highlightedRanges(in: new).isEmpty)
        #expect(carried.retired.count == 1)
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

    /// A mark survives a writer's deletion of part of it, and their typing
    /// inside it, but not their rewriting of it: then what is left is
    /// scraps of their own sentence, not the assistant's passage.
    @Test func amarkSurvivesAnEditOfItButNotARewriteOfIt() {
        let before = "Noah was ready."
        let shown = "The flood came suddenly. Noah was ready."
        let marked = LampWritingReview(writingID: "w").markingAssistantChange(from: before, to: shown)
        #expect(marked.highlightedRanges(in: shown).count == 1)

        // Typed into: still the assistant's passage, in two runs.
        let typed = "The flood came very suddenly. Noah was ready."
        #expect(!marked.carryingWriterEdit(from: shown, to: typed)
            .highlightedRanges(in: typed).isEmpty)

        // Part deleted: what is left stands together, and is still theirs.
        let shortened = "The flood came. Noah was ready."
        #expect(!marked.carryingWriterEdit(from: shown, to: shortened)
            .highlightedRanges(in: shortened).isEmpty)

        // Rewritten: "The" and the full stop stand by coincidence, which is
        // not the mark. It is retired rather than drawn in scraps for ever.
        let rewritten = "The rain fell for days. Noah was ready."
        let after = marked.carryingWriterEdit(from: shown, to: rewritten)
        #expect(after.highlightedRanges(in: rewritten).isEmpty)
        #expect(after.retired.count == 1)
    }

    /// Both sides changing one document leaves this device's body under a
    /// copy's name: the marks were made of the words in that body, so they
    /// go with it, and the document's own name — now holding the server's
    /// body, which they were never made against — is left with none.
    @Test func marksGoWithTheBodyKeptAsACopy() throws {
        let store = try temporaryStore()
        let id = "exhortation-2026-01-18"
        let name = "outline.md"
        let copy = "outline (edits from Mac, 18 January 2026).md"
        let shown = "The flood came suddenly. Noah was ready."
        try store.save(
            LampWritingReview(writingID: id, document: name)
                .markingAssistantChange(from: "Noah was ready.", to: shown)
        )

        let deletions = try LampWritingDocumentReview.moved(
            name, to: copy, writingID: id, in: store, now: 100
        )
        #expect(try store.review(writingID: id, document: copy).highlightedRanges(in: shown).count == 1)
        #expect(try store.review(writingID: id, document: name).marks.isEmpty)
        // The record says which document it is for, or the next device to
        // take it in would refuse it.
        #expect(try store.review(writingID: id, document: copy).document == copy)
        // And the record left behind is recorded as deleted, or it comes
        // back from the server on the next pass.
        #expect(deletions.keys.sorted() == [
            try LampSyncFolderLayout.writingReviewPath(writingID: id, document: name)
        ])
    }

    /// A deleted document's marks go with it, and the deletion is recorded
    /// so other devices sweep theirs. A rename is a deletion and a new
    /// document, so its marks are gone: carrying them over would mean
    /// deciding two documents are one from their words alone.
    @Test func adeletedDocumentsMarksAreSweptAndRecorded() throws {
        let store = try temporaryStore()
        let id = "exhortation-2026-01-18"
        try store.save(LampWritingReview(writingID: id, document: "outline.md"))
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: id, document: "outline.md")

        let deletions = try LampWritingDocumentReview.removed(
            "outline.md", writingID: id, in: store, members: [path: 500], now: 100
        )
        #expect(try store.reviewed().isEmpty)
        // Never before the write the manifest holds: a device whose clock
        // runs ahead wrote it after this one's now.
        #expect(deletions == [path: 501])
    }

    /// A mark an ordinary save had split into two pieces is judged as one
    /// mark when the writer rewrites it, not as two little ones.
    ///
    /// Judged piece by piece, "The" survives whole in the first and "."
    /// whole in the second, each filling its own span — so a save between
    /// the typing and the rewrite decided whether the mark survived it.
    @Test func amarkSplitByAnEarlierSaveIsStillJudgedWhole() {
        let before = "Noah was ready."
        let shown = "The flood came suddenly. Noah was ready."
        let marked = LampWritingReview(writingID: "w").markingAssistantChange(from: before, to: shown)

        // A word typed into the middle of it: two pieces now.
        let typed = "The flood came very suddenly. Noah was ready."
        let split = marked.carryingWriterEdit(from: shown, to: typed)
        #expect(!split.highlightedRanges(in: typed).isEmpty)

        // And then rewritten. The mark goes, as it does without the save.
        let rewritten = "The rain fell for days. Noah was ready."
        let after = split.carryingWriterEdit(from: typed, to: rewritten)
        #expect(after.highlightedRanges(in: rewritten).isEmpty)
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
