import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncMigrationCopyTests {
    private enum Stop: Error { case appeared }

    @Test func editableModulesUseMergedExport() {
        let source = Data("source notes".utf8)
        let destination = Data("destination notes".utf8)
        #expect(LampSyncMigrationCopy.action(
            isEditable: true, source: source, destination: destination
        ) == .publishMerged)
    }

    @Test func readOnlyCopyPreservesDifferentDestination() {
        let source = Data("source translation".utf8)
        #expect(LampSyncMigrationCopy.action(
            isEditable: false, source: source, destination: nil
        ) == .create)
        #expect(LampSyncMigrationCopy.action(
            isEditable: false, source: source, destination: source
        ) == .alreadyPresent)
        #expect(LampSyncMigrationCopy.action(
            isEditable: false, source: source,
            destination: Data("destination translation".utf8)
        ) == .conflict)
    }

    @Test func runnerNeverWritesOverDifferentDestination() async throws {
        let source = Data("source".utf8)
        let events = MigrationCopyEvents()
        await #expect(throws: LampSyncMigrationCopy.CopyError.self) {
            try await LampSyncMigrationCopy.run(
                isEditable: false,
                source: source,
                readDestination: {
                    await events.append("read")
                    return Data("different".utf8)
                },
                createIfAbsent: { _ in await events.append("write") }
            )
        }
        #expect(await events.all() == ["read"])
    }

    @Test func editableRunnerDefersToMergedExport() async throws {
        let events = MigrationCopyEvents()
        let action = try await LampSyncMigrationCopy.run(
            isEditable: true,
            source: Data("source".utf8),
            readDestination: {
                await events.append("read")
                return nil
            },
            createIfAbsent: { _ in await events.append("write") }
        )
        #expect(action == .publishMerged)
        #expect((await events.all()).isEmpty)
    }

    @Test func createFailureStopsMigration() async throws {
        let events = MigrationCopyEvents()
        await #expect(throws: Stop.self) {
            try await LampSyncMigrationCopy.run(
                isEditable: false,
                source: Data("source".utf8),
                readDestination: { await events.append("read"); return nil },
                createIfAbsent: { _ in
                    await events.append("create")
                    throw Stop.appeared
                }
            )
        }
        #expect(await events.all() == ["read", "create"])
    }
}

private actor MigrationCopyEvents {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}
