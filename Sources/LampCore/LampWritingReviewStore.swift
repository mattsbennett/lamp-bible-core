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

    /// Where a writing's marks are kept, or those of one document beside
    /// it. Nil document throughout here means the writing's own prose,
    /// whose file keeps the name and the meaning it has always had.
    public func url(writingID: String, document: String? = nil) throws -> URL {
        rootURL.appendingPathComponent(
            try LampSyncFolderLayout.writingReviewPath(writingID: writingID, document: document)
        )
    }

    /// The writing's marks, or an empty record where it has none. A file
    /// that cannot be read is an error, not an empty record: reading it as
    /// none would let the next write replace marks the writer still has.
    public func review(writingID: String, document: String? = nil) throws -> LampWritingReview {
        let url = try url(writingID: writingID, document: document)
        return try Self.locks.holding(url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return LampWritingReview(writingID: writingID, document: document)
            }
            return try LampWritingReview.decoded(from: Data(contentsOf: url))
        }
    }

    /// A writing's marks with the date of the file they were read from.
    ///
    /// Both are taken under the file's lock. A watcher that read the record
    /// and then the date apart could pair an older record with the date of a
    /// write that landed between the two, and then never read that write,
    /// since the date would say it had.
    public struct Snapshot: Equatable, Sendable {
        public let review: LampWritingReview
        /// Nil where the writing has no file.
        public let modified: Date?
    }

    public func snapshot(writingID: String, document: String? = nil) throws -> Snapshot {
        let url = try url(writingID: writingID, document: document)
        return try Self.locks.holding(url) {
            Snapshot(
                review: try review(writingID: writingID, document: document),
                modified: Self.modified(url)
            )
        }
    }

    /// `update`, returning the record as saved with the date of the file
    /// that holds it, both taken before the lock is let go.
    @discardableResult
    public func updating(
        writingID: String, document: String? = nil,
        _ change: (LampWritingReview) throws -> LampWritingReview
    ) throws -> Snapshot {
        let url = try url(writingID: writingID, document: document)
        return try Self.locks.holding(url) {
            Snapshot(
                review: try update(writingID: writingID, document: document, change),
                modified: Self.modified(url)
            )
        }
    }

    /// Read from the file system each time. A URL's resource values can be
    /// answered from a cache, and under load were: three writes in a row
    /// came back with the first one's date.
    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes the record, unless the file already holds these bytes.
    /// Returns whether it wrote, which is whether a pass has anything to send.
    @discardableResult
    public func save(_ review: LampWritingReview) throws -> Bool {
        // The record's own document, so a record cannot be saved into
        // another document's file by a caller that passed the wrong one.
        let url = try url(writingID: review.writingID, document: review.document)
        let data = try review.encoded()
        return try Self.locks.holding(url) {
            if (try? Data(contentsOf: url)) == data { return false }
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        }
    }

    /// Changes the writing's marks by `change`, and saves what comes of it.
    /// Returns the record as saved.
    ///
    /// Read, changed and written under the file's lock, as `takeIn` is: the
    /// reconciler, a clear and a save's carrying change marks on the main
    /// actor while a pass takes a download in off it, and either writing
    /// over a copy read before the other wrote would lose a mark or a clear.
    @discardableResult
    public func update(
        writingID: String, document: String? = nil,
        _ change: (LampWritingReview) throws -> LampWritingReview
    ) throws -> LampWritingReview {
        try Self.locks.holding(try url(writingID: writingID, document: document)) {
            let next = try change(review(writingID: writingID, document: document))
            guard next.writingID == writingID, next.document == document else {
                throw StoreError.notThisDocument
            }
            try save(next)
            return next
        }
    }

    public enum StoreError: Error, Equatable {
        /// A record whose own writing or document is not the one it was
        /// read for. Nothing in the merge checks identity, so a file that
        /// reached the wrong place would otherwise merge in silence.
        case notThisDocument
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
    public func takeIn(
        downloaded data: Data, writingID: String, document: String? = nil
    ) throws -> Bool {
        let incoming = try LampWritingReview.decoded(from: data)
        // A record that says it is another place's is refused, not
        // merged. Its marks are anchored in that place's words, and the
        // merge compares no identity at all: it would take them for this
        // one's. The writing as well as the document — a file routed to
        // the wrong writing was merged in silence before this.
        guard incoming.writingID == writingID, incoming.document == document else {
            throw StoreError.notThisDocument
        }
        let url = try url(writingID: writingID, document: document)
        return try Self.locks.holding(url) {
            let merged = try review(writingID: writingID, document: document).merged(with: incoming)
            let wrote = try save(merged)
            let differs = try merged.encoded() != incoming.encoded()
            if differs, !wrote {
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            }
            return differs
        }
    }

    /// Removes the writing's marks, as its writing is deleted. The caller
    /// records the removal as a deletion, so other devices remove theirs.
    public func remove(writingID: String, document: String? = nil) throws {
        try removeFile(at: try url(writingID: writingID, document: document))
    }

    private func removeFile(at url: URL) throws {
        try Self.locks.holding(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
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
    /// same id; `members` the paths the library's manifest names, each with
    /// the latest time a device wrote it; `now` the time to record, in
    /// milliseconds. Ids are compared folded, since a writing's is not
    /// spelled alike on every platform.
    ///
    /// Recorded now, not at the writing's own time. Marks cleared on another
    /// device after the writing went are still the marks of a writing that
    /// is gone, and a deletion dated before that upload would lose to it:
    /// the file would come back down, be swept again, and do so on every
    /// pass. For the same reason never before the write the manifest holds,
    /// which a device whose clock runs ahead can date after this one's now.
    /// Once recorded the path is no member and there is no file, so nothing
    /// is recorded again.
    public func deletions(
        deleted: Set<String>, held: Set<String>, members: [String: Int64], now: Int64
    ) throws -> [String: Int64] {
        let gone = Set(deleted.map { $0.lowercased() }).subtracting(held.map { $0.lowercased() })
        guard !gone.isEmpty else { return [:] }
        func stamp(_ path: String) -> Int64 {
            members[path].map { max(now, $0 + 1) } ?? now
        }
        var result: [String: Int64] = [:]
        // Every record of a deleted writing, its documents' as well as its
        // prose's: a document's file left here is fetched from the server
        // for ever, by a device that will never have the document.
        for kept in try reviewed() where gone.contains(kept.writingID.lowercased()) {
            let path = try LampSyncFolderLayout.writingReviewPath(
                writingID: kept.writingID, documentKey: kept.documentKey
            )
            try removeFile(at: rootURL.appendingPathComponent(path))
            result[path] = stamp(path)
        }
        for path in members.keys {
            guard let id = LampSyncFolderLayout.writingID(ofReviewPath: path),
                  gone.contains(id.lowercased()) else { continue }
            result[path] = stamp(path)
        }
        return result
    }

    /// The writings whose deletion stands in `ledger`, to pass to
    /// `deletions` as `deleted`: those deleted after their last recorded
    /// save. A writing deleted and later saved again under its id keeps its
    /// deletion in the ledger beside the newer save, and taking any recorded
    /// deletion as standing swept a live writing's marks everywhere, on a
    /// device that had not yet fetched the writing back.
    public static func deletedWritings(in ledger: LampPersonalDeletionLedger) -> Set<String> {
        Set(ledger.entries(of: .devotional).filter { $0.value.isDeleted(itemModified: nil) }.keys)
    }

    /// The writing ids that have a file here.
    public func writingIDs() throws -> [String] {
        Array(Set(try reviewed().map(\.writingID))).sorted()
    }

    /// Every record kept here, each with the writing and the document it
    /// is for. A writing can have several: its prose and a document beside
    /// it are separate records in separate files.
    public func reviewed() throws -> [(writingID: String, documentKey: String?)] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .compactMap {
                LampSyncFolderLayout.reviewTarget(
                    ofPath: "\(LampSyncFolderLayout.writingReviewDirectory)/\($0)"
                )
            }
            .sorted { ($0.writingID, $0.documentKey ?? "") < ($1.writingID, $1.documentKey ?? "") }
    }

    private static let locks = FileLocks()

    /// How long a retirement is kept before it is pruned. A device away
    /// from sync for longer than this could show a passage it last saw
    /// marked as marked again; nothing else depends on it.
    public static let retirementLifetime: TimeInterval = 60 * 60 * 24 * 90
}

/// One lock for each file a store keeps, review marks or a writing's
/// documents, shared by every store in the process, so two stores over the
/// same library change a file one at a time. Recursive, since a change reads
/// and saves under the lock it already holds. Keyed folded and in NFC, as
/// the file systems Lamp runs on name files.
final class FileLocks: @unchecked Sendable {
    private let lock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func holding<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let key = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        lock.lock()
        let fileLock = locks[key] ?? NSRecursiveLock()
        locks[key] = fileLock
        lock.unlock()
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }
}
