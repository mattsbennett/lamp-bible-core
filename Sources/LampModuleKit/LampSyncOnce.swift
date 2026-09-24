/// Runs an initial sync once after it succeeds. Concurrent callers share the
/// same attempt; a failed attempt leaves the gate open for a later retry.
public actor LampSyncOnce {
    private var completed = false
    private var running = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    var waitingCallerCount: Int { waiters.count }

    public init() {}

    public func run(_ operation: () async throws -> Void) async throws {
        try Task.checkCancellation()
        if completed { return }
        if running {
            let waiterID = nextWaiterID
            nextWaiterID += 1
            try await withTaskCancellationHandler(operation: { () async throws -> Void in
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task<Never, Never>.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
            }, onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
            try Task.checkCancellation()
            return
        }

        running = true
        do {
            try await operation()
            completed = true
            running = false
            let pending = waiters.values
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        } catch {
            running = false
            let pending = waiters.values
            waiters.removeAll()
            for continuation in pending { continuation.resume(throwing: error) }
            throw error
        }
        try Task.checkCancellation()
    }

    private func cancelWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
