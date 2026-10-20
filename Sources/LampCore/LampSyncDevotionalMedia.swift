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

    /// An attachment to publish: where it goes, and the local file that
    /// holds it.
    public struct OutgoingFile: Equatable, Sendable {
        public let remotePath: String
        public let localURL: URL

        public init(remotePath: String, localURL: URL) {
            self.remotePath = remotePath
            self.localURL = localURL
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
        try outgoingFileURLs(
            for: devotionals, to: moduleID, from: libraryRootURL, fileManager: fileManager
        ).map {
            UploadFile(remotePath: $0.remotePath, data: try Data(contentsOf: $0.localURL, options: [.mappedIfSafe]))
        }
    }

    /// The same plan as `outgoingFiles`, naming each local file rather than
    /// reading it, for a pass that publishes from disk. A missing or
    /// non-regular attachment still throws: a writing published without its
    /// image is worse than a pass that stops.
    public static func outgoingFileURLs(
        for devotionals: [LampDevotional],
        to moduleID: String,
        from libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> [OutgoingFile] {
        var files: [OutgoingFile] = []
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
                let localURL = localURL(in: libraryRootURL, devotionalID: devotional.id, filename: filename)
                guard fileManager.fileExists(atPath: localURL.path),
                      let values = try? localURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw UploadError.invalidLocalFile(remotePath)
                }
                files.append(OutgoingFile(remotePath: remotePath, localURL: localURL))
            }
        }
        return files
    }

    /// Where the library keeps a writing's attachment.
    private static func localURL(in libraryRootURL: URL, devotionalID: String, filename: String) -> URL {
        libraryRootURL
            .appendingPathComponent("Media/Devotionals", isDirectory: true)
            .appendingPathComponent(devotionalID, isDirectory: true)
            .appendingPathComponent(filename)
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
                items.append(.init(
                    remotePath: remotePath,
                    localURL: localURL(in: libraryRootURL, devotionalID: devotional.id, filename: filename)
                ))
            }
        }
        try await LampSyncReferencedMedia.downloadMissing(items, readRemote: readRemote)
    }
}
