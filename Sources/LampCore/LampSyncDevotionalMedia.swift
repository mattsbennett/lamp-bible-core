import Foundation
import LampModuleKit

/// Imports media referenced by iOS devotional records into the portable
/// library layout used by Mac. The caller supplies its remote provider read.
public enum LampSyncDevotionalMedia {
    public struct UploadFile: Sendable {
        public let remotePath: String
        public let data: Data

        public init(remotePath: String, data: Data) {
            self.remotePath = remotePath
            self.data = data
        }
    }

    public enum UploadError: Error, LocalizedError {
        case invalidLocalFile(String)
        case conflictingRemoteFile(String)

        public var errorDescription: String? {
            switch self {
            case .invalidLocalFile(let path):
                "A devotional attachment is missing or is not a regular file: \(path)."
            case .conflictingRemoteFile(let path):
                "A different devotional attachment already exists at \(path)."
            }
        }
    }

    /// Plan all files used by the iOS-compatible devotional module. This also
    /// covers legacy Mac Markdown before its rich metadata has been saved back
    /// into the personal library. Unknown future media types retain their files.
    public static func outgoingFiles(
        for devotionals: [LampDevotional],
        to moduleID: String,
        from libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> [UploadFile] {
        var files: [UploadFile] = []
        var plannedPaths = Set<String>()
        for devotional in devotionals {
            let legacy = try LampPortableDevotionalMedia.references(
                in: devotional.content, devotionalID: devotional.id
            )
            let filenames = legacy.map(\.filename)
                + (try LampPortableDevotionalMedia.filenames(in: devotional.mediaJSON))
            for filename in filenames {
                let remotePath = try LampPortableDevotionalMedia.iOSRemotePath(
                    moduleID: moduleID, devotionalID: devotional.id,
                    filename: filename
                )
                guard plannedPaths.insert(remotePath).inserted else { continue }
                let localURL = libraryRootURL
                    .appendingPathComponent("Media/Devotionals", isDirectory: true)
                    .appendingPathComponent(devotional.id, isDirectory: true)
                    .appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: localURL.path),
                      let values = try? localURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw UploadError.invalidLocalFile(remotePath)
                }
                files.append(UploadFile(
                    remotePath: remotePath,
                    data: try Data(contentsOf: localURL, options: [.mappedIfSafe])
                ))
            }
        }
        return files
    }

    /// Missing immutable attachments are created conditionally. An identical
    /// remote copy is already complete; a different copy must stop publication.
    public static func pendingUploads(
        _ files: [UploadFile],
        readRemote: (String) async throws -> LampSyncRemoteFile?
    ) async throws -> [LampSyncCompatibilityPublisher.File] {
        var pending: [LampSyncCompatibilityPublisher.File] = []
        for file in files {
            if let remote = try await readRemote(file.remotePath) {
                guard remote.data == file.data else {
                    throw UploadError.conflictingRemoteFile(file.remotePath)
                }
                continue
            }
            pending.append(.init(
                remotePath: file.remotePath, data: file.data, condition: .ifAbsent
            ))
        }
        return pending
    }

    public static func downloadToLibrary(
        for devotionals: [LampDevotional],
        from moduleID: String,
        into libraryRootURL: URL,
        readRemote: (String) async throws -> Data
    ) async throws {
        var items: [LampSyncReferencedMedia.Item] = []
        for devotional in devotionals {
            for filename in try LampPortableDevotionalMedia.filenames(
                in: devotional.mediaJSON
            ) {
                let remotePath = try LampPortableDevotionalMedia.iOSRemotePath(
                    moduleID: moduleID, devotionalID: devotional.id,
                    filename: filename
                )
                let localURL = libraryRootURL
                    .appendingPathComponent("Media/Devotionals", isDirectory: true)
                    .appendingPathComponent(devotional.id, isDirectory: true)
                    .appendingPathComponent(filename)
                items.append(.init(remotePath: remotePath, localURL: localURL))
            }
        }
        try await LampSyncReferencedMedia.downloadMissing(items, readRemote: readRemote)
    }
}
