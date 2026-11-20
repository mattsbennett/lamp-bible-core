/// What a sync pass does with each file in the library.
///
/// A pure decision, so neither app works it out for itself. Deletions arrive
/// as an explicit list of actions; nothing here, and nothing a caller should
/// write, computes them by differencing a listing.
///
/// One rule underlies the rest: a file and the manifest disagreeing means the
/// file changed, and the content is compared by value. It is never a conflict
/// and never a loss. That is what lets a pass write its files first and
/// record them all in one bundle update at the end: a pass that stops in
/// between leaves files the manifest doesn't know yet, and the next pass, on
/// any device, adopts them. (`Verification/SyncMerge.lean`: `filePlanAction`.)
public enum LampSyncFilePlan {
    /// A file this client holds.
    public struct Local: Equatable, Sendable {
        public let path: String
        /// This client's export now differs from the last state it and the
        /// server agreed on: compare a digest of this client's own export
        /// with the one taken at its last upload, or straight after its last
        /// install. Taking it after an install matters: without it, every
        /// download comes back as an upload in this client's encoding.
        public let changedSinceUpload: Bool
        /// The revision this client last installed or wrote, whichever came
        /// last. Meaningful only within one provider: an ETag never equals a
        /// digest, so records kept for one provider must not be offered to
        /// another, or every file reads as changed.
        public let lastRevision: String?
        /// When this client last saved it, in milliseconds since 1970. A
        /// copy saved after a deletion survives it.
        public let savedAt: Int64?

        public init(path: String, changedSinceUpload: Bool, lastRevision: String?, savedAt: Int64?) {
            self.path = path
            self.changedSinceUpload = changedSinceUpload
            self.lastRevision = lastRevision
            self.savedAt = savedAt
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Files to fetch and install. Media is fetched only when absent
        /// here, since a path never changes its bytes; a 404 means not
        /// uploaded yet.
        public var downloads: [String] = []
        /// Files both sides changed. The caller reconciles them (personal
        /// modules by value, in one transaction), then uploads the result
        /// under the revision listed here, `.ifRevision`.
        ///
        /// These paths are not in `uploads`, but each must be written too:
        /// a caller that writes only `uploads` keeps every merge on this
        /// device, silently.
        public var merge: [String: String] = [:]
        /// Files to write, each under its condition. Media is always
        /// `.ifAbsent`. Record every write that succeeds in the pass's
        /// bundle update with `recordingWrite`. Merged files are not here:
        /// write those from `merge`, once reconciled.
        public var uploads: [String: LampSyncWriteCondition] = [:]
        /// Deleted elsewhere after the copy here was saved.
        public var deleteLocally: [String] = []
        /// On the server but unknown to the manifest, or put back after a
        /// deletion: record each with `adopting` once it is installed here.
        /// An adopted file is also in `downloads`, `merge` or `uploads` when
        /// its bytes differ from what this client holds.
        public var adopt: [String: String] = [:]
        /// Deleted here: record each with `removing`.
        public var tombstone: [String: Int64] = [:]
        /// Uploads that survive a tombstone, with its time: record each write
        /// after that time, so it supersedes the tombstone however far ahead
        /// the deleting device's clock ran. Recorded at the pass's own time,
        /// a write under a tombstone from a faster clock leaves it in place,
        /// and the copy goes up again on every pass until the clocks meet.
        public var supersede: [String: Int64] = [:]
        /// Tombstoned files still on the server. Delete each, conditionally
        /// on this revision, only after the bundle that tombstones it is
        /// written, so no device reads the deletion as a missing upload.
        public var reap: [String: String] = [:]
        /// Deletions queued here the manifest needs nothing more of: one it
        /// carries already, at that time or later, and a copy written since
        /// put back; or one a write recorded after it wins. The manifest
        /// takes nothing new for them, so the pass reports them for the
        /// client to drop with the tombstoned.
        public var settled: [String] = []

        public init() {}
    }

    /// `listing` maps paths to revisions for the files found on the server:
    /// the kind folders and the deck folder, from `listing(in:manifest:)`,
    /// and any workspace files the caller checked. It discovers changes and
    /// dropped-in files. Absence from it never decides membership.
    public static func plan(
        manifest: LampSyncLibraryManifest,
        local: [Local],
        deletedLocally: [String: Int64],
        listing: [String: String],
        deletedRecords: [String: String] = [:]
    ) -> Plan {
        let held = Dictionary(local.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = Plan()
        let paths = manifest.paths.union(held.keys).union(deletedLocally.keys).union(listing.keys)
        for path in paths.sorted() {
            guard let kind = LampSyncFolderLayout.kind(of: path) else { continue }
            let action = action(
                kind: kind,
                entry: manifest.entry(at: path),
                local: held[path],
                deletedHere: deletedLocally[path],
                listed: listing[path],
                deletable: LampSyncLocalDeletion.target(of: path).isAllowed,
                deletedRecord: deletedRecords[path]
            )
            plan.apply(action, at: path)
        }
        return plan
    }

    /// What happens to one file: which of the plan's lists it joins.
    struct Action: Equatable {
        var download = false
        var merge: String?
        var upload: LampSyncWriteCondition?
        var deleteLocally = false
        var adopt: String?
        var tombstone: Int64?
        var reap: String?
        var supersede: Int64?
        var settled = false

        static let none = Action()
        static let download = Action(download: true)
        static func upload(_ condition: LampSyncWriteCondition) -> Action { Action(upload: condition) }
    }

    /// `deletable` is whether a library carries out a deletion of this path
    /// (`LampSyncLocalDeletion`). One it never does is never tombstoned,
    /// asked to be deleted here, or reaped: under a tombstone some older
    /// client recorded it is planned as a member, and its next write
    /// supersedes the tombstone, rather than the deletion being asked for on
    /// every pass and refused.
    static func action(
        kind: LampSyncFileKind,
        entry: LampSyncLibraryManifest.Entry?,
        local: Local?,
        deletedHere: Int64?,
        listed: String?,
        deletable: Bool = true,
        deletedRecord: String? = nil
    ) -> Action {
        if deletable, let deletedHere {
            if let entry, !entry.isMember, entry.deletedAt != nil,
               let listed, !entry.deletes(revision: listed),
               !LampSyncConditionalWrite.namesSameRevision(listed, deletedRecord) {
                // Already deleted, by an earlier pass here that stopped before
                // the queue was cleared or by another device, and the server's
                // copy is neither the one that deletion was of nor the one
                // this client last had (`deletedRecord`): written or put back
                // since, by someone else, not yet recorded. When the deletions
                // came says nothing of which copy each saw; the record does.
                // The copy this client had is its own deletion's, planned
                // below.
                // It is put back, as below. The queued deletion is published
                // already and has nothing left to do: `settled`, for the
                // client to drop, since one kept would plan the path as
                // deleted here on every pass and never sync it again. A copy
                // this client held and deleted itself comes back once, which is
                // the safe way to be wrong. Tombstoned here, it would be
                // recorded as the deletion's revision, and reaped.
                var action = change(kind: kind, local: local, listed: listed)
                action.adopt = listed
                action.settled = true
                return action
            }
            var after = entry ?? .init(path: "")
            (after.deletedAt, after.deletedRevision) = LampSyncLibraryManifest.Entry.later(
                (after.deletedAt, after.deletedRevision), (deletedHere, listed)
            )
            var action = Action(tombstone: deletedHere)
            if after.isMember {
                // Written elsewhere after it was deleted here: it comes back,
                // and the deletion has nothing left to do (`settled`). Kept, it
                // would plan the path as deleted here on every pass.
                action.download = local == nil && (listed != nil || kind.isMedia)
                action.settled = true
            } else {
                // Unasked, or unanswered, an unlisted file's revision is the
                // copy this client deleted, or failing a record of it the one
                // the manifest recorded.
                let candidate = listed ?? (kind.isListed ? nil : deletedRecord ?? entry?.revision)
                action.reap = candidate
                // Carried already by a deletion at or after it, by an earlier
                // pass here or another device deleting it later, which covers
                // the copy the server holds. The manifest takes nothing new,
                // so it is not `tombstoned`, and kept it would be asked for on
                // every pass. A copy the manifest's deletion does not cover,
                // this client's own, is reaped on the strength of the queue
                // alone, so the deletion waits until the reap is done.
                action.settled = entry.map { entry in
                    (entry.deletedAt.map { $0 >= deletedHere } ?? false)
                        && (candidate.map { entry.deletes(revision: $0) } ?? true)
                } ?? false
            }
            return action
        }
        guard let entry, entry.isMember || entry.deletedAt != nil else {
            // Unknown to the manifest.
            guard let listed else {
                return local == nil ? .none : .upload(.ifAbsent)
            }
            var action = change(kind: kind, local: local, listed: listed)
            action.adopt = listed
            return action
        }
        if entry.isMember {
            return change(kind: kind, local: local, listed: listed)
        }
        if !deletable, let deletedAt = entry.deletedAt {
            // A path no library deletes, under a tombstone some older client
            // recorded: never carried out. Planned as a member — taken,
            // merged or sent as the revisions say, and sent if the server has
            // lost it — and any write is recorded after the tombstone, which
            // it then supersedes.
            var action = local != nil && listed == nil
                ? Action.upload(.ifAbsent)
                : change(kind: kind, local: local, listed: listed)
            if action.upload != nil || action.merge != nil { action.supersede = deletedAt }
            return action
        }
        // Tombstoned.
        if let listed, !entry.deletes(revision: listed) {
            // Put back by hand after the deletion.
            var action = change(kind: kind, local: local, listed: listed)
            action.adopt = listed
            return action
        }
        if let local, let deletedAt = entry.deletedAt, (local.savedAt ?? .min) > deletedAt {
            // Saved here after the deletion: it survives, and goes back up,
            // recorded after the deletion.
            var action = Action.upload(kind.isMedia ? .ifAbsent : listed.map { .ifRevision($0) } ?? .ifAbsent)
            action.supersede = deletedAt
            return action
        }
        return Action(deleteLocally: local != nil, reap: listed)
    }

    /// A member, or a file being adopted: compare this client's copy with
    /// the server's.
    private static func change(kind: LampSyncFileKind, local: Local?, listed: String?) -> Action {
        if kind.isMedia {
            // Never probed and never merged: a copy here is done, and one
            // this client never uploaded goes up only where absent.
            guard let local else { return .download }
            return local.lastRevision == nil ? .upload(.ifAbsent) : .none
        }
        guard let local else { return listed == nil ? .none : .download }
        guard let listed else {
            return local.changedSinceUpload || local.lastRevision == nil ? .upload(.ifAbsent) : .none
        }
        let remoteChanged = !LampSyncConditionalWrite.namesSameRevision(listed, local.lastRevision)
        switch (remoteChanged, local.changedSinceUpload) {
        case (false, false): return .none
        case (false, true): return .upload(.ifRevision(listed))
        case (true, false): return .download
        case (true, true): return Action(merge: listed)
        }
    }

    /// The revision of each file in the listed folders.
    ///
    /// A listing that reports a revision is used as it is: WebDAV's ETags.
    /// One that doesn't, the folder provider's, takes a member's revision
    /// from the manifest, so evicted iCloud files are never read just to be
    /// compared. Only a file the manifest doesn't record as a member, one
    /// dropped in or put back, is asked for its revision, which on the
    /// folder provider reads that one file.
    public static func listing(
        in store: any LampSyncRemoteStore,
        manifest: LampSyncLibraryManifest
    ) async throws -> [String: String] {
        try await listingAndFolders(in: store, manifest: manifest).listing
    }

    /// The listing, with the folders the store listed — a folder it has no
    /// listing for (nil, not empty) is left out — and every listed file,
    /// including one no revision could be found for.
    static func listingAndFolders(
        in store: any LampSyncRemoteStore,
        manifest: LampSyncLibraryManifest
    ) async throws -> (listing: [String: String], folders: Set<String>, found: Set<String>) {
        var listing: [String: String] = [:]
        var folders = Set<String>()
        var found = Set<String>()
        for directory in LampSyncFolderLayout.listedDirectories {
            guard let items = try await store.list(directory: directory + "/") else { continue }
            folders.insert(directory)
            for item in items where !item.isDirectory {
                let path = "\(directory)/\(item.name)"
                guard LampSyncFolderLayout.kind(of: path)?.isListed == true else { continue }
                found.insert(path)
                let entry = manifest.entry(at: path)
                let recorded = entry?.isMember == true ? entry?.revision : nil
                if let revision = item.revision ?? recorded {
                    listing[path] = revision
                } else if let revision = try await store.revision(path: path) {
                    listing[path] = revision
                }
            }
        }
        return (listing, folders, found)
    }
}

extension LampSyncFilePlan {
    /// Why a module this client holds was not found on the server.
    public enum Missing: Equatable, Sendable {
        /// Its folder was listed and the file was not in it: deleted from the
        /// server by hand, or, on iCloud, not arrived yet.
        case notOnServer
        /// Its folder could not be listed at all, so whether the file is
        /// there is unknown.
        case folderNotListed
    }

    /// The modules and decks the manifest names, that this client holds as
    /// the server last had them, and that a listing did not find.
    ///
    /// A report, never an action: absence is no evidence of a deletion. A
    /// server can answer a listing from a stale view, and iCloud refills a
    /// folder file by file while the manifest already names everything. The
    /// plan does nothing about these, and a caller marks them; the person
    /// deletes one, if they mean to, by the recorded deletion every device
    /// follows.
    ///
    /// Left out: a copy changed here, or one with no record of agreeing,
    /// which this pass sends back (`.ifAbsent`); a path deleted here; media
    /// and workspace files, which are never listed.
    ///
    /// `found` is every path the listing held, with a revision or without.
    /// A name found only in another case counts as found when that spelling
    /// is no module of its own here or in the manifest: on a store that
    /// ignores case it is the same file, renamed only in case, while on one
    /// that doesn't, `Study.lamp` and `study.lamp` can be two modules.
    public static func missing(
        manifest: LampSyncLibraryManifest,
        local: [Local],
        deletedLocally: [String: Int64],
        found: Set<String>,
        listedFolders: Set<String>
    ) -> [String: Missing] {
        let known = Set(local.map(\.path)).union(manifest.paths)
        let renamedInCase = Set(found.subtracting(known).map { $0.lowercased() })
        var missing: [String: Missing] = [:]
        for held in local
        where !found.contains(held.path) && !renamedInCase.contains(held.path.lowercased())
            && deletedLocally[held.path] == nil {
            guard LampSyncFolderLayout.kind(of: held.path)?.isListed == true,
                  manifest.entry(at: held.path)?.isMember == true,
                  !held.changedSinceUpload, held.lastRevision != nil else { continue }
            missing[held.path] = listedFolders.contains(folder(of: held.path)) ? .notOnServer : .folderNotListed
        }
        return missing
    }

    /// The folder a path is listed in.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The listed files' revisions as a listing reports them, reading no
    /// file: for a probe made every couple of minutes while the app is open.
    ///
    /// WebDAV reports each file's ETag. A folder listing reports none, and
    /// its revision is a digest of the contents, which would mean reading
    /// (and on iCloud, downloading) every file each time; so a folder file
    /// takes the revision this client recorded, or "present" for one it has
    /// no record of. On a folder, then, a probe sees files dropped in and
    /// taken away, but not one replaced in place, which waits for the next
    /// pass.
    public static func listing(
        in store: any LampSyncRemoteStore,
        recorded: [String: String]
    ) async throws -> [String: String] {
        var listing: [String: String] = [:]
        for directory in LampSyncFolderLayout.listedDirectories {
            for item in try await store.list(directory: directory + "/") ?? [] where !item.isDirectory {
                let path = "\(directory)/\(item.name)"
                guard LampSyncFolderLayout.kind(of: path)?.isListed == true else { continue }
                listing[path] = item.revision ?? recorded[path] ?? "present"
            }
        }
        return listing
    }

    /// The listed files a pass would act on: one whose revision has moved
    /// from what this client recorded, one with no record (dropped in from
    /// outside the apps, as a module replaced by hand on the server), and a
    /// recorded one the listing no longer holds. Empty when a pass would find
    /// nothing to do, so a probe starts one only when it has work.
    public static func remoteChanges(
        listing: [String: String],
        recorded: [String: String]
    ) -> Set<String> {
        var changed = Set<String>()
        for (path, revision) in listing {
            guard let known = recorded[path] else { changed.insert(path); continue }
            if !LampSyncConditionalWrite.namesSameRevision(revision, known) { changed.insert(path) }
        }
        for path in recorded.keys where listing[path] == nil { changed.insert(path) }
        return changed
    }
}

extension LampSyncFilePlan.Plan {
    mutating func apply(_ action: LampSyncFilePlan.Action, at path: String) {
        if action.download { downloads.append(path) }
        if let revision = action.merge { merge[path] = revision }
        if let condition = action.upload { uploads[path] = condition }
        if action.deleteLocally { deleteLocally.append(path) }
        if let revision = action.adopt { adopt[path] = revision }
        if let time = action.tombstone { tombstone[path] = time }
        if let revision = action.reap { reap[path] = revision }
        if let time = action.supersede { supersede[path] = time }
        if action.settled { settled.append(path) }
    }
}
