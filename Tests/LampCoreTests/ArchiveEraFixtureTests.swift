import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

/// The move, held to bytes the archive-era writers wrote.
struct ArchiveEraFixtureTests {
    @Test func aMacArchiveIsReadJudgedAndCarried() throws {
        let archive = try LampSyncArchive.decode(compressedData: ArchiveEraFixtures.macArchive)
        #expect(LampSyncSettingsStore.earlierLibrary(ofArchive: archive) == .mac)
        #expect(LampSyncLibraryMigration.unplaceableEntries(in: archive).isEmpty)
        #expect(LampSyncSettingsStore.verdict(fromStart: ArchiveEraFixtures.macArchive) == .mac)
        let bundle = try LampSyncLibraryMigration.firstBundle(from: archive)
        #expect(bundle.macSettings == Data("mac settings".utf8))
        #expect(bundle.userSettings == Data("phone settings".utf8))
        #expect(bundle.preferences.fields["reader.fontSize"]?.value == .number(19))
        let deletions = try LampPersonalDeletionLedger.decode(try #require(bundle.personalDeletions))
        #expect(deletions.entry(.note, "n1")?.deletedAt == 5_000)
        #expect(LampPresentationDeckDeletionLedger.decoded(from: try #require(bundle.deckDeletions))
            .deletedAt.keys.sorted() == ["easter"])
    }

    @Test func aMacArchiveOnWebDAVIsMovedOverItsRevision() async throws {
        let store = FixtureStore()
        store.files[LampSyncSettingsStore.path] = (ArchiveEraFixtures.macArchive, "\"a1\"")
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .mac)
        #expect(store.wholeReads == 0)
        let archive = try LampSyncArchive.decode(compressedData: ArchiveEraFixtures.macArchive)
        let moved = try await LampSyncLibraryMigration.migrate(
            in: store, imported: archive, revision: "\"a1\"", patience: .immediate
        )
        #expect(store.conditions == [.ifRevision("\"a1\"")])
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
    }

    @Test func aPhonesArchiveIsMovedByThePhone() async throws {
        let store = FixtureStore()
        store.files[LampSyncSettingsStore.path] = (ArchiveEraFixtures.phoneArchive, "\"a1\"")
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .phone)
        let moved = try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
        #expect(moved.bundle.userSettings == Data("phone settings".utf8))
        #expect(moved.bundle.preferences.fields["reader.fontSize"]?.value == .number(19))
        #expect(store.conditions == [.ifRevision("\"a1\"")])
    }

    /// The folder as the Mac's folder sync left it: its seal still vouches
    /// for it, and the move writes the first bundle beside it.
    @Test func aMacFolderIsCapturedAndMoved() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-fixture-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (path, data) in ArchiveEraFixtures.macFolder {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let captured = try await LampSyncFolderPublisher.capture(from: folder)
        #expect(LampSyncLibraryMigration.unplaceableEntries(in: captured).isEmpty)
        let store = LampSyncDirectoryStore(root: folder)
        #expect(try await LampSyncSettingsStore.earlierLibrary(in: store) == .mac)
        let moved = try await LampSyncLibraryMigration.migrate(
            in: store, imported: captured, revision: nil, patience: .immediate
        )
        #expect(moved.bundle.macSettings == Data("mac settings".utf8))
        #expect(try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate) == moved)
    }

    /// A file changed after the folder sync sealed the folder: its seal no
    /// longer vouches for it, so capture refuses it rather than import what
    /// may be a stopped publication.
    @Test func aChangedSealedFileIsNeverCaptured() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-fixture-sealed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (path, data) in ArchiveEraFixtures.macFolder {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try Data("edited later".utf8).write(to: folder.appendingPathComponent("Study/Notes/john.json"))
        await #expect(throws: LampSyncFolderPublisher.FolderError.incompletePublication(folder.path)) {
            _ = try await LampSyncFolderPublisher.capture(from: folder)
        }
    }
}

/// A WebDAV server with conditional writes that answers a ranged read, and
/// counts whole reads.
private final class FixtureStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: (Data, String)] = [:]
    private(set) var conditions: [LampSyncWriteCondition] = []
    private(set) var wholeReads = 0
    private var counter = 0

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        wholeReads += 1
        return files[path].map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
    }

    func readPrefix(path: String, count: Int) async throws -> LampSyncRemoteFile? {
        files[path].map { LampSyncRemoteFile(data: $0.0.prefix(count), revision: $0.1) }
    }

    func revision(path: String) async throws -> String? { files[path]?.1 }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        conditions.append(condition)
        switch condition {
        case .ifAbsent where files[path] != nil:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        case .ifRevision(let expected) where files[path]?.1 != expected:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        counter += 1
        let revision = "\"w\(counter)\""
        files[path] = (data, revision)
        return revision
    }
}
