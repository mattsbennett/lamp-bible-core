import Foundation
import Testing
@testable import LampModuleKit

/// The small object that says what the archive holds, so a client can tell
/// what changed without fetching a library to find out.
struct LampSyncArchiveIndexTests {
    private func archive(_ entries: [(String, String)]) -> LampSyncArchive {
        LampSyncArchive(entries: entries.map { path, body in
            LampSyncArchive.Entry(
                path: path,
                data: Data(body.utf8),
                modifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        })
    }

    @Test func itDescribesEveryEntryByDigest() {
        let index = LampSyncArchiveIndex(
            describing: archive([("Modules/a.lamp", "alpha"), ("Modules/b.lamp", "beta")]),
            at: "\"r1\""
        )

        #expect(index.archiveRevision == "\"r1\"")
        #expect(index.digest(forEntryAt: "Modules/a.lamp")
            == LampSyncContentRevision.digest(for: Data("alpha".utf8)))
        #expect(index.digest(forEntryAt: "Modules/missing.lamp") == nil)
    }

    /// The entry carries its own digest when the archive was built with one;
    /// the index must use it rather than recomputing something different.
    @Test func itPrefersTheDigestTheEntryAlreadyCarries() {
        let entry = LampSyncArchive.Entry(
            path: "Modules/a.lamp",
            data: Data("alpha".utf8),
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            sha256: "recorded-digest"
        )
        let index = LampSyncArchiveIndex(
            describing: LampSyncArchive(entries: [entry]), at: "\"r1\""
        )

        #expect(index.digest(forEntryAt: "Modules/a.lamp") == "recorded-digest")
    }

    // MARK: - The fingerprint a module import compares

    @Test func contentChangesMoveTheFingerprint() {
        let before = LampSyncArchiveIndex(
            describing: archive([("Modules/a.lamp", "alpha")]), at: "\"r1\""
        )
        let edited = LampSyncArchiveIndex(
            describing: archive([("Modules/a.lamp", "altered")]), at: "\"r2\""
        )
        let added = LampSyncArchiveIndex(
            describing: archive([("Modules/a.lamp", "alpha"), ("Modules/b.lamp", "beta")]),
            at: "\"r3\""
        )
        let removed = LampSyncArchiveIndex(describing: archive([]), at: "\"r4\"")

        #expect(edited.importableFingerprint != before.importableFingerprint)
        #expect(added.importableFingerprint != before.importableFingerprint)
        #expect(removed.importableFingerprint != before.importableFingerprint)
    }

    /// The whole point: a settings edit on one device must not make every
    /// other device fetch a library whose content has not moved.
    @Test func settingsChangesLeaveTheFingerprintAlone() {
        let before = LampSyncArchiveIndex(
            describing: archive([
                ("Modules/a.lamp", "alpha"),
                (LampSyncLayout.userSettingsPath, "settings one"),
                (LampPortableBackupLayout.sharedPreferencesPath, "prefs one"),
                (LampSyncSettingsArchive.legacyManifestPath, "manifest one"),
            ]),
            at: "\"r1\""
        )
        let after = LampSyncArchiveIndex(
            describing: archive([
                ("Modules/a.lamp", "alpha"),
                (LampSyncLayout.userSettingsPath, "settings two"),
                (LampPortableBackupLayout.sharedPreferencesPath, "prefs two"),
                (LampSyncSettingsArchive.legacyManifestPath, "manifest two"),
            ]),
            at: "\"r2\""
        )

        #expect(after.importableFingerprint == before.importableFingerprint)
    }

    /// Two archives holding the same content in a different order are the
    /// same library, and must not look like a change.
    @Test func entryOrderDoesNotMoveTheFingerprint() {
        let one = LampSyncArchiveIndex(
            describing: archive([("Modules/a.lamp", "alpha"), ("Modules/b.lamp", "beta")]),
            at: "\"r1\""
        )
        let other = LampSyncArchiveIndex(
            describing: archive([("Modules/b.lamp", "beta"), ("Modules/a.lamp", "alpha")]),
            at: "\"r1\""
        )

        #expect(one.importableFingerprint == other.importableFingerprint)
    }

    /// A path and a digest swapping places must not collide into the same
    /// fingerprint, which is why they are joined by a separator that cannot
    /// occur in either.
    @Test func aPathCannotBeConfusedWithADigest() {
        let one = LampSyncArchiveIndex(
            archiveRevision: "\"r1\"", digests: ["Modules/a": "b"]
        )
        let other = LampSyncArchiveIndex(
            archiveRevision: "\"r1\"", digests: ["Modules/a\u{0}b": ""]
        )

        #expect(one.importableFingerprint != other.importableFingerprint)
    }

    // MARK: - Reading it back

    @Test func anIndexForTheCurrentRevisionIsUsed() async throws {
        let store = IndexStore(archiveRevision: "\"r1\"")
        try await LampSyncArchiveIndex.publish(
            describing: archive([("Modules/a.lamp", "alpha")]),
            at: "\"r1\"",
            in: store
        )

        let index = await LampSyncArchiveIndex.current(in: store)

        #expect(index?.archiveRevision == "\"r1\"")
    }

    /// An index describing a body the server has since replaced is worthless,
    /// and must read as absent rather than as reassurance.
    @Test func anIndexForAnOlderRevisionIsIgnored() async throws {
        let store = IndexStore(archiveRevision: "\"r1\"")
        try await LampSyncArchiveIndex.publish(
            describing: archive([("Modules/a.lamp", "alpha")]),
            at: "\"r1\"",
            in: store
        )
        await store.setArchiveRevision("\"r2\"")

        #expect(await LampSyncArchiveIndex.current(in: store) == nil)
    }

    @Test func noIndexAtAllReadsAsAbsent() async {
        let store = IndexStore(archiveRevision: "\"r1\"")

        #expect(await LampSyncArchiveIndex.current(in: store) == nil)
    }

    /// A weak revision cannot stand for a body, so an index keyed to one is
    /// not trusted even if it matches.
    @Test func aWeakArchiveRevisionIsNotTrusted() async throws {
        let store = IndexStore(archiveRevision: "W/\"r1\"")
        try await LampSyncArchiveIndex.publish(
            describing: archive([("Modules/a.lamp", "alpha")]),
            at: "W/\"r1\"",
            in: store
        )

        #expect(await LampSyncArchiveIndex.current(in: store) == nil)
    }

    /// An index written by a newer client, in a shape this one does not know,
    /// is ignored rather than misread.
    @Test func anUnsupportedFormatVersionIsIgnored() async throws {
        let store = IndexStore(archiveRevision: "\"r1\"")
        let future = LampSyncArchiveIndex(
            formatVersion: LampSyncArchiveIndex.currentFormatVersion + 1,
            archiveRevision: "\"r1\"",
            digests: [:]
        )
        _ = try await store.write(
            try JSONEncoder().encode(future),
            to: LampSyncLayout.archiveIndexPath,
            condition: .unconditional
        )

        #expect(await LampSyncArchiveIndex.current(in: store) == nil)
    }

    @Test func rubbishWhereTheIndexShouldBeIsIgnored() async throws {
        let store = IndexStore(archiveRevision: "\"r1\"")
        _ = try await store.write(
            Data([0x00, 0x01, 0x02]),
            to: LampSyncLayout.archiveIndexPath,
            condition: .unconditional
        )

        #expect(await LampSyncArchiveIndex.current(in: store) == nil)
    }
}

/// A store that reports an archive revision and keeps whatever is written.
private actor IndexStore: LampSyncRemoteStore {
    private var archiveRevision: String
    private var files: [String: Data] = [:]

    init(archiveRevision: String) {
        self.archiveRevision = archiveRevision
    }

    func setArchiveRevision(_ revision: String) { archiveRevision = revision }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }

    func revision(path: String) async throws -> String? {
        path == LampSyncLayout.archivePath ? archiveRevision : nil
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        guard let data = files[path] else { return nil }
        return LampSyncRemoteFile(data: data, revision: "\"\(path)\"")
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        files[path] = data
        return "\"\(path)\""
    }
}
