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
