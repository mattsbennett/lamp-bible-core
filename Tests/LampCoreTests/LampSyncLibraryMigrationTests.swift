import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// The Mac's one-time move, over WebDAV's archive and a folder's tree.
struct LampSyncLibraryMigrationTests {
    private let deckLedger = Data(#"{"deletedAt":{"easter":0},"formatVersion":1}"#.utf8)

    /// What a Mac's archive holds, with the phone's settings published into
    /// it as the phone does.
    private func macArchive(adding extra: [String: Data] = [:]) throws -> (LampSyncArchive, LampSharedPreferenceLedger) {
        var deletions = LampPersonalDeletionLedger()
        deletions.recordDeletion(.note, "n1", at: 5)
        let preferences = LampSharedPreferenceLedger(fields: ["reader.fontSize": .init(value: .number(19))])
        var archive = try LampSyncPreferenceState.replacing(
            preferences, in: LampSyncSettingsArchive.replacingData(Data("phone settings".utf8), in: nil)
        )
        let entries: [String: Data] = [
            LampPortableBackupLayout.settingsPath: Data("mac settings".utf8),
            LampPortableBackupLayout.deletionLedgerPath: try deletions.encoded(),
            LampPresentationDeckPortableLayout.deletionsPath: deckLedger,
            "Modules/9f86d081884c7d65.lamp": Data("module".utf8),
            "Study/Notes/john.json": Data("{}".utf8),
            "Devotionals/daily.json": Data("{}".utf8),
            "Media/Devotionals/daily/a.png": Data("png".utf8),
            "Compatibility/Notes/notes.lamp": Data("notes".utf8),
            "Workspaces/Presentations/easter.lampdeck": Data("deck".utf8),
        ].merging(extra) { _, new in new }
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            archive = try archive.replacingEntry(at: path, with: data)
        }
        return (archive, preferences)
    }

    @Test func theFirstBundleCarriesEverySettingAndLedger() throws {
        let (archive, preferences) = try macArchive()
        let bundle = try LampSyncLibraryMigration.firstBundle(from: archive)
        #expect(bundle.macSettings == Data("mac settings".utf8))
        #expect(bundle.userSettings == Data("phone settings".utf8))
        #expect(bundle.preferences == preferences)
        let deletions = try LampPersonalDeletionLedger.decode(try #require(bundle.personalDeletions))
        #expect(deletions.entry(.note, "n1")?.deletedAt == 5)
        #expect(bundle.deckDeletions == deckLedger)
        #expect(bundle.manifest.paths.isEmpty)
    }

    /// Something the move cannot place stops it, before anything is written;
    /// Finder's dotfiles are dropped.
    @Test func anUnknownEntryStopsTheMoveAndADotfileDoesNot() async throws {
        let (unknown, _) = try macArchive(adding: ["Backups/old.zip": Data("zip".utf8)])
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try unknown.compressedData(), "\"a1\"")
        await #expect(throws: LampSyncLibraryMigration.MigrationError.unknownEntry("Backups/old.zip")) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: unknown, revision: "\"a1\"")
        }
        #expect(store.writes == 0)

        let (dotfile, _) = try macArchive(adding: ["Media/.DS_Store": Data()])
        #expect(try LampSyncLibraryMigration.firstBundle(from: dotfile).macSettings == Data("mac settings".utf8))
    }

    /// WebDAV: the bundle replaces the archive the Mac imported, and only
    /// that one. Run again, it writes nothing.
    @Test func anArchiveIsReplacedOnlyAtTheRevisionImported() async throws {
        let (archive, _) = try macArchive()
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a1\"")

        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"")
        #expect(store.conditions == [.ifRevision("\"a1\"")])
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store) == moved)
        #expect(try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"") == moved)
        #expect(store.writes == 1)
    }

    @Test func anArchiveThatMovedSinceTheImportIsImportedAgain() async throws {
        let (archive, _) = try macArchive()
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a2\"")
        await #expect(throws: LampSyncLibraryMigration.MigrationError.importAgain) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"")
        }
        #expect(store.writes == 0)
    }

    /// Another device wrote between the check and the write: refused, and
    /// what it wrote decides. Another Mac's bundle is returned; an archive
    /// that moved means importing again.
    @Test func aRaceIsSettledByWhatWonIt() async throws {
        let (archive, _) = try macArchive()
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a1\"")
        let other = LampSyncSettingsBundle(macSettings: Data("other mac".utf8))
        store.beforeNextWrite = { store.files[LampSyncSettingsStore.path] = (try other.encoded(), "\"b1\"") }
        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"")
        #expect(moved == LampSyncSettingsStore.Snapshot(bundle: other, revision: "\"b1\"") && store.writes == 0)

        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a1\"")
        let newer = try archive.replacingEntry(at: "Modules/other.lamp", with: Data("newer".utf8))
        store.beforeNextWrite = { store.files[LampSyncSettingsStore.path] = (try newer.compressedData(), "\"a2\"") }
        await #expect(throws: LampSyncLibraryMigration.MigrationError.importAgain) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"")
        }
    }

    @Test func aPhonesArchiveIsNotTheMacsToMove() async throws {
        let phone = try LampSyncSettingsArchive.replacingData(Data("phone".utf8), in: nil)
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try phone.compressedData(), "\"a1\"")
        await #expect(throws: LampSyncLibraryMigration.MigrationError.notTheMacsLibrary) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: phone, revision: "\"a1\"")
        }
        #expect(store.writes == 0)
    }

    /// A folder the Mac's folder sync kept, published and captured as that
    /// sync does; the phone then writes a module beside it. The move writes
    /// the bundle where nothing was; the next pass adopts the phone's module
    /// and the deck, and leaves the old tree's writings alone.
    @Test func aFolderTheMacKeptIsMovedByWritingTheFirstBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-move-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Library", isDirectory: true)
        let tree = root.appendingPathComponent("Tree", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (archive, _) = try macArchive()
        try archive.extract(to: tree)
        let observed = try await LampSyncFolderPublisher.capture(from: folder)
        try await LampSyncFolderPublisher.publish(
            LampSyncArchive.create(from: tree), to: folder, replacing: observed
        )
        let imported = try await LampSyncFolderPublisher.capture(from: folder)
        // The phone writes a module after the Mac's import, before the move.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Translations"), withIntermediateDirectories: true
        )
        try Data("kjv".utf8).write(to: folder.appendingPathComponent("Translations/kjv.lamp"))

        let store = LampSyncDirectoryStore(root: folder)
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .mac)
        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: imported, revision: nil)
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store) == moved)

        let listing = try await LampSyncFilePlan.listing(in: store, manifest: moved.bundle.manifest)
        #expect(listing.keys.sorted() == ["Translations/kjv.lamp", "Workspaces/Presentations/easter.lampdeck"])
        let plan = LampSyncFilePlan.plan(
            manifest: moved.bundle.manifest, local: [], deletedLocally: [:], listing: listing
        )
        #expect(plan.adopt.keys.sorted() == ["Translations/kjv.lamp", "Workspaces/Presentations/easter.lampdeck"])
    }

    @Test func anEmptyFolderIsNotTheMacsToMove() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-move-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await #expect(throws: LampSyncLibraryMigration.MigrationError.notTheMacsLibrary) {
            try await LampSyncLibraryMigration.migrate(
                in: LampSyncDirectoryStore(root: folder), imported: LampSyncArchive(entries: []), revision: nil
            )
        }
    }
}

/// A WebDAV server reduced to conditional writes on files by path.
private final class ArchiveStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: (Data, String)] = [:]
    var beforeNextWrite: (() throws -> Void)?
    private(set) var writes = 0
    private(set) var conditions: [LampSyncWriteCondition] = []
    private var counter = 0

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        files[path].map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
    }

    func revision(path: String) async throws -> String? { files[path]?.1 }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        if let beforeNextWrite {
            self.beforeNextWrite = nil
            try beforeNextWrite()
        }
        conditions.append(condition)
        switch condition {
        case .ifAbsent where files[path] != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let revision) where files[path]?.1 != revision:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        writes += 1
        counter += 1
        let revision = "\"w\(counter)\""
        files[path] = (data, revision)
        return revision
    }
}
