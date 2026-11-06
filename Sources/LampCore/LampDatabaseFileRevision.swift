import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A local cache invalidation token, not a content digest. ctime catches edits
/// even when a writer preserves size and restores mtime; inode catches atomic
/// replacement. Include the WAL because its commits can leave the main file alone.
struct LampDatabaseFileRevision: Codable, Equatable, Sendable {
    private struct File: Codable, Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(url: URL) throws {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
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
    }

    private let database: File
    private let wal: File?

    init(url: URL) throws {
        database = try File(url: url)
        wal = try? File(url: URL(fileURLWithPath: url.path + "-wal"))
    }

    /// Which file is at `url`, by device and inode, whatever it holds.
    static func identity(of url: URL) throws -> (device: Int64, inode: UInt64) {
        let file = try File(url: url)
        return (file.device, file.inode)
    }

    func serialized() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
