import Foundation

/// Reads and publishes the portable archive against the exact remote revision
/// whose contents were merged by the caller.
public enum LampSyncArchiveRemote {
    public enum Observation: Sendable {
        case unchanged(revision: String)
        case snapshot(Snapshot?)
    }

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

    /// A caller with a valid local cache may skip the archive GET only when
    /// the provider still reports that exact strong revision. Without such a
    /// cache, read the body directly so its bytes and revision stay paired.
    public static func readIfChanged(
        from store: any LampSyncRemoteStore,
        knownRevision: String?
    ) async throws -> Observation {
        if let knownRevision, LampWebDAVStorage.isStrongETag(knownRevision),
           try await store.revision(path: LampSyncLayout.archivePath) == knownRevision {
            return .unchanged(revision: knownRevision)
        }
        return .snapshot(try await read(from: store))
    }

    /// The provider enforces the condition during PUT. If it omits a strong
    /// response ETag, the shared write helper confirms the body with one GET.
    @discardableResult
    public static func publish(
        _ archive: LampSyncArchive,
        replacing snapshot: Snapshot?,
        in store: any LampSyncRemoteStore
    ) async throws -> String {
        _ = try archive.portableBackupManifest()
        _ = try archive.compatibilityManifest()
        _ = try LampSyncSettingsArchive.legacyManifest(in: archive)
        let condition = try snapshot?.writeCondition ?? .ifAbsent
        // Packed and sent from disk: the archive is the whole library.
        let revision = try await LampSyncScratchFile.with { body in
            try archive.writeCompressed(to: body)
            return try await LampSyncConditionalWrite.writeAndConfirm(
                fileAt: body,
                to: LampSyncLayout.archivePath,
                in: store,
                condition: condition
            )
        }
        // Every writer goes through here, so maintaining the index here is
        // what keeps it worth reading. It describes the revision just
        // written, and a reader checks that before believing it, so losing
        // this write costs the next reader a fetch it would have made anyway
        // — not correctness. That is why it cannot fail the publish: the
        // archive is already safely written at this point.
        try? await LampSyncArchiveIndex.publish(
            describing: archive, at: revision, in: store
        )
        return revision
    }
}
