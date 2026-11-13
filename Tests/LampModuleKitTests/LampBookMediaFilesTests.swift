import Foundation
import Testing
@testable import LampModuleKit

/// A book's pictures are not inside its module, so these files are a
/// library's only copy. One set of rules for every app, with each app's
/// folders handed in.
struct LampBookMediaFilesTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, at path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    /// The phone's folders: one per module, in its module media cache, which
    /// also holds commentaries' and notes' pictures.
    private func phoneFolders(_ cache: URL) -> (String) -> LampBookMediaFiles.Folders {
        { moduleID in
            let folder = cache.appendingPathComponent(moduleID, isDirectory: true)
            return LampBookMediaFiles.Folders(read: [folder], install: folder)
        }
    }

    @Test func aLibraryInstallsWhereItsReaderLooksSecond() {
        let root = URL(fileURLWithPath: "/library", isDirectory: true)
        let folders = LampBookMediaFiles.libraryFolders(libraryRootURL: root, moduleID: "atonement")
        #expect(folders.read.map(\.path) == [
            "/library/Media/Modules/atonement",
            "/library/Media/Books/atonement",
            "/library/Media/atonement",
            "/library/Modules/atonement/media",
        ])
        #expect(folders.install == folders.read[1], "what arrives is what the reader finds")
    }

    @Test func aPictureIsFoundInTheFirstFolderThatHasIt() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("old layout", at: "Media/Modules/a-book/images/cover.jpg", in: library)
        try write("synced", at: "Media/Books/a-book/images/cover.jpg", in: library)
        try write("synced", at: "Media/Books/a-book/plate.jpg", in: library)
        let folders = LampBookMediaFiles.libraryFolders(libraryRootURL: library, moduleID: "a-book")

        #expect(LampBookMediaFiles.url(for: "images/cover.jpg", in: folders)
            == library.appendingPathComponent("Media/Modules/a-book/images/cover.jpg"))
        #expect(LampBookMediaFiles.url(for: "plate.jpg", in: folders)
            == library.appendingPathComponent("Media/Books/a-book/plate.jpg"))
        #expect(LampBookMediaFiles.url(for: "missing.jpg", in: folders) == nil)
        #expect(LampBookMediaFiles.url(for: "../../secrets.txt", in: folders) == nil)
        #expect(LampBookMediaFiles.url(for: "https://example.com/image.jpg", in: folders)
            == URL(string: "https://example.com/image.jpg"))
    }

    /// Gathered from every folder the reader looks in, in its order, so what
    /// is published is what the reader would show.
    @Test func aBooksPicturesAreGatheredInTheReadersOrder() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("preferred", at: "Media/Modules/atonement/plates/one.jpg", in: library)
        try write("shadowed", at: "Media/Books/atonement/plates/one.jpg", in: library)
        try write("only here", at: "Media/Books/atonement/two.jpg", in: library)
        try write("legacy", at: "Modules/atonement/media/three.jpg", in: library)
        try write("another book", at: "Media/Books/ignored/four.jpg", in: library)

        let found = LampBookMediaFiles.outgoing(forBookModuleIDs: ["atonement"]) {
            LampBookMediaFiles.libraryFolders(libraryRootURL: library, moduleID: $0)
        }

        #expect(found.unplaceable.isEmpty)
        #expect(found.files.map(\.remotePath) == [
            "BookMedia/atonement/plates/one.jpg",
            "BookMedia/atonement/two.jpg",
            "BookMedia/atonement/three.jpg",
        ])
        #expect(try Data(contentsOf: #require(found.files.first).url) == Data("preferred".utf8))
    }

    /// The phone keeps every module's pictures in one cache. Only the books'
    /// go up as books': a commentary's picture published under `BookMedia`
    /// would be a picture no book has, on every device.
    @Test func anotherModulesPicturesInTheSameFolderAreNotABooks() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try write("a plate", at: "atonement/plate.jpg", in: cache)
        try write("a commentary's map", at: "nic-commentary/map.jpg", in: cache)

        let found = LampBookMediaFiles.outgoing(
            forBookModuleIDs: ["atonement"], folders: phoneFolders(cache)
        )

        #expect(found.files.map(\.remotePath) == ["BookMedia/atonement/plate.jpg"])
    }

    @Test func linksAndHiddenFilesAreNotPublished() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try write("a plate", at: "atonement/plate.jpg", in: cache)
        try write("finder", at: "atonement/.DS_Store", in: cache)
        try write("elsewhere", at: "outside/secret.jpg", in: cache)
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("atonement/link.jpg"),
            withDestinationURL: cache.appendingPathComponent("outside/secret.jpg")
        )

        let found = LampBookMediaFiles.outgoing(
            forBookModuleIDs: ["atonement"], folders: phoneFolders(cache)
        )

        #expect(found.files.map(\.remotePath) == ["BookMedia/atonement/plate.jpg"])
    }

    @Test func aPictureThatArrivesGoesToTheInstallFolder() {
        let library = URL(fileURLWithPath: "/library", isDirectory: true)
        let folders: (String) -> LampBookMediaFiles.Folders = {
            LampBookMediaFiles.libraryFolders(libraryRootURL: library, moduleID: $0)
        }
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/atonement/plates/one.jpg", folders: folders)?.path
            == "/library/Media/Books/atonement/plates/one.jpg")
        #expect(LampBookMediaFiles.installURL(forRemotePath: "NoteMedia/notes/1001001/a.jpg", folders: folders) == nil)
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/atonement/../x.jpg", folders: folders) == nil)
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/atonement", folders: folders) == nil)
    }

    /// A server path is the name the file had where it was gathered. Two
    /// files whose names differ by an escape are two files, and installing
    /// one must not replace the other.
    @Test func aServerPathIsInstalledAsItIsNotDecoded() {
        let library = URL(fileURLWithPath: "/library", isDirectory: true)
        let folders: (String) -> LampBookMediaFiles.Folders = {
            LampBookMediaFiles.libraryFolders(libraryRootURL: library, moduleID: $0)
        }
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/a/Figure%20A.png", folders: folders)?.path
            == "/library/Media/Books/a/Figure%20A.png")
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/a/Figure A.png", folders: folders)?.path
            == "/library/Media/Books/a/Figure A.png")
    }

    /// The phone kept a picture under the metadata's own spelling before the
    /// name was decoded. That file is its only copy, so it is still found.
    @Test func aPictureKeptUnderItsEscapedNameIsStillFound() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try write("old", at: "a/plates/Figure%201.png", in: cache)
        let folders = phoneFolders(cache)("a")
        #expect(LampBookMediaFiles.url(for: "plates/Figure%201.png", in: folders)
            == cache.appendingPathComponent("a/plates/Figure%201.png"))
        // The decoded name wins where both are kept.
        try write("new", at: "a/plates/Figure 1.png", in: cache)
        #expect(LampBookMediaFiles.url(for: "plates/Figure%201.png", in: folders)
            == cache.appendingPathComponent("a/plates/Figure 1.png"))
    }

    /// A book whose ID names one of the library's own media folders must not
    /// read that folder, every book's or every note's pictures, as its own.
    @Test(arguments: ["Books", "books", "Modules", "Notes", "Devotionals"])
    func aBookNamedAfterAMediaFolderDoesNotTakeItOver(_ moduleID: String) {
        let root = URL(fileURLWithPath: "/library", isDirectory: true)
        let folders = LampBookMediaFiles.libraryFolders(libraryRootURL: root, moduleID: moduleID)
        #expect(!folders.read.map(\.path).contains("/library/Media/\(moduleID)"))
        #expect(folders.install.path == "/library/Media/Books/\(moduleID)")
    }

    /// A book deleted elsewhere can leave its pictures on the server. A
    /// commentary here under the same ID does not publish its own as that
    /// book's.
    @Test func anotherKindOfModuleIsNotTakenForABookTheServerNames() {
        let ids = LampBookMediaFiles.publishedBookModuleIDs(
            books: ["atonement"],
            otherModules: ["study"],
            remotePaths: ["BookMedia/study/map.png", "BookMedia/creeds/cover.png"]
        )
        #expect(ids == ["atonement", "creeds"])
    }

    /// A name sync cannot carry is refused when the book is brought in, not
    /// kept as a picture that never reaches another device.
    @Test func aNameSyncCannotCarryIsRefusedOnTheWayIn() {
        let folders = LampBookMediaFiles.Folders(
            read: [URL(fileURLWithPath: "/cache/a", isDirectory: true)],
            install: URL(fileURLWithPath: "/cache/a", isDirectory: true)
        )
        #expect(LampBookMediaFiles.installURL(forFilename: "plates/Figure%201.png", in: folders)?.path
            == "/cache/a/plates/Figure 1.png")
        #expect(LampBookMediaFiles.installURL(forFilename: "%2Ecover.png", in: folders) == nil)
        #expect(LampBookMediaFiles.installURL(forFilename: ".cover.png", in: folders) == nil)
        #expect(LampBookMediaFiles.installURL(forFilename: "../x.png", in: folders) == nil)
        #expect(LampBookMediaFiles.relativePath(forFilename: "plates/a\\b.png") == nil)
    }

    /// Gathering skips links, so the reader and an install do not go through
    /// one either: a link could have one book's folder show, or receive,
    /// another's pictures.
    @Test func neitherTheReaderNorAnInstallGoesThroughALink() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try write("other book", at: "other/plates/map.jpg", in: cache)
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("a"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("a/plates"),
            withDestinationURL: cache.appendingPathComponent("other/plates")
        )
        let folders = phoneFolders(cache)
        #expect(LampBookMediaFiles.url(for: "plates/map.jpg", in: folders("a")) == nil)
        #expect(LampBookMediaFiles.installURL(forRemotePath: "BookMedia/a/plates/map.jpg", folders: folders) == nil)
        #expect(LampBookMediaFiles.installURL(forFilename: "plates/map.jpg", in: folders("a")) == nil)
        #expect(LampBookMediaFiles.outgoing(forBookModuleIDs: ["a"], folders: folders).files.isEmpty)
    }

    @Test func theServerSaysWhichBooksItHoldsPicturesFor() {
        #expect(LampBookMediaFiles.bookModuleIDs(inRemotePaths: [
            "BookMedia/atonement/plates/one.jpg",
            "BookMedia/atonement/two.jpg",
            "BookMedia/creeds/cover.png",
            "NoteMedia/notes/1001001/a.jpg",
            "Books/atonement.lamp",
        ]) == ["atonement", "creeds"])
    }
}
