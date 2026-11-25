import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A file a pass is holding open, so that everything it needs to know comes
/// from the one file rather than from several resolutions of a path.
///
/// `Documentation/decisions/0012`. A pass used to ask a path what it held, open
/// it to hash it, and open it again to copy it — three walks of the same
/// directories, which a reviewer found three different ways of disagreeing.
/// What is here instead is one `open`, and the identity, the kind of file and
/// the bytes all taken from that descriptor.
///
/// Two things it does **not** do, both written down in `0012`:
///
/// - `O_NOFOLLOW` refuses a symbolic link as the *last* component only. A
///   directory on the way replaced between a caller's two calls is not caught
///   by this; catching it needs `openat` relative to a descriptor on the
///   library root, which needs a refusal the plan can carry.
/// - The copy it writes is a path afterwards, read by the store and by the
///   read-back confirmation. It is in the pass's own scratch directory, which
///   is out of the library but not out of reach of another process of the same
///   user.
struct LampSyncOpenFile {
    private let descriptor: Int32
    private let url: URL

    /// Opens `url` and hands it to `body`, closing it afterwards however that
    /// ends.
    ///
    /// Synchronous on purpose. Both callers — `LampSyncLocalFiles.describe`
    /// and the upload loop — are done with the file before they await
    /// anything, so nothing has to hold a descriptor across a suspension.
    /// The descriptor is closed when `body` returns, so a `LampSyncOpenFile`
    /// that escapes the closure holds a number the system is free to give to
    /// another file — at which point it would answer about that one. The type
    /// is **internal** for that reason: the two callers that want it are in
    /// this module, and an escape hatch nobody needs is not worth making
    /// public. A `~Copyable` value with a closing `deinit` would enforce it,
    /// and costs the testing macros their view of the value
    /// (`Documentation/decisions/0012`).
    /// - Parameter followingLinks: whether to open what a symbolic link
    ///   points at. **A gather must**, and an upload must not.
    ///
    ///   Refusing a link looks like the safer default and is not. A gather
    ///   that refuses one leaves the path out of the plan's locals, which
    ///   reads as "this client does not hold it" — so the plan schedules a
    ///   download and the install writes the server's bytes *through* the
    ///   link, into whatever it points at. That is worse than publishing it,
    ///   and it is `0010`'s rejection of refusing in `describe`. The place a
    ///   refusal is safe is the upload, where it is a reported failure and
    ///   nothing else follows from it.
    static func with<T>(
        _ url: URL,
        followingLinks: Bool = false,
        _ body: (LampSyncOpenFile) throws -> T
    ) throws -> T {
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw Failure.cannotBeOpened(errno: EINVAL) }
            // `O_NONBLOCK`, so that opening is not where this waits. A
            // named pipe with no writer blocks an ordinary open for as long
            // as nobody writes to it — and a pass that met one where it
            // expected a file would stop there, for ever, rather than
            // reporting that the path holds something it will not publish.
            // On a regular file the flag changes nothing.
            let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followingLinks ? 0 : O_NOFOLLOW)
            let opened = open(path, flags)
            guard opened >= 0 else { throw Failure.cannotBeOpened(errno: errno) }
            return opened
        }
        let file = LampSyncOpenFile(descriptor: descriptor, url: url)
        defer { close(descriptor) }
        return try body(file)
    }

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    /// Which file this is, from the descriptor rather than from the path.
    func identity() throws -> LampFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw Failure.cannotBeRead(errno: errno)
        }
        return LampFileIdentity(info)
    }

    /// What `fstatfs` calls the filesystem this file is on — from the
    /// descriptor, so it is the volume the bytes were read from, not whatever
    /// is mounted at the path by the time anyone asks.
    func filesystemName() -> String? {
        #if canImport(Darwin)
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).lowercased()
        }
        #else
        return nil
        #endif
    }

    /// Whether this is an ordinary file — not a directory, a socket or a
    /// device. A symbolic link never gets this far: `O_NOFOLLOW` refuses one
    /// at `open`.
    ///
    /// A hard link **is** ordinary. A workspace's context files are links
    /// into a store of content-addressed objects, so a published file whose
    /// link count is above one is normal.
    var isOrdinaryFile: Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// SHA-256 of this file's bytes, read from the descriptor.
    ///
    /// Read rather than mapped. A mapping of a file that is truncated under it
    /// raises SIGBUS and takes the process with it, and since `0008` these are
    /// live files in the library that a pane or an agent may be writing; a
    /// read that runs out of file is a short read.
    func digest() throws -> String {
        var hash = SHA256()
        try eachRunOfBytes { bytes in hash.update(bufferPointer: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the whole file from the start, handing each run of bytes to
    /// `take`.
    ///
    /// The buffer is allocated once per call, uninitialised, and no bigger
    /// than the file. Zeroing a fixed 256 KB for each of fourteen thousand
    /// candidates — most of them a few kilobytes — cost four times what
    /// mapping them had, which is what the first version of this did.
    private func eachRunOfBytes(_ take: (UnsafeRawBufferPointer) throws -> Void) throws {
        // What it is, before anything is asked of it. Nothing but an ordinary
        // file is read: a character device never reaches the end of itself —
        // `/dev/zero` would be read until the disk filled or the pass was
        // killed — a pipe cannot be seeked at all, and a directory read is an
        // error on some filesystems and a surprise on others. Asked first so
        // that what comes back names the thing that is wrong, rather than
        // whichever syscall happened to refuse first.
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw Failure.cannotBeRead(errno: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notAnOrdinaryFile }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw Failure.cannotBeRead(errno: errno)
        }
        let size = Int(clamping: info.st_size)
        let capacity = max(1, min(size == 0 ? 1 : size, 1 << 18))
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }
        while true {
            let count = read(descriptor, buffer.baseAddress, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw Failure.cannotBeRead(errno: errno)
            }
            try take(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
    }

    /// Copies this file's bytes to `destination`, which must not exist.
    ///
    /// Cloned where the filesystem can, which on APFS moves no bytes. A clone
    /// of an open regular file cannot come out as anything else, which is the
    /// point: a path that changed under the copy cannot make the copy
    /// something other than this file.
    func copy(into destination: URL) throws {
        let cloned = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            #if canImport(Darwin)
            return fclonefileat(descriptor, AT_FDCWD, path, 0)
            #else
            return -1
            #endif
        }
        if cloned == 0 { return }

        // No clone: another volume, or a filesystem without them.
        let out = try destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw Failure.cannotBeWritten(errno: EINVAL) }
            let opened = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard opened >= 0 else { throw Failure.cannotBeWritten(errno: errno) }
            return opened
        }
        defer { close(out) }
        try eachRunOfBytes { bytes in
            var written = 0
            while written < bytes.count {
                let wrote = write(out, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard wrote > 0 else {
                    if errno == EINTR { continue }
                    throw Failure.cannotBeWritten(errno: errno)
                }
                written += wrote
            }
        }
    }

    enum Failure: Error, Equatable {
        case cannotBeOpened(errno: Int32)
        case cannotBeRead(errno: Int32)
        case cannotBeWritten(errno: Int32)
        /// The path holds something a pass will not publish: a directory, a
        /// socket, a device. A symbolic link never reaches this — it is
        /// refused at the open, where `followingLinks` is false.
        case notAnOrdinaryFile

        /// Whether this says the file is not there, as against there and
        /// unreadable. A pass reports the first as a file that changed under
        /// it and the second as a failure.
        var namesAMissingFile: Bool {
            switch self {
            case .cannotBeOpened(let code): code == ENOENT || code == ENOTDIR
            case .cannotBeRead, .cannotBeWritten, .notAnOrdinaryFile: false
            }
        }

        /// Whether this says the path holds something a pass will not
        /// publish: a symbolic link, which `O_NOFOLLOW` refuses with `ELOOP`.
        var namesALink: Bool {
            switch self {
            case .cannotBeOpened(let code): code == ELOOP
            case .cannotBeRead, .cannotBeWritten, .notAnOrdinaryFile: false
            }
        }

        /// Whether this says the path holds something other than an ordinary
        /// file — a link included, which is the same answer to a pass.
        var namesSomethingUnpublishable: Bool {
            self == .notAnOrdinaryFile || namesALink
        }
    }
}

/// What one open of a file said about it: which file it was, and the digest
/// of its bytes — for a caller outside this module that is about to act on
/// the answer.
///
/// The Mac deletes a reader's source on the strength of a digest matching
/// what it uploaded. Hashing a path and then asking the path who it is are
/// two resolutions that can name two files, which is how a review found it
/// binding one file's verified bytes to another's identity. Both come from a
/// single descriptor here (`Documentation/decisions/0012`).
///
/// The descriptor itself stays inside this module, for `0012`'s reason: one
/// that escapes its closure names whatever the system gives the number to
/// next. Only the answer leaves, and it can only be made by reading —
/// there is no public initialiser.
public struct LampVerifiedFileRead: Equatable, Sendable {
    public let identity: LampFileIdentity
    public let digest: String
    /// Whether this file's identity can be trusted to say its bytes have not
    /// changed since — `LampSyncIdentityTrust`, `decisions/0007`.
    ///
    /// A caller that will act on the identity alone later, as the Mac's
    /// offload does when it deletes a source it read earlier, must not where
    /// this is false. On exFAT there is no change time in the format, and a
    /// share can mirror the write time into it, so a file rewritten at the
    /// same size with its date put back keeps an identity that matches.
    public let identityIsTrusted: Bool

    public enum Failure: Error, Equatable {
        /// Not an ordinary file, or a symbolic link, or not there.
        case notAnOrdinaryFile
        /// Written to while it was being read: the bytes hashed are not the
        /// bytes of any one moment.
        case changedWhileRead
        case unreadable
    }

    /// What a path that would not open holds, asked without following a link.
    ///
    /// Not there, or not a regular file: not an ordinary file. A regular file,
    /// or one whose type cannot be learned because a folder on the way denies
    /// it: unreadable — the path may well hold a source the process is not
    /// allowed to see, and calling that "not a file" would let a caller treat
    /// it as gone.
    static func whyItWouldNotOpen(_ url: URL) -> Failure {
        do {
            _ = try LampFileIdentity(regularFileAt: url)
            return .unreadable
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ENOENT, ENOTDIR, EFTYPE: return .notAnOrdinaryFile
            default: return .unreadable
            }
        } catch {
            return .unreadable
        }
    }

    /// Opens `url` once, without following a link, and reads its identity
    /// and digest from that descriptor.
    ///
    /// The identity is taken either side of the read and must agree in
    /// full — change time included — so the digest is of the bytes the
    /// identity names rather than of a file rewritten part way through.
    public static func read(_ url: URL) throws -> LampVerifiedFileRead {
        do {
            return try LampSyncOpenFile.with(url, followingLinks: false) { file in
                guard file.isOrdinaryFile else { throw Failure.notAnOrdinaryFile }
                let before = try file.identity()
                let digest = try file.digest()
                let after = try file.identity()
                // The whole identity, change time included. `0007`: a file
                // replaced at the same size with its date put back is noticed
                // by the change time, and nothing else will notice it.
                guard before == after else { throw Failure.changedWhileRead }
                return LampVerifiedFileRead(
                    identity: before,
                    digest: digest,
                    identityIsTrusted: LampSyncIdentityTrust.trustsIdentity(
                        filesystemNamed: file.filesystemName()
                    )
                )
            }
        } catch let failure as Failure {
            throw failure
        } catch LampSyncOpenFile.Failure.notAnOrdinaryFile {
            throw Failure.notAnOrdinaryFile
        } catch LampSyncOpenFile.Failure.cannotBeOpened {
            // Asked of the path, without following a link, rather than read
            // from the errno: a socket refuses to open with `EOPNOTSUPP`, a
            // link with `ELOOP`, and the list of errnos that mean "not a
            // file" is not one to keep by hand. A regular file that would not
            // open — no permission, no descriptors left — is unreadable, which
            // a caller must not mistake for one that is not there.
            throw Self.whyItWouldNotOpen(url)
        } catch {
            throw Failure.unreadable
        }
    }
}
