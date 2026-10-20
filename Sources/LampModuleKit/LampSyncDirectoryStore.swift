import Foundation

/// A folder as a sync store: iCloud Drive, or any folder the person picks.
///
/// It lets the folder provider run the same per-file pass as WebDAV. A
/// file's revision is the SHA-256 digest of its bytes, quoted like a strong
/// ETag so every check made of revisions elsewhere holds. It is computed
/// from a read every time, never cached and never inferred from a
/// modification date. A pass reads it rarely: `list` reports none, and
/// `LampSyncFilePlan.listing` takes members' revisions from the manifest, so a
/// pass that changes nothing reads no file and downloads nothing evicted.
///
/// Every read, write and delete is coordinated, and refuses a file iCloud
/// holds unresolved conflict versions of. A conditional write compares the
/// file's digest inside its coordinated block. That protects against writers
/// on this device only: iCloud has no server-side condition, so another
/// device's upload can still land afterwards, and iCloud then keeps both as
/// conflict versions (`Verification/SyncMerge.lean`:
/// `stableICloudReadDoesNotProtectLaterWrite`). The settings bundle is the
/// one file that merges them, through `LampSyncVersionedStore`; a module
/// file with versions stops its own sync until someone resolves them.
///
/// `root` must already be accessible. On the Mac the caller holds its
/// security scope for the store's whole lifetime, which is now a whole pass.
public struct LampSyncDirectoryStore: LampSyncVersionedStore, Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        /// Not a folder, or an evicted file that never arrived.
        case unreadable(String)
        /// iCloud holds conflict versions of the file that nobody has resolved.
        case unresolvedVersions(String)
        /// An empty, relative or hidden-escaping component, or a symbolic link.
        case unsafePath(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Cannot read the sync folder's file: \(path)."
            case .unresolvedVersions(let path): "The sync folder has unresolved versions of \(path)."
            case .unsafePath(let path): "Unsafe path in the sync folder: \(path)."
            }
        }
    }

    /// iCloud's unresolved conflict versions of a file. Tests stage their
    /// own, since a plain folder never has any.
    public struct ConflictVersions: Sendable {
        /// A readable copy of each unresolved version of the file.
        public var unresolved: @Sendable (URL) -> [URL]
        /// Marks resolved the file's versions at the URLs given.
        public var resolve: @Sendable (URL, [URL]) throws -> Void

        public init(
            unresolved: @escaping @Sendable (URL) -> [URL],
            resolve: @escaping @Sendable (URL, [URL]) throws -> Void
        ) {
            self.unresolved = unresolved
            self.resolve = resolve
        }

        public static let iCloud = ConflictVersions(
            unresolved: { NSFileVersion.unresolvedConflictVersionsOfItem(at: $0)?.map(\.url) ?? [] },
            resolve: { file, urls in
                let named = Set(urls.map(\.standardizedFileURL))
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
                where named.contains(version.url.standardizedFileURL) {
                    version.isResolved = true
                    // Resolved is what matters; removing the copy only frees
                    // its space, and a failure there leaves nothing unmerged.
                    try? version.remove()
                }
            }
        )
    }

    public let root: URL
    private let downloadTimeout: Duration
    private let conflictVersions: ConflictVersions
    private let startDownloading: @Sendable (URL) throws -> Void

    /// `startDownloading` asks iCloud for an evicted file. It must come before
    /// the wait: on iOS a coordinated read of an evicted file doesn't
    /// reliably start the download. Tests pass their own to make a file
    /// arrive without iCloud.
    public init(
        root: URL,
        downloadTimeout: Duration = .seconds(30),
        conflictVersions: ConflictVersions = .iCloud,
        startDownloading: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
    ) {
        self.root = root
        self.downloadTimeout = downloadTimeout
        self.conflictVersions = conflictVersions
        self.startDownloading = startDownloading
    }

    /// A file's revision, from the digest of its bytes.
    public static func revision(forDigest digest: String) -> String { "\"\(digest)\"" }

    // MARK: - Decisions

    /// What a coordinated write or delete does, decided inside the
    /// coordinated block from what it finds there.
    enum Outcome: Equatable {
        case proceed
        /// The condition no longer holds: a refusal, as a server's 412 is.
        case refuse
        case unresolved
        /// A delete found nothing to delete.
        case nothingThere
    }

    /// Unresolved versions stop it. A placeholder that appeared means iCloud
    /// is replacing the file under us. Otherwise the condition decides.
    /// (`Verification/SyncMerge.lean`: `directoryWrite`.)
    static func writeOutcome(
        condition: LampSyncWriteCondition,
        exists: Bool,
        currentRevision: () throws -> String,
        placeholderVisible: Bool,
        unresolved: Bool
    ) rethrows -> Outcome {
        if unresolved { return .unresolved }
        if placeholderVisible { return .refuse }
        switch condition {
        case .unconditional: return .proceed
        case .ifAbsent: return exists ? .refuse : .proceed
        case .ifRevision(let expected):
            guard exists else { return .refuse }
            return LampSyncConditionalWrite.namesSameRevision(try currentRevision(), expected) ? .proceed : .refuse
        }
    }

    /// As a write, except that a file already gone is done, and a delete
    /// "only where absent" can only refuse. (`directoryDelete`.)
    static func deleteOutcome(
        condition: LampSyncWriteCondition,
        exists: Bool,
        currentRevision: () throws -> String,
        placeholderVisible: Bool,
        unresolved: Bool
    ) rethrows -> Outcome {
        if unresolved { return .unresolved }
        if placeholderVisible { return .refuse }
        guard exists else { return .nothingThere }
        switch condition {
        case .unconditional: return .proceed
        case .ifAbsent: return .refuse
        case .ifRevision(let expected):
            return LampSyncConditionalWrite.namesSameRevision(try currentRevision(), expected) ? .proceed : .refuse
        }
    }

    // MARK: - LampSyncRemoteStore

    /// The folder's entries, without revisions. An evicted file's placeholder
    /// is reported under the file's own name: the file is there, only not
    /// downloaded.
    public func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        let path = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let folder = path.isEmpty ? root : try url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { throw StoreError.unreadable(path) }
        var found: [String: Bool] = [:]
        for item in try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            if let name = Self.evictedName(item.lastPathComponent) {
                found[name] = found[name] ?? false
            } else {
                let isFolder = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
                found[item.lastPathComponent] = isFolder
            }
        }
        return found.keys.sorted().map { name in
            LampSyncRemoteEntry(
                path: path.isEmpty ? name : "\(path)/\(name)", name: name,
                isDirectory: found[name] ?? false, revision: nil, modifiedAt: nil, size: nil
            )
        }
    }

    public func read(path: String) async throws -> LampSyncRemoteFile? {
        try await LampSyncScratchFile.with { scratch in
            guard let file = try await read(path: path, into: scratch) else { return nil }
            return LampSyncRemoteFile(data: try Data(contentsOf: file.url), revision: file.revision)
        }
    }

    /// Copies the file out under coordination, and names the revision of the
    /// bytes copied.
    public func read(path: String, into destination: URL) async throws -> LampSyncDownloadedFile? {
        guard try await materialize(path) else { return nil }
        let source = try url(for: path)
        let digest: String? = try coordinate(reading: source) { coordinated in
            try rejectSymbolicLinks(path)
            if hasUnresolvedVersions(coordinated) { throw StoreError.unresolvedVersions(path) }
            guard FileManager.default.fileExists(atPath: coordinated.path) else { return nil }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: coordinated, to: destination)
            return try LampSyncContentRevision.digest(forFileAt: destination)
        }
        return digest.map { LampSyncDownloadedFile(url: destination, revision: Self.revision(forDigest: $0)) }
    }

    /// Reads and digests the file: only for a file the manifest doesn't
    /// record, since it downloads an evicted one.
    public func revision(path: String) async throws -> String? {
        guard try await materialize(path) else { return nil }
        let source = try url(for: path)
        return try coordinate(reading: source) { coordinated in
            try rejectSymbolicLinks(path)
            if hasUnresolvedVersions(coordinated) { throw StoreError.unresolvedVersions(path) }
            guard FileManager.default.fileExists(atPath: coordinated.path) else { return nil }
            return Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: coordinated))
        }
    }

    public func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        try await replace(path, condition: condition, digest: LampSyncContentRevision.digest(for: data)) {
            try data.write(to: $0, options: .atomic)
        }
    }

    public func write(fileAt source: URL, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        try await replace(path, condition: condition, digest: LampSyncContentRevision.digest(forFileAt: source)) {
            try Data(contentsOf: source, options: .alwaysMapped).write(to: $0, options: .atomic)
        }
    }

    public func delete(path: String, condition: LampSyncWriteCondition) async throws {
        // An evicted file is fetched first, so its revision can be compared
        // and the file itself, not its placeholder, is what goes.
        guard try await materialize(path) else { return }
        let target = try url(for: path)
        try coordinate(writing: target, options: .forDeleting) { coordinated in
            try rejectSymbolicLinks(path)
            let outcome = try Self.deleteOutcome(
                condition: condition,
                exists: FileManager.default.fileExists(atPath: coordinated.path),
                currentRevision: { Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: coordinated)) },
                placeholderVisible: FileManager.default.fileExists(atPath: Self.placeholder(for: coordinated).path),
                unresolved: hasUnresolvedVersions(coordinated)
            )
            switch outcome {
            case .proceed: try FileManager.default.removeItem(at: coordinated)
            case .nothingThere: break
            case .refuse: throw LampSyncConditionalWrite.WriteError.conflict
            case .unresolved: throw StoreError.unresolvedVersions(path)
            }
        }
    }

    // MARK: - LampSyncVersionedStore

    public func readWithVersions(
        path: String, into destination: URL
    ) async throws -> (current: LampSyncDownloadedFile?, versions: [LampSyncDownloadedFile]) {
        guard try await materialize(path) else { return (nil, []) }
        let source = try url(for: path)
        return try coordinate(reading: source) { coordinated in
            try rejectSymbolicLinks(path)
            guard FileManager.default.fileExists(atPath: coordinated.path) else { return (nil, []) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: coordinated, to: destination)
            let current = LampSyncDownloadedFile(
                url: destination,
                revision: Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: destination))
            )
            var versions: [LampSyncDownloadedFile] = []
            do {
                for version in conflictVersions.unresolved(coordinated) {
                    let copy = LampSyncScratchFile.url()
                    try FileManager.default.copyItem(at: version, to: copy)
                    versions.append(LampSyncDownloadedFile(
                        url: copy,
                        revision: Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: copy))
                    ))
                }
            } catch {
                for version in versions { try? FileManager.default.removeItem(at: version.url) }
                throw error
            }
            return (current, versions)
        }
    }

    public func resolveVersions(
        of path: String, writing data: Data, ifRevision revision: String, resolving versions: Set<String>
    ) async throws -> String {
        try await replace(
            path, condition: .ifRevision(revision), digest: LampSyncContentRevision.digest(for: data),
            resolving: versions
        ) {
            try data.write(to: $0, options: .atomic)
        }
    }

    public func hasVersions(path: String) async throws -> Bool {
        hasUnresolvedVersions(try url(for: path))
    }

    // MARK: - Files

    /// Writes the file where `condition` holds. With `resolving`, versions
    /// don't stop the write: once it's made, those versions whose bytes have
    /// the revisions named are resolved, in the same coordinated block.
    private func replace(
        _ path: String,
        condition: LampSyncWriteCondition,
        digest: String,
        resolving: Set<String>? = nil,
        writing: (URL) throws -> Void
    ) async throws -> String {
        // A revision can only be compared once an evicted file has arrived.
        if case .ifRevision = condition { _ = try await materialize(path) }
        let destination = try url(for: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try rejectSymbolicLinks(path)
        try coordinate(writing: destination, options: .forReplacing) { coordinated in
            try rejectSymbolicLinks(path)
            let outcome = try Self.writeOutcome(
                condition: condition,
                exists: FileManager.default.fileExists(atPath: coordinated.path),
                currentRevision: { Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: coordinated)) },
                placeholderVisible: FileManager.default.fileExists(atPath: Self.placeholder(for: coordinated).path),
                unresolved: resolving == nil && hasUnresolvedVersions(coordinated)
            )
            switch outcome {
            case .proceed, .nothingThere:
                try writing(coordinated)
                if let resolving {
                    let merged = try conflictVersions.unresolved(coordinated).filter {
                        resolving.contains(Self.revision(forDigest: try LampSyncContentRevision.digest(forFileAt: $0)))
                    }
                    if !merged.isEmpty { try conflictVersions.resolve(coordinated, merged) }
                }
            case .refuse: throw LampSyncConditionalWrite.WriteError.conflict
            case .unresolved: throw StoreError.unresolvedVersions(path)
            }
        }
        return Self.revision(forDigest: digest)
    }

    /// Whether the file is there, downloading it first if it's evicted.
    /// A file that never arrives is an error, never "absent".
    private func materialize(_ path: String) async throws -> Bool {
        let file = try url(for: path)
        let placeholder = Self.placeholder(for: file)
        let hasFile = FileManager.default.fileExists(atPath: file.path)
        let hasPlaceholder = FileManager.default.fileExists(atPath: placeholder.path)
        if hasFile && hasPlaceholder { throw StoreError.unresolvedVersions(path) }
        if hasFile { return true }
        guard hasPlaceholder else { return false }
        try startDownloading(file)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: downloadTimeout)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard clock.now < deadline else { throw StoreError.unreadable(path) }
            try await Task.sleep(for: .milliseconds(500))
        }
        return true
    }

    private func url(for path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
              }) else { throw StoreError.unsafePath(path) }
        try rejectSymbolicLinks(path)
        return root.appendingPathComponent(path)
    }

    /// No component of the path may be a link, which could lead a write out
    /// of the folder. Checked before and again inside coordination.
    private func rejectSymbolicLinks(_ path: String) throws {
        var url = root
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw StoreError.unsafePath(path)
            }
        }
    }

    static func placeholder(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
    }

    /// The file an iCloud placeholder name stands for.
    static func evictedName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func hasUnresolvedVersions(_ url: URL) -> Bool {
        !conflictVersions.unresolved(url).isEmpty
    }

    private func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let result { return try result.get() }
        throw (coordinationError as Error?) ?? StoreError.unreadable(url.path)
    }

    private func coordinate(
        writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let result { return try result.get() }
        throw (coordinationError as Error?) ?? StoreError.unreadable(url.path)
    }
}
