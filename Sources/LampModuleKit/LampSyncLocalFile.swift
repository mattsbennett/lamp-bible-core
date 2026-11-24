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
    /// The app's word that nothing rewrites this file where it sits — see
    /// `LampSyncLocalFiles.Candidate.isFixedAtItsPath`.
    public let isFixedAtItsPath: Bool

    public init(
        path: String,
        kind: LampSyncFileKind,
        url: URL,
        digest: String,
        isFixedAtItsPath: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.url = url
        self.digest = digest
        self.isFixedAtItsPath = isFixedAtItsPath
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
        /// The app's word that nothing rewrites this file where it sits:
        /// what changes at this path arrives as a different file, or as
        /// nothing.
        ///
        /// Not "the bytes will not change" — a revision is deleted and
        /// replaced by compaction, which is the whole of `0009` — but "they
        /// will not change *under a reader*". A file like that may have its
        /// digest kept against its identity even where its kind says
        /// otherwise, and a pass refuses to publish it if the identity has
        /// moved since the gather. `Documentation/decisions/0011`.
        ///
        /// The kind cannot answer this for a workspace file, because one
        /// kind covers a revision, which is fixed, and a document staged
        /// into a fresh scratch directory every pass, which is not. The
        /// exporter chooses per file and so is the only thing that knows.
        /// False unless an app says otherwise; iOS writes a copy of
        /// everything it publishes and never says so.
        public let isFixedAtItsPath: Bool

        public init(
            path: String,
            kind: LampSyncFileKind,
            url: URL,
            isFixedAtItsPath: Bool = false
        ) {
            self.path = path
            self.kind = kind
            self.url = url
            self.isFixedAtItsPath = isFixedAtItsPath
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
            // One open, and the identity, the bytes and the digest all come
            // from that descriptor. It used to be a stat, then an open and a
            // mapping for the digest, then another stat — three walks of the
            // same directories, which three review rounds found three ways
            // of disagreeing (`Documentation/decisions/0012`).
            //
            // Following a symbolic link, deliberately: a gather that refused
            // one would leave the path out of the plan's locals, and the
            // install would then write the server's bytes through the link.
            // `0010` rejects that; the upload is where a refusal is safe.
            // A digest already held is answered from a stat, without opening
            // the file. That is sound where opening would be pointless: an
            // identity *is* an identification — device and inode name the
            // file, and the size and the two times say it has not been
            // touched — so a digest recorded against it is of that file's
            // bytes however the path was resolved to find it. Nothing is
            // read here, so there is nothing for a second resolution to
            // disagree with.
            //
            // It also matters: an open where a stat would do cost 200 ms of
            // a 540 ms pass over fourteen thousand candidates, most of them
            // already known.
            let digest: String
            if let digests, candidate.kind.keepsDigestAgainstIdentity || candidate.isFixedAtItsPath,
               let identity = try? LampFileIdentity(url: candidate.url),
               digests.keeps(identity),
               let held = digests.digest(at: candidate.url, identity: identity) {
                digest = held
            } else {
                // Anything that has to be read is read through **one** open,
                // and the identity it is remembered under comes from that
                // same descriptor. It used to be a stat, then an open and a
                // mapping, then another stat — three walks of the same
                // directories, which three review rounds found three ways of
                // disagreeing (`Documentation/decisions/0012`).
                //
                // Following a symbolic link, deliberately: a gather that
                // refused one would leave the path out of the plan's locals,
                // and the install would then write the server's bytes
                // through the link. `0010` rejects that; the upload is where
                // a refusal is safe.
                do {
                    digest = try LampSyncOpenFile.with(candidate.url, followingLinks: true) { file in
                        let identity = try file.identity()
                        let read = try file.digest()
                        // The same descriptor throughout, so this cannot be a
                        // different file — but it can be the same file written
                        // while it was being read, which would be a digest of
                        // a torn body. Remembered only where nothing moved.
                        let caching = digests.flatMap {
                            (candidate.kind.keepsDigestAgainstIdentity
                                || candidate.isFixedAtItsPath) && $0.keeps(identity) ? $0 : nil
                        }
                        if let caching, try file.identity() == identity {
                            caching.remember(read, at: candidate.url, identity: identity)
                        }
                        return read
                    }
                } catch {
                    described.unreadable.append(
                        Unreadable(path: candidate.path, reason: "its file could not be read")
                    )
                    continue
                }
            }
            described.files.append(LampSyncLocalFile(
                path: candidate.path,
                kind: candidate.kind,
                url: candidate.url,
                digest: digest,
                isFixedAtItsPath: candidate.isFixedAtItsPath
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
