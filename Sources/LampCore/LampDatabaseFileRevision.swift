import Foundation
import LampModuleKit

/// A local cache invalidation token, not a content digest. ctime catches edits
/// even when a writer preserves size and restores mtime; inode catches atomic
/// replacement. Include the WAL because its commits can leave the main file alone.
struct LampDatabaseFileRevision: Codable, Equatable, Sendable {
    /// `LampFileIdentity`, under the names this has always serialized with:
    /// the Strong's fingerprint cache keys on `serialized()`, so the JSON is
    /// a stored format and must not move.
    private struct File: Codable, Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(url: URL) throws {
            let identity = try LampFileIdentity(url: url)
            device = identity.device
            inode = identity.inode
            size = identity.size
            modifiedSeconds = identity.modifiedSeconds
            modifiedNanoseconds = identity.modifiedNanoseconds
            changedSeconds = identity.changedSeconds
            changedNanoseconds = identity.changedNanoseconds
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
        try LampFileIdentity(url: url).place
    }

    func serialized() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Which file is at a path, by device and inode, whatever it holds.
struct LampDatabaseFileIdentity: Equatable {
    let device: Int64
    let inode: UInt64

    init(_ identity: (device: Int64, inode: UInt64)) {
        device = identity.device
        inode = identity.inode
    }
}
