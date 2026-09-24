import Foundation

/// Keeps revision checks and write confirmation consistent across sync clients.
public enum LampSyncConditionalWrite {
    public enum WriteError: Error, LocalizedError {
        case conflict

        public var errorDescription: String? {
            "The remote file changed before it could be saved."
        }
    }

    /// A missing file may be created. An existing file requires its exact,
    /// strong ETag so the provider can enforce the condition during PUT.
    public static func condition(for remote: LampSyncRemoteFile?) throws -> LampSyncWriteCondition {
        guard let remote else { return .ifAbsent }
        return try condition(forExistingRevision: remote.revision)
    }

    /// Use when the caller has already read and validated an existing file
    /// and needs to retain only its revision for the later conditional PUT.
    public static func condition(forExistingRevision revision: String?) throws -> LampSyncWriteCondition {
        guard let revision,
              LampWebDAVStorage.isStrongETag(revision) else {
            throw WriteError.conflict
        }
        return .ifRevision(revision)
    }

    /// Prepare an upload against the revision last merged by this client.
    /// A missing HEAD ETag is checked with GET before assuming absence.
    public static func condition(
        for path: String,
        in store: any LampSyncRemoteStore,
        matching expectedToken: String?
    ) async throws -> LampSyncWriteCondition {
        if let revision = try await store.revision(path: path) {
            guard LampWebDAVStorage.isStrongETag(revision),
                  token(for: revision) == expectedToken else {
                throw WriteError.conflict
            }
            return .ifRevision(revision)
        }
        let remote = try await store.read(path: path)
        if remote == nil && expectedToken != nil {
            throw WriteError.conflict
        }
        let writeCondition = try condition(for: remote)
        if case .ifRevision(let revision) = writeCondition,
           token(for: revision) != expectedToken {
            throw WriteError.conflict
        }
        return writeCondition
    }

    /// A PUT response may omit ETag. Confirm the uploaded body and revision
    /// from one GET response rather than pairing a GET body with a later HEAD.
    public static func writeAndConfirm(
        _ data: Data,
        to path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition
    ) async throws -> String {
        let responseRevision = try await store.write(data, to: path, condition: condition)
        if let responseRevision, LampWebDAVStorage.isStrongETag(responseRevision) {
            return responseRevision
        }
        guard let remote = try await store.read(path: path),
              remote.data == data,
              let revision = remote.revision,
              LampWebDAVStorage.isStrongETag(revision) else {
            throw WriteError.conflict
        }
        return revision
    }

    /// The iOS settings cache stores an ETag without HTTP quote delimiters.
    public static func token(for revision: String) -> String {
        var value = revision
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Only a complete strong entity-tag can identify an applied remote base.
    public static func strongToken(for revision: String?) -> String? {
        guard let revision, LampWebDAVStorage.isStrongETag(revision) else {
            return nil
        }
        return token(for: revision)
    }
}
