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

    @Test func publishesSettingsAsOneRevisionConditionedArchiveEntry() async throws {
        let store = SettingsArchiveStore()
        let empty = try await LampSyncSettingsArchive.read(from: store)
        #expect(empty.archive == nil)
        #expect(empty.data == nil)

        _ = try await LampSyncSettingsArchive.publish(
            Data("first".utf8), replacing: empty, observedLegacy: nil, in: store
        )
        #expect(await store.lastCondition() == .ifAbsent)
        let first = try await LampSyncSettingsArchive.read(from: store)
        #expect(first.data == Data("first".utf8))

        _ = try await LampSyncSettingsArchive.publish(
            Data("second".utf8), replacing: first, observedLegacy: nil, in: store
        )
        #expect(await store.lastCondition() == .ifRevision("\"revision-1\""))
        let second = try await LampSyncSettingsArchive.read(from: store)
        #expect(second.data == Data("second".utf8))

        await #expect(throws: LampSyncConditionalWrite.WriteError.self) {
            try await LampSyncSettingsArchive.publish(
                Data("stale".utf8), replacing: first, observedLegacy: nil, in: store
            )
        }
    }

    @Test func classifiesLegacyMirrorAndOlderClientEdit() throws {
        let archived = Data("archive".utf8)
        let original = LampSyncRemoteFile(data: Data("old".utf8), revision: "\"old-revision\"")
        let manifest = try LampSyncSettingsArchive.LegacyManifest(
            archiveData: archived, observedLegacy: original
        )
        #expect(try LampSyncSettingsArchive.classifyLegacy(
            archiveData: archived, manifest: manifest, legacy: original
        ) == .superseded)
        #expect(try LampSyncSettingsArchive.classifyLegacy(
            archiveData: archived, manifest: manifest,
            legacy: LampSyncRemoteFile(data: archived, revision: "\"mirror-revision\"")
        ) == .mirrored)
        #expect(try LampSyncSettingsArchive.classifyLegacy(
            archiveData: archived, manifest: manifest,
            legacy: LampSyncRemoteFile(data: Data("older client edit".utf8), revision: "\"new-revision\"")
        ) == .changed)
        #expect(try LampSyncSettingsArchive.classifyLegacy(
            archiveData: archived, manifest: manifest,
            legacy: LampSyncRemoteFile(data: Data("changed-with-same-revision".utf8), revision: "\"old-revision\"")
        ) == .changed)
        #expect(try LampSyncSettingsArchive.classifyLegacy(
            archiveData: archived, manifest: manifest, legacy: nil
        ) == .changed)
        #expect(throws: LampSyncSettingsArchive.SettingsArchiveError.unversionedLegacyFile) {
            try LampSyncSettingsArchive.LegacyManifest(
                archiveData: archived,
                observedLegacy: LampSyncRemoteFile(data: Data("old".utf8), revision: nil)
            )
        }
    }

    @Test func resolvedReadUsesArchiveAndReportsLaterLegacyEdit() async throws {
        let store = SettingsPairStore()
        let old = LampSyncRemoteFile(
            data: Data("old settings".utf8), revision: "\"legacy-1\""
        )
        await store.seed(old, at: LampSyncLayout.userSettingsPath)
        let fallback = try #require(await LampSyncSettingsArchive.readWithLegacy(from: store))
        #expect(fallback.isLegacy)
        #expect(fallback.data == old.data)
        #expect(fallback.token == "legacy-1")

        let archiveData = Data("archive settings".utf8)
        let archive = try LampSyncSettingsArchive.replacingData(
            archiveData, in: nil, observedLegacy: old
        )
        await store.seed(
            LampSyncRemoteFile(
                data: try archive.compressedData(), revision: "\"archive-1\""
            ),
            at: LampSyncLayout.archivePath
        )
        let resolved = try #require(await LampSyncSettingsArchive.readWithLegacy(from: store))
        #expect(!resolved.isLegacy)
        #expect(resolved.data == archiveData)
        #expect(resolved.token == "archive-1")
        #expect(resolved.legacyState == .superseded)

        await store.seed(
            LampSyncRemoteFile(
                data: Data("older client edit".utf8), revision: "\"legacy-2\""
            ),
            at: LampSyncLayout.userSettingsPath
        )
        await #expect(throws: LampSyncSettingsArchive.SettingsArchiveError.changedLegacyFile) {
            try await LampSyncSettingsArchive.readWithLegacy(from: store)
        }
    }

    @Test func unchangedPollRequiresBothStrongMatchingRevisions() async throws {
        let store = SettingsPairStore()
        let archive = try LampSyncSettingsArchive.replacingData(
            Data("settings".utf8), in: nil
        )
        await store.seed(
            LampSyncRemoteFile(
                data: try archive.compressedData(), revision: "\"archive-1\""
            ),
            at: LampSyncLayout.archivePath
        )
        await store.seed(
            LampSyncRemoteFile(
                data: Data("settings".utf8), revision: "\"legacy-1\""
            ),
            at: LampSyncLayout.userSettingsPath
        )
        #expect(await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: "archive-1", expectedLegacyRevision: "\"legacy-1\"",
            in: store
        ))
        #expect(!(await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: "old-archive", expectedLegacyRevision: "\"legacy-1\"",
            in: store
        )))
        #expect(!(await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: "archive-1", expectedLegacyRevision: "\"old-legacy\"",
            in: store
        )))
        #expect(!(await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: "archive-1", expectedLegacyRevision: "W/\"legacy-1\"",
            in: store
        )))
        await store.remove(at: LampSyncLayout.userSettingsPath)
        #expect(!(await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: "archive-1", expectedLegacyRevision: "\"legacy-1\"",
            in: store
        )))
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
    private var version = 0

    func lastCondition() -> LampSyncWriteCondition? { condition }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { remote }
    func revision(path: String) async throws -> String? { remote?.revision }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        self.condition = condition
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
