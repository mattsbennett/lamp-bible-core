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

    /// Every media file one scope actually has on disk, whatever owns it.
    ///
    /// `outgoingFileURLs` asks the *owners* what files they refer to, which
    /// is right for publishing and wrong for saying what the library holds:
    /// a picture whose writing this library does not have is still a file at
    /// the member's path, and nothing else claims it. Nothing lists media,
    /// so a media member with no local copy is downloaded on **every pass,
    /// unconditionally** (`LampSyncFilePlan.change`'s media branch) — then
    /// written where it already was. Five such files were doing that on the
    /// owner's library, for a writing the deletion ledger records neither as
    /// present nor as deleted.
    ///
    /// Claiming them rather than sweeping them is the deliberate choice: the
    /// ledger does not say that writing was deleted, so its pictures may
    /// still belong to a writing another device holds, and a sweep would
    /// destroy them. A file on disk at the path the member names *is* held,
    /// and saying so is true.
    ///
    /// Only regular files directly inside `Media/<folder>/<owner>/`. A link
    /// is skipped, as `outgoingFileURLs` skips one, and for the reason
    /// `decisions/0010` gives: a pass publishes only an ordinary file.
    /// - Parameter satisfying: the member paths this answer may cover.
    ///   **Required, and the whole safety of this.** Disk discovery exists to
    ///   say "that member is here", never to volunteer something new: a
    ///   writing deleted before its first sync leaves its attachments on
    ///   disk, and a candidate at a path the manifest does not name is
    ///   uploaded — which would publish pictures the owner deleted. It also
    ///   keeps a notes *module*'s pictures out of this, since
    ///   `Media/Notes/module-<id>/` is a different owner namespace whose
    ///   members are named differently and gathered elsewhere.
    public static func filesOnDisk(
        scope: LampMediaScope,
        moduleID: String,
        satisfying members: Set<String>,
        in libraryRootURL: URL,
        fileManager: FileManager = .default
    ) -> [OutgoingFile] {
        guard !members.isEmpty else { return [] }
        let root = libraryRootURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(scope.folder, isDirectory: true)
        guard let owners = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [OutgoingFile] = []
        for owner in owners.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? owner.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let contents = try? fileManager.contentsOfDirectory(
                    at: owner, includingPropertiesForKeys:
                        [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
                  )
            else { continue }
            let ownerID = owner.lastPathComponent
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let remotePath = try? LampPortableDevotionalMedia.remotePath(
                        scope: scope, moduleID: moduleID,
                        ownerID: ownerID, filename: url.lastPathComponent
                      )
                else { continue }
                guard members.contains(remotePath) else { continue }
                files.append(OutgoingFile(remotePath: remotePath, localURL: url))
            }
        }
        return files
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
