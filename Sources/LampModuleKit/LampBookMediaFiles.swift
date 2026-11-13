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
    ///
    /// `Media/<book>` is left out for a book whose ID names one of the
    /// library's own media folders: a book called `Books` would otherwise
    /// read every book's pictures as its own, and one called `Notes` every
    /// note's.
    public static func libraryFolders(libraryRootURL: URL, moduleID: String) -> Folders {
        var paths = ["Media/Modules/\(moduleID)", "Media/Books/\(moduleID)"]
        if !reservedMediaFolders.contains(moduleID.lowercased()) {
            paths.append("Media/\(moduleID)")
        }
        paths.append("Modules/\(moduleID)/media")
        let read = paths.map { libraryRootURL.appendingPathComponent($0, isDirectory: true) }
        return Folders(read: read, install: read[1])
    }

    /// The folders under a library's `Media` that are not one book's.
    private static let reservedMediaFolders: Set<String> =
        Set(["books", "modules"] + LampMediaScope.allCases.map { $0.folder.lowercased() })

    /// Where, inside a book's folder, the picture a book names is kept, or
    /// nil for a name no device can keep and publish.
    ///
    /// A book names its pictures as written in its metadata, which may be
    /// percent-escaped: the file is kept under the name decoded. A name that
    /// climbs out of the folder, or that decodes to one sync cannot carry — a
    /// hidden file, say — is refused here, so that an import refuses it too
    /// rather than keep a picture that never reaches another device.
    public static func relativePath(forFilename filename: String) -> String? {
        guard let relative = LampPortableBookJSON.safeRelativeMediaPath(filename),
              isPublishable(relative) else { return nil }
        return relative
    }

    /// Where a picture a book names is put when it is brought in with the
    /// book — an import, or a download by name — or nil for a name
    /// `relativePath(forFilename:)` refuses.
    public static func installURL(
        forFilename filename: String,
        in folders: Folders,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let relative = relativePath(forFilename: filename) else { return nil }
        let url = folders.install.appendingPathComponent(relative)
        return isReachedWithoutLinks(url, from: folders.install, fileManager: fileManager) ? url : nil
    }

    /// Where a picture a book names is, or nil when it is nowhere here.
    ///
    /// A web address is its own answer. A relative path that climbs out of
    /// the book's folders, or names nothing, is no picture, and neither is
    /// one reached through a link: gathering skips links, and the reader must
    /// not show what a sync would not publish.
    ///
    /// The name decoded is looked for first, as `relativePath(forFilename:)`
    /// keeps it. Then the name as written: a phone kept its pictures under
    /// the metadata's own spelling, escapes and all, before the name was
    /// decoded, and those files are its only copy.
    public static func url(
        for filename: String,
        in folders: Folders,
        fileManager: FileManager = .default
    ) -> URL? {
        if let remote = URL(string: filename),
           let scheme = remote.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return remote
        }
        var names: [String] = []
        if let decoded = relativePath(forFilename: filename) { names.append(decoded) }
        if let literal = literalRelativePath(filename), !names.contains(literal) { names.append(literal) }
        for root in folders.read {
            for name in names {
                let url = root.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: url.path),
                      isReachedWithoutLinks(url, from: root, fileManager: fileManager) else { continue }
                return url
            }
        }
        return nil
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
            for root in folders(moduleID).read
            where isReachedWithoutLinks(root, from: root, fileManager: fileManager) {
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

    /// The books whose pictures a pass publishes: the device's own books, and
    /// those the server already holds pictures for, so a picture already
    /// there keeps its book.
    ///
    /// Less any ID this device holds as another kind of module. A book
    /// deleted elsewhere can leave its pictures on the server, and a
    /// commentary here under the same ID would otherwise have its own
    /// pictures published as that book's.
    public static func publishedBookModuleIDs(
        books: Set<String>,
        otherModules: Set<String>,
        remotePaths: some Sequence<String>
    ) -> Set<String> {
        books.union(bookModuleIDs(inRemotePaths: remotePaths).subtracting(otherModules))
    }

    /// The books a set of server paths holds pictures for.
    public static func bookModuleIDs(inRemotePaths paths: some Sequence<String>) -> Set<String> {
        Set(paths.compactMap { path in
            guard LampSyncFolderLayout.kind(of: path) == .bookMedia else { return nil }
            return path.split(separator: "/").dropFirst().first.map(String.init)
        })
    }

    /// Where a picture that arrives at `remotePath` is put, or nil for a path
    /// that is not a book's picture, or one that would be written through a
    /// link into somewhere else.
    ///
    /// The path is taken as it is, not decoded: it is the name the file had
    /// where it was gathered, and two files whose names differ only by an
    /// escape (`Figure%20A.png` and `Figure A.png`) are two files.
    public static func installURL(
        forRemotePath remotePath: String,
        folders: (String) -> Folders,
        fileManager: FileManager = .default
    ) -> URL? {
        // `kind(of:)` has checked every component already: none empty, none
        // hidden or climbing (`..` is hidden), none with a backslash.
        guard LampSyncFolderLayout.kind(of: remotePath) == .bookMedia else { return nil }
        let components = remotePath.split(separator: "/").map(String.init)
        guard components.count >= 3 else { return nil }
        let install = folders(components[1]).install
        let url = install.appendingPathComponent(components.dropFirst(2).joined(separator: "/"))
        return isReachedWithoutLinks(url, from: install, fileManager: fileManager) ? url : nil
    }

    /// A name as written, if it is a safe, publishable path without decoding.
    private static func literalRelativePath(_ filename: String) -> String? {
        let components = filename.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !filename.hasPrefix("/"), !components.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        let relative = components.joined(separator: "/")
        return isPublishable(relative) ? relative : nil
    }

    /// Whether sync can carry a file at this path inside a book's folder.
    private static func isPublishable(_ relative: String) -> Bool {
        (try? LampSyncFolderLayout.bookMediaPath(moduleID: "book", path: relative)) != nil
    }

    /// Whether `url` lies under `root` through real folders alone: neither
    /// the root nor anything between it and `url` (`url` included) a link. A
    /// link could have a picture shown from, or written into, a folder that
    /// is not this book's.
    static func isReachedWithoutLinks(_ url: URL, from root: URL, fileManager: FileManager) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        func isLink(_ path: String) -> Bool {
            (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
        }
        var current = rootPath
        if isLink(current) { return false }
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            current += "/" + component
            if isLink(current) { return false }
        }
        return true
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
