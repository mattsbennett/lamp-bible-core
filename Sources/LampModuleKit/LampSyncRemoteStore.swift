import Foundation

/// An opaque server revision. Keep ETags exactly as returned by the server;
/// removing quotes or a weak-validator prefix changes HTTP preconditions.
public struct LampSyncRemoteFile: Sendable {
    public let data: Data
    public let revision: String?

    public init(data: Data, revision: String?) {
        self.data = data
        self.revision = revision
    }
}

public struct LampSyncRemoteEntry: Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let revision: String?
    public let modifiedAt: Date?
    public let size: Int64?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        revision: String?,
        modifiedAt: Date?,
        size: Int64?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

public enum LampSyncWriteCondition: Sendable, Equatable {
    case unconditional
    case ifAbsent
    case ifRevision(String)
}

/// Path-based remote storage used by sync clients. A conditional write must
/// be checked by the provider as part of the write, not by a prior read.
public protocol LampSyncRemoteStore {
    func list(directory: String) async throws -> [LampSyncRemoteEntry]?

    func read(path: String) async throws -> LampSyncRemoteFile?

    /// Returns the provider's exact revision for a file, if available.
    func revision(path: String) async throws -> String?

    /// Returns the new revision only when it is supplied by the write response.
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String?
}
