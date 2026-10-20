import Foundation

/// Reads and writes the settings bundle, the one object every device
/// read-merge-writes.
///
/// `update` is the only read-merge-retry in the design. Each module file has
/// its own conditional write, and races one file at a time.
public enum LampSyncSettingsStore {
    public struct Snapshot: Equatable, Sendable {
        public let bundle: LampSyncSettingsBundle
        public let revision: String
        /// Copies another device wrote at the same time, which the store kept
        /// beside this one rather than refusing: iCloud Drive's conflict
        /// versions. Always empty on WebDAV. Ordered by revision.
        ///
        /// Whatever an app merges from them into its own state, it must do
        /// without a base: after a lost write, the base it recorded is its
        /// own write, which the current copy never saw.
        public let versions: [Version]

        public init(bundle: LampSyncSettingsBundle, revision: String, versions: [Version] = []) {
            self.bundle = bundle
            self.revision = revision
            self.versions = versions
        }
    }

    public struct Version: Equatable, Sendable {
        public let bundle: LampSyncSettingsBundle
        /// Names this version's bytes, for the store to resolve exactly it.
        public let revision: String

        public init(bundle: LampSyncSettingsBundle, revision: String) {
            self.bundle = bundle
            self.revision = revision
        }
    }

    public enum StoreError: Error, Equatable {
        /// The path still holds an archive, or nothing while the library
        /// holds an earlier sync's files: the Mac has not migrated. The
        /// archive's revision is the one read, so a caller can skip the next
        /// read while the server still reports it.
        case notMigrated(revision: String?)
        /// The server sent the bundle without a strong revision, so nothing
        /// could be written over it safely.
        case unversioned
        /// Another device wrote first on every attempt.
        case tooManyAttempts
        /// A version that isn't a bundle this client reads: an archive, a
        /// newer format or damage. Merging it is impossible and dropping it
        /// loses another device's write, so the update stops.
        case unreadableVersion(String)
        /// The bundle has versions and `update` was given no way to merge
        /// them.
        case versionsNeedAMerge
    }

    /// What `update` writes, decided once `change` has run.
    /// (`Verification/SyncMerge.lean`: `settingsWrite`.)
    enum Write: Equatable {
        /// Stop: versions are there and nothing can merge them.
        case needsMerge
        /// Write over the current copy and resolve the versions merged, even
        /// if the merge changed nothing, or they would stay forever.
        case resolve
        case create
        case replace
        case nothing
    }

    static func write(current: Bool, versions: Bool, merges: Bool, changed: Bool) -> Write {
        if versions { return merges ? .resolve : .needsMerge }
        if !current { return .create }
        return changed ? .replace : .nothing
    }

    /// Only a bundle this client reads can be merged; anything else stops the
    /// update. (`Verification/SyncMerge.lean`: `versionMerges`.)
    static func versionMerges(_ contents: LampSyncSettingsBundle.Contents) -> Bool {
        contents == .bundle
    }

    public static let path = LampSyncFolderLayout.bundlePath

    /// What an earlier sync leaves at a library's root: the Mac's folder seal
    /// and its portable backup's manifest, and the phone's settings folder.
    public static let earlierLibraryMarkers: Set<String> = [
        LampSyncFolderPublisher.snapshotPath,
        LampPortableBackupLayout.manifestPath,
        String(LampSyncLayout.userSettingsPath.prefix { $0 != "/" }),
    ]

    /// The bundle, or nil for a library nobody has synced to yet.
    ///
    /// The body is saved to disk and only its header is unpacked until it is
    /// known to be a bundle: before the Mac migrates, it is the whole library.
    /// Pass the revision of the archive this client last read there as
    /// `knownArchiveRevision`, and while the server still reports it, this
    /// answers `notMigrated` from one HEAD instead of fetching it again.
    ///
    /// Nothing at the path is not enough to call a library new. A folder the
    /// Mac keeps holds its files loose with no archive, so with nothing there,
    /// an earlier library's marker or any file in a kind folder answers
    /// `notMigrated` with no revision. Only the migration creates a bundle
    /// over an earlier library; `update` never does.
    /// (`Verification/SyncMerge.lean`: `emptyBundlePath`.)
    public static func read(
        from store: any LampSyncRemoteStore,
        knownArchiveRevision: String? = nil
    ) async throws -> Snapshot? {
        if let knownArchiveRevision, LampWebDAVStorage.isStrongETag(knownArchiveRevision),
           let current = try await store.revision(path: path),
           LampSyncConditionalWrite.namesSameRevision(current, knownArchiveRevision) {
            throw StoreError.notMigrated(revision: current)
        }
        let snapshot = try await readBundle(from: store)
        if snapshot == nil, try await holdsEarlierLibrary(store) {
            throw StoreError.notMigrated(revision: nil)
        }
        return snapshot
    }

    /// Whether a store with nothing at the bundle path holds a library an
    /// earlier sync kept. A root listing, then one listing per kind folder
    /// present, and only when there is no bundle.
    static func holdsEarlierLibrary(_ store: any LampSyncRemoteStore) async throws -> Bool {
        let root = try await store.list(directory: "") ?? []
        let names = Set(root.map(\.name))
        var contentFound = false
        for kind in LampSyncContentKind.allCases where names.contains(kind.rawValue) {
            let entries = try await store.list(directory: kind.rawValue + "/") ?? []
            if entries.contains(where: { !$0.isDirectory && !$0.name.hasPrefix(".") }) {
                contentFound = true
                break
            }
        }
        return emptyPathMeansEarlierLibrary(
            marker: !names.isDisjoint(with: earlierLibraryMarkers), content: contentFound
        )
    }

    /// (`Verification/SyncMerge.lean`: `emptyBundlePath`.)
    static func emptyPathMeansEarlierLibrary(marker: Bool, content: Bool) -> Bool {
        marker || content
    }

    private static func readBundle(from store: any LampSyncRemoteStore) async throws -> Snapshot? {
        try await LampSyncScratchFile.with { scratch in
            var body: LampSyncDownloadedFile?
            var versionFiles: [LampSyncDownloadedFile] = []
            defer { for file in versionFiles { try? FileManager.default.removeItem(at: file.url) } }
            if let versioned = store as? any LampSyncVersionedStore {
                (body, versionFiles) = try await versioned.readWithVersions(path: path, into: scratch)
            } else {
                body = try await store.read(path: path, into: scratch)
            }
            guard let body else { return nil }
            let data = try Data(contentsOf: body.url, options: .alwaysMapped)
            if LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: data))
                == .archive {
                throw StoreError.notMigrated(revision: body.revision)
            }
            let bundle = try LampSyncSettingsBundle.decode(data)
            guard let revision = body.revision, LampWebDAVStorage.isStrongETag(revision) else {
                throw StoreError.unversioned
            }
            var versions: [String: Version] = [:]
            for file in versionFiles {
                guard let revision = file.revision else { throw StoreError.unreadableVersion("") }
                versions[revision] = try version(at: file.url, revision: revision)
            }
            return Snapshot(
                bundle: bundle, revision: revision,
                versions: versions.keys.sorted().compactMap { versions[$0] }
            )
        }
    }

    private static func version(at url: URL, revision: String) throws -> Version {
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard versionMerges(LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: data)))
            else { throw StoreError.unreadableVersion(revision) }
            return Version(bundle: try LampSyncSettingsBundle.decode(data), revision: revision)
        } catch {
            throw StoreError.unreadableVersion(revision)
        }
    }

    /// Whether the bundle moved since `revision`, or has versions waiting to
    /// be merged. One HEAD, no body.
    public static func hasChanged(
        since revision: String?,
        in store: any LampSyncRemoteStore
    ) async throws -> Bool {
        guard let revision else { return true }
        if let versioned = store as? any LampSyncVersionedStore, try await versioned.hasVersions(path: path) {
            return true
        }
        return !LampSyncConditionalWrite.namesSameRevision(try await store.revision(path: path), revision)
    }

    /// Reads the bundle, applies `change` to the server's copy, and writes it
    /// back under the revision it read. If another device wrote first, it
    /// reads again and re-applies, up to `attempts` times. With nothing at
    /// the path, `change` starts from an empty bundle, written only where
    /// still absent.
    ///
    /// `change` may run more than once, each time against a newer bundle, so
    /// it must be a merge that only computes. Apply the result to local
    /// state after `update` returns the written snapshot, or a retry applies
    /// it twice. A change that leaves the bundle as it was writes nothing.
    ///
    /// Where the store kept versions, each is folded in by `mergingVersion`
    /// before `change` runs, and the write resolves exactly those versions.
    /// Pass `LampSyncSettingsBundle.merge(version:)` from LampCore, which
    /// joins everything but the apps' own settings, plus whatever merge the
    /// app makes of those. It may check a version against the ones its
    /// participants were prepared with and throw, as a moved bundle does.
    /// Without it, versions stop the update rather than being dropped.
    ///
    /// Use the returned revision for the rest of the pass. Never re-probe
    /// with `hasChanged` straight after your own write: a NAS may answer with
    /// the revision from before the PUT for a while, which reads as a phantom
    /// change. (`Verification/SyncMerge.lean`: `settingsUpdate`,
    /// `settingsWrite`.)
    @discardableResult
    public static func update(
        in store: any LampSyncRemoteStore,
        attempts: Int = 3,
        mergingVersion: ((inout LampSyncSettingsBundle, Version) throws -> Void)? = nil,
        _ change: (inout LampSyncSettingsBundle) throws -> Void
    ) async throws -> Snapshot {
        for _ in 0..<max(attempts, 1) {
            let current = try await read(from: store)
            let versions = current?.versions ?? []
            var bundle = current?.bundle ?? LampSyncSettingsBundle()
            if let mergingVersion {
                for version in versions { try mergingVersion(&bundle, version) }
            }
            try change(&bundle)
            let decision = write(
                current: current != nil, versions: !versions.isEmpty,
                merges: mergingVersion != nil, changed: bundle != current?.bundle
            )
            let revision: String
            do {
                switch decision {
                case .needsMerge:
                    throw StoreError.versionsNeedAMerge
                case .nothing:
                    // Only with a copy there: an absent bundle is created.
                    if let current { return current }
                    preconditionFailure("an absent bundle is created, never left")
                case .resolve:
                    guard let current, let versioned = store as? any LampSyncVersionedStore else {
                        throw StoreError.versionsNeedAMerge
                    }
                    revision = try await versioned.resolveVersions(
                        of: path, writing: bundle.encoded(), ifRevision: current.revision,
                        resolving: Set(versions.map(\.revision))
                    )
                case .create, .replace:
                    revision = try await LampSyncConditionalWrite.writeAndConfirm(
                        bundle.encoded(), to: path, in: store,
                        condition: current.map { .ifRevision($0.revision) } ?? .ifAbsent
                    )
                }
            } catch where LampSyncConditionalWrite.isRefusal(error) {
                continue
            }
            return Snapshot(bundle: bundle, revision: revision)
        }
        throw StoreError.tooManyAttempts
    }
}
