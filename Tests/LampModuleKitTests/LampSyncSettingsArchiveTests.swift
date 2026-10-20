import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncSettingsArchiveTests {
    @Test func settingsWriteRetainsOtherArchiveContents() throws {
        let original = try LampSyncSettingsArchive.replacingData(
            Data("first".utf8), in: nil
        ).replacingEntry(at: "Modules/example.lamp", with: Data("module".utf8))
        let updated = try LampSyncSettingsArchive.replacingData(
            Data("second".utf8), in: original
        )
        #expect(LampSyncSettingsArchive.preservesOtherContents(
            from: original, to: updated
        ))
        let changedModule = try updated.replacingEntry(
            at: "Modules/example.lamp", with: Data("changed".utf8)
        )
        #expect(!LampSyncSettingsArchive.preservesOtherContents(
            from: original, to: changedModule
        ))
        let settingsOnly = try LampSyncSettingsArchive.replacingData(
            Data("first".utf8), in: nil
        )
        #expect(LampSyncSettingsArchive.preservesOtherContents(
            from: nil, to: settingsOnly
        ))
        #expect(!LampSyncSettingsArchive.preservesOtherContents(
            from: nil, to: original
        ))
    }

    @Test func createsSettingsOnlyArchiveAndPreservesOtherEntriesOnUpdate() throws {
        let first = try LampSyncSettingsArchive.replacingData(
            Data("first".utf8), in: nil, modifiedAt: .distantPast
        )
        #expect(try LampSyncSettingsArchive.data(in: first) == Data("first".utf8))
        #expect(try first.portableBackupManifest().summary.moduleCount == 0)
        #expect(try LampSyncSettingsArchive.legacyManifest(in: first) != nil)

        let withModule = try first.replacingEntry(
            at: "Modules/book.lamp", with: Data("module".utf8)
        )
        let second = try LampSyncSettingsArchive.replacingData(
            Data("second".utf8), in: withModule
        )
        #expect(try LampSyncSettingsArchive.data(in: second) == Data("second".utf8))
        #expect(second.entries.first { $0.path == "Modules/book.lamp" }?.data == Data("module".utf8))
        #expect(try LampSyncArchive.decode(compressedData: second.compressedData()) == second)
    }

    @Test func macRebuildRetainsObservedSettingsBytesAndTimestamp() throws {
        let observed = try LampSyncSettingsArchive.replacingData(
            Data("iOS database".utf8), in: nil, modifiedAt: .distantPast
        )
        let outgoing = try LampSyncSettingsArchive.replacingData(
            Data("stale local copy".utf8), in: nil
        ).replacingEntry(at: "settings.plist", with: Data("Mac preferences".utf8))
        let preserved = try LampSyncSettingsArchive.preservingRemoteEntry(
            in: outgoing, from: observed
        )
        let originalEntry = try #require(observed.entries.first { $0.path == LampSyncSettingsArchive.path })
        let preservedEntry = try #require(preserved.entries.first { $0.path == LampSyncSettingsArchive.path })
        #expect(preservedEntry.data == originalEntry.data)
        #expect(preservedEntry.modifiedAt == originalEntry.modifiedAt)
        #expect(try LampSyncSettingsArchive.legacyManifest(in: preserved)
            == LampSyncSettingsArchive.legacyManifest(in: observed))
        #expect(preserved.entries.first { $0.path == "settings.plist" }?.data == Data("Mac preferences".utf8))
        #expect(try LampSyncArchive.decode(compressedData: preserved.compressedData()) == preserved)

        let withoutObserved = try LampSyncSettingsArchive.preservingRemoteEntry(
            in: outgoing, from: nil
        )
        #expect(try LampSyncSettingsArchive.data(in: withoutObserved) == nil)
        #expect(try LampSyncSettingsArchive.legacyManifest(in: withoutObserved) == nil)
    }

    @Test func rejectsArchiveWhoseSettingsManifestDoesNotMatchDatabase() throws {
        let archive = try LampSyncSettingsArchive.replacingData(
            Data("settings".utf8), in: nil
        )
        let manifestEntry = try #require(archive.entries.first {
            $0.path == LampSyncSettingsArchive.legacyManifestPath
        })
        var object = try #require(JSONSerialization.jsonObject(
            with: manifestEntry.data
        ) as? [String: Any])
        object["archiveSHA256"] = "invalid"
        let tampered = try archive.replacingEntry(
            at: LampSyncSettingsArchive.legacyManifestPath,
            with: JSONSerialization.data(withJSONObject: object)
        )
        let remote = LampSyncRemoteFile(
            data: try tampered.compressedData(), revision: "\"revision\""
        )
        #expect(throws: LampSyncSettingsArchive.SettingsArchiveError.invalidManifest) {
            try LampSyncArchiveRemote.decode(remote)
        }
    }
}

private actor SettingsPairStore: LampSyncRemoteStore {
    private var files: [String: LampSyncRemoteFile] = [:]

    func seed(_ file: LampSyncRemoteFile, at path: String) { files[path] = file }
    func remove(at path: String) { files.removeValue(forKey: path) }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { files[path] }
    func revision(path: String) async throws -> String? { files[path]?.revision }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        throw LampSyncConditionalWrite.WriteError.conflict
    }
}

private actor SettingsArchiveStore: LampSyncRemoteStore {
    private var remote: LampSyncRemoteFile?
    private var condition: LampSyncWriteCondition?
    private var conditions: [String: LampSyncWriteCondition] = [:]
    private var sidecars: [String: LampSyncRemoteFile] = [:]
    private var version = 0

    func lastCondition() -> LampSyncWriteCondition? { condition }
    /// The archive is published with an index beside it, so "the last write"
    /// is no longer the archive's. Ask about the write you mean.
    func condition(forPath path: String) -> LampSyncWriteCondition? {
        conditions[path]
    }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? {
        path == LampSyncLayout.archivePath ? remote : sidecars[path]
    }
    func revision(path: String) async throws -> String? {
        path == LampSyncLayout.archivePath ? remote?.revision : sidecars[path]?.revision
    }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        self.condition = condition
        conditions[path] = condition
        // The index beside the archive is a separate object.
        guard path == LampSyncLayout.archivePath else {
            sidecars[path] = LampSyncRemoteFile(data: data, revision: "\"\(path)\"")
            return nil
        }
        switch condition {
        case .ifAbsent where remote != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let expected) where expected != remote?.revision:
            throw LampSyncConditionalWrite.WriteError.conflict
        default:
            break
        }
        version += 1
        remote = LampSyncRemoteFile(
            data: data, revision: "\"revision-\(version)\""
        )
        return remote?.revision
    }
}
