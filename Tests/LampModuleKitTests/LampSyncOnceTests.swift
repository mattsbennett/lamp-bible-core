import Testing
@testable import LampModuleKit

private actor OnceAttemptCounter {
    private(set) var count = 0

    func attempt(fail: Bool) throws {
        count += 1
        if fail { throw AttemptError.failed }
    }
}

private enum AttemptError: Error {
    case failed
}

private actor SuspendedAttempt {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct LampSyncOnceTests {
    @Test func failedAttemptCanRetryButSuccessfulAttemptRunsOnlyOnce() async throws {
        let gate = LampSyncOnce()
        let attempts = OnceAttemptCounter()

        await #expect(throws: AttemptError.self) {
            try await gate.run { try await attempts.attempt(fail: true) }
        }
        #expect(await attempts.count == 1)

        try await gate.run { try await attempts.attempt(fail: false) }
        try await gate.run { try await attempts.attempt(fail: false) }
        #expect(await attempts.count == 2)
    }

    @Test func cancelledCallerLeavesInitialSyncAvailable() async throws {
        let gate = LampSyncOnce()
        let attempts = OnceAttemptCounter()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.run { try await attempts.attempt(fail: false) }
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await attempts.count == 0)

        try await gate.run { try await attempts.attempt(fail: false) }
        #expect(await attempts.count == 1)
    }

    @Test func cancelledWaitingCallerResumesBeforeSharedAttemptFinishes() async throws {
        let gate = LampSyncOnce()
        let blocker = SuspendedAttempt()
        let attempts = OnceAttemptCounter()
        let first = Task {
            try await gate.run { await blocker.hold() }
        }
        await blocker.waitUntilStarted()

        let second = Task {
            try await gate.run { try await attempts.attempt(fail: false) }
        }
        while await gate.waitingCallerCount == 0 { await Task.yield() }

        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await gate.waitingCallerCount == 0)
        #expect(await attempts.count == 0)

        await blocker.release()
        try await first.value
        try await gate.run { try await attempts.attempt(fail: false) }
        #expect(await attempts.count == 0)
    }
}
