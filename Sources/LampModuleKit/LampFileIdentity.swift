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

    /// The identity of the regular file **at** `url`, without following a
    /// link there; throws for anything else.
    ///
    /// For a caller about to unlink the path. `init(url:)` follows a link,
    /// so a link put where a checked file was would answer with its target's
    /// identity — and a link into the object store a source came from would
    /// answer with the source's own. A folder is refused too: what the caller
    /// checked was a file.
    ///
    /// Refusing here rather than storing the file's type: this value is
    /// persisted in digest caches, and a new stored field would discard every
    /// one of them on the next read.
    public init(regularFileAt url: URL) throws {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) } ?? -1
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(EFTYPE),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        self.init(info)
    }

    /// Whether `other` names the same bytes as this: everything but the
    /// **change** time.
    ///
    /// A reader's sources are hard links into a store of content-addressed
    /// objects, so one workspace holding the same file twice holds two links
    /// to one inode — and unlinking either moves that inode's `ctime`. Full
    /// equality would read the survivor as replaced. Replacement still shows:
    /// a new file is a new inode, and a write in place moves the modification
    /// time or the size.
    public func namesSameBytes(as other: LampFileIdentity) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds
    }

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
        self.init(info)
    }

    /// From a `stat` a caller already has — one taken from a descriptor it is
    /// holding, rather than from a path it would have to resolve again
    /// (`LampSyncOpenFile`, `Documentation/decisions/0012`).
    init(_ info: stat) {
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
}
