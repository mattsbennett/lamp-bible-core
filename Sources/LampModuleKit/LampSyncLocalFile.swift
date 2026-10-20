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

    /// Digests each candidate, every pass, by reading its file.
    ///
    /// Deliberately not skipped by comparing size and modification date with
    /// what was recorded last time. SHA-256 over a whole library costs well
    /// under a second here, while a file replaced at the same size with its
    /// date preserved — a restore, `cp -p`, `rsync -t` — would be skipped and
    /// never uploaded again. A cheap shortcut that loses a file is a bad
    /// trade, and mtime is not how this project compares content.
    public static func describe(
        _ candidates: [Candidate],
        fileManager: FileManager = .default
    ) -> Described {
        var described = Described()
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.url.path),
                  let digest = try? LampSyncContentRevision.digest(forFileAt: candidate.url)
            else {
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
