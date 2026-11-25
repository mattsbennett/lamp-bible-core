import Foundation
import Testing
@testable import LampModuleKit

/// `Documentation/decisions/0012`: a pass holds a file open and asks it
/// everything, rather than resolving a path once per question.
struct LampSyncOpenFileTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-open-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func answersTheSameAsAskingThePathWould() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        let body = Data(String(repeating: "A lamp unto my feet. ", count: 50_000).utf8)
        try body.write(to: file)

        let byPath = try LampFileIdentity(url: file)
        let digestByPath = try LampSyncContentRevision.digest(forFileAt: file)
        try LampSyncOpenFile.with(file) { open in
            #expect(open.isOrdinaryFile)
            let identity = try open.identity()
            let first = try open.digest()
            // Asked twice, because each answer seeks back to the start.
            let second = try open.digest()
            #expect(identity == byPath)
            #expect(first == digestByPath)
            #expect(second == LampSyncContentRevision.digest(for: body))
        }
    }

    /// Bigger than the read buffer, so the chunked read is exercised rather
    /// than a single read that happens to take everything.
    @Test func hashesAFileBiggerThanOneRead() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.lamp")
        var body = Data()
        for index in 0..<40 {
            body.append(Data(String(repeating: "\(index)", count: 32 * 1024).utf8))
        }
        try body.write(to: file)
        #expect(body.count > 1 << 18)

        let want = LampSyncContentRevision.digest(for: body)
        try LampSyncOpenFile.with(file) { open in
            let got = try open.digest()
            #expect(got == want)
        }
    }

    /// A symbolic link is refused at the open, so nothing it points at is
    /// ever read — which is the whole of `0010` done one layer lower.
    @Test func refusesASymbolicLink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("not-for-the-server.txt")
        try Data("the contents of another file".utf8).write(to: outside)
        let link = root.appendingPathComponent("link.lamp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let failure = #expect(throws: LampSyncOpenFile.Failure.self) {
            try LampSyncOpenFile.with(link) { try $0.digest() }
        }
        #expect(failure?.namesALink == true)
        #expect(failure?.namesAMissingFile == false)
    }

    @Test func tellsAMissingFileFromADirectory() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let gone = #expect(throws: LampSyncOpenFile.Failure.self) {
            try LampSyncOpenFile.with(root.appendingPathComponent("nothing.lamp")) {
                try $0.digest()
            }
        }
        #expect(gone?.namesAMissingFile == true)
        #expect(gone?.namesALink == false)

        // A directory opens, and says what it is.
        try LampSyncOpenFile.with(root) { #expect(!$0.isOrdinaryFile) }
    }

    /// A hard link is an ordinary file. The context store publishes nothing
    /// else, so refusing one would stop most of a workspace syncing.
    @Test func aHardLinkIsOrdinary() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let object = root.appendingPathComponent("object")
        try Data("shared bytes".utf8).write(to: object)
        let link = root.appendingPathComponent("context.md")
        try FileManager.default.linkItem(at: object, to: link)

        let want = LampSyncContentRevision.digest(for: Data("shared bytes".utf8))
        try LampSyncOpenFile.with(link) { open in
            #expect(open.isOrdinaryFile)
            let got = try open.digest()
            #expect(got == want)
        }
    }

    /// A named pipe with nobody writing to it does not stop the pass.
    ///
    /// An ordinary `open` of one waits until somebody writes, which for a
    /// pass that expected a file is for ever. `O_NONBLOCK` makes opening
    /// answer, and what is at the path is then reported like anything else
    /// that will not be published.
    @Test(.timeLimit(.minutes(1)))
    func doesNotWaitOnAPipeNobodyIsWriting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appendingPathComponent("waiting.lamp")
        #expect(pipe.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0)

        try LampSyncOpenFile.with(pipe) { open in
            #expect(!open.isOrdinaryFile)
            #expect(throws: LampSyncOpenFile.Failure.notAnOrdinaryFile) { try open.digest() }
        }
    }

    /// A character device is not read to the end of itself, because it has
    /// none. `/dev/zero` would be read until the disk filled.
    @Test(.timeLimit(.minutes(1)))
    func refusesToReadADeviceThatNeverEnds() throws {
        let device = URL(fileURLWithPath: "/dev/zero")
        try LampSyncOpenFile.with(device) { open in
            #expect(!open.isOrdinaryFile)
            #expect(throws: LampSyncOpenFile.Failure.notAnOrdinaryFile) { try open.digest() }
        }
        // And the gather reports it rather than hanging, where one is
        // somehow offered as a candidate.
        let described = LampSyncLocalFiles.describe([
            LampSyncLocalFiles.Candidate(path: "Translations/x.lamp", kind: .module(.translations), url: device),
        ])
        #expect(described.files.isEmpty)
        #expect(described.unreadable.count == 1)
    }

    @Test func copiesTheBytesItWasOpenedOn() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        let body = Data(String(repeating: "Thy word is a lamp. ", count: 40_000).utf8)
        try body.write(to: file)
        let copy = root.appendingPathComponent("copy.lamp")

        try LampSyncOpenFile.with(file) { try $0.copy(into: copy) }

        let copied = try Data(contentsOf: copy)
        #expect(copied == body)
        // A separate file, not a second name for the same one: a clone shares
        // its bytes until one side is written, but it is its own inode.
        let copyPlace = try LampFileIdentity(url: copy).place
        let filePlace = try LampFileIdentity(url: file).place
        #expect(copyPlace != filePlace)
    }

    /// The read-and-write fallback, for a destination a clone cannot reach —
    /// another volume, or a filesystem without clones. Forced here by
    /// copying twice over: the second finds the destination already there,
    /// which the clone refuses, and must not fall back into appending.
    @Test func copyRefusesADestinationThatExists() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try Data("the body".utf8).write(to: file)
        let copy = root.appendingPathComponent("copy.lamp")
        try LampSyncOpenFile.with(file) { try $0.copy(into: copy) }

        #expect(throws: LampSyncOpenFile.Failure.self) {
            try LampSyncOpenFile.with(file) { try $0.copy(into: copy) }
        }
        let kept = try Data(contentsOf: copy)
        #expect(kept == Data("the body".utf8))
    }

    /// Replacing the file at the path after it is open changes nothing: the
    /// descriptor holds the file, not the name.
    @Test func keepsTheFileItOpenedWhenThePathIsReplaced() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("module.lamp")
        try Data("as opened".utf8).write(to: file)
        let copy = root.appendingPathComponent("copy.lamp")

        let asOpened = LampSyncContentRevision.digest(for: Data("as opened".utf8))
        try LampSyncOpenFile.with(file) { open in
            try FileManager.default.removeItem(at: file)
            try Data("put there afterwards".utf8).write(to: file)

            let got = try open.digest()
            #expect(got == asOpened)
            try open.copy(into: copy)
        }
        let copied = try Data(contentsOf: copy)
        #expect(copied == Data("as opened".utf8))
    }

    // MARK: - The verified read, for callers outside this module

    @Test func aVerifiedReadNamesTheFileItHashed() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf")
        try Data("the bytes".utf8).write(to: file)

        let read = try LampVerifiedFileRead.read(file)
        #expect(read.digest == LampSyncContentRevision.digest(for: Data("the bytes".utf8)))
        #expect(read.identity == (try LampFileIdentity(url: file)))
    }

    /// The Mac deletes a source on the strength of this answer, so it refuses
    /// anything that is not a plain file rather than hashing what a link
    /// points at or treating a folder as nothing.
    @Test func aVerifiedReadRefusesALinkAndAFolder() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.pdf")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(throws: LampVerifiedFileRead.Failure.notAnOrdinaryFile) {
            try LampVerifiedFileRead.read(link)
        }
        #expect(throws: LampVerifiedFileRead.Failure.notAnOrdinaryFile) {
            try LampVerifiedFileRead.read(folder)
        }
    }

    /// A file rewritten at the same size with its date put back is noticed,
    /// by the change time and by nothing else (`decisions/0007`).
    ///
    /// The Mac deletes a reader's source when a verified read still names
    /// it, so a comparison that ignored the change time — tempting, because
    /// unlinking a hard-linked twin moves it too — would delete bytes the
    /// server has never seen.
    @Test func afileRewrittenWithItsDatePutBackIsNotTheSameFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf")
        try Data("first".utf8).write(to: file)
        let before = try LampFileIdentity(url: file)
        // The exact timespecs, not a `Date`: a `Date` keeps microseconds, so
        // putting one back moves the modification time by the remainder and
        // the file is noticed for the wrong reason.
        var original = stat()
        #expect(stat(file.path, &original) == 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("other".utf8))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)

        let after = try LampFileIdentity(url: file)
        #expect(before.size == after.size, "same size")
        #expect(before.inode == after.inode, "same file")
        // The date really is back, to the nanosecond — so what tells them
        // apart below is the change time and only that.
        #expect(before.modifiedSeconds == after.modifiedSeconds)
        #expect(before.modifiedNanoseconds == after.modifiedNanoseconds)
        #expect(before.changedSeconds != after.changedSeconds
            || before.changedNanoseconds != after.changedNanoseconds)
        #expect(before != after, "and still noticed")
    }

    @Test func aWriteInPlaceIsNotTheSameBytes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf")
        try Data("first".utf8).write(to: file)
        let before = try LampFileIdentity(url: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("second, and longer".utf8))
        try handle.close()

        let after = try LampFileIdentity(url: file)
        #expect(before.inode == after.inode, "the same file, written over")
        #expect(before != after)
    }

    /// The read says whether its identity can be trusted, from the volume the
    /// file was read on. The test volume is the build machine's APFS one.
    @Test func aVerifiedReadSaysWhetherItsIdentityCanBeTrusted() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf")
        try Data("x".utf8).write(to: file)

        let read = try LampVerifiedFileRead.read(file)
        #expect(
            read.identityIsTrusted
                == LampSyncIdentityTrust.trustsIdentity(ofVolumeAt: root),
            "the same answer the gather's own digest cache gets for that volume"
        )
    }

    /// A socket is not an ordinary file, though it refuses to open with an
    /// errno that says nothing of the kind.
    @Test func aVerifiedReadCallsASocketNotAfile() throws {
        // A short path: a socket's address has room for 104 bytes.
        let root = URL(fileURLWithPath: "/tmp/lamp-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)

        #expect(throws: LampVerifiedFileRead.Failure.notAnOrdinaryFile) {
            try LampVerifiedFileRead.read(URL(fileURLWithPath: path))
        }
    }
}
