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

    /// A real export, not a hand-made list: the library's own portable
    /// backup, with what the Mac adds beside it, as its archive pass packs
    /// it. Every entry must have a place, or the person's move would refuse.
    @Test func everyEntryOfARealExportHasAPlace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-move-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let library = LampLibrary(rootURL: libraryRoot)
        try await library.savePersonalDevotional(LampDevotional(
            id: "daily", moduleID: "personal-devotionals", moduleName: "My Writing", title: "Daily",
            content: "![A](lamp-media://daily/a.png)",
            mediaJSON: #"[{"id":"a","type":"image","filename":"a.png"}]"#
        ))
        try await library.savePersonalDevotional(LampDevotional(
            id: "gone", moduleID: "personal-devotionals", moduleName: "My Writing", title: "Gone", content: "x"
        ))
        try await library.deletePersonalDevotional(id: "gone")
        _ = try await library.setPersonalVerseNote(reference: 43_003_016, content: "Note")
        _ = try await library.saveVerseHighlight(
            translationID: "TEST", reference: 43_003_016, startOffset: 0, endOffset: 4, color: "#FFCC00"
        )
        let media = libraryRoot.appendingPathComponent("Media/Devotionals/daily", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: media.appendingPathComponent("a.png"))
        try Data().write(to: libraryRoot.appendingPathComponent("Media/.DS_Store"))

        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        _ = try await library.exportPortableBackup(to: outgoing)
        // What the Mac writes beside the backup, and what the phone adds.
        let beside: [String: Data] = [
            LampPortableBackupLayout.settingsPath: Data("plist".utf8),
            LampPortableBackupLayout.sharedPreferencesPath: try LampSyncPreferenceState.encode(.init()),
            "Workspaces/Skills/build-lamp-deck/SKILL.md": Data("skill".utf8),
            "Workspaces/Devotionals/daily/Documents/draft.md": Data("draft".utf8),
            "Workspaces/Devotionals/daily/EnabledSkills.json": Data("[]".utf8),
            "Workspaces/Presentations/easter.lampdeck": Data("deck".utf8),
            "Workspaces/Presentations/Assets/slide.png": Data("png".utf8),
            LampPresentationDeckPortableLayout.deletionsPath: deckLedger,
            LampPortableBackupLayout.compatibilityManifestPath: Data("{}".utf8),
            "Compatibility/Notes/notes.lamp": Data("notes".utf8),
            "Compatibility/Devotionals/devotionals.lamp": Data("writing".utf8),
            LampSyncSettingsArchive.path: Data("phone".utf8),
            LampSyncSettingsArchive.legacyManifestPath: Data("{}".utf8),
        ]
        for (path, data) in beside {
            let url = outgoing.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let archive = try LampSyncArchive.create(from: outgoing)
        #expect(archive.entries.contains { $0.path == LampPortableBackupLayout.deletionLedgerPath })
        #expect(archive.entries.contains { $0.path.hasPrefix("Study/") })
        #expect(LampSyncLibraryMigration.unplaceableEntries(in: archive).isEmpty)
        let bundle = try LampSyncLibraryMigration.firstBundle(from: archive)
        #expect(bundle.personalDeletions != nil && bundle.macSettings == Data("plist".utf8))
    }

    @Test func everyUnplaceableEntryIsNamedAtOnce() throws {
        let (archive, _) = try macArchive(adding: ["Backups/old.zip": Data(), "notes.txt": Data()])
        #expect(LampSyncLibraryMigration.unplaceableEntries(in: archive) == ["Backups/old.zip", "notes.txt"])
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
            try await LampSyncLibraryMigration.migrate(in: store, imported: unknown, revision: "\"a1\"", patience: .immediate)
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

        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"", patience: .immediate)
        #expect(store.conditions == [.ifRevision("\"a1\"")])
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == moved)
        #expect(try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"", patience: .immediate) == moved)
        #expect(store.writes == 1)
    }

    /// The user's first move: the bundle lands over the archive, and the
    /// Synology keeps naming the archive for a few reads. The move waits for
    /// it, asking by HEAD so the library-sized archive is not downloaded
    /// again, and never retries into a refusal of its own write.
    @Test func aMoveWaitsForALaggingServerRatherThanRetrying() async throws {
        let (archive, _) = try macArchive()
        let store = ArchiveStore()
        let packed = try archive.compressedData()
        store.files[LampSyncSettingsStore.path] = (packed, "\"a1\"")
        store.watched = packed
        store.namesRevisionOnPut = false
        store.lag = 3
        let moved = try await LampSyncLibraryMigration.migrate(
            in: store, imported: archive, revision: "\"a1\"",
            patience: .init(confirm: Array(repeating: .zero, count: 5), retry: [.zero])
        )
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(store.writes == 1 && store.archiveDownloads == 0)
    }

    @Test func anArchiveThatMovedSinceTheImportIsImportedAgain() async throws {
        let (archive, _) = try macArchive()
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a2\"")
        await #expect(throws: LampSyncLibraryMigration.MigrationError.importAgain) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"", patience: .immediate)
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
        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"", patience: .immediate)
        #expect(moved == LampSyncSettingsStore.Snapshot(bundle: other, revision: "\"b1\"") && store.writes == 0)

        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a1\"")
        let newer = try archive.replacingEntry(at: "Modules/other.lamp", with: Data("newer".utf8))
        store.beforeNextWrite = { store.files[LampSyncSettingsStore.path] = (try newer.compressedData(), "\"a2\"") }
        await #expect(throws: LampSyncLibraryMigration.MigrationError.importAgain) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: archive, revision: "\"a1\"", patience: .immediate)
        }
    }

    @Test func aPhonesArchiveIsNotTheMacsToMove() async throws {
        let phone = try LampSyncSettingsArchive.replacingData(Data("phone".utf8), in: nil)
        let store = ArchiveStore()
        store.files[LampSyncSettingsStore.path] = (try phone.compressedData(), "\"a1\"")
        await #expect(throws: LampSyncLibraryMigration.MigrationError.notTheMacsLibrary) {
            try await LampSyncLibraryMigration.migrate(in: store, imported: phone, revision: "\"a1\"", patience: .immediate)
        }
        #expect(store.writes == 0)
    }

    /// A folder the Mac's folder sync kept, as that sync left it; the phone
    /// then writes a module beside it. The move writes
    /// the bundle where nothing was; the next pass adopts the phone's module
    /// and the deck, and leaves the old tree's writings alone.
    @Test func aFolderTheMacKeptIsMovedByWritingTheFirstBundle() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-move-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The folder as the Mac's folder sync left it, captured from that sync.
        for (path, data) in ArchiveEraFixtures.macFolder {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let imported = try await LampSyncFolderPublisher.capture(from: folder)
        // The phone writes a module after the Mac's import, before the move.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Translations"), withIntermediateDirectories: true
        )
        try Data("kjv".utf8).write(to: folder.appendingPathComponent("Translations/kjv.lamp"))

        let store = LampSyncDirectoryStore(root: folder)
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .mac)
        let moved = try await LampSyncLibraryMigration.migrate(in: store, imported: imported, revision: nil, patience: .immediate)
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == moved)

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
                in: LampSyncDirectoryStore(root: folder), imported: LampSyncArchive(entries: []), revision: nil,
                patience: .immediate
            )
        }
    }
}

/// A WebDAV server reduced to conditional writes on files by path.
private final class ArchiveStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: (Data, String)] = [:]
    var beforeNextWrite: (() throws -> Void)?
    /// False for a server like the user's Synology, which names no revision
    /// on PUT and answers the next `lag` reads with what it held before.
    var namesRevisionOnPut = true
    var lag = 0
    private var before: [String: (Data, String)] = [:]
    private var remaining: [String: Int] = [:]
    private(set) var writes = 0
    /// Bytes whose downloads are counted in `archiveDownloads`.
    var watched: Data?
    private(set) var archiveDownloads = 0
    private(set) var conditions: [LampSyncWriteCondition] = []
    private var counter = 0

    private func visible(_ path: String) -> (Data, String)? {
        guard let left = remaining[path], left > 0 else { return files[path] }
        remaining[path] = left - 1
        return before[path]
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        let file = visible(path)
        if let watched, file?.0 == watched { archiveDownloads += 1 }
        return file.map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
    }

    func revision(path: String) async throws -> String? { visible(path)?.1 }

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
        before[path] = files[path]
        remaining[path] = lag
        files[path] = (data, revision)
        return namesRevisionOnPut ? revision : nil
    }
}
