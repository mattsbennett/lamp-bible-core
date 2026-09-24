import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncModuleFolderTests {
    @Test func filtersFolderEntriesWithoutHidingListingErrors() async throws {
        let observation = FolderListingObservation()
        func entry(_ name: String, directory: Bool = false) -> LampSyncRemoteEntry {
            LampSyncRemoteEntry(
                path: "Notes/\(name)", name: name, isDirectory: directory,
                revision: nil, modifiedAt: nil, size: nil
            )
        }
        let store = FolderListingStore(
            entries: [
                entry("notes.LAMP"), entry("notes.LAMP"),
                entry("legacy.JSON"), entry("readme.txt"),
                entry("folder.lamp", directory: true)
            ],
            fails: false, observation: observation
        )

        let files = try await LampSyncModuleFolder.list(in: store, directory: "Notes")
        #expect(files.map(\.name) == ["notes.LAMP", "notes.LAMP", "legacy.JSON"])
        #expect(await observation.paths == ["Notes/"])
        #expect(try await LampSyncModuleFolder.list(
            in: FolderListingStore(entries: nil, fails: false, observation: observation),
            directory: "Notes/"
        ).isEmpty)
        #expect(await observation.paths == ["Notes/", "Notes/"])

        do {
            _ = try await LampSyncModuleFolder.list(
                in: FolderListingStore(entries: nil, fails: true, observation: observation),
                directory: "Notes"
            )
            Issue.record("A listing error must stop the module pull")
        } catch FolderListingError.denied {
            #expect(await observation.paths == ["Notes/", "Notes/", "Notes/"])
        }
    }
}

private enum FolderListingError: Error { case denied }

private actor FolderListingObservation {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

private struct FolderListingStore: LampSyncRemoteStore {
    let entries: [LampSyncRemoteEntry]?
    let fails: Bool
    let observation: FolderListingObservation

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        await observation.record(directory)
        if fails { throw FolderListingError.denied }
        return entries
    }
    func read(path: String) async throws -> LampSyncRemoteFile? { nil }
    func revision(path: String) async throws -> String? { nil }
    func write(
        _ data: Data, to path: String, condition: LampSyncWriteCondition
    ) async throws -> String? { nil }
}
