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

/// A remote body saved to a local file, with the revision from the same
/// response. `url` is always the one the caller asked for.
public struct LampSyncDownloadedFile: Sendable {
    public let url: URL
    public let revision: String?

    public init(url: URL, revision: String?) {
        self.url = url
        self.revision = revision
    }
}

/// Scratch files for sync bodies too large to hold in memory.
///
/// Each is removed when its work ends. A pass the system kills leaves its
/// file behind, so the name prefix is fixed for a launch sweep to find.
public enum LampSyncScratchFile {
    public static let prefix = "lamp-sync-"

    public static func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
    }

    /// Runs `body` with a fresh scratch path and removes whatever is there
    /// afterwards.
    public static func with<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
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
    /// Saves a file's body to `url`, replacing whatever is there, and returns
    /// the revision from the same response, or nil when there is no file.
    ///
    /// A store that can should stream the body to disk. The archive is the
    /// whole library, and a phone that holds it in memory beside its unpacked
    /// form is stopped by the system. The default reads it into memory first.
    func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile?
    /// Writes the file at `url` as `write` writes data, and returns what it
    /// returns. A store that can should send it from disk; the default reads
    /// it through a mapping and calls `write`.
    func write(
        fileAt url: URL,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String?
    /// Deletes the file at `path` if it is still at `condition`, checked as
    /// part of the delete. A file already gone counts as deleted; a file at
    /// another revision is a refusal, and stays.
    ///
    /// This is how a tombstoned file is reaped. The default throws
    /// `LampSyncRemoteStoreError.deleteUnsupported`, so a store that has not
    /// implemented it fails the reap visibly rather than never reaping.
    func delete(path: String, condition: LampSyncWriteCondition) async throws
}

public enum LampSyncRemoteStoreError: Error, Equatable {
    case deleteUnsupported
}

/// A store that keeps two devices' copies of a file side by side instead of
/// refusing the later write, as iCloud Drive keeps conflict versions.
///
/// Its plain `read` refuses a file with unresolved versions, so a reader that
/// doesn't merge them stops rather than overwriting one. A wrapper around a
/// store like this must adopt this protocol too and forward it, or the
/// settings bundle stops at the first conflict.
public protocol LampSyncVersionedStore: LampSyncRemoteStore {
    /// The file saved to `destination`, and each unresolved version of it
    /// saved to a scratch file of its own, which the caller removes. Each
    /// revision names the bytes saved. Nil with no versions when nothing is
    /// there.
    func readWithVersions(
        path: String, into destination: URL
    ) async throws -> (current: LampSyncDownloadedFile?, versions: [LampSyncDownloadedFile])

    /// Writes `data` over the file if it is still at `revision`, then marks
    /// resolved the versions whose revisions are named, in one coordinated
    /// write. A version not named stays for the next read. A file that moved
    /// is a refusal, as for any conditional write.
    func resolveVersions(
        of path: String, writing data: Data, ifRevision revision: String, resolving versions: Set<String>
    ) async throws -> String

    /// Whether the file has unresolved versions, without reading it.
    func hasVersions(path: String) async throws -> Bool
}

public extension LampSyncRemoteStore {
    func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile? {
        guard let file = try await read(path: path) else { return nil }
        try file.data.write(to: url, options: .atomic)
        return LampSyncDownloadedFile(url: url, revision: file.revision)
    }

    func write(
        fileAt url: URL,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await write(Data(contentsOf: url, options: .alwaysMapped), to: path, condition: condition)
    }

    func delete(path: String, condition: LampSyncWriteCondition) async throws {
        throw LampSyncRemoteStoreError.deleteUnsupported
    }
}
