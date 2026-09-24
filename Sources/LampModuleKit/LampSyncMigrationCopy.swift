import Foundation

/// Chooses how a module participates in backend migration after both
/// providers' editable content has been reconciled into the local library.
public enum LampSyncMigrationCopy {
    public enum CopyError: Error, LocalizedError {
        case destinationConflict

        public var errorDescription: String? {
            "The destination module differs from the source module."
        }
    }

    public enum Action: Equatable, Sendable {
        case publishMerged
        case create
        case alreadyPresent
        case conflict
    }

    public static func action(
        isEditable: Bool,
        source: Data,
        destination: Data?
    ) -> Action {
        if isEditable { return .publishMerged }
        guard let destination else { return .create }
        return destination == source ? .alreadyPresent : .conflict
    }

    /// The caller's create operation must reject a file that appears after
    /// the read. WebDAV uses If-None-Match; iCloud rechecks local existence.
    @discardableResult
    public static func run(
        isEditable: Bool,
        source: Data,
        readDestination: () async throws -> Data?,
        createIfAbsent: (Data) async throws -> Void
    ) async throws -> Action {
        if isEditable { return .publishMerged }
        let decision = action(
            isEditable: false,
            source: source,
            destination: try await readDestination()
        )
        switch decision {
        case .create:
            try await createIfAbsent(source)
        case .conflict:
            throw CopyError.destinationConflict
        case .alreadyPresent, .publishMerged:
            break
        }
        return decision
    }
}
