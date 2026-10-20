import Foundation

/// Reads the portable archive an earlier sync left, for moving a library to
/// the per-file layout. Nothing publishes one any more.
public enum LampSyncArchiveRemote {
    public struct Snapshot: Sendable {
        public let archive: LampSyncArchive
        public let compatibilityManifest: LampCompatibilityManifest?
        public let revision: String?

        public var writeCondition: LampSyncWriteCondition {
            get throws { try LampSyncConditionalWrite.condition(forExistingRevision: revision) }
        }
    }

    public static func decode(_ remoteFile: LampSyncRemoteFile) throws -> Snapshot {
        try snapshot(
            of: LampSyncArchive.decode(compressedData: remoteFile.data), revision: remoteFile.revision
        )
    }

    private static func snapshot(of archive: LampSyncArchive, revision: String?) throws -> Snapshot {
        _ = try archive.portableBackupManifest()
        let compatibilityManifest = try archive.compatibilityManifest()
        _ = try LampSyncSettingsArchive.legacyManifest(in: archive)
        return Snapshot(
            archive: archive,
            compatibilityManifest: compatibilityManifest,
            revision: revision
        )
    }

    public static func read(from store: any LampSyncRemoteStore) async throws -> Snapshot? {
        // Streamed to disk: the archive is the whole library.
        try await LampSyncScratchFile.with { scratch in
            guard let body = try await store.read(path: LampSyncLayout.archivePath, into: scratch) else {
                return nil
            }
            return try snapshot(of: LampSyncArchive.decode(compressedFileAt: body.url), revision: body.revision)
        }
    }

}
