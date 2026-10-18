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
    static func current(
        in store: any LampSyncRemoteStore
    ) async -> LampSyncArchiveIndex? {
        await current(
            in: store,
            knownRevision: try? await store.revision(path: LampSyncLayout.archivePath)
        )
    }

    /// The same, for a caller that has already asked what the revision is.
    static func current(
        in store: any LampSyncRemoteStore,
        knownRevision: String?
    ) async -> LampSyncArchiveIndex? {
        guard let revision = knownRevision,
              LampWebDAVStorage.isStrongETag(revision),
              let file = try? await store.read(path: LampSyncLayout.archiveIndexPath),
              let index = try? JSONDecoder().decode(Self.self, from: file.data),
              index.isSupported,
              index.archiveRevision == revision else {
            return nil
        }
        return index
    }

    /// Publish an index for the archive just written.
    ///
    /// Unconditional on purpose: it describes one specific revision and says
    /// so, so a loser in a race writes something a reader will discard rather
    /// than something a reader will believe.
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
