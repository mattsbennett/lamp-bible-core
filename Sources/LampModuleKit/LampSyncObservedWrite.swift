import Foundation

/// Publishes a legacy file only when it still matches the version previously
/// imported by the caller. A content digest supports older module records
/// that stored a SHA-256 instead of a WebDAV ETag.
public enum LampSyncObservedWrite {
    @discardableResult
    public static func publish(
        _ data: Data,
        to path: String,
        in store: any LampSyncRemoteStore,
        matching base: String?,
        supersededBy archiveFile: LampCompatibilityManifest.File? = nil
    ) async throws -> String {
        let remote = try await store.read(path: path)
        let condition = try LampSyncConditionalWrite.condition(for: remote)
        if let remote {
            let archiveSupersedesRemote = archiveFile?.path == path
                && archiveFile?.sha256 == base?.lowercased()
                && archiveFile?.baseRevision == remote.revision
                && remote.revision != nil
            guard archiveSupersedesRemote || LampSyncContentRevision.allowsUnbasedWrite(
                data, over: remote.data
            ) || (base.map {
                remote.revision == $0 && LampWebDAVStorage.isStrongETag($0)
                    || LampSyncContentRevision.digest(for: remote.data) == $0.lowercased()
            } ?? false) else {
                throw LampSyncConditionalWrite.WriteError.conflict
            }
        } else if let base, LampWebDAVStorage.isStrongETag(base) {
            // A previously observed file disappeared. Its removal may carry
            // meaning, so a stale writer must not silently recreate it.
            throw LampSyncConditionalWrite.WriteError.conflict
        }
        return try await LampSyncConditionalWrite.writeAndConfirm(
            data, to: path, in: store, condition: condition
        )
    }

}
