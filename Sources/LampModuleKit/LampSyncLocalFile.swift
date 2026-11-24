import Foundation

/// One local file as a sync pass sees it: where it belongs on the server,
/// where its bytes are now, and what they hash to.
///
/// Always a file on disk rather than bytes in hand. A pass publishes with
/// `write(fileAt:to:condition:)` and digests through a mapping, so nothing
/// here holds a module body in memory — which is what stops a library-sized
/// pass from being killed for it.
public struct LampSyncLocalFile: Equatable, Sendable {
    public let path: String
    public let kind: LampSyncFileKind
    public let url: URL
    public let digest: String

    public init(
        path: String,
        kind: LampSyncFileKind,
        url: URL,
        digest: String
    ) {
        self.path = path
        self.kind = kind
        self.url = url
        self.digest = digest
    }
}

/// Gathers what a client holds, in the form `LampSyncFilePlan.plan` reads.
///
/// A pass asks the library what it has, turns each thing into a remote path,
/// and hands the plan a digest per path. The plan then decides; nothing here
/// decides anything. Each app extends this with its own enumeration: where it
/// keeps its modules, collections, attachments, pictures, decks and
/// workspaces is the part each answers for itself.
public enum LampSyncLocalFiles {
    /// A file to describe: its remote path, what kind of thing it is, and
    /// where its bytes are.
    public struct Candidate: Equatable, Sendable {
        public let path: String
        public let kind: LampSyncFileKind
        public let url: URL

        public init(path: String, kind: LampSyncFileKind, url: URL) {
            self.path = path
            self.kind = kind
            self.url = url
        }
    }

    /// Where a candidate's bytes turned out not to be readable. A pass reports
    /// these rather than silently publishing a shorter library.
    public struct Unreadable: Equatable, Sendable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public struct Described: Equatable, Sendable {
        public var files: [LampSyncLocalFile] = []
        public var unreadable: [Unreadable] = []
    }

    /// Digests each candidate by reading its file — unless a cache can say
    /// the file has not changed since it was last read.
    ///
    /// Never by comparing a modification date, which is the shortcut
    /// `Documentation/decisions/0001` refused and `0007` still refuses: a
    /// file replaced at the same size with its date preserved — a restore,
    /// `cp -p`, `rsync -t` — would be skipped and never uploaded again.
    ///
    /// What `0007` allows instead is a digest kept against the file's whole
    /// identity, `st_ctime` and inode included, and only where three things
    /// hold: the filesystem maintains that identity
    /// (`LampSyncIdentityTrust` — the caller decides, and passes no cache
    /// where it does not), the kind is one whose bytes are worth it
    /// (`keepsDigestAgainstIdentity`), and the cache lives no longer than
    /// the process. With no cache this reads every file, as it always did.
    ///
    /// A digest is still SHA-256 of the bytes at that path, whichever way it
    /// was obtained; that is what the plan is given and what the model
    /// assumes.
    public static func describe(
        _ candidates: [Candidate],
        fileManager: FileManager = .default,
        digests: LampSyncDigestCache? = nil
    ) -> Described {
        var described = Described()
        for candidate in candidates {
            // One stat answers both questions: whether the file is there, and
            // which file it is.
            guard let identity = try? LampFileIdentity(url: candidate.url) else {
                described.unreadable.append(
                    Unreadable(path: candidate.path, reason: "its file could not be read")
                )
                continue
            }
            let caching = digests.flatMap {
                candidate.kind.keepsDigestAgainstIdentity ? $0 : nil
            }
            let digest: String
            if let held = caching?.digest(at: candidate.url, identity: identity) {
                digest = held
            } else if let read = try? LampSyncContentRevision.digest(forFileAt: candidate.url) {
                digest = read
                caching?.remember(read, at: candidate.url, identity: identity)
            } else {
                described.unreadable.append(
                    Unreadable(path: candidate.path, reason: "its file could not be read")
                )
                continue
            }
            described.files.append(LampSyncLocalFile(
                path: candidate.path,
                kind: candidate.kind,
                url: candidate.url,
                digest: digest
            ))
        }
        return described
    }

    /// Each described file in the form the plan reads, with `savedAt` looked
    /// up per path — a module file has no save time of its own, so a caller
    /// with nothing better passes nil and lets the manifest's own times rule.
    public static func locals(
        _ files: [LampSyncLocalFile],
        records: LampSyncFileRecords,
        source: String,
        savedAt: (String) -> Int64? = { _ in nil }
    ) -> [LampSyncFilePlan.Local] {
        files.map {
            records.local($0.path, in: source, digest: $0.digest, savedAt: savedAt($0.path))
        }
    }
}
