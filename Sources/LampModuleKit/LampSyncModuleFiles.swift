/// Chooses one remote representation of a module before a sync pass. The
/// canonical compressed format outranks legacy files, regardless of extension
/// case. The installed path breaks ties between files of the same format.
public enum LampSyncModuleFiles {
    public struct Candidate: Equatable, Sendable {
        public let identity: String
        public let path: String
        public let isSuperseded: Bool

        public init(identity: String, path: String, isSuperseded: Bool = false) {
            self.identity = identity
            self.path = path
            self.isSuperseded = isSuperseded
        }
    }

    public static func canonicalIdentity(_ id: String, isNotes: Bool) -> String {
        isNotes && id == "bible-notes" ? "notes" : id
    }

    /// A remote payload may be applied to a listed module only when its
    /// embedded identity names that same module (including the notes alias).
    public static func matchesContentIdentity(
        listedID: String,
        contentID: String,
        isNotes: Bool
    ) -> Bool {
        canonicalIdentity(listedID, isNotes: isNotes)
            == canonicalIdentity(contentID, isNotes: isNotes)
    }

    /// Return the filename identity only for a supported portable module.
    /// The returned spelling preserves the original filename's case.
    public static func moduleID(from filename: String) -> String? {
        let lowercased = filename.lowercased()
        for suffix in [".lamp", ".db.zlib", ".db", ".json"] {
            if lowercased.hasSuffix(suffix) {
                let id = String(filename.dropLast(suffix.count))
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    /// A missing remote revision is not evidence of unchanged content.
    /// Providers without a stable revision must fetch the module again.
    public static func needsImport(
        isNew: Bool,
        installedPath: String?,
        remotePath: String,
        installedRevision: String?,
        remoteRevision: String?
    ) -> Bool {
        isNew || installedPath != remotePath || remoteRevision == nil
            || installedRevision != remoteRevision
    }

    public static func preferredPath(
        among paths: [String],
        installedPath: String?
    ) -> String? {
        guard let bestRank = paths.map(rank).min() else { return nil }
        let candidates = paths.filter { rank($0) == bestRank }
        if let installedPath, candidates.contains(installedPath) {
            return installedPath
        }
        return candidates.min()
    }

    /// Pick a current representation independently for each module identity.
    /// Archive-superseded files are removed before format ranking, so a stale
    /// canonical file cannot hide a newer legacy-file edit. A JSON file can
    /// contain several modules, so its path may win for one identity while a
    /// .lamp path wins for another.
    public static func preferredPathsByIdentity(
        _ candidates: [Candidate],
        installedPaths: [String: String] = [:]
    ) -> [String: String] {
        Dictionary(grouping: candidates.filter { !$0.isSuperseded }, by: \.identity)
            .compactMapValues { group in
            guard let identity = group.first?.identity else { return nil }
            return preferredPath(
                among: group.map(\.path),
                installedPath: installedPaths[identity]
            )
        }
    }

    /// Select one active candidate per identity while keeping the caller's
    /// original index, so its payload and observed revision stay paired.
    /// When one path appears more than once, a superseded occurrence cannot
    /// be chosen ahead of an active occurrence of that same path.
    public static func preferredCandidateIndices(
        _ candidates: [Candidate],
        installedPaths: [String: String] = [:]
    ) -> [Int] {
        let selectedPaths = preferredPathsByIdentity(
            candidates, installedPaths: installedPaths
        )
        var selectedIdentities = Set<String>()
        return candidates.indices.filter { index in
            let candidate = candidates[index]
            guard !candidate.isSuperseded,
                  selectedPaths[candidate.identity] == candidate.path else {
                return false
            }
            return selectedIdentities.insert(candidate.identity).inserted
        }
    }

    private static func rank(_ path: String) -> Int {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".lamp") { return 0 }
        if lowercased.hasSuffix(".db.zlib") { return 1 }
        if lowercased.hasSuffix(".db") { return 2 }
        if lowercased.hasSuffix(".json") { return 3 }
        return 4
    }
}
