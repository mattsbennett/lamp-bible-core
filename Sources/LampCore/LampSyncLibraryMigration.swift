import Foundation
import LampModuleKit

/// The Mac's one-time move of a library it kept into the per-file layout.
///
/// It moves only what lives nowhere else under that layout: the Mac's
/// settings, the phone's settings, the shared preferences and both deletion
/// ledgers, which become the first bundle. The library's content it does not
/// copy. The Mac publishes that from its library on its next pass, as every
/// pass does: installed modules by `syncPath()`, personal modules in the
/// phone's format, media, decks and workspace files. Files already on the
/// server in the per-file layout, the phone's and the copies the Mac's
/// compatibility publisher wrote, are adopted by that pass, never written
/// over.
///
/// So the Mac must have just imported the library it moves: on WebDAV the
/// archive at `revision`, on a folder the tree it captured. The bundle is
/// written over the archive only while it is still at that revision, and on a
/// folder only where nothing is yet. Run again, it finds the bundle and writes
/// nothing; a second Mac migrating at the same time has its write refused and
/// returns the first Mac's bundle.
///
/// Nothing old is deleted: the archive is replaced, and a folder's old tree
/// stays where it is. Ask the person to update their other devices first. A
/// device still on format 1 or 2 stops receiving deletions once the bundle is
/// written, and the Mac's folder sync before it, which never reads the bundle,
/// stops at the files it does not recognise.
public enum LampSyncLibraryMigration {
    public enum MigrationError: Error, Equatable, LocalizedError {
        /// An entry the migration cannot place: not a setting or ledger it
        /// carries, not content the Mac publishes from its library, not the
        /// old layout's bookkeeping. It stops rather than lose it.
        case unknownEntry(String)
        /// The library is empty, or only the phone kept it.
        case notTheMacsLibrary
        /// The archive moved since the Mac imported it, or the library is not
        /// the kind it imported: import again, then migrate.
        case importAgain

        public var errorDescription: String? {
            switch self {
            case .unknownEntry(let path): "The library holds a file the move does not know: \(path)."
            case .notTheMacsLibrary: "This library was not kept by the Mac, so the Mac does not move it."
            case .importAgain: "The library changed since it was last synced. Sync, then move it."
            }
        }
    }

    /// What becomes of one entry of the archive or folder tree.
    /// (`Verification/SyncMerge.lean`: `entryFate`.)
    public enum Fate: Equatable, Sendable {
        /// Moved into the first bundle.
        case carried
        /// Content the Mac publishes from its library on its next pass.
        case republished
        /// Already a per-file layout file where it stands; the next pass
        /// adopts it.
        case inPlace
        /// The old layout's bookkeeping, or a retired alias's copy, with
        /// nothing to carry.
        case dropped
        /// Stops the migration.
        case unknown
    }

    private static let carriedPaths: Set<String> = [
        LampPortableBackupLayout.settingsPath,
        LampSyncSettingsArchive.path,
        LampPortableBackupLayout.sharedPreferencesPath,
        LampPortableBackupLayout.deletionLedgerPath,
        LampPresentationDeckPortableLayout.deletionsPath,
    ]

    private static let droppedPaths: Set<String> = [
        LampSyncSettingsArchive.legacyManifestPath,
        LampPortableBackupLayout.compatibilityManifestPath,
        LampPortableBackupLayout.manifestPath,
        LampSyncFolderPublisher.snapshotPath,
        LampSyncLayout.archiveIndexPath,
    ]

    /// The old layout's content folders, which the Mac's library holds.
    private static let republishedDirectories: Set<String> = [
        LampPortableBackupLayout.modulesDirectory,
        LampPortableBackupLayout.studyDirectory,
        LampPortableBackupLayout.mediaDirectory,
        LampPortableBackupLayout.compatibleDirectory,
        LampPortableBackupLayout.workspacesDirectory,
    ]

    public static func fate(of path: String) -> Fate {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.hasPrefix(".") }) { return .dropped }
        if carriedPaths.contains(path) { return .carried }
        if droppedPaths.contains(path) || LampSyncFolderLayout.isRetiredAlias(path) { return .dropped }
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return .unknown }
        let head = String(components[0])
        // The portable tree's writings are JSON documents; a writing in the
        // per-file layout is a `.lamp` module in the same folder.
        if head == LampPortableBackupLayout.devotionalsDirectory, components.count == 2,
           path.lowercased().hasSuffix(".json") {
            return .republished
        }
        if republishedDirectories.contains(head) { return .republished }
        return LampSyncFolderLayout.kind(of: path) == nil ? .unknown : .inPlace
    }

    /// Every entry the move cannot place, so the Mac can name them all
    /// before it asks the person, rather than stop at the first.
    public static func unplaceableEntries(in archive: LampSyncArchive) -> [String] {
        archive.entries.map(\.path).filter { fate(of: $0) == .unknown }.sorted()
    }

    /// The first bundle: every setting and ledger the archive holds. Throws
    /// for an entry it cannot place, before anything is written.
    public static func firstBundle(from archive: LampSyncArchive) throws -> LampSyncSettingsBundle {
        var bundle = LampSyncSettingsBundle()
        for entry in archive.entries {
            switch fate(of: entry.path) {
            case .unknown:
                throw MigrationError.unknownEntry(entry.path)
            case .carried:
                switch entry.path {
                case LampPortableBackupLayout.settingsPath:
                    bundle.macSettings = entry.data
                case LampSyncSettingsArchive.path:
                    bundle.userSettings = entry.data
                case LampPortableBackupLayout.sharedPreferencesPath:
                    bundle.preferences = try LampSyncPreferenceState.decode(entry.data)
                case LampPortableBackupLayout.deletionLedgerPath:
                    // Unreadable stops a pass, so it stops the move.
                    _ = try LampPersonalDeletionLedger.decode(entry.data)
                    bundle.personalDeletions = entry.data
                default:
                    bundle.deckDeletions = entry.data
                }
            case .republished, .inPlace, .dropped:
                continue
            }
        }
        return bundle
    }

    /// One step, decided from whether a bundle is there, the archive revision
    /// the Mac imported (nil for a folder tree), the one there now, and who
    /// kept the library. (`Verification/SyncMerge.lean`: `macMigrationStep`.)
    enum Step: Equatable {
        case alreadyMigrated
        case write(LampSyncWriteCondition)
        case importAgain
        case notTheMacs
    }

    static func step(
        bundlePresent: Bool,
        imported: String?,
        current: String?,
        keeper: LampSyncSettingsStore.EarlierLibrary?
    ) -> Step {
        if bundlePresent { return .alreadyMigrated }
        switch (imported, current) {
        case let (imported?, current?):
            guard LampSyncConditionalWrite.namesSameRevision(imported, current) else { return .importAgain }
            return keeper == .mac ? .write(.ifRevision(current)) : .notTheMacs
        case (nil, nil):
            return keeper == .mac ? .write(.ifAbsent) : .notTheMacs
        default:
            return .importAgain
        }
    }

    /// Moves the library. `archive` is what the Mac just imported: the
    /// archive downloaded at `revision` on WebDAV, or on a folder the tree
    /// it captured, with `revision` nil. Returns the bundle there afterwards,
    /// the Mac's or one another Mac wrote first; run the next pass with it.
    public static func migrate(
        in store: any LampSyncRemoteStore,
        imported archive: LampSyncArchive,
        revision: String?,
        attempts: Int = 3
    ) async throws -> LampSyncSettingsStore.Snapshot {
        for _ in 0..<max(attempts, 1) {
            var snapshot: LampSyncSettingsStore.Snapshot?
            var current: String?
            do {
                // While the server still reports the imported revision, one
                // HEAD answers, and the library is not downloaded again.
                snapshot = try await LampSyncSettingsStore.read(from: store, knownArchiveRevision: revision)
            } catch LampSyncSettingsStore.StoreError.notMigrated(let found) {
                current = found
            }
            let keeper: LampSyncSettingsStore.EarlierLibrary? = switch (snapshot, current) {
            case (.some, _): nil
            case (nil, nil): try await LampSyncSettingsStore.earlierLibrary(in: store)
            case (nil, .some): LampSyncSettingsStore.earlierLibrary(ofArchive: archive)
            }
            switch step(bundlePresent: snapshot != nil, imported: revision, current: current, keeper: keeper) {
            case .alreadyMigrated:
                if let snapshot { return snapshot }
            case .importAgain:
                throw MigrationError.importAgain
            case .notTheMacs:
                throw MigrationError.notTheMacsLibrary
            case .write(let condition):
                let bundle = try firstBundle(from: archive)
                do {
                    let written = try await LampSyncConditionalWrite.writeAndConfirm(
                        bundle.encoded(), to: LampSyncSettingsStore.path, in: store, condition: condition
                    )
                    return LampSyncSettingsStore.Snapshot(bundle: bundle, revision: written)
                } catch where LampSyncConditionalWrite.isRefusal(error) {
                    continue
                }
            }
        }
        throw LampSyncSettingsStore.StoreError.tooManyAttempts
    }
}
