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
/// 2. **The kind.** Only the kinds that are immutable at a path — a module
///    file, a book picture, a deck image, a writing's or a note's media.
///    `LampSyncFileKind.isImmutableAtItsPath` says which.
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

    public init() {}

    /// The digest held for this file, if what is held was taken from the file
    /// as it now stands.
    public func digest(at url: URL, identity: LampFileIdentity) -> String? {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard let held = digests[path], held.identity == identity else { return nil }
        answered += 1
        return held.digest
    }

    public func remember(_ digest: String, at url: URL, identity: LampFileIdentity) {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        read += 1
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
