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
        writingID: String, document: String? = nil, now: Date = Date(),
        _ change: (LampWritingReview) throws -> LampWritingReview
    ) throws -> LampWritingReview {
        try Self.locks.holding(try url(writingID: writingID, document: document)) {
            let url = try url(writingID: writingID, document: document)
            let held = try? Data(contentsOf: url)
            var next = try change(review(writingID: writingID, document: document))
            guard next.writingID == writingID, next.document == document else {
                throw StoreError.notThisDocument
            }
            // What is past its time goes with a change that is being
            // written anyway, and never makes one: a carry that moves
            // nothing still writes nothing (`ReviewPrunePlan.md`). The
            // copies this goes to let it go too, as they take it in.
            // Judged by the bytes, as `save` judges whether to write: a
            // change that only reorders writes nothing, and must not prune.
            if try next.encoded() != held {
                next = next.pruning(before: now.addingTimeInterval(-Self.retirementLifetime))
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
        downloaded data: Data, writingID: String, document: String? = nil, now: Date = Date()
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
            let merged = try review(writingID: writingID, document: document).merged(
                with: incoming,
                lettingGoOfRetiredBefore: now.addingTimeInterval(-Self.retirementLifetime),
                restoredBefore: now.addingTimeInterval(-LampWritingReview.restorationWindow)
            )
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

    /// The same by the document's key rather than its name, for a caller
    /// working from the files that are there — a pass carrying out a
    /// deletion — which has the key and may have no name to look it up by.
    /// A record by its document's key rather than its name, for a caller
    /// working from the files that are there. Nil where there is none.
    public func review(writingID: String, documentKey: String?) throws -> LampWritingReview? {
        let url = rootURL.appendingPathComponent(
            try LampSyncFolderLayout.writingReviewPath(writingID: writingID, documentKey: documentKey)
        )
        return try Self.locks.holding(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try LampWritingReview.decoded(from: Data(contentsOf: url))
        }
    }

    public func remove(writingID: String, documentKey: String?) throws {
        try removeFile(at: rootURL.appendingPathComponent(
            try LampSyncFolderLayout.writingReviewPath(writingID: writingID, documentKey: documentKey)
        ))
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

    /// The server path of every record kept here.
    ///
    /// What a pass sends up. Both apps listed these for themselves, one
    /// from the folder and one from the records, and a file the layout
    /// does not name must not be sent under a path it does not have.
    public func paths() throws -> [String] {
        try reviewed().compactMap {
            try? LampSyncFolderLayout.writingReviewPath(
                writingID: $0.writingID, documentKey: $0.documentKey
            )
        }
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

    /// How long a retirement is kept before it is pruned: by `update`, on a
    /// write that changes the record, and by `takeIn` where the incoming
    /// copy has pruned it already. A device away from sync for longer than
    /// this could show a passage it last saw marked as marked again. So
    /// could a restore recorded again after its re-mark's retirement went
    /// (`remarkID(restoring:)`), which waits on a device keeping a restore
    /// owed for that long.
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

/// Keeping a document's marks on its words as the writer edits it.
///
/// A mark is anchored in the words it was made of, so a text it was never
/// anchored in has to be carried to: without that, the first keystroke
/// after a mark strays every one of them. The writing's own prose has had
/// this since marks existed, carried by the save that writes the body.
/// The documents beside it are written by another path on each app — the
/// workspace's own store on the Mac, the Files sheet on the phone — and
/// neither carried anything, so the rule is here rather than twice.
public enum LampWritingDocumentReview {
    /// Carries a document's marks onto the text just written.
    ///
    /// `known` is every text of this document the app has held, newest
    /// first or in any order: a mark anchored in one of them is carried
    /// from it, and one anchored in a text nobody here has seen — a copy
    /// the phone saved and this device has not read — is left alone,
    /// unless its words stand just once in a text that is known. `saved`
    /// is counted as known, so a carry that has already happened is not
    /// made twice.
    ///
    /// Returns whether anything moved, which is whether a pass has
    /// something to send.
    @discardableResult
    public static func carry(
        _ saved: String, ofDocument document: String, writingID: String,
        from known: [String], in store: LampWritingReviewStore, at date: Date = Date()
    ) throws -> Bool {
        let url = try store.url(writingID: writingID, document: document)
        // No record is the ordinary case — most documents are never
        // marked — and reading one in to write it back unchanged would
        // date a file every save, which a pass would then send.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var moved = false
        _ = try store.update(writingID: writingID, document: document) { review in
            let carried = review.carryingToText(saved, from: known, at: date)
            moved = carried != review
            return carried
        }
        return moved
    }

    /// Moves a document's marks to the copy its body was kept as.
    ///
    /// Both sides changing one document leaves this device's body under a
    /// copy's name and the server's at the document's own. The marks were
    /// made of the words in the body that moved, so they move with it:
    /// left where they were, they would be drawn against a body they were
    /// never made against — the server's — and the copy, which is the
    /// text they are the marks of, would carry none.
    ///
    /// The same when a deletion made elsewhere is carried out here and
    /// this device's edits are kept instead.
    ///
    /// Returns the deletion to record for the record left behind, by path
    /// and time, so other devices drop their copy of it; nothing where
    /// there was no record to move.
    @discardableResult
    public static func moved(
        _ document: String, to copy: String, writingID: String,
        in store: LampWritingReviewStore, members: [String: Int64] = [:], now: Int64
    ) throws -> [String: Int64] {
        let from = try store.url(writingID: writingID, document: document)
        guard FileManager.default.fileExists(atPath: from.path) else { return [:] }
        var review = try store.review(writingID: writingID, document: document)
        review.document = copy
        _ = try store.save(review)
        try store.remove(writingID: writingID, document: document)
        return try deletion(of: document, writingID: writingID, members: members, now: now)
    }

    /// Sweeps a deleted document's marks, and says what deletion to record
    /// so other devices sweep theirs.
    ///
    /// A document deleted anywhere is deleted everywhere, and its marks go
    /// with it. A record only removed here would be fetched again from the
    /// server's copy on the next pass, for ever, by a device that will
    /// never hold the document it belongs to.
    ///
    /// A rename is a deletion and a new document, here as everywhere else
    /// in sync: the marks of the name that went are gone, and the name
    /// that arrived has none. Carrying them across would mean deciding
    /// that two documents are one from their words alone, which no part of
    /// Lamp does.
    @discardableResult
    public static func removed(
        _ document: String, writingID: String,
        in store: LampWritingReviewStore, members: [String: Int64] = [:], now: Int64
    ) throws -> [String: Int64] {
        try store.remove(writingID: writingID, document: document)
        return try deletion(of: document, writingID: writingID, members: members, now: now)
    }

    /// Dated now, and never before the write the manifest holds: a device
    /// whose clock runs ahead can have written the file after this one's
    /// now, and a deletion dated before that write would lose to it — the
    /// file would come back down and be swept again on every pass.
    private static func deletion(
        of document: String, writingID: String, members: [String: Int64], now: Int64
    ) throws -> [String: Int64] {
        let path = try LampSyncFolderLayout.writingReviewPath(writingID: writingID, document: document)
        return [path: members[path].map { max(now, $0 + 1) } ?? now]
    }
}

extension LampWritingDocumentReview {
    /// What a pass should do with each document's review record: delete
    /// it and tell the other devices, cancel a deletion already asked
    /// for, or leave it alone.
    ///
    /// A record belongs to its document and goes when the document goes.
    /// Deciding when that has happened is the whole difficulty, and the
    /// Mac got it wrong three times in three different ways:
    ///
    /// - Dated now, a deletion still queued after a failed pass beat
    ///   another device's later save of the document. The document came
    ///   back and every mark on it was gone everywhere.
    /// - Dated from the document's own deletion, it still lost: two
    ///   files are dated independently, so a record untouched since
    ///   before either is older than both.
    /// - Swept because the document was neither held nor on the server,
    ///   it deleted the records of documents that were merely **not
    ///   uploaded yet** — one device's document upload failing while its
    ///   review upload succeeded is enough.
    ///
    /// So absence is never taken for deletion. A record is deleted only
    /// where a deletion of its document is known and still stands, or
    /// where the library itself has let the document go.
    public enum Fate: Equatable, Sendable {
        /// Delete the record here and record the deletion at this time.
        case deleted(at: Int64)
        /// Take back a deletion asked for earlier: the document is here.
        case cancelled
        /// Nothing to do.
        case none
    }

    /// `held` whether this device has the document; `deletedHere` the
    /// deletion this device has recorded for it, if any, with the
    /// revision it deleted; `document` what the library's manifest says
    /// of the document, nil where it names none; `documentWritten` when
    /// the library last saw **the document**; `asked` a deletion of the
    /// record already queued.
    ///
    /// `documentWritten` is the document's, never the record's. Whether
    /// a deletion of the document still stands is a question about the
    /// document: another device saving it since is what overtakes the
    /// deletion, and the record may not have been touched for months.
    /// Handed the record's time instead, this deleted every mark on a
    /// document whose newer version survived — and the model said the
    /// same thing in the same wrong words, so the table agreed with it.
    public static func fate(
        held: Bool,
        deletedHere: (at: Int64, revision: String?)?,
        document: (revision: String?, isMember: Bool)?,
        documentWritten: Int64?,
        asked: Int64?,
        now: Int64
    ) -> Fate {
        // The document is here, so its marks are its own, and any
        // deletion asked for earlier is taken back.
        if held { return asked == nil ? .none : .cancelled }
        if let deletedHere {
            // A deletion this device made. It stands unless the library
            // holds a newer write of the document than the one deleted,
            // which is another device saving it since.
            var stands = true
            if let document, document.isMember {
                let sameRevision = document.revision != nil
                    && document.revision == deletedHere.revision
                stands = sameRevision || (documentWritten.map { $0 <= deletedHere.at } ?? true)
            }
            guard stands else { return asked == nil ? .none : .cancelled }
            return .deleted(at: max(asked ?? deletedHere.at, deletedHere.at))
        }
        guard let document else {
            // The library names no such document and this device has
            // none. Nothing says it was ever there, so nothing is
            // concluded — except that a deletion already asked for goes
            // up, since something asked for it.
            return asked.map { Fate.deleted(at: $0) } ?? .none
        }
        // The library holds it, and this device deleted nothing. A
        // deletion of the record asked for earlier was asked for about
        // a document that is alive — another device made it again after
        // a deletion this one acknowledged, and its marks came with it.
        // Left to go up, that tombstone deletes marks of a document the
        // same pass is fetching.
        guard !document.isMember else { return asked == nil ? .none : .cancelled }
        return .deleted(at: max(asked ?? now, now))
    }
}

extension LampWritingDocumentReview {
    /// Which writing and which document a review file at `path` is for.
    ///
    /// The writing's own prose answers with a nil document. A document's
    /// file answers with its name, which is in the file's name unless
    /// that name was too long to keep — then only the record inside has
    /// it, and `record` is asked for.
    ///
    /// Whatever the name comes from, it must be the name that makes this
    /// file's name. Taking it from the record alone is the record
    /// agreeing with itself: a file put at another document's path would
    /// be read as the document it names and merged into that one's
    /// marks. Both apps needed this and both wrote it wrong once.
    public static func place(
        of path: String, record: @autoclosure () -> LampWritingReview?
    ) -> (writingID: String, document: String?)? {
        guard let target = LampSyncFolderLayout.reviewTarget(ofPath: path) else { return nil }
        guard let key = target.documentKey else { return (target.writingID, nil) }
        if let name = LampSyncFolderLayout.documentName(fromReviewKey: key) {
            return (target.writingID, name)
        }
        guard let name = record()?.document,
              LampSyncFolderLayout.reviewDocumentKey(
                  writingID: target.writingID, document: name
              ) == key
        else { return nil }
        return (target.writingID, name)
    }
}

/// What a set of review marks is for: a writing, and one of the
/// documents beside it or its own prose.
///
/// A type rather than the two joined into a string. Joined, a writing
/// `"w"` with a document `"a.md"` and a writing `"wa"` with `".md"` are
/// one key, and one document's texts would carry another's marks.
public struct LampWritingReviewPlace: Hashable, Sendable {
    public let writingID: String
    /// Nil for the writing's own prose.
    public let document: String?

    public init(writingID: String, document: String? = nil) {
        self.writingID = writingID
        self.document = document
    }
}

/// The texts of a writing, or of one document beside it, that a device
/// has held.
///
/// A mark is anchored in the words it was made of, so carrying it to a
/// text nobody here has seen needs the texts in between. Both apps keep
/// these and both kept them the same way; this is that, once.
///
/// Not persisted, by design. These exist to carry marks across edits
/// this run has seen; a text from a run that has ended is a text the
/// record has already been carried through.
public final class LampWritingReviewTexts: @unchecked Sendable {
    /// How many of each are kept: enough to span a clear and the saves
    /// after it, few enough that a long manuscript costs little.
    public static let kept = 24

    private let lock = NSLock()
    private var texts: [LampWritingReviewPlace: [String]] = [:]

    public init() {}

    public func remember(_ text: String, for place: LampWritingReviewPlace) {
        lock.withLock {
            var held = texts[place, default: []]
            guard held.last != text else { return }
            held.append(text)
            texts[place] = Array(held.suffix(Self.kept))
        }
    }

    public func known(for place: LampWritingReviewPlace) -> [String] {
        lock.withLock { texts[place, default: []] }
    }

    public func forget(_ place: LampWritingReviewPlace) {
        lock.withLock { texts[place] = nil }
    }
}

extension LampWritingReview.RestorePlan {
    /// What a save proves of the restores still owed, and what waits.
    ///
    /// `saved` is what the text just written says of each passage;
    /// `current` what the text the writer has now says. Both come from
    /// `standingByMark(from:in:)`.
    ///
    /// A passage the saved text holds is written down. One the words
    /// cannot answer for waits — `unknown` is not `gone`, and treating
    /// it as either loses a record or invents one. One the save does not
    /// hold but the writing still does waits too: that save was taken
    /// before the restore was made. A passage in neither is one the
    /// writer has undone — but that is not the end of it, because Redo
    /// puts the restored wording back without the surface asking
    /// anything: the page only reports that its marks are stale.
    ///
    /// Dropped outright, such a passage is owed by nobody, so the save
    /// that then holds the restored wording records nothing. No
    /// restoration reaches the assistant, and the words it put back and
    /// nobody has read carry no mark. So an undone passage is returned
    /// as `dormant`: still owed, out of the queue, and recorded by a
    /// later save that holds it. Found by the iOS session.
    ///
    /// Both apps decide this and neither had a test for it.
    public static func settlement(
        pending: Set<UUID>,
        inSaved saved: [UUID: Standing],
        inCurrent current: [UUID: Standing]
    ) -> (record: Set<UUID>, waiting: Set<UUID>, dormant: Set<UUID>) {
        var record: Set<UUID> = []
        var waiting: Set<UUID> = []
        var dormant: Set<UUID> = []
        for mark in pending {
            if saved[mark] == .stands {
                record.insert(mark)
            } else if saved[mark] == .unknown || current[mark] != .gone {
                waiting.insert(mark)
            } else {
                dormant.insert(mark)
            }
        }
        return (record, waiting, dormant)
    }
}
