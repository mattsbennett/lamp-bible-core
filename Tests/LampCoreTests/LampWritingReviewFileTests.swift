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
}
