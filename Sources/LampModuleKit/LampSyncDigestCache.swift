import Foundation

/// Digests a pass has already taken, against the files they were taken from.
///
/// `Documentation/decisions/0007`, which supersedes `0001`. A pass used to
/// read every candidate's bytes every time — 2.43 GB/s, so seconds and a
/// whole library pulled through the page cache on a pass that runs every six
/// to ten seconds while someone writes.
///
/// Three things bound what this is allowed to answer, and all three are the
/// caller's to apply:
///
/// 1. **The filesystem.** Only where `LampSyncIdentityTrust` says an identity
///    means what it looks like.
/// 2. **The file being fixed at its path.** The kinds that always are — a
///    module file, a book picture, a deck image, a writing's or a note's
///    media — by `LampSyncFileKind.keepsDigestAgainstIdentity`; and, file by
///    file, the candidates an app says are, by
///    `LampSyncLocalFiles.Candidate.isFixedAtItsPath`, where one kind covers
///    both sorts and only the app can tell them apart
///    (`Documentation/decisions/0011`).
/// 3. **The process.** In memory, so the first pass after launch reads
///    everything. Nothing is written down, because across launches the
///    inode's namespace (`st_dev`) moves on every remount of an external
///    volume, and this would be new state in the one subsystem with a model.
///
/// What a pass hands the plan is unchanged either way: SHA-256 of the bytes at
/// that path.
public final class LampSyncDigestCache: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: (identity: LampFileIdentity, digest: String)] = [:]
    /// How many digests were answered from here rather than read, so a test
    /// and a measurement can tell.
    private var answered = 0
    /// How many files were read.
    private var read = 0
    /// The device whose files this cache will answer for, where its maker
    /// named one.
    ///
    /// The trust in `0007` is a property of a **filesystem**, and a caller
    /// decides it by asking what the library root sits on. A library can
    /// have another volume mounted inside it, and the files under that mount
    /// are on a filesystem nobody vouched for — so a cache made for an APFS
    /// library would otherwise answer for a file on an exFAT stick beneath
    /// it, where a replacement can keep the identity it reported. Caught by
    /// a Codex review of `0011`, which is what made a workspace file
    /// eligible at all.
    private let trustedDevice: Int64?

    /// - Parameter trustedDevice: the `st_dev` the caller checked. Files on
    ///   any other device are read rather than answered. Nil answers for
    ///   any device, which is for a caller with nothing mounted inside what
    ///   it is caching — a test, or the phone's own library.
    public init(trustedDevice: Int64? = nil) {
        self.trustedDevice = trustedDevice
    }

    /// Whether this cache will keep anything about a file with this
    /// identity. False for a file on a device its maker did not vouch for,
    /// so a caller can skip the work of offering one.
    public func keeps(_ identity: LampFileIdentity) -> Bool {
        trustedDevice == nil || identity.device == trustedDevice
    }

    /// The digest held for this file, if what is held was taken from the file
    /// as it now stands.
    public func digest(at url: URL, identity: LampFileIdentity) -> String? {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard trustedDevice == nil || identity.device == trustedDevice else { return nil }
        guard let held = digests[path], held.identity == identity else { return nil }
        answered += 1
        return held.digest
    }

    public func remember(_ digest: String, at url: URL, identity: LampFileIdentity) {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        read += 1
        guard trustedDevice == nil || identity.device == trustedDevice else { return }
        digests[path] = (identity, digest)
    }

    /// Forgets everything, for a caller whose library has moved under it.
    public func forgetEverything() {
        lock.lock()
        defer { lock.unlock() }
        digests = [:]
    }

    /// Digests answered from here, and files read, since this cache was made.
    public func counts() -> (answered: Int, read: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (answered, read)
    }
}
