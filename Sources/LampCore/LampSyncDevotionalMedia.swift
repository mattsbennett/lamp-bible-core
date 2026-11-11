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

    /// Something that has media: a writing or one of the reader's notes.
    ///
    /// `ownerID` is the folder and path component — a writing's id, a note's
    /// verse — and `content` is searched for the Mac's older
    /// `lamp-media://` links, which only writings ever had.
    public struct Owner: Equatable, Sendable {
        public let id: String
        public let mediaJSON: String?
        public let content: String?

        public init(id: String, mediaJSON: String?, content: String? = nil) {
            self.id = id
            self.mediaJSON = mediaJSON
            self.content = content
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
        try outgoingFileURLs(
            scope: .devotional,
            owners: devotionals.map {
                Owner(id: $0.id, mediaJSON: $0.mediaJSON, content: $0.content)
            },
            to: moduleID, from: libraryRootURL, fileManager: fileManager
        )
    }

    /// The files one scope's owners have, to publish.
    public static func outgoingFileURLs(
        scope: LampMediaScope,
        owners: [Owner],
        to moduleID: String,
        from libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> [OutgoingFile] {
        var files: [OutgoingFile] = []
        var plannedPaths = Set<String>()
        for owner in owners {
            // The Mac's older `lamp-media://` links, which only a writing
            // ever had: a note's media has been metadata from the start.
            let legacy = owner.content.map {
                (try? LampPortableDevotionalMedia.references(in: $0, devotionalID: owner.id)) ?? []
            } ?? []
            let filenames = legacy.map(\.filename)
                + (try LampPortableDevotionalMedia.filenames(in: owner.mediaJSON))
            for filename in filenames {
                let remotePath = try LampPortableDevotionalMedia.remotePath(
                    scope: scope, moduleID: moduleID, ownerID: owner.id, filename: filename
                )
                guard plannedPaths.insert(remotePath).inserted else { continue }
                let localURL = localURL(
                    in: libraryRootURL, scope: scope, ownerID: owner.id, filename: filename
                )
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

    /// Where the library keeps one owner's attachment. The folder was
    /// written out here too — the fourth copy of `Media/Devotionals`, and
    /// the reason a note's file would have been looked for among the
    /// writings'.
    private static func localURL(
        in libraryRootURL: URL, scope: LampMediaScope, ownerID: String, filename: String
    ) -> URL {
        (LampPortableDevotionalMedia.folderURL(
            rootURL: libraryRootURL, scope: scope, ownerID: ownerID
        ) ?? libraryRootURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(scope.folder, isDirectory: true)
            .appendingPathComponent(ownerID, isDirectory: true))
            .appendingPathComponent(filename)
    }

    public static func downloadToLibrary(
        for devotionals: [LampDevotional],
        from moduleID: String,
        into libraryRootURL: URL,
        readRemote: (String) async throws -> Data
    ) async throws {
        try await downloadToLibrary(
            scope: .devotional,
            owners: devotionals.map { Owner(id: $0.id, mediaJSON: $0.mediaJSON) },
            from: moduleID, into: libraryRootURL, readRemote: readRemote
        )
    }

    /// Fetches whatever one scope's owners reference and this library does
    /// not have.
    public static func downloadToLibrary(
        scope: LampMediaScope,
        owners: [Owner],
        from moduleID: String,
        into libraryRootURL: URL,
        readRemote: (String) async throws -> Data
    ) async throws {
        var items: [LampSyncReferencedMedia.Item] = []
        for owner in owners {
            for filename in try LampPortableDevotionalMedia.filenames(in: owner.mediaJSON) {
                let remotePath = try LampPortableDevotionalMedia.remotePath(
                    scope: scope, moduleID: moduleID, ownerID: owner.id, filename: filename
                )
                items.append(.init(
                    remotePath: remotePath,
                    localURL: localURL(
                        in: libraryRootURL, scope: scope, ownerID: owner.id, filename: filename
                    )
                ))
            }
        }
        try await LampSyncReferencedMedia.downloadMissing(items, readRemote: readRemote)
    }
}
