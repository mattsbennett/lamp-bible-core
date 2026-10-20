/// Which files belong to the library.
///
/// A file is a member only because this says so. Never because a listing
/// shows it: absence from a listing means "not uploaded yet" as often as
/// "deleted", and guessing re-uploads what another device deleted.
///
/// Per path it keeps the latest write and the latest deletion, each with the
/// revision it concerned. Two manifests merge by keeping the later of each,
/// so devices agree whatever order they merge in. Times are milliseconds
/// since 1970. (`Verification/SyncMerge.lean`: `mergeManifestEntry`.)
public struct LampSyncLibraryManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        /// The latest time a device added or wrote it.
        public internal(set) var presentSince: Int64?
        /// The provider's revision for that write: an ETag on WebDAV, a
        /// content digest on the folder provider. Comparable only within
        /// one provider.
        public internal(set) var revision: String?
        /// The latest deletion. Equal times are a deletion, as the other
        /// ledgers rule.
        public internal(set) var deletedAt: Int64?
        /// The revision the deletion was of, so a copy put back by hand later
        /// can be told from the one that was deleted.
        public internal(set) var deletedRevision: String?

        init(path: String) {
            self.path = path
        }

        public var kind: LampSyncFileKind? { LampSyncFolderLayout.kind(of: path) }

        /// Written after its latest deletion. (`entryIsMember`.)
        public var isMember: Bool {
            guard let presentSince else { return false }
            guard let deletedAt else { return true }
            return presentSince > deletedAt
        }

        /// Whether a file on the server at `revision` is the one this
        /// entry's deletion was of, or the write it recorded before that.
        /// A tombstone with neither recorded matches any copy.
        func deletes(revision: String) -> Bool {
            let recorded = [self.revision, deletedRevision].compactMap { $0 }
            return recorded.isEmpty
                || recorded.contains { LampSyncConditionalWrite.namesSameRevision($0, revision) }
        }

        func merged(with other: Entry) -> Entry {
            var merged = self
            (merged.presentSince, merged.revision) = Self.later(
                (presentSince, revision), (other.presentSince, other.revision)
            )
            (merged.deletedAt, merged.deletedRevision) = Self.later(
                (deletedAt, deletedRevision), (other.deletedAt, other.deletedRevision)
            )
            return merged
        }

        /// The later of two stamped values: by time, then by revision, so
        /// equal times still pick one the same way everywhere.
        static func later(
            _ a: (Int64?, String?), _ b: (Int64?, String?)
        ) -> (Int64?, String?) {
            switch (a.0, b.0) {
            case (nil, nil): return (nil, max(a.1, b.1))
            case (nil, _): return b
            case (_, nil): return a
            case let (x?, y?):
                if x != y { return x > y ? a : b }
                return (x, max(a.1, b.1))
            }
        }

        private static func max(_ a: String?, _ b: String?) -> String? {
            switch (a, b) {
            case let (a?, b?): Swift.max(a, b)
            case let (a?, nil): a
            case let (nil, b): b
            }
        }
    }

    public enum ManifestError: Error, Equatable {
        case outsideLayout(String)
        case duplicatePath(String)
    }

    /// How long a deletion is remembered, in milliseconds: 180 days. A
    /// device offline for longer brings the file back once; that cost was
    /// accepted (`tombstoneLifetimeCost`).
    public static let tombstoneLifetime: Int64 = 180 * 24 * 60 * 60 * 1_000

    var entries: [String: Entry]

    /// Empty. Deliberately there is no way to make one from a listing.
    public init() {
        entries = [:]
    }

    public var members: [Entry] { sorted.filter(\.isMember) }
    public var tombstones: [Entry] { sorted.filter { !$0.isMember } }
    public var paths: Set<String> { Set(entries.keys) }

    public func entry(at path: String) -> Entry? {
        entries[path]
    }

    /// Records a write of `revision` at `path` over `previous`, the revision
    /// the write was conditioned on (nil for a file created where none was).
    ///
    /// When the manifest still holds `previous`, this write is its
    /// successor and is stamped after it, so a slow clock cannot make the
    /// later write lose. Otherwise the later stamp wins, which also repairs
    /// a manifest left behind by a pass that ended before recording.
    /// Pass the later of now and the copy's own save time as `time`: a copy
    /// saved after a deletion must come out a member.
    /// (`recordWrite`.)
    public func recordingWrite(
        _ path: String, revision: String?, replacing previous: String?, at time: Int64
    ) throws -> Self {
        var copy = self
        var entry = try copy.existing(path)
        if LampSyncConditionalWrite.namesSameRevision(entry.revision, previous) {
            let after = entry.presentSince.map { $0 == .max ? $0 : $0 + 1 } ?? time
            (entry.presentSince, entry.revision) = (Swift.max(time, after), revision)
        } else {
            (entry.presentSince, entry.revision) = Entry.later(
                (entry.presentSince, entry.revision), (time, revision)
            )
        }
        copy.entries[path] = entry
        return copy
    }

    /// Makes a file found on the server a member: one dropped in by hand, or
    /// one written by a pass that ended before recording it.
    ///
    /// A member is left as it is. A tombstone whose deleted revision this
    /// is stays a tombstone: that file is waiting to be reaped, and adopting
    /// it would undo the deletion. Any other copy was put back after the
    /// deletion, and is adopted. (`adoptFile`.)
    public func adopting(_ path: String, revision: String, at time: Int64) throws -> Self {
        var copy = self
        var entry = try copy.existing(path)
        if entry.isMember {
            if entry.revision == nil { entry.revision = revision }
        } else if entry.deletedAt != nil, entry.deletes(revision: revision) {
            return self
        } else {
            let after = [entry.presentSince, entry.deletedAt].compactMap { $0 }.max()
                .map { $0 == .max ? $0 : $0 + 1 }
            (entry.presentSince, entry.revision) = (Swift.max(time, after ?? time), revision)
        }
        copy.entries[path] = entry
        return copy
    }

    /// Records a deletion at `time` of the copy at `revision`, the one this
    /// device saw.
    public func removing(_ path: String, at time: Int64, revision: String?) throws -> Self {
        var copy = self
        var entry = try copy.existing(path)
        (entry.deletedAt, entry.deletedRevision) = Entry.later(
            (entry.deletedAt, entry.deletedRevision), (time, revision)
        )
        copy.entries[path] = entry
        return copy
    }

    /// Per path, the later of each stamp: commutative, associative and
    /// idempotent. (`mergeManifestEntry_comm`, `_assoc`, `_idem`.)
    public func merged(with other: Self) -> Self {
        var copy = self
        copy.entries.merge(other.entries) { $0.merged(with: $1) }
        return copy
    }

    /// Drops tombstones older than `tombstoneLifetime`. A listed kind's
    /// tombstone goes only once its file is gone from `present`, so a file
    /// still waiting to be reaped keeps its deletion. Media and workspace
    /// files are never listed and go by age alone; a file left behind then
    /// is never listed either, so it cannot come back. (`pruneTombstone`.)
    public func pruned(now: Int64, present: Set<String>) -> Self {
        var copy = self
        copy.entries = entries.filter { path, entry in
            !Self.prunes(entry, now: now, present: present.contains(path))
        }
        return copy
    }

    static func prunes(_ entry: Entry, now: Int64, present: Bool) -> Bool {
        let (cutoff, overflow) = now.subtractingReportingOverflow(tombstoneLifetime)
        guard !entry.isMember, let deletedAt = entry.deletedAt, !overflow, deletedAt <= cutoff
        else { return false }
        return !(entry.kind?.isListed ?? false) || !present
    }

    private var sorted: [Entry] {
        entries.values.sorted { $0.path < $1.path }
    }

    private func existing(_ path: String) throws -> Entry {
        guard LampSyncFolderLayout.kind(of: path) != nil else {
            throw ManifestError.outsideLayout(path)
        }
        return entries[path] ?? Entry(path: path)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Entries in path order, so an unchanged manifest encodes to the same
    /// bytes. Paths a later version adds to the layout are kept as they are,
    /// so this version passes them on rather than dropping them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sorted, forKey: .entries)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = [:]
        for entry in try container.decode([Entry].self, forKey: .entries) {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ManifestError.outsideLayout(entry.path)
            }
            guard entries.updateValue(entry, forKey: entry.path) == nil else {
                throw ManifestError.duplicatePath(entry.path)
            }
        }
    }
}
