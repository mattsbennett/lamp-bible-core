import Testing
@testable import LampModuleKit

private actor TransitionEvents {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

struct LampSyncBackendTransitionTests {
    private enum Stop: Error { case expected }

    @Test func successfulSwitchOnlyPersistsThenWipesThenActivates() async throws {
        let events = TransitionEvents()
        try await LampSyncBackendTransition.run(
            wipeLocalAfterPublish: true,
            pullAndMerge: { await events.append("pull") },
            publish: { await events.append("publish") },
            persistBackend: {
                await events.append("persist")
                return "selected-provider"
            },
            wipeLocal: { await events.append("wipe") },
            rollbackBackend: { selected in
                #expect(selected == "selected-provider")
                await events.append("rollback")
            },
            activateBackend: { selected in
                #expect(selected == "selected-provider")
                await events.append("activate")
            }
        )
        #expect(await events.all() == ["pull", "publish", "persist", "wipe", "activate"])
    }

    @Test func failedPublishKeepsLocalDataAndOldBackend() async {
        let events = TransitionEvents()
        do {
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: true,
                pullAndMerge: { await events.append("pull") },
                publish: {
                    await events.append("publish")
                    throw Stop.expected
                },
                persistBackend: { await events.append("persist") },
                wipeLocal: { await events.append("wipe") },
                rollbackBackend: { _ in await events.append("rollback") },
                activateBackend: { _ in await events.append("activate") }
            )
            Issue.record("Expected publish to fail")
        } catch Stop.expected {
            #expect(await events.all() == ["pull", "publish"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func failedWipeRestoresOldBackendBeforeActivation() async {
        let events = TransitionEvents()
        do {
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: true,
                pullAndMerge: { await events.append("pull") },
                publish: { await events.append("publish") },
                persistBackend: { await events.append("persist") },
                wipeLocal: {
                    await events.append("wipe")
                    throw Stop.expected
                },
                rollbackBackend: { _ in await events.append("rollback") },
                activateBackend: { _ in await events.append("activate") }
            )
            Issue.record("Expected wipe to fail")
        } catch Stop.expected {
            #expect(await events.all() == ["pull", "publish", "persist", "wipe", "rollback"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func failedBackendPersistenceCannotWipe() async {
        let events = TransitionEvents()
        do {
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: true,
                pullAndMerge: { await events.append("pull") },
                publish: { await events.append("publish") },
                persistBackend: { () async throws -> Void in
                    await events.append("persist")
                    throw Stop.expected
                },
                wipeLocal: { await events.append("wipe") },
                rollbackBackend: { _ in await events.append("rollback") },
                activateBackend: { _ in await events.append("activate") }
            )
            Issue.record("Expected backend persistence to fail")
        } catch Stop.expected {
            #expect(await events.all() == ["pull", "publish", "persist"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func failedRollbackIsReportedAndDoesNotActivate() async {
        let events = TransitionEvents()
        do {
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: true,
                pullAndMerge: { await events.append("pull") },
                publish: { await events.append("publish") },
                persistBackend: { await events.append("persist") },
                wipeLocal: {
                    await events.append("wipe")
                    throw Stop.expected
                },
                rollbackBackend: { _ in
                    await events.append("rollback")
                    throw Stop.expected
                },
                activateBackend: { _ in await events.append("activate") }
            )
            Issue.record("Expected rollback to fail")
        } catch let error as LampSyncBackendTransition.TransitionError {
            if case .rollbackFailed = error {
                #expect(await events.all() == ["pull", "publish", "persist", "wipe", "rollback"])
            } else {
                Issue.record("Unexpected transition error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func migrationDoesNotWipeLocalData() async throws {
        let events = TransitionEvents()
        try await LampSyncBackendTransition.run(
            wipeLocalAfterPublish: false,
            pullAndMerge: { await events.append("pull") },
            publish: { await events.append("publish") },
            persistBackend: { await events.append("persist") },
            wipeLocal: { await events.append("wipe") },
            rollbackBackend: { _ in await events.append("rollback") },
            activateBackend: { _ in await events.append("activate") }
        )
        #expect(await events.all() == ["pull", "publish", "persist", "activate"])
    }
}
