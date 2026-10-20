import Foundation

/// Orders a backend change so remote preparation succeeds before local state
/// changes. Provider selection is persisted before a destructive wipe, then
/// activated only after the wipe succeeds. Earlier remote writes are not
/// rolled back if a later stage fails.
///
/// A client's per-path sync records (the revision it last installed or
/// wrote, its last upload's digest, writes and deletions waiting for a
/// bundle) belong to one provider, and a transition leaves them behind: an
/// ETag never equals a digest, so records offered to another provider make
/// every file read as changed. Key them by provider, as the preference
/// ledger is, so the new one starts with none. With no record a file is
/// downloaded and compared by value, never written over
/// (`Verification/SyncMerge.lean`: `noRecordNeverOverwrites`), and a switch
/// back finds the old records intact.
public enum LampSyncBackendTransition {
    public enum TransitionError: Error, LocalizedError {
        case rollbackFailed(wipeError: Error, rollbackError: Error)

        public var errorDescription: String? {
            switch self {
            case .rollbackFailed(let wipeError, let rollbackError):
                "The local reset failed (\(wipeError.localizedDescription)), and restoring the previous backend failed (\(rollbackError.localizedDescription))."
            }
        }
    }

    public static func run<Selection>(
        wipeLocalAfterPublish: Bool,
        pullAndMerge: () async throws -> Void,
        publish: () async throws -> Void,
        persistBackend: () async throws -> Selection,
        wipeLocal: () async throws -> Void,
        rollbackBackend: (Selection) async throws -> Void,
        activateBackend: (Selection) async -> Void
    ) async throws {
        try await LampSyncEngine.run(
            pullAndMerge: pullAndMerge,
            publish: publish,
            complete: {
                let selection = try await persistBackend()
                if wipeLocalAfterPublish {
                    do {
                        try await wipeLocal()
                    } catch {
                        let wipeError = error
                        do {
                            try await rollbackBackend(selection)
                        } catch {
                            throw TransitionError.rollbackFailed(
                                wipeError: wipeError,
                                rollbackError: error
                            )
                        }
                        throw wipeError
                    }
                }
                await activateBackend(selection)
            }
        )
    }
}
