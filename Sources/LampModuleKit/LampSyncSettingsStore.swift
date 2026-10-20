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

    /// What the Mac's folder sync leaves at a library's root: its seal and its
    /// portable backup's manifest.
    public static let macLibraryMarkers: Set<String> = [
        LampSyncFolderPublisher.snapshotPath,
        LampPortableBackupLayout.manifestPath,
    ]

    /// What the phone's earlier sync leaves at a library's root: its settings
    /// folder.
    public static let phoneLibraryMarkers: Set<String> = [
        String(LampSyncLayout.userSettingsPath.prefix { $0 != "/" }),
    ]

    /// Everything an earlier sync leaves at a library's root.
    public static let earlierLibraryMarkers = macLibraryMarkers.union(phoneLibraryMarkers)

    /// Who kept a library nobody has migrated.
    public enum EarlierLibrary: Equatable, Sendable {
        /// The Mac's folder sync, by its seal or its portable manifest. Its
        /// files are a backup's layout, not the per-file one, so only the
        /// Mac's migration can move it.
        case mac
        /// Only the phone's own files, or modules dropped in by hand: already
        /// the per-file layout, named by their IDs. Moved by claiming the
        /// path (`migratePhoneLibrary`); the next pass adopts the files.
        case phone
    }

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

    /// The bundle, or, in a library nobody has synced to yet, an empty one
    /// written there first. Start a pass with this rather than `read`.
    ///
    /// A pass that found nothing and wrote its files before the bundle would
    /// lock itself out: its own files are what make the next read call the
    /// library an earlier one, so its closing `update` would throw
    /// `notMigrated` on every pass. Claiming the path first means every read
    /// after finds a bundle. The empty bundle is written only where still
    /// absent; a device that loses that race reads the winner's.
    /// (`Verification/SyncMerge.lean`: `bundleRead`,
    /// `uploadingFirstLocksAFreshLibraryOut`.)
    public static func readOrClaim(
        from store: any LampSyncRemoteStore,
        knownArchiveRevision: String? = nil,
        attempts: Int = 3
    ) async throws -> Snapshot {
        try await claim(
            in: store, knownArchiveRevision: knownArchiveRevision, attempts: attempts, migratingPhone: false
        )
    }

    /// Moves a library only the phone kept to the per-file layout, by
    /// writing the first bundle. The pass that follows adopts its files:
    /// they are already in the per-file layout, named by their IDs. Returns
    /// the bundle there if another device got there first, and the bundle
    /// already there if the library is migrated.
    ///
    /// On a folder, nothing is at the bundle path, and the first bundle is
    /// empty, written where still absent. On WebDAV, the phone left a
    /// settings-only archive there. The bundle replaces it, written only
    /// while it is still the archive judged, and carries its settings and
    /// shared preferences, so nothing set on another phone is lost.
    ///
    /// A library the Mac kept still throws `notMigrated`, whether a folder or
    /// an archive. Call this only once the person has agreed,
    /// having been asked to update their other devices first: the phone's
    /// iCloud sync before 1.2.0 never reads the bundle, so an un-updated
    /// device keeps writing files and settings the new sync ignores.
    /// (`Verification/SyncMerge.lean`: `mayClaim`,
    /// `thePhoneNeverClaimsAMacLibrary`.)
    public static func migratePhoneLibrary(
        in store: any LampSyncRemoteStore,
        attempts: Int = 3
    ) async throws -> Snapshot {
        try await claim(in: store, knownArchiveRevision: nil, attempts: attempts, migratingPhone: true)
    }

    private static func claim(
        in store: any LampSyncRemoteStore,
        knownArchiveRevision: String?,
        attempts: Int,
        migratingPhone: Bool
    ) async throws -> Snapshot {
        var knownArchiveRevision = knownArchiveRevision
        for _ in 0..<max(attempts, 1) {
            // The bundle to write first, and the condition it is written
            // under: where nothing is, or over the phone's archive as read.
            var first = LampSyncSettingsBundle()
            var condition = LampSyncWriteCondition.ifAbsent
            do {
                if let snapshot = try await read(from: store, knownArchiveRevision: knownArchiveRevision) {
                    return snapshot
                }
            } catch StoreError.notMigrated(revision: nil) where migratingPhone {
                guard mayClaim(try await earlierLibrary(in: store), migratingPhone: true) else {
                    throw StoreError.notMigrated(revision: nil)
                }
            } catch StoreError.notMigrated(let revision?) where migratingPhone {
                guard let archive = try await phoneArchive(in: store) else {
                    throw StoreError.notMigrated(revision: revision)
                }
                first = try bundle(fromPhoneArchive: archive.archive)
                condition = .ifRevision(archive.revision)
            }
            knownArchiveRevision = nil
            do {
                let revision = try await LampSyncConditionalWrite.writeAndConfirm(
                    first.encoded(), to: path, in: store, condition: condition
                )
                return Snapshot(bundle: first, revision: revision)
            } catch where LampSyncConditionalWrite.isRefusal(error) {
                continue
            }
        }
        throw StoreError.tooManyAttempts
    }

    /// Whether a pass may write the first bundle: in a new library, or in one
    /// only the phone kept when migrating it. Never in one the Mac kept.
    /// (`Verification/SyncMerge.lean`: `mayClaim`.)
    static func mayClaim(_ earlier: EarlierLibrary?, migratingPhone: Bool) -> Bool {
        switch earlier {
        case nil: true
        case .phone: migratingPhone
        case .mac: false
        }
    }

    /// Who kept the library, or nil for an empty one or one already
    /// migrated. An archive at the bundle path is judged by its entries
    /// (`earlierLibrary(ofArchive:)`); it is downloaded to judge it, so a
    /// caller that already read the archive should judge that instead, and
    /// one that polls should remember the answer by the archive's revision.
    /// Otherwise one root listing, then one listing per kind folder present.
    public static func earlierLibrary(in store: any LampSyncRemoteStore) async throws -> EarlierLibrary? {
        if try await store.revision(path: path) != nil {
            return try await LampSyncScratchFile.with { scratch -> EarlierLibrary? in
                guard let body = try await store.read(path: path, into: scratch) else { return nil }
                return try archiveKeeper(at: body.url)?.keeper
            }
        }
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
        return earlierLibrary(
            mac: !names.isDisjoint(with: macLibraryMarkers),
            phone: !names.isDisjoint(with: phoneLibraryMarkers),
            content: contentFound
        )
    }

    /// What a phone's settings-only archive holds: its settings, the legacy
    /// manifest beside them, the shared preferences, and the empty portable
    /// manifest core writes into any new archive. All sort at or after
    /// `Settings/`.
    public static let phoneArchivePaths: Set<String> = [
        LampSyncSettingsArchive.path,
        LampSyncSettingsArchive.legacyManifestPath,
        LampPortableBackupLayout.sharedPreferencesPath,
        LampPortableBackupLayout.manifestPath,
    ]

    /// Who wrote an archive. The phone's holds nothing but settings; one with
    /// anything else, a module or the Mac's own `settings.plist`, is the
    /// Mac's. (`Verification/SyncMerge.lean`: `archiveKeeper`.)
    public static func earlierLibrary(ofArchive archive: LampSyncArchive) -> EarlierLibrary {
        archiveKeeper(paths: archive.entries.map(\.path))
    }

    static func archiveKeeper(paths: [String]) -> EarlierLibrary {
        paths.allSatisfy(phoneArchivePaths.contains) ? .phone : .mac
    }

    /// Whether an archive's first entry already says it is the Mac's. Entries
    /// are sorted by path, and everything a phone's archive holds sorts at
    /// or after `Settings/`, so a first entry before it (`Modules/`,
    /// `Media/`, …) means the Mac's, judged without unpacking a library.
    /// (`Verification/SyncMerge.lean`: `thePeekNeverMisjudgesAPhoneArchive`.)
    static func firstEntryIsTheMacs(_ path: String) -> Bool {
        path < "Settings/"
    }

    /// Judges the body at `url`: nil for a bundle, otherwise who wrote the
    /// archive, and the archive when it was unpacked to tell.
    private static func archiveKeeper(at url: URL) throws -> (keeper: EarlierLibrary, archive: LampSyncArchive?)? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: data)) == .archive
        else { return nil }
        if let prefix = try? LampZlib.decompressedPrefix(of: data, count: 1024),
           let match = String(decoding: prefix, as: UTF8.self)
               .firstMatch(of: #/"entries"\s*:\s*\[\s*\{\s*"path"\s*:\s*"([^"\\]*)"/#),
           firstEntryIsTheMacs(String(match.1)) {
            return (.mac, nil)
        }
        let archive = try LampSyncArchive.decode(compressedFileAt: url)
        return (earlierLibrary(ofArchive: archive), archive)
    }

    /// The archive at the bundle path and its revision, if the phone wrote it.
    private static func phoneArchive(
        in store: any LampSyncRemoteStore
    ) async throws -> (archive: LampSyncArchive, revision: String)? {
        try await LampSyncScratchFile.with { scratch in
            guard let body = try await store.read(path: path, into: scratch),
                  let revision = body.revision, LampWebDAVStorage.isStrongETag(revision),
                  let judged = try archiveKeeper(at: body.url), judged.keeper == .phone,
                  let archive = judged.archive
            else { return nil }
            return (archive, revision)
        }
    }

    /// The first bundle over a phone's archive: its settings and its shared
    /// preferences. The phone's modules were never in it; they are loose
    /// files, which the next pass adopts.
    static func bundle(fromPhoneArchive archive: LampSyncArchive) throws -> LampSyncSettingsBundle {
        LampSyncSettingsBundle(
            userSettings: archive.entries.first { $0.path == LampSyncSettingsArchive.path }?.data,
            preferences: try LampSyncPreferenceState.ledger(in: archive) ?? .init()
        )
    }

    /// The Mac's marks win: only its migration can move its layout.
    /// (`Verification/SyncMerge.lean`: `earlierLibrary`.)
    static func earlierLibrary(mac: Bool, phone: Bool, content: Bool) -> EarlierLibrary? {
        if mac { return .mac }
        return phone || content ? .phone : nil
    }

    static func holdsEarlierLibrary(_ store: any LampSyncRemoteStore) async throws -> Bool {
        try await earlierLibrary(in: store) != nil
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
