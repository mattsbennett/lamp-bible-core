import Foundation

/// Publishes older-client compatibility files in order after the archive
/// commit. Each file keeps the revision condition observed before that commit.
/// A failed write stops the batch; already published files remain committed.
public enum LampSyncCompatibilityPublisher {
    public struct File: Sendable {
        public let remotePath: String
        public let data: Data
        public let condition: LampSyncWriteCondition

        public init(
            remotePath: String,
            data: Data,
            condition: LampSyncWriteCondition
        ) {
            self.remotePath = remotePath
            self.data = data
            self.condition = condition
        }
    }

    /// What a batch managed to publish, and what the server would not take.
    ///
    /// A file the server refuses is a disagreement about that one file. It
    /// says nothing about the others, so it is reported rather than thrown:
    /// stopping the pass over one module means the library, the settings and
    /// every other module stop syncing too, and the one file is no more
    /// published for it.
    public struct Attempt: Sendable {
        public let revisions: [String: String]
        /// Paths the server refused, in the order they were attempted.
        public let refused: [String]

        public init(revisions: [String: String], refused: [String]) {
            self.revisions = revisions
            self.refused = refused
        }
    }

    /// Publish each file, carrying on past any the server refuses.
    ///
    /// Only a refusal is survivable. Anything else — a dropped connection, a
    /// rejected credential — is not about one file and will meet every
    /// remaining write in the batch, so it is thrown as before rather than
    /// collected once per file.
    public static func publishReportingRefusals(
        _ files: [File],
        in store: any LampSyncRemoteStore,
        prepareDirectory: ((String) async throws -> Void)? = nil
    ) async throws -> Attempt {
        var preparedDirectories = Set<String>()
        var revisions: [String: String] = [:]
        var refused: [String] = []
        for file in files {
            if let prepareDirectory {
                preparedDirectories = try await LampSyncRemoteDirectories.prepareParents(
                    for: file.remotePath,
                    alreadyPrepared: preparedDirectories,
                    createDirectory: prepareDirectory
                )
            }
            do {
                revisions[file.remotePath] = try await LampSyncConditionalWrite.writeAndConfirm(
                    file.data,
                    to: file.remotePath,
                    in: store,
                    condition: file.condition
                )
            } catch LampSyncConditionalWrite.WriteError.conflict {
                refused.append(file.remotePath)
            }
        }
        return Attempt(revisions: revisions, refused: refused)
    }

    @discardableResult
    public static func publish(
        _ files: [File],
        in store: any LampSyncRemoteStore,
        prepareDirectory: ((String) async throws -> Void)? = nil
    ) async throws -> [String: String] {
        var preparedDirectories = Set<String>()
        var revisions: [String: String] = [:]
        for file in files {
            if let prepareDirectory {
                preparedDirectories = try await LampSyncRemoteDirectories.prepareParents(
                    for: file.remotePath,
                    alreadyPrepared: preparedDirectories,
                    createDirectory: prepareDirectory
                )
            }
            revisions[file.remotePath] = try await LampSyncConditionalWrite.writeAndConfirm(
                file.data,
                to: file.remotePath,
                in: store,
                condition: file.condition
            )
        }
        return revisions
    }
}
