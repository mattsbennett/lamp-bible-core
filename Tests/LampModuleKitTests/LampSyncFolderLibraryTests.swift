import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncFolderLibraryTests {
    // MARK: - Layout

    @Test func eachPathSaysWhatItHolds() throws {
        #expect(LampSyncFolderLayout.kind(of: "Translations/kjv.lamp") == .module(.translations))
        #expect(LampSyncFolderLayout.kind(of: "Notes/notes.LAMP") == .module(.notes))
        #expect(LampSyncFolderLayout.kind(of: "DevotionalMedia/m/w/a.png") == .devotionalMedia)
        #expect(LampSyncFolderLayout.kind(of: "BookMedia/b/images/a.png") == .bookMedia)
        #expect(LampSyncFolderLayout.kind(of: "Workspaces/Presentations/d.lampdeck") == .deck)
        #expect(LampSyncFolderLayout.kind(of: "Workspaces/Presentations/Assets/a.png") == .deckAsset)
        #expect(LampSyncFolderLayout.kind(of: "Workspaces/Sermons/a.md") == .workspaceFile)
        #expect(try LampSyncFolderLayout.modulePath(kind: .notes, moduleID: "notes") == "Notes/notes.lamp")
        #expect(try LampSyncFolderLayout.bookMediaPath(moduleID: "b", path: "images/a.png") == "BookMedia/b/images/a.png")
        #expect(LampSyncFolderLayout.remoteModuleID(of: "Highlights/set-1.lamp") == "set-1")
        #expect(LampSyncFolderLayout.remoteModuleID(of: "DevotionalMedia/m/w/a.png") == "m")
    }

    /// Placeholders, legacy formats, the bundle and anything unsafe are
    /// outside the library, so a listing can never adopt them.
    @Test func whatIsOutsideTheLayoutIsNothing() {
        for path in [
            "Translations/.kjv.lamp.icloud", "Translations/.DS_Store", "Translations/kjv.db.zlib",
            "Translations/kjv.json", "Translations/.lamp", "lamp-bible.lampsync",
            "lamp-bible.lampsync.index.json", "Notes/../x.lamp", "Notes/a/b.lamp",
            "Workspaces/Presentations/deleted-decks.json", "Workspaces/Presentations/x/y.lampdeck",
            "DevotionalMedia/m/a.png", "Unknown/a.lamp",
        ] {
            #expect(LampSyncFolderLayout.kind(of: path) == nil, "\(path)")
        }
        #expect(throws: LampSyncFolderLayout.PathError.self) {
            try LampSyncFolderLayout.modulePath(kind: .notes, moduleID: "../x")
        }
        #expect(throws: LampSyncFolderLayout.PathError.self) {
            try LampSyncFolderLayout.workspaceFilePath(relativePath: "Presentations/d.lampdeck")
        }
    }

    // MARK: - Manifest

    @Test func membershipComesOnlyFromTheManifest() throws {
        var manifest = LampSyncLibraryManifest()
        manifest = try manifest.recordingWrite("Notes/notes.lamp", revision: "\"1\"", replacing: nil, at: 5)
        manifest = try manifest.removing("Notes/notes.lamp", at: 5, revision: "\"1\"")
        // Equal times are a deletion.
        #expect(manifest.members.isEmpty)
        #expect(manifest.tombstones.map(\.path) == ["Notes/notes.lamp"])
        #expect(throws: LampSyncLibraryManifest.ManifestError.outsideLayout("x.txt")) {
            try manifest.adopting("x.txt", revision: "\"1\"", at: 1)
        }
    }

    /// A slow clock cannot make a later write lose to the one it replaced.
    @Test func aSuccessorWriteIsStampedAfterItsPredecessor() throws {
        var manifest = try LampSyncLibraryManifest()
            .recordingWrite("Notes/notes.lamp", revision: "\"1\"", replacing: nil, at: 100)
        manifest = try manifest.recordingWrite("Notes/notes.lamp", revision: "\"2\"", replacing: "\"1\"", at: 40)
        #expect(manifest.entry(at: "Notes/notes.lamp")?.presentSince == 101)
        #expect(manifest.entry(at: "Notes/notes.lamp")?.revision == "\"2\"")
    }

    @Test func aManifestEncodesTheSameEveryTime() throws {
        var manifest = LampSyncLibraryManifest()
        for (index, path) in ["Notes/b.lamp", "Notes/a.lamp", "Translations/c.lamp"].enumerated() {
            manifest = try manifest.recordingWrite(path, revision: "\"\(index)\"", replacing: nil, at: Int64(index))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(manifest)
        #expect(try JSONDecoder().decode(LampSyncLibraryManifest.self, from: encoded) == manifest)
        #expect(try encoder.encode(JSONDecoder().decode(LampSyncLibraryManifest.self, from: encoded)) == encoded)
    }

    @Test func aManifestWithAnUnsafePathIsRefused() {
        let json = #"{"entries":[{"path":"Notes/../../etc/passwd","presentSince":1}]}"#
        #expect(throws: LampSyncLibraryManifest.ManifestError.self) {
            try JSONDecoder().decode(LampSyncLibraryManifest.self, from: Data(json.utf8))
        }
    }

    // MARK: - Plan

    /// The batched pass: files written, then the pass ends before its
    /// bundle update. Another device adopts what it finds rather than
    /// treating it as a conflict or a loss, and the writer itself only
    /// records it.
    @Test func aPassThatEndedBeforeRecordingHealsOnTheNext() {
        let path = "Notes/notes.lamp"
        let other = LampSyncFilePlan.plan(
            manifest: .init(), local: [], deletedLocally: [:], listing: [path: "\"7\""]
        )
        #expect(other.adopt == [path: "\"7\""] && other.downloads == [path])
        let writer = LampSyncFilePlan.plan(
            manifest: .init(),
            local: [.init(path: path, changedSinceUpload: false, lastRevision: "7", savedAt: 1)],
            deletedLocally: [:],
            listing: [path: "\"7\""]
        )
        #expect(writer.adopt == [path: "\"7\""] && writer.downloads.isEmpty && writer.uploads.isEmpty)
    }

    /// The deck deletion ledger sits in the listed deck folder but belongs
    /// in the bundle. Adopted as a member file, two Macs' deletions would be
    /// won rather than merged, and a deleted deck would come back.
    @Test func aLedgerInAListedFolderIsNeverAdopted() async throws {
        let ledger = "Workspaces/Presentations/deleted-decks.json"
        let plan = LampSyncFilePlan.plan(
            manifest: .init(), local: [], deletedLocally: [:], listing: [ledger: "\"1\""]
        )
        #expect(plan == .init())
        let store = DeckFolderStore()
        let listing = try await LampSyncFilePlan.listing(in: store, manifest: .init())
        #expect(listing == ["Workspaces/Presentations/d.lampdeck": "\"2\""])
    }

    // MARK: - Store

    @Test func anUnmigratedLibraryIsReportedNotRead() async throws {
        let store = BundleStore()
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "manifest.json", data: Data("{}".utf8), modifiedAt: Date(timeIntervalSince1970: 0)),
        ])
        store.files[LampSyncSettingsStore.path] = (try archive.compressedData(), "\"a1\"")
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"a1\"")) {
            try await LampSyncSettingsStore.read(from: store)
        }
        // While the server still reports that archive, one HEAD answers.
        let reads = store.reads
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"a1\"")) {
            try await LampSyncSettingsStore.read(from: store, knownArchiveRevision: "\"a1\"")
        }
        #expect(store.reads == reads)
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"a1\"")) {
            try await LampSyncSettingsStore.update(in: store, patience: .immediate) { $0.userSettings = Data() }
        }
        #expect(store.writes == 0)
    }

    @Test func anEmptyServerStartsAFreshBundleOnlyWhereStillAbsent() async throws {
        let store = BundleStore()
        let written = try await LampSyncSettingsStore.update(in: store, patience: .immediate) {
            $0.manifest = try $0.manifest.recordingWrite("Notes/notes.lamp", revision: "\"1\"", replacing: nil, at: 1)
        }
        #expect(store.conditions == [.ifAbsent])
        #expect(try await LampSyncSettingsStore.read(from: store) == written)
        #expect(try await !LampSyncSettingsStore.hasChanged(since: written.revision, in: store))
        #expect(try await LampSyncSettingsStore.hasChanged(since: "\"other\"", in: store))
        // A change that changes nothing writes nothing.
        let unchanged = try await LampSyncSettingsStore.update(in: store, patience: .immediate) { _ in }
        #expect(unchanged == written && store.writes == 1)
    }

    /// The copy the old sync left under notes' retired ID is outside the
    /// layout: adopted, it would be a second notes module of old notes.
    @Test func theRetiredNotesAliasIsOutsideTheLayout() {
        #expect(LampSyncFolderLayout.kind(of: "Notes/bible-notes.lamp") == nil)
        #expect(LampSyncFolderLayout.isRetiredAlias("Notes/bible-notes.lamp"))
        #expect(LampSyncFolderLayout.kind(of: "Notes/notes.lamp") == .module(.notes))
        #expect(LampSyncFolderLayout.kind(of: "Highlights/bible-notes.lamp") == .module(.highlights))
        #expect(!LampSyncFolderLayout.isRetiredAlias("Highlights/bible-notes.lamp"))
    }

    /// Every module kind has a folder, and a module placed there by its ID
    /// reads back as that kind and that ID.
    @Test func eachModuleKindHasAFolderThatRoundTrips() throws {
        #expect(Set(LampModuleKind.allCases.map(LampSyncContentKind.init)) == Set(LampSyncContentKind.allCases))
        for kind in LampModuleKind.allCases {
            let folder = LampSyncContentKind(kind)
            let path = try LampSyncFolderLayout.modulePath(kind: folder, moduleID: "web")
            #expect(path == "\(folder.rawValue)/web.lamp")
            #expect(LampSyncFolderLayout.kind(of: path) == .module(folder))
            #expect(LampSyncFolderLayout.remoteModuleID(of: path) == "web")
        }
    }

    /// A phone's settings-only archive, as the phone published one to a
    /// WebDAV server it alone used.
    private func phoneArchive(settings: String, fontSize: Double) throws -> (Data, LampSharedPreferenceLedger) {
        let ledger = LampSharedPreferenceLedger(fields: ["reader.fontSize": .init(value: .number(fontSize))])
        let archive = try LampSyncPreferenceState.replacing(
            ledger, in: LampSyncSettingsArchive.replacingData(Data(settings.utf8), in: nil)
        )
        return (try archive.compressedData(), ledger)
    }

    /// Everything a phone's archive holds sorts at or after `Settings/`, so
    /// judging an archive by a first entry before it never misjudges one.
    @Test func noPhoneArchivePathIsJudgedTheMacsByItsFirstEntry() {
        #expect(LampSyncSettingsStore.phoneArchivePaths.allSatisfy { !LampSyncSettingsStore.firstEntryIsTheMacs($0) })
        #expect(LampSyncSettingsStore.firstEntryIsTheMacs("Modules/kjv.lamp"))
        #expect(LampSyncSettingsStore.firstEntryIsTheMacs("Media/x.png"))
    }

    /// On WebDAV the phone left a settings-only archive. The migration
    /// replaces it with a bundle carrying its settings and preferences,
    /// written only while it is still that archive.
    @Test func aPhonesArchiveIsReplacedByABundleCarryingItsSettings() async throws {
        let store = BundleStore()
        let (archive, ledger) = try phoneArchive(settings: "phone settings", fontSize: 21)
        store.files[LampSyncSettingsStore.path] = (archive, "\"a1\"")
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"a1\"")) {
            try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate)
        }
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .phone)

        let moved = try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
        #expect(moved.bundle.userSettings == Data("phone settings".utf8))
        #expect(moved.bundle.preferences == ledger)
        #expect(store.conditions == [.ifRevision("\"a1\"")])
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == moved)
    }

    @Test func aMacsArchiveIsNeverReplacedByThePhone() async throws {
        let store = BundleStore()
        let mac = try LampSyncSettingsArchive.replacingData(Data("settings".utf8), in: nil)
            .replacingEntry(at: "Modules/kjv.lamp", with: Data("module".utf8))
            .replacingEntry(at: LampPortableBackupLayout.settingsPath, with: Data("plist".utf8))
        store.files[LampSyncSettingsStore.path] = (try mac.compressedData(), "\"a1\"")
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .mac)
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"a1\"")) {
            try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
        }
        #expect(store.writes == 0)
    }

    /// The Mac publishes its archive between the phone's judging and its
    /// write: the write is refused, and the phone judges again and stops.
    @Test func aPhonesArchiveThatTheMacReplacesIsLeftToTheMac() async throws {
        let store = BundleStore()
        store.files[LampSyncSettingsStore.path] = (try phoneArchive(settings: "phone", fontSize: 18).0, "\"a1\"")
        let mac = try LampSyncSettingsArchive.replacingData(Data("settings".utf8), in: nil)
            .replacingEntry(at: "Modules/kjv.lamp", with: Data("module".utf8))
        store.beforeNextWrite = {
            store.files[LampSyncSettingsStore.path] = (try mac.compressedData(), "\"mac\"")
        }
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: "\"mac\"")) {
            try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
        }
        #expect(store.writes == 0 && store.files[LampSyncSettingsStore.path]?.1 == "\"mac\"")
    }

    // MARK: - A server that lags after a write

    private let slow = LampSyncConditionalWrite.Patience(confirm: Array(repeating: .zero, count: 5), retry: [.zero])

    /// What failed the user's first move: the write lands, the server keeps
    /// showing the old bundle for a few reads, and the update must wait for
    /// it rather than retry into a refusal of its own write.
    @Test func anUpdateWaitsForALaggingServerRatherThanRetrying() async throws {
        let store = LaggingStore()
        store.files[LampSyncSettingsStore.path] = (try LampSyncSettingsBundle().encoded(), "\"1\"")
        store.lag = 3
        let written = try await LampSyncSettingsStore.update(in: store, patience: slow) {
            $0.userSettings = Data("phone".utf8)
        }
        #expect(written.bundle.userSettings == Data("phone".utf8))
        #expect(store.writes == 1)
        // While it still named the old revision, it asked by HEAD alone.
        #expect(store.bodyReads == 2)
    }

    @Test func aClaimWaitsForALaggingServer() async throws {
        let store = LaggingStore()
        store.lag = 2
        let claimed = try await LampSyncSettingsStore.readOrClaim(from: store, patience: slow)
        #expect(claimed.bundle == LampSyncSettingsBundle() && store.writes == 1)
    }

    /// A write the server never shows back in the time allowed is reported
    /// as taken, not refused, and the next read finds it.
    @Test func aWriteNotYetShownBackIsUnconfirmedNotRefused() async throws {
        let store = LaggingStore()
        store.files[LampSyncSettingsStore.path] = (try LampSyncSettingsBundle().encoded(), "\"1\"")
        store.lag = 100
        await #expect(throws: LampSyncConditionalWrite.Unconfirmed(path: LampSyncSettingsStore.path)) {
            try await LampSyncSettingsStore.update(in: store, patience: .immediate) { $0.userSettings = Data("phone".utf8) }
        }
        #expect(store.writes == 1)
        store.settle()
        #expect(try await LampSyncSettingsStore.read(from: store)?.bundle.userSettings == Data("phone".utf8))
    }

    /// A read just after a write, by any device, meets Apache's weak tag
    /// and waits it out, instead of calling the server unversioned.
    @Test func aReadJustAfterAWriteWaitsOutTheWeakTag() async throws {
        let store = LaggingStore()
        store.files[LampSyncSettingsStore.path] = (try LampSyncSettingsBundle().encoded(), "\"6946-65e4a2c28c82f\"")
        store.justWritten(LampSyncSettingsStore.path, reads: 2)
        let read = try #require(try await LampSyncSettingsStore.read(from: store, patience: slow))
        #expect(read.revision == "\"6946-65e4a2c28c82f\"")

        store.justWritten(LampSyncSettingsStore.path, reads: 2)
        await #expect(throws: LampSyncSettingsStore.StoreError.unversioned) {
            try await LampSyncSettingsStore.read(from: store, patience: .immediate)
        }
    }

    /// The same weak second after this device's own write: the read-back
    /// and the next update's read wait it out, and nothing is refused.
    @Test func anUpdateRightAfterAWriteWaitsOutTheWeakTag() async throws {
        let store = LaggingStore()
        store.files[LampSyncSettingsStore.path] = (try LampSyncSettingsBundle().encoded(), "\"1\"")
        store.weakFor = 2
        let first = try await LampSyncSettingsStore.update(in: store, patience: slow) {
            $0.userSettings = Data("one".utf8)
        }
        let second = try await LampSyncSettingsStore.update(in: store, patience: slow) {
            $0.userSettings = Data("two".utf8)
        }
        #expect(first.bundle.userSettings == Data("one".utf8) && second.bundle.userSettings == Data("two".utf8))
        #expect(store.writes == 2)
    }

    /// Two devices starting the same library: the one whose claim is refused
    /// reads the other's bundle rather than failing or writing over it.
    @Test func aRefusedClaimReadsTheWinnersBundle() async throws {
        let store = BundleStore()
        let theirs = LampSyncSettingsBundle(userSettings: Data("theirs".utf8))
        store.beforeNextWrite = {
            store.files[LampSyncSettingsStore.path] = (try theirs.encoded(), "\"theirs\"")
        }
        let claimed = try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate)
        #expect(claimed == LampSyncSettingsStore.Snapshot(bundle: theirs, revision: "\"theirs\""))
        #expect(store.conditions == [.ifAbsent] && store.writes == 0)
    }

    /// The change runs again against the newer bundle, so another device's
    /// edit survives the retry.
    @Test func aRefusedUpdateMergesIntoTheNewerBundle() async throws {
        let store = BundleStore()
        try await LampSyncSettingsStore.update(in: store, patience: .immediate) { $0.userSettings = Data("phone".utf8) }
        store.beforeNextWrite = {
            var newer = try LampSyncSettingsBundle.decode(store.files[LampSyncSettingsStore.path]!.0)
            newer.macSettings = Data("mac".utf8)
            store.files[LampSyncSettingsStore.path] = (try newer.encoded(), "\"mac\"")
        }
        var runs = 0
        let written = try await LampSyncSettingsStore.update(in: store, patience: .immediate) { bundle in
            runs += 1
            bundle.manifest = try bundle.manifest.recordingWrite(
                "Notes/notes.lamp", revision: "\"1\"", replacing: nil, at: 1
            )
        }
        #expect(runs == 2)
        #expect(written.bundle.macSettings == Data("mac".utf8))
        #expect(written.bundle.userSettings == Data("phone".utf8))
        #expect(written.bundle.manifest.members.map(\.path) == ["Notes/notes.lamp"])
    }

    @Test func anErrorFromTheChangeLeavesUnchanged() async throws {
        struct Stop: Error {}
        let store = BundleStore()
        await #expect(throws: Stop.self) {
            try await LampSyncSettingsStore.update(in: store, patience: .immediate) { _ in throw Stop() }
        }
        #expect(store.writes == 0)
    }

    @Test func anAppsOwnErrorCanStandForARefusal() {
        enum AppError: LampSyncRefusal {
            case preconditionFailed, offline
            var isRefusal: Bool { self == .preconditionFailed }
        }
        #expect(LampSyncConditionalWrite.isRefusal(AppError.preconditionFailed))
        #expect(!LampSyncConditionalWrite.isRefusal(AppError.offline))
        #expect(!LampSyncConditionalWrite.isRefusal(URLError(.notConnectedToInternet)))
    }

    @Test func aStoreThatCannotDeleteSaysSo() async {
        await #expect(throws: LampSyncRemoteStoreError.deleteUnsupported) {
            try await BundleStore().delete(path: "Notes/notes.lamp", condition: .ifRevision("\"1\""))
        }
    }
}

/// The deck folder as a server lists it: a deck beside the old ledger file.
private struct DeckFolderStore: LampSyncRemoteStore {
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        guard directory == "Workspaces/Presentations/" else { return nil }
        return [("d.lampdeck", "\"2\""), ("deleted-decks.json", "\"1\"")].map {
            LampSyncRemoteEntry(path: "/dav/\(directory)\($0.0)", name: $0.0, isDirectory: false,
                                revision: $0.1, modifiedAt: nil, size: nil)
        }
    }

    func read(path: String) async throws -> LampSyncRemoteFile? { nil }
    func revision(path: String) async throws -> String? { nil }
    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? { nil }
}

/// One file per path, with conditional writes enforced as a server would.
private final class BundleStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: (Data, String)] = [:]
    var beforeNextWrite: (() throws -> Void)?
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var conditions: [LampSyncWriteCondition] = []
    private var counter = 0

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        reads += 1
        return files[path].map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
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
            // What a WebDAV store throws for a 412.
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

/// A server like the user's Synology after a PUT: it takes the write at once
/// and names no revision, and the next `lag` reads of the path, HEADs
/// included, still answer with what was there before. After those, the next
/// `weakFor` answer with the new body under a weak tag, as Apache does for
/// the second after a file changes.
private final class LaggingStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: (Data, String)] = [:]
    var lag = 0
    var weakFor = 0
    private var before: [String: (Data, String)] = [:]
    private var remaining: [String: Int] = [:]
    private var weakRemaining: [String: Int] = [:]
    private(set) var writes = 0
    private(set) var bodyReads = 0
    private var counter = 0

    func settle() {
        remaining = [:]
        weakRemaining = [:]
    }

    /// The file as stored, still within its weak second.
    func justWritten(_ path: String, reads: Int) { weakRemaining[path] = reads }

    private func visible(_ path: String) -> (Data, String)? {
        if let left = remaining[path], left > 0 {
            remaining[path] = left - 1
            return before[path]
        }
        if let left = weakRemaining[path], left > 0, let file = files[path] {
            weakRemaining[path] = left - 1
            return (file.0, "W/" + file.1)
        }
        return files[path]
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        bodyReads += 1
        return visible(path).map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
    }

    func revision(path: String) async throws -> String? { visible(path)?.1 }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        switch condition {
        case .ifAbsent where files[path] != nil:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        case .ifRevision(let revision) where files[path]?.1 != revision:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        before[path] = files[path]
        remaining[path] = lag
        weakRemaining[path] = weakFor
        counter += 1
        files[path] = (data, "\"w\(counter)\"")
        writes += 1
        return nil
    }
}

