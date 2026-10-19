import Foundation

/// A small object listing what the sync archive holds, so a client can tell
/// what changed without fetching the archive itself.
///
/// The archive is a single zlib stream over a JSON document with base64
/// entries: there is no way to read one entry out of it, so a device that
/// wanted a few kilobytes of settings had to download and inflate every
/// module body in the library to reach them. A settings edit on one device
/// cost every other device the whole library.
///
/// This is published beside the archive, naming the revision it describes and
/// the digest of each entry. A reader can then compare digests against what it
/// already has and fetch the archive only when something it cares about moved.
/// It is advisory in the strictest sense: a missing, stale, or unreadable index
/// means the archive is read exactly as before, so an older client that does
/// not write one costs nothing but the saving.
public struct LampSyncArchiveIndex: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// The archive revision these digests describe. An index whose revision is
    /// not the one the server currently reports describes a body that has
    /// since been replaced, and is ignored.
    public let archiveRevision: String
    /// Each entry's SHA-256, keyed by its path inside the archive.
    public let digests: [String: String]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        archiveRevision: String,
        digests: [String: String]
    ) {
        self.formatVersion = formatVersion
        self.archiveRevision = archiveRevision
        self.digests = digests
    }

    public init(describing archive: LampSyncArchive, at revision: String) {
        self.init(
            archiveRevision: revision,
            digests: Dictionary(
                archive.entries.map {
                    ($0.path, $0.sha256 ?? LampSyncContentRevision.digest(for: $0.data))
                },
                // A well-formed archive has no repeated paths; if one somehow
                // does, the first wins rather than trapping over an index.
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    public var isSupported: Bool { formatVersion <= Self.currentFormatVersion }

    public func digest(forEntryAt path: String) -> String? { digests[path] }

    /// Paths holding settings rather than content: the pieces a module import
    /// neither reads nor installs, and whose movement must not make it refetch
    /// a library whose content is unchanged.
    public static let settingsPaths: Set<String> = [
        LampSyncLayout.userSettingsPath,
        LampPortableBackupLayout.sharedPreferencesPath,
        LampSyncSettingsArchive.legacyManifestPath,
    ]

    /// One value standing for every entry a module import cares about.
    ///
    /// Compared against the value recorded by the import that ran last, this
    /// answers "has anything I would install changed?" without fetching the
    /// archive. It covers additions and removals as well as edits, because
    /// the paths are part of what is hashed — a new module changes it, and so
    /// does a deleted one. Settings entries are left out so that editing a
    /// preference on one device does not cost every other device its library.
    public var importableFingerprint: String {
        let listed = digests
            .filter { !Self.settingsPaths.contains($0.key) }
            .map { "\($0.key)\u{0}\($0.value)" }
            .sorted()
            .joined(separator: "\u{1}")
        return LampSyncContentRevision.digest(for: Data(listed.utf8))
    }
}

public extension LampSyncArchiveIndex {
    /// Read the index only if it describes what the server holds right now.
    ///
    /// Two cheap requests — the archive's revision and this small object —
    /// decide whether the library has to be fetched at all. Anything doubtful
    /// returns nil, which means "read the archive", the behaviour that
    /// predates this.
    /// What the server has, and when it is of no use, why.
    ///
    /// The reasons are worth keeping apart: an absent index means nobody has
    /// published since this existed, one keyed to another revision means a
    /// writer that does not maintain it has been through, and both are
    /// temporary in a way that a malformed one is not.
    enum Availability: Equatable, Sendable {
        case current(LampSyncArchiveIndex)
        /// Nothing published at the index path.
        case absent
        /// Published, but describing a body the server no longer holds.
        case staleRevision(describing: String, server: String)
        /// Written by a client that knows a shape this one does not.
        case unsupportedVersion(Int)
        /// Present and unreadable.
        case malformed
        /// The server's revision cannot stand for a body, so nothing can be
        /// keyed to it.
        case unusableRevision(String?)

        public var index: LampSyncArchiveIndex? {
            if case .current(let index) = self { return index }
            return nil
        }

        /// A phrase fit for a log line, saying what is wrong.
        public var reason: String {
            switch self {
            case .current: "current"
            case .absent: "no index published"
            case .staleRevision(let describing, let server):
                "index describes \(describing), server holds \(server)"
            case .unsupportedVersion(let version): "index format version \(version)"
            case .malformed: "index unreadable"
            case .unusableRevision(let revision):
                "server revision \(revision ?? "absent") cannot identify a body"
            }
        }
    }

    static func current(
        in store: any LampSyncRemoteStore
    ) async -> LampSyncArchiveIndex? {
        await availability(
            in: store,
            knownRevision: try? await store.revision(path: LampSyncLayout.archivePath)
        ).index
    }

    /// The same, for a caller that has already asked what the revision is.
    static func current(
        in store: any LampSyncRemoteStore,
        knownRevision: String?
    ) async -> LampSyncArchiveIndex? {
        await availability(in: store, knownRevision: knownRevision).index
    }

    static func availability(
        in store: any LampSyncRemoteStore,
        knownRevision: String?
    ) async -> Availability {
        guard let revision = knownRevision,
              LampWebDAVStorage.isStrongETag(revision) else {
            return .unusableRevision(knownRevision)
        }
        guard let file = try? await store.read(path: LampSyncLayout.archiveIndexPath) else {
            return .absent
        }
        guard let index = try? JSONDecoder().decode(Self.self, from: file.data) else {
            return .malformed
        }
        guard index.isSupported else {
            return .unsupportedVersion(index.formatVersion)
        }
        guard index.archiveRevision == revision else {
            return .staleRevision(describing: index.archiveRevision, server: revision)
        }
        return .current(index)
    }

    /// Publish an index for the archive just written.
    ///
    /// Unconditional on purpose: it describes one specific revision and says
    /// so, so a loser in a race writes something a reader will discard rather
    /// than something a reader will believe.
    /// Whether a pass may take the server's archive revision as applied
    /// without fetching the archive: the index describes that very revision,
    /// and every entry a pass would install has the digest this device last
    /// installed. Settings are left out of the fingerprint because their own
    /// sync reads them. (`Verification/SyncMerge.lean`: `mayAdvanceWithoutFetch`.)
    static func mayAdvanceWithoutFetch(
        cacheUsable: Bool,
        appliedFingerprint: String?,
        availability: Availability
    ) -> Bool {
        guard cacheUsable, let appliedFingerprint,
              let index = availability.index else { return false }
        return index.importableFingerprint == appliedFingerprint
    }

    static func publish(
        describing archive: LampSyncArchive,
        at revision: String,
        in store: any LampSyncRemoteStore
    ) async throws {
        let index = LampSyncArchiveIndex(describing: archive, at: revision)
        _ = try await store.write(
            try JSONEncoder().encode(index),
            to: LampSyncLayout.archiveIndexPath,
            condition: .unconditional
        )
    }
}
