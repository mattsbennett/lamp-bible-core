import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether a file's identity can be trusted to say that its bytes have not
/// changed, on the filesystem a library is sitting on.
///
/// `Documentation/decisions/0007`. A `LampFileIdentity` is only as good as the
/// filesystem behind it:
///
/// - **apfs, hfs** maintain `st_ctime` as the kernel's own and do not reuse
///   inode numbers — APFS allocates them from a monotonic counter, HFS+
///   recycles only after 2^32 — so identity equal means bytes equal.
/// - **exfat, msdos** have no change time in the format at all; the driver
///   synthesises one, and inode numbers come from the directory entry's
///   position, so a same-name replacement often reuses one. The key degrades
///   to size and modification date, which is exactly what `0001` refused.
/// - **smbfs, nfs** depend on the server. A Windows or Samba-on-ext4 server
///   maintains a change time; a share backed by exFAT cannot, and some
///   servers mirror the write time into it. The client cannot tell which, and
///   both cache attributes for seconds besides.
///
/// There is no capability bit for "maintains a change time", so the only
/// honest test is the filesystem's name. A list of what is known to be safe,
/// never a list of what is known to be unsafe: a filesystem nobody here has
/// thought about is read, not trusted.
public enum LampSyncIdentityTrust {
    /// The filesystems whose identities mean what this code needs them to.
    public static let trustedFilesystems: Set<String> = ["apfs", "hfs"]

    /// What `statfs` calls the filesystem holding `url`, or nil where it
    /// cannot be asked.
    public static func filesystemName(ofVolumeAt url: URL) -> String? {
        #if canImport(Darwin)
        var info = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { statfs($0, &info) } ?? -1
        }
        guard result == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { bytes in
            let name = bytes.prefix { $0 != 0 }
            return String(decoding: name, as: UTF8.self).lowercased()
        }
        #else
        return nil
        #endif
    }

    /// Whether a digest may be kept against a file's identity under `url`.
    ///
    /// A volume that cannot be asked is not trusted, so the answer where
    /// anything is uncertain is the behaviour `0001` required: read the file.
    public static func trustsIdentity(ofVolumeAt url: URL) -> Bool {
        trustsIdentity(filesystemNamed: filesystemName(ofVolumeAt: url))
    }

    /// The same question of a filesystem by name, so a test can ask it about
    /// a share or a memory card without one to hand.
    public static func trustsIdentity(filesystemNamed name: String?) -> Bool {
        guard let name else { return false }
        return trustedFilesystems.contains(name.lowercased())
    }
}
