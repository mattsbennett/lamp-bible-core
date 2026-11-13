import Foundation

/// A book's pictures, as files.
///
/// They are not inside the book's module: its `media_json` holds only each
/// picture's metadata. So the files are a library's only copy, and a device
/// that drops them shows the book with its pictures missing. This holds the
/// rules every app follows for them:
///
/// - which files are a book's,
/// - where each goes on the server (`BookMedia/<book>/<path>`),
/// - where one that arrives is put,
/// - where a picture a book names is found.
///
/// Where an app keeps them is its own, and is handed in as folders, one list
/// per book. The Mac keeps them in its library (`libraryFolders`). The phone
/// keeps them in its module media cache, `ModuleMediaCache/<book>`.
public enum LampBookMediaFiles {
    /// One file to publish: its path on the server and where it is here.
    public struct File: Equatable, Sendable {
        public let remotePath: String
        public let url: URL

        public init(remotePath: String, url: URL) {
            self.remotePath = remotePath
            self.url = url
        }
    }

    /// A file found where a book's pictures are kept that has no place on
    /// the server, with why.
    public struct Unplaceable: Equatable, Sendable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Where a book's pictures are kept on one device.
    public struct Folders: Equatable, Sendable {
        /// Where a reader looks, in its order of precedence. A picture found
        /// in an earlier folder wins.
        public let read: [URL]
        /// Where a picture that arrives is put. One of `read`, so that what
        /// arrives is what the reader finds.
        public let install: URL

        public init(read: [URL], install: URL) {
            self.read = read
            self.install = install
        }
    }

    /// A library's folders for a book, for an app that keeps books' pictures
    /// in the library: `Media/Books/<book>`, which a sync writes, and the
    /// layouts older libraries have, in the order a reader looks.
    public static func libraryFolders(libraryRootURL: URL, moduleID: String) -> Folders {
        let read = [
            "Media/Modules/\(moduleID)",
            "Media/Books/\(moduleID)",
            "Media/\(moduleID)",
            "Modules/\(moduleID)/media",
        ].map { libraryRootURL.appendingPathComponent($0, isDirectory: true) }
        return Folders(read: read, install: read[1])
    }

    /// Where a picture a book names is, or nil when it is nowhere here.
    ///
    /// A web address is its own answer. A relative path that climbs out of
    /// the book's folders, or names nothing, is no picture.
    public static func url(
        for filename: String,
        in folders: Folders,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        if let remote = URL(string: filename),
           let scheme = remote.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return remote
        }
        guard let relative = LampPortableBookJSON.safeRelativeMediaPath(filename) else { return nil }
        return folders.read
            .map { $0.appendingPathComponent(relative) }
            .first { fileExists($0.path) }
    }

    /// The pictures to publish for `moduleIDs`, gathered from each book's
    /// folders in the reader's order. A path found in an earlier folder wins,
    /// as it does for the reader, so what is published is what is shown.
    ///
    /// Only for the books named: the books in the library, and any the server
    /// already names. That is what keeps a picture belonging to something
    /// else — a commentary's, a note's — from going up as a book's when it
    /// shares a folder with them. Links are skipped: what one points at is
    /// not this library's to publish.
    public static func outgoing(
        forBookModuleIDs moduleIDs: Set<String>,
        folders: (String) -> Folders,
        fileManager: FileManager = .default
    ) -> (files: [File], unplaceable: [Unplaceable]) {
        var files: [File] = []
        var unplaceable: [Unplaceable] = []
        for moduleID in moduleIDs.sorted() {
            var taken = Set<String>()
            for root in folders(moduleID).read {
                for (relative, url) in regularFiles(under: root, fileManager: fileManager) {
                    guard taken.insert(relative).inserted else { continue }
                    do {
                        files.append(File(
                            remotePath: try LampSyncFolderLayout.bookMediaPath(
                                moduleID: moduleID, path: relative
                            ),
                            url: url
                        ))
                    } catch {
                        unplaceable.append(Unplaceable(
                            path: "\(moduleID)/\(relative)",
                            reason: error.localizedDescription
                        ))
                    }
                }
            }
        }
        return (files, unplaceable)
    }

    /// The books a set of server paths holds pictures for. A pass publishes
    /// these as well as the library's own books, so a picture already on the
    /// server keeps its book.
    public static func bookModuleIDs(inRemotePaths paths: some Sequence<String>) -> Set<String> {
        Set(paths.compactMap { path in
            guard LampSyncFolderLayout.kind(of: path) == .bookMedia else { return nil }
            return path.split(separator: "/").dropFirst().first.map(String.init)
        })
    }

    /// Where a picture that arrives at `remotePath` is put, or nil for a path
    /// that is not a book's picture.
    public static func installURL(forRemotePath remotePath: String, folders: (String) -> Folders) -> URL? {
        guard LampSyncFolderLayout.kind(of: remotePath) == .bookMedia else { return nil }
        let components = remotePath.split(separator: "/").map(String.init)
        guard components.count >= 3,
              let relative = LampPortableBookJSON.safeRelativeMediaPath(
                  components.dropFirst(2).joined(separator: "/")
              )
        else { return nil }
        return folders(components[1]).install.appendingPathComponent(relative)
    }

    /// Every regular file under a directory, by its path relative to it.
    private static func regularFiles(under root: URL, fileManager: FileManager) -> [(String, URL)] {
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        var found: [(String, URL)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            found.append((String(path.dropFirst(prefix.count)), url))
        }
        return found.sorted { $0.0 < $1.0 }
    }
}
