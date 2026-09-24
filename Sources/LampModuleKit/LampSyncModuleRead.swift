import Foundation

/// Keeps imported module bytes and the revision that describes those bytes
/// together. A weak WebDAV validator cannot serve as a stable sync revision.
public enum LampSyncModuleRead {
    public static func webDAV(_ file: LampSyncRemoteFile) -> LampSyncRemoteFile {
        LampSyncRemoteFile(
            data: file.data,
            revision: file.revision.flatMap {
                LampWebDAVStorage.isStrongETag($0) ? $0 : nil
            }
        )
    }

    public static func content(_ data: Data) -> LampSyncRemoteFile {
        LampSyncRemoteFile(
            data: data,
            revision: LampSyncContentRevision.digest(for: data)
        )
    }
}
