import Testing
@testable import LampModuleKit

private actor SyncEvents {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

struct LampSyncEngineTests {
    private enum Stop: Error { case expected }

    @Test func successfulRunOrdersAllStages() async throws {
        let events = SyncEvents()
        try await LampSyncEngine.run(
            pullAndMerge: { await events.append("pull") },
            publish: { await events.append("publish") },
            complete: { await events.append("complete") }
        )
        #expect(await events.all() == ["pull", "publish", "complete"])
    }

    @Test func failedPullNeverPublishesOrCompletes() async {
        let events = SyncEvents()
        do {
            try await LampSyncEngine.run(
                pullAndMerge: {
                    await events.append("pull")
                    throw Stop.expected
                },
                publish: { await events.append("publish") },
                complete: { await events.append("complete") }
            )
            Issue.record("Expected pull to fail")
        } catch Stop.expected {
            #expect(await events.all() == ["pull"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func failedPublishNeverCompletes() async {
        let events = SyncEvents()
        do {
            try await LampSyncEngine.run(
                pullAndMerge: { await events.append("pull") },
                publish: {
                    await events.append("publish")
                    throw Stop.expected
                },
                complete: { await events.append("complete") }
            )
            Issue.record("Expected publish to fail")
        } catch Stop.expected {
            #expect(await events.all() == ["pull", "publish"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellationAfterPullNeverPublishes() async {
        let events = SyncEvents()
        let sync = Task {
            try await LampSyncEngine.run(
                pullAndMerge: {
                    await events.append("pull")
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                publish: { await events.append("publish") },
                complete: { await events.append("complete") }
            )
        }
        do {
            try await sync.value
            Issue.record("A cancelled pull must stop before publication")
        } catch is CancellationError {
            #expect(await events.all() == ["pull"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellationAfterPublishNeverCompletes() async {
        let events = SyncEvents()
        let sync = Task {
            try await LampSyncEngine.run(
                pullAndMerge: { await events.append("pull") },
                publish: {
                    await events.append("publish")
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                complete: { await events.append("complete") }
            )
        }
        do {
            try await sync.value
            Issue.record("A cancelled publication must not record completion")
        } catch is CancellationError {
            #expect(await events.all() == ["pull", "publish"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
