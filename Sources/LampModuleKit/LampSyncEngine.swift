/// Runs the shared sync transaction in order. A failed pull prevents publish;
/// a failed publish prevents recording completion. Cancellation is checked
/// before each phase. Platform adapters provide the actual database and
/// storage operations.
public enum LampSyncEngine {
    public static func run(
        pullAndMerge: () async throws -> Void,
        publish: () async throws -> Void,
        complete: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await pullAndMerge()
        try Task.checkCancellation()
        try await publish()
        try Task.checkCancellation()
        try await complete()
    }
}
