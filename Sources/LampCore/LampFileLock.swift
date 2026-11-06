import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An exclusive lock that every process opening a library takes on the same
/// file: the app and each lamp-mcp share one. Held from `init` until
/// `unlock()`, or until it is released, and let go by the system if its holder
/// dies, so a crash never leaves it held. `flock` locks belong to an open
/// file, not a process, so two holders in one process exclude each other too.
final class LampFileLock {
    private var descriptor: Int32

    /// Waits for the lock for as long as another holder keeps it. On a
    /// filesystem that has no such locks, as some network shares don't, it
    /// holds nothing and the caller goes on as it did before there was one,
    /// rather than failing what used to work.
    init(url: URL) throws {
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) } ?? -1
        }
        guard opened >= 0 else { throw Self.error(errno, url) }
        var result: Int32
        repeat { result = flock(opened, LOCK_EX) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            close(opened)
            guard code == ENOTSUP || code == EOPNOTSUPP || code == ENOLCK else { throw Self.error(code, url) }
            descriptor = -1
            return
        }
        descriptor = opened
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }

    private static func error(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
