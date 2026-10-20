import Foundation
import Testing
@testable import LampModuleKit

/// The folder provider's store, against a real folder. iCloud's eviction is
/// played by a `.name.icloud` placeholder, and its download by the
/// `startDownloading` seam putting the file back.
struct LampSyncDirectoryStoreTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-directory-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func put(_ text: String, at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func contents(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func revision(of text: String) -> String {
        LampSyncDirectoryStore.revision(forDigest: LampSyncContentRevision.digest(for: Data(text.utf8)))
    }

    /// Evicts a file: iCloud leaves `.name.icloud` in its place.
    private func evict(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.moveItem(at: url, to: LampSyncDirectoryStore.placeholder(for: url))
    }

    /// A store whose download request brings an evicted file back.
    private func store(
        timeout: Duration = .seconds(5), versions: StagedVersions? = nil
    ) -> LampSyncDirectoryStore {
        LampSyncDirectoryStore(
            root: root, downloadTimeout: timeout, conflictVersions: versions?.seam ?? .iCloud
        ) { url in
            let placeholder = LampSyncDirectoryStore.placeholder(for: url)
            if FileManager.default.fileExists(atPath: placeholder.path) {
                try FileManager.default.moveItem(at: placeholder, to: url)
            }
        }
    }

    @Test func aListingNamesEvictedFilesAndCarriesNoRevisions() async throws {
        try put("kjv", at: "Translations/kjv.lamp")
        try put("web", at: "Translations/web.lamp")
        try evict("Translations/web.lamp")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Translations/nested"), withIntermediateDirectories: true
        )
        let listed = try #require(try await store().list(directory: "Translations/"))
        #expect(listed.map(\.name) == ["kjv.lamp", "nested", "web.lamp"])
        #expect(listed.map(\.path) == ["Translations/kjv.lamp", "Translations/nested", "Translations/web.lamp"])
        #expect(listed.map(\.isDirectory) == [false, true, false])
        #expect(listed.allSatisfy { $0.revision == nil })
        #expect(try await store().list(directory: "Notes/") == nil)
    }

    @Test func aReadNamesTheRevisionOfTheBytesItCopied() async throws {
        try put("notes", at: "Notes/notes.lamp")
        let file = try #require(try await store().read(path: "Notes/notes.lamp"))
        #expect(file.data == Data("notes".utf8))
        #expect(file.revision == revision(of: "notes"))
        #expect(try await store().revision(path: "Notes/notes.lamp") == revision(of: "notes"))
        #expect(try await store().read(path: "Notes/missing.lamp") == nil)
        #expect(try await store().revision(path: "Notes/missing.lamp") == nil)
    }

    @Test func anEvictedFileIsDownloadedBeforeItIsRead() async throws {
        try put("web", at: "Translations/web.lamp")
        try evict("Translations/web.lamp")
        let file = try #require(try await store().read(path: "Translations/web.lamp"))
        #expect(file.data == Data("web".utf8))
    }

    /// A file that never arrives is an error, never "absent", or the plan
    /// would upload over it.
    @Test func anEvictedFileThatNeverArrivesIsAnError() async throws {
        try put("web", at: "Translations/web.lamp")
        try evict("Translations/web.lamp")
        let stalled = LampSyncDirectoryStore(root: root, downloadTimeout: .milliseconds(10)) { _ in }
        await #expect(throws: LampSyncDirectoryStore.StoreError.unreadable("Translations/web.lamp")) {
            try await stalled.read(path: "Translations/web.lamp")
        }
    }

    @Test func writesHoldTheirConditions() async throws {
        let store = store()
        let first = try await store.write(Data("one".utf8), to: "Notes/notes.lamp", condition: .ifAbsent)
        #expect(first == revision(of: "one"))
        await #expect(throws: LampSyncConditionalWrite.WriteError.conflict) {
            try await store.write(Data("again".utf8), to: "Notes/notes.lamp", condition: .ifAbsent)
        }
        await #expect(throws: LampSyncConditionalWrite.WriteError.conflict) {
            try await store.write(Data("two".utf8), to: "Notes/notes.lamp", condition: .ifRevision(revision(of: "other")))
        }
        #expect(contents("Notes/notes.lamp") == "one")
        let second = try await store.write(Data("two".utf8), to: "Notes/notes.lamp", condition: .ifRevision(first!))
        #expect(second == revision(of: "two") && contents("Notes/notes.lamp") == "two")
    }

    @Test func aFileIsWrittenFromDisk() async throws {
        let source = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("from disk".utf8).write(to: source)
        let written = try await store().write(fileAt: source, to: "BookMedia/b/images/a.png", condition: .ifAbsent)
        #expect(written == revision(of: "from disk") && contents("BookMedia/b/images/a.png") == "from disk")
    }

    /// An evicted file is still there: creating one where it stands is
    /// refused, and replacing it is checked against the downloaded bytes.
    @Test func anEvictedFileIsNeverWrittenOverBlindly() async throws {
        try put("web", at: "Translations/web.lamp")
        try evict("Translations/web.lamp")
        await #expect(throws: LampSyncConditionalWrite.WriteError.conflict) {
            try await store().write(Data("mine".utf8), to: "Translations/web.lamp", condition: .ifAbsent)
        }
        let replaced = try await store().write(
            Data("mine".utf8), to: "Translations/web.lamp", condition: .ifRevision(revision(of: "web"))
        )
        #expect(replaced == revision(of: "mine") && contents("Translations/web.lamp") == "mine")
    }

    @Test func aDeleteRemovesOnlyTheCopyItWasAskedTo() async throws {
        try put("one", at: "Notes/notes.lamp")
        let store = store()
        await #expect(throws: LampSyncConditionalWrite.WriteError.conflict) {
            try await store.delete(path: "Notes/notes.lamp", condition: .ifRevision(revision(of: "other")))
        }
        #expect(contents("Notes/notes.lamp") == "one")
        try await store.delete(path: "Notes/notes.lamp", condition: .ifRevision(revision(of: "one")))
        #expect(contents("Notes/notes.lamp") == nil)
        // Already gone counts as done.
        try await store.delete(path: "Notes/notes.lamp", condition: .ifRevision(revision(of: "one")))
    }

    @Test func linksAndEscapesAreRefused() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Notes"), withDestinationURL: outside)
        await #expect(throws: LampSyncDirectoryStore.StoreError.unsafePath("Notes/notes.lamp")) {
            try await store().write(Data("x".utf8), to: "Notes/notes.lamp", condition: .ifAbsent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        await #expect(throws: LampSyncDirectoryStore.StoreError.unsafePath("../x.lamp")) {
            try await store().read(path: "../x.lamp")
        }
    }

    /// The whole pass's first step on the folder provider: an unchanged
    /// library is listed without reading one file.
    @Test func aPlanOverTheFolderReadsNothingForRecordedMembers() async throws {
        try put("kjv", at: "Translations/kjv.lamp")
        try evict("Translations/kjv.lamp")
        let manifest = try LampSyncLibraryManifest()
            .recordingWrite("Translations/kjv.lamp", revision: revision(of: "kjv"), replacing: nil, at: 1)
        let untouched = LampSyncDirectoryStore(root: root) { _ in
            Issue.record("A recorded member was downloaded just to be compared")
        }
        let listing = try await LampSyncFilePlan.listing(in: untouched, manifest: manifest)
        #expect(listing == ["Translations/kjv.lamp": revision(of: "kjv")])
    }

    // MARK: - Conflict versions

    /// Two copies another device wrote, staged as iCloud would keep them.
    private func stageVersions(_ texts: [String], of path: String) throws -> StagedVersions {
        let staged = StagedVersions()
        let side = root.deletingLastPathComponent().appendingPathComponent("versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        for (index, text) in texts.enumerated() {
            let url = side.appendingPathComponent("\(index)")
            try Data(text.utf8).write(to: url)
            staged.add(url, to: root.appendingPathComponent(path))
        }
        return staged
    }

    @Test func aReadWithVersionsCopiesOutEachOne() async throws {
        try put("current", at: "lamp-bible.lampsync")
        let staged = try stageVersions(["mine", "theirs"], of: "lamp-bible.lampsync")
        let store = store(versions: staged)
        #expect(try await store.hasVersions(path: "lamp-bible.lampsync"))
        await #expect(throws: LampSyncDirectoryStore.StoreError.unresolvedVersions("lamp-bible.lampsync")) {
            try await store.read(path: "lamp-bible.lampsync")
        }
        let destination = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: destination) }
        let (current, versions) = try await store.readWithVersions(path: "lamp-bible.lampsync", into: destination)
        defer { for version in versions { try? FileManager.default.removeItem(at: version.url) } }
        #expect(current?.revision == revision(of: "current"))
        #expect(versions.compactMap(\.revision).sorted() == [revision(of: "mine"), revision(of: "theirs")].sorted())
        #expect(try versions.map { String(decoding: try Data(contentsOf: $0.url), as: UTF8.self) }.sorted()
            == ["mine", "theirs"])
        #expect(try await store.readWithVersions(path: "missing", into: destination).current == nil)
    }

    @Test func aResolvingWriteResolvesOnlyTheVersionsNamed() async throws {
        try put("current", at: "lamp-bible.lampsync")
        let staged = try stageVersions(["mine", "theirs"], of: "lamp-bible.lampsync")
        let store = store(versions: staged)
        await #expect(throws: LampSyncConditionalWrite.WriteError.conflict) {
            try await store.resolveVersions(
                of: "lamp-bible.lampsync", writing: Data("merged".utf8),
                ifRevision: revision(of: "other"), resolving: [revision(of: "mine")]
            )
        }
        #expect(contents("lamp-bible.lampsync") == "current" && staged.count == 2)
        let written = try await store.resolveVersions(
            of: "lamp-bible.lampsync", writing: Data("merged".utf8),
            ifRevision: revision(of: "current"), resolving: [revision(of: "mine")]
        )
        #expect(written == revision(of: "merged") && contents("lamp-bible.lampsync") == "merged")
        // One that arrived after the read, or wasn't merged, stays.
        #expect(staged.count == 1)
        #expect(try await store.hasVersions(path: "lamp-bible.lampsync"))
    }

    @Test func anUpdateFoldsInVersionsAndResolvesThem() async throws {
        let path = LampSyncSettingsStore.path
        func bundle(_ module: String) throws -> Data {
            try LampSyncSettingsBundle(
                manifest: try LampSyncLibraryManifest().recordingWrite(
                    "Notes/\(module).lamp", revision: "\"\(module)\"", replacing: nil, at: 1
                )
            ).encoded()
        }
        try bundle("current").write(to: root.appendingPathComponent(path))
        let staged = StagedVersions()
        let side = root.deletingLastPathComponent().appendingPathComponent("versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try bundle("lost").write(to: side.appendingPathComponent("lost"))
        staged.add(side.appendingPathComponent("lost"), to: root.appendingPathComponent(path))
        let store = store(versions: staged)

        let read = try #require(try await LampSyncSettingsStore.read(from: store))
        #expect(read.versions.map { $0.bundle.manifest.paths } == [["Notes/lost.lamp"]])
        #expect(try await LampSyncSettingsStore.hasChanged(since: read.revision, in: store))

        // With nothing to merge them, versions stop the update untouched.
        await #expect(throws: LampSyncSettingsStore.StoreError.versionsNeedAMerge) {
            try await LampSyncSettingsStore.update(in: store, patience: .immediate) { _ in }
        }
        #expect(staged.count == 1)

        // An update that changes nothing still writes, to resolve them.
        let written = try await LampSyncSettingsStore.update(
            in: store, patience: .immediate, mergingVersion: { $0.manifest = $0.manifest.merged(with: $1.bundle.manifest) }
        ) { _ in }
        #expect(written.bundle.manifest.paths == ["Notes/current.lamp", "Notes/lost.lamp"])
        #expect(staged.count == 0 && written.versions.isEmpty)
        #expect(try await LampSyncSettingsStore.hasChanged(since: written.revision, in: store) == false)
    }

    /// An archive or damage beside the bundle is another device's write that
    /// can't be merged, so it stops the update rather than being dropped.
    @Test func aVersionThatIsNotABundleStopsTheUpdate() async throws {
        let path = LampSyncSettingsStore.path
        try LampSyncSettingsBundle().encoded().write(to: root.appendingPathComponent(path))
        let staged = try stageVersions(["not a bundle"], of: path)
        let store = store(versions: staged)
        await #expect(throws: LampSyncSettingsStore.StoreError.unreadableVersion(revision(of: "not a bundle"))) {
            try await LampSyncSettingsStore.update(in: store, patience: .immediate, mergingVersion: { _, _ in }) { _ in }
        }
        #expect(staged.count == 1)
    }

    /// The pass a new library's first device runs: claim the path, then
    /// write files, then record them. Writing files first would make the
    /// closing update find them and call the library an earlier one.
    @Test func aFreshLibraryIsClaimedBeforeItsFiles() async throws {
        let store = store()
        let claimed = try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate)
        #expect(claimed.bundle == LampSyncSettingsBundle())
        let revision = try #require(
            try await store.write(Data("notes".utf8), to: "Notes/notes.lamp", condition: .ifAbsent)
        )
        let recorded = try await LampSyncSettingsStore.update(in: store, patience: .immediate) {
            $0.manifest = try $0.manifest.recordingWrite("Notes/notes.lamp", revision: revision, replacing: nil, at: 1)
        }
        #expect(recorded.bundle.manifest.members.map(\.path) == ["Notes/notes.lamp"])
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == recorded)
    }

    /// A library only the phone kept: an ordinary pass leaves it alone, the
    /// migration claims it, and the next pass adopts its files as they are.
    @Test func aPhoneLibraryIsMigratedByClaimingItsPath() async throws {
        try put("notes", at: "Notes/notes.lamp")
        try put("settings", at: LampSyncLayout.userSettingsPath)
        let store = store()
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: nil)) {
            try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate)
        }
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .phone)

        let claimed = try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
        #expect(claimed.bundle == LampSyncSettingsBundle())
        #expect(try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate) == claimed)
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == claimed)

        let listing = try await LampSyncFilePlan.listing(in: store, manifest: claimed.bundle.manifest)
        let plan = LampSyncFilePlan.plan(
            manifest: claimed.bundle.manifest, local: [], deletedLocally: [:], listing: listing
        )
        #expect(plan.adopt == ["Notes/notes.lamp": revision(of: "notes")])
        #expect(plan.downloads == ["Notes/notes.lamp"])
    }

    /// The Mac's folder is the Mac's to migrate, whatever else is in it.
    @Test func aMacLibraryIsNeverClaimedByThePhone() async throws {
        try put("{}", at: LampSyncFolderPublisher.snapshotPath)
        try put("settings", at: LampSyncLayout.userSettingsPath)
        try put("notes", at: "Notes/notes.lamp")
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store()) == .mac)
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: nil)) {
            try await LampSyncSettingsStore.migratePhoneLibrary(in: store(), patience: .immediate)
        }
        #expect(contents(LampSyncSettingsStore.path) == nil)
    }

    /// A pass never lists the old notes alias, so it is never adopted.
    @Test func theRetiredNotesAliasIsNeverListed() async throws {
        try put("old notes", at: "Notes/bible-notes.lamp")
        try put("notes", at: "Notes/notes.lamp")
        let listing = try await LampSyncFilePlan.listing(in: store(), manifest: LampSyncLibraryManifest())
        #expect(listing == ["Notes/notes.lamp": revision(of: "notes")])
    }

    @Test func nothingAtTheBundlePathIsNewOnlyInAnEmptyLibrary() async throws {
        #expect(try await LampSyncSettingsStore.read(from: store()) == nil)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Translations"), withIntermediateDirectories: true
        )
        try put("", at: "Translations/.DS_Store")
        #expect(try await LampSyncSettingsStore.read(from: store()) == nil)
        try put("web", at: "Translations/web.lamp")
        try evict("Translations/web.lamp")
        await #expect(throws: LampSyncSettingsStore.StoreError.notMigrated(revision: nil)) {
            try await LampSyncSettingsStore.update(in: store(), patience: .immediate) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(LampSyncSettingsStore.path).path))
    }
}

/// Conflict versions staged for a plain folder, resolved as iCloud would
/// resolve them.
final class StagedVersions: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [URL: [URL]] = [:]

    func add(_ version: URL, to file: URL) {
        lock.withLock { versions[file.standardizedFileURL, default: []].append(version) }
    }

    var count: Int { lock.withLock { versions.values.map(\.count).reduce(0, +) } }

    var seam: LampSyncDirectoryStore.ConflictVersions {
        .init(
            unresolved: { [self] file in lock.withLock { versions[file.standardizedFileURL] ?? [] } },
            resolve: { [self] file, resolved in
                lock.withLock { versions[file.standardizedFileURL]?.removeAll { resolved.contains($0) } }
            }
        )
    }
}
