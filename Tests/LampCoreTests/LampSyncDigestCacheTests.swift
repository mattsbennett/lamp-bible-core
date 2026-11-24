import Foundation
import LampModuleKit
import Testing

/// `Documentation/decisions/0007`: a pass may trust a file's identity for its
/// digest, where the filesystem maintains one.
///
/// 0001 refused a modification date for a reason that still holds, so most of
/// these are attempts to slip a changed file past the cache: rewritten in
/// place with the date put back, replaced wholesale, truncated. The rest hold
/// the three bounds — the filesystem, the kind, and that a pass with no cache
/// reads everything.
struct LampSyncDigestCacheTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-digest-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func candidate(_ url: URL, kind: LampSyncFileKind) -> LampSyncLocalFiles.Candidate {
        LampSyncLocalFiles.Candidate(path: "Translations/x.lamp", kind: kind, url: url)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func readsOnceAndThenAnswersFromWhatItRead() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the first body", to: file)
        let cache = LampSyncDigestCache()
        let one = [candidate(file, kind: .module(.translations))]

        let first = LampSyncLocalFiles.describe(one, digests: cache)
        let second = LampSyncLocalFiles.describe(one, digests: cache)

        #expect(first.files.map(\.digest) == second.files.map(\.digest))
        let counts = cache.counts()
        #expect(counts.answered == 1)
        #expect(counts.read == 1)
    }

    /// The case 0001 was right about, and the reason the key is the whole
    /// identity rather than a date: same size, same modification time, bytes
    /// changed, inode unmoved. `st_ctime` is what catches it.
    @Test func noticesARewriteInPlaceWithTheDatePutBack() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the first body", to: file)
        let cache = LampSyncDigestCache()
        let one = [candidate(file, kind: .module(.translations))]
        let before = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest
        let was = try #require(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        // In place, so the inode does not move; the same length, so the size
        // cannot give it away; and the date put back afterwards.
        try write("the second body", to: file)
        try FileManager.default.setAttributes([.modificationDate: was], ofItemAtPath: file.path)

        let after = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest
        #expect(after != before)
        #expect(cache.counts().read == 2)
    }

    @Test func noticesAReplacementAndATruncation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the first body", to: file)
        let cache = LampSyncDigestCache()
        let one = [candidate(file, kind: .module(.translations))]
        let first = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest

        // Replaced atomically, as an install does: a new inode.
        try Data("a replacement".utf8).write(to: file, options: [.atomic])
        let second = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest
        #expect(second != first)

        try FileHandle(forWritingTo: file).truncate(atOffset: 4)
        let third = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest
        #expect(third != second)
    }

    /// Identical bytes are identical bytes: a file rewritten with the same
    /// content gets a new identity, is read again, and yields the digest it
    /// had — so nothing is uploaded.
    @Test func thesameBytesWrittenAgainAreTheSameDigest() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the body", to: file)
        let cache = LampSyncDigestCache()
        let one = [candidate(file, kind: .module(.translations))]
        let before = LampSyncLocalFiles.describe(one, digests: cache).files[0].digest

        try Data("the body".utf8).write(to: file, options: [.atomic])

        #expect(LampSyncLocalFiles.describe(one, digests: cache).files[0].digest == before)
        #expect(cache.counts().read == 2)
    }

    /// The kinds that are small and mutable are read every pass, cache or no.
    @Test func onlyTheKindsWorthItAreKept() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = root.appendingPathComponent("a.lampdeck")
        try write("{}", to: deck)
        let cache = LampSyncDigestCache()
        let one = [candidate(deck, kind: .deck)]

        _ = LampSyncLocalFiles.describe(one, digests: cache)
        _ = LampSyncLocalFiles.describe(one, digests: cache)

        let counts = cache.counts()
        #expect(counts.answered == 0)
        #expect(counts.read == 0)
        #expect(LampSyncFileKind.deck.keepsDigestAgainstIdentity == false)
        #expect(LampSyncFileKind.module(.translations).keepsDigestAgainstIdentity)
        #expect(LampSyncFileKind.bookMedia.keepsDigestAgainstIdentity)
    }

    /// No cache is the behaviour 0001 required, and it is what a pass gets on
    /// any filesystem this code does not vouch for.
    @Test func withoutACacheEveryFileIsRead() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the body", to: file)
        let one = [candidate(file, kind: .module(.translations))]

        let first = LampSyncLocalFiles.describe(one)
        let second = LampSyncLocalFiles.describe(one)
        #expect(first.files.map(\.digest) == second.files.map(\.digest))
    }

    @Test func trustsOnlyTheFilesystemsThatMaintainAnIdentity() {
        #expect(LampSyncIdentityTrust.trustsIdentity(filesystemNamed: "apfs"))
        #expect(LampSyncIdentityTrust.trustsIdentity(filesystemNamed: "APFS"))
        #expect(LampSyncIdentityTrust.trustsIdentity(filesystemNamed: "hfs"))
        for share in ["smbfs", "nfs", "exfat", "msdos", "ntfs", "webdav", "osxfuse", "lifs"] {
            #expect(
                LampSyncIdentityTrust.trustsIdentity(filesystemNamed: share) == false,
                "\(share) does not keep an identity this code can trust"
            )
        }
        // Nothing to ask is nothing to trust.
        #expect(LampSyncIdentityTrust.trustsIdentity(filesystemNamed: nil) == false)
        // And this machine's own temporary directory is one of the two.
        #expect(LampSyncIdentityTrust.filesystemName(
            ofVolumeAt: FileManager.default.temporaryDirectory
        ) == "apfs")
    }

    @Test func aFileThatIsGoneIsUnreadableRatherThanRemembered() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try write("the body", to: file)
        let cache = LampSyncDigestCache()
        let one = [candidate(file, kind: .module(.translations))]
        _ = LampSyncLocalFiles.describe(one, digests: cache)

        try FileManager.default.removeItem(at: file)
        let described = LampSyncLocalFiles.describe(one, digests: cache)

        #expect(described.files.isEmpty)
        #expect(described.unreadable.map(\.path) == ["Translations/x.lamp"])
    }
}
