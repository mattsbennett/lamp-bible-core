import Foundation
import LampModuleKit

/// Where a device keeps its writings' review marks, one file each, laid out
/// as the server lays them out (`LampSyncFolderLayout.writingReviewPath`), so
/// a pass can upload a file from here and install one to here by its path.
///
/// Both apps use this, so a file merges the same way wherever it arrives:
/// the copy a pass downloads is merged into the one here, never put over it.
public struct LampWritingReviewStore: Sendable {
    /// The folder holding the `WritingReview` folder: the library's sync
    /// root on the Mac, the app's documents on the phone.
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var directoryURL: URL {
        rootURL.appendingPathComponent(LampSyncFolderLayout.writingReviewDirectory, isDirectory: true)
    }

    public func url(writingID: String) throws -> URL {
        rootURL.appendingPathComponent(try LampSyncFolderLayout.writingReviewPath(writingID: writingID))
    }

    /// The writing's marks, or an empty record where it has none. A file
    /// that cannot be read is an error, not an empty record: reading it as
    /// none would let the next write replace marks the writer still has.
    public func review(writingID: String) throws -> LampWritingReview {
        let url = try url(writingID: writingID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LampWritingReview(writingID: writingID)
        }
        return try LampWritingReview.decoded(from: Data(contentsOf: url))
    }

    /// Writes the record, unless the file already holds these bytes.
    /// Returns whether it wrote, which is whether a pass has anything to send.
    @discardableResult
    public func save(_ review: LampWritingReview) throws -> Bool {
        let url = try url(writingID: review.writingID)
        let data = try review.encoded()
        if (try? Data(contentsOf: url)) == data { return false }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Changes the writing's marks by `change`, and saves what comes of it.
    /// Returns the record as saved.
    @discardableResult
    public func update(
        writingID: String, _ change: (LampWritingReview) throws -> LampWritingReview
    ) throws -> LampWritingReview {
        let next = try change(review(writingID: writingID))
        try save(next)
        return next
    }

    /// Takes in a copy a pass downloaded: merged with the copy here, if any.
    /// Returns whether the merged record differs from what was downloaded,
    /// which is whether it has to go back up — this device had marks or
    /// clears the server's copy did not.
    ///
    /// When it does, the file is dated now even if its bytes did not move.
    /// A pass records what it downloaded, so the file differing from that is
    /// work for the next pass; but a device that starts passes by watching
    /// file dates would not see it, and the clear would wait for something
    /// else to start one.
    @discardableResult
    public func takeIn(downloaded data: Data, writingID: String) throws -> Bool {
        let incoming = try LampWritingReview.decoded(from: data)
        let merged = try review(writingID: writingID).merged(with: incoming)
        let wrote = try save(merged)
        let differs = try merged.encoded() != incoming.encoded()
        if differs, !wrote {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: try url(writingID: writingID).path
            )
        }
        return differs
    }

    /// Removes the writing's marks, as its writing is deleted. The caller
    /// records the removal as a deletion, so other devices remove theirs.
    public func remove(writingID: String) throws {
        let url = try url(writingID: writingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The deletions a pass records for the marks of writings deleted, by
    /// path, at the time each writing went; the files here are removed as
    /// they are found.
    ///
    /// A writing's marks go with it everywhere. A file only removed here
    /// would be fetched again from the server's copy, so each is recorded
    /// as a deletion, as a deck of a deleted writing is — but only where
    /// there is a file to delete, here or on the server, so a writing that
    /// was never reviewed leaves no tombstone behind.
    ///
    /// `deleted` is the writings deleted, from the personal ledger; `held`
    /// the writings this device still has, which win over a deletion of the
    /// same id; `members` the paths the library's manifest names; `now` the
    /// time to record, in milliseconds. Ids are compared folded, since a
    /// writing's is not spelled alike on every platform.
    ///
    /// Recorded now, not at the writing's own time. Marks cleared on another
    /// device after the writing went are still the marks of a writing that
    /// is gone, and a deletion dated before that upload would lose to it:
    /// the file would come back down, be swept again, and do so on every
    /// pass. Once recorded the path is no member and there is no file, so
    /// nothing is recorded again.
    public func deletions(
        deleted: Set<String>, held: Set<String>, members: Set<String>, now: Int64
    ) throws -> [String: Int64] {
        let gone = Set(deleted.map { $0.lowercased() }).subtracting(held.map { $0.lowercased() })
        guard !gone.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        for id in try writingIDs() where gone.contains(id.lowercased()) {
            try remove(writingID: id)
            result[try LampSyncFolderLayout.writingReviewPath(writingID: id)] = now
        }
        for path in members {
            guard let id = LampSyncFolderLayout.writingID(ofReviewPath: path),
                  gone.contains(id.lowercased()) else { continue }
            result[path] = now
        }
        return result
    }

    /// The writing ids that have a file here.
    public func writingIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .compactMap { LampSyncFolderLayout.writingID(ofReviewPath: "\(LampSyncFolderLayout.writingReviewDirectory)/\($0)") }
            .sorted()
    }

    /// How long a retirement is kept before it is pruned. A device away
    /// from sync for longer than this could show a passage it last saw
    /// marked as marked again; nothing else depends on it.
    public static let retirementLifetime: TimeInterval = 60 * 60 * 24 * 90
}
