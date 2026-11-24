import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Which file is at a path and what state it is in: device, inode, size, and
/// the modification and change times to the nanosecond.
///
/// A cache invalidation token, never a content digest. What makes it one is
/// `st_ctime`: on a local Darwin filesystem that is the kernel's own, set on
/// any change to the inode, and there is no call that sets it to a chosen
/// value — so a file rewritten in place at the same size with its
/// modification date put back still reads as changed, which a date alone
/// cannot catch. The inode catches an atomic replacement, and the device is
/// the inode's namespace.
///
/// Where that holds is a property of the filesystem, not of this type: exFAT
/// has no change time in its format and reuses directory-entry inode numbers,
/// and an SMB share may have a server that does not maintain one. Anything
/// deciding what to trust on the strength of this must ask what it is sitting
/// on first — see `LampSyncIdentityTrust` and
/// `Documentation/decisions/0007`.
public struct LampFileIdentity: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(url: URL) throws {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(info.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        changedSeconds = Int64(info.st_ctim.tv_sec)
        changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #endif
    }

    /// Where a file is, by device and inode, whatever it holds.
    public var place: (device: Int64, inode: UInt64) { (device, inode) }

    /// Whether `url` is an ordinary file — not a symbolic link, a directory,
    /// a socket or a device — without following a link to ask.
    ///
    /// Deliberately not a property of an identity. An identity is a cache
    /// token that can be written down, and this is a fact about a path at a
    /// moment that cannot be: an identity decoded from somewhere could only
    /// guess at it, and guessing either way would be wrong. Ask it of the
    /// file in front of you, which is what
    /// `Documentation/decisions/0010` does.
    ///
    /// A hard link **is** ordinary: a workspace's context files are links
    /// into a per-library store of content-addressed objects, so a published
    /// file with a link count above one is normal.
    public static func isOrdinaryFile(at url: URL) -> Bool {
        whatIs(at: url) == .ordinaryFile
    }

    /// What is at a path: an ordinary file, something else, or nothing.
    ///
    /// Three answers rather than two, because the two that are not an
    /// ordinary file mean opposite things to a pass. Nothing there is a file
    /// that has gone since the plan, which is no failure; something else is
    /// a file that will not be published, which is one.
    public static func whatIs(at url: URL) -> WhatIsAtAPath {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) } ?? -1
        }
        guard result == 0 else { return .nothing }
        return (info.st_mode & S_IFMT) == S_IFREG ? .ordinaryFile : .somethingElse
    }

    public enum WhatIsAtAPath: Sendable, Equatable {
        case ordinaryFile
        /// A symbolic link, a directory, a socket, a device.
        case somethingElse
        case nothing
    }
}
