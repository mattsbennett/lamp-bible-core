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
