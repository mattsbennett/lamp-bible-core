import Foundation

/// Reads a folder as one observed snapshot, then publishes each file only if
/// its locally visible bytes still match that snapshot. The files form an
/// ordered batch, not one atomic transaction across devices.
public enum LampSyncFolderPublisher {
    /// A visible sidecar lets this publisher's readers detect a stopped batch.
    /// It is deliberately outside the portable backup manifest format.
    public static let snapshotPath = "lamp-sync-snapshot.json"
    private static let stagedArchivePrefix = ".lamp-sync-staged-"

    private struct SnapshotSeal: Codable {
        struct File: Codable, Equatable {
            let path: String
            let sha256: String
        }

        let formatVersion: Int
        let files: [File]
        let pendingFiles: [File]?
        let pendingArchivePath: String?
        let pendingArchiveSHA256: String?

        init(
            entries: [LampSyncArchive.Entry],
            pendingEntries: [LampSyncArchive.Entry]? = nil,
            pendingArchivePath: String? = nil,
            pendingArchiveSHA256: String? = nil
        ) {
            formatVersion = 1
            files = Self.files(in: entries)
            pendingFiles = pendingEntries.map { Self.files(in: $0) }
            self.pendingArchivePath = pendingArchivePath
            self.pendingArchiveSHA256 = pendingArchiveSHA256
        }

        func matches(_ entries: [LampSyncArchive.Entry]) -> Bool {
            guard formatVersion == 1 else { return false }
            let observed = Self.files(in: entries)
            return files == observed || pendingFiles == observed
        }

        func matchesPending(_ entries: [LampSyncArchive.Entry]) -> Bool {
            formatVersion == 1 && pendingFiles == Self.files(in: entries)
        }

        private static func files(in entries: [LampSyncArchive.Entry]) -> [File] {
            entries.filter { $0.path != snapshotPath }.map {
                File(path: $0.path, sha256: LampSyncContentRevision.digest(for: $0.data))
            }.sorted { $0.path < $1.path }
        }
    }

    public enum FolderError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case conflict(String)
        case unresolvedVersions(String)
        case incompletePublication(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                "Cannot read sync folder: \(path)."
            case .conflict(let path):
                "Sync folder changed since it was read: \(path)."
            case .unresolvedVersions(let path):
                "Sync folder has unresolved file versions: \(path)."
            case .incompletePublication(let path):
                "Sync folder contains an incomplete file publication: \(path)."
            }
        }
    }

    public static func capture(
        from folder: URL,
        fileManager: FileManager = .default,
        downloadItem: ((URL) throws -> Void)? = nil
    ) async throws -> LampSyncArchive {
        let archive = try await captureContents(
            from: folder, fileManager: fileManager, downloadItem: downloadItem
        )
        if let sealEntry = archive.entries.first(where: { $0.path == snapshotPath }) {
            guard let seal = try? JSONDecoder().decode(SnapshotSeal.self, from: sealEntry.data),
                  seal.matches(archive.entries) else {
                throw FolderError.incompletePublication(folder.path)
            }
        }
        return archive
    }

    private static func captureContents(
        from folder: URL,
        fileManager: FileManager,
        downloadItem: ((URL) throws -> Void)?
    ) async throws -> LampSyncArchive {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FolderError.unreadable(folder.path)
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw FolderError.unreadable(folder.path) }
        var placeholders: [URL] = []
        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud"),
               try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                placeholders.append(item)
            }
        }
        if let enumerationError { throw enumerationError }

        let beginDownload = downloadItem ?? {
            try fileManager.startDownloadingUbiquitousItem(at: $0)
        }
        for placeholder in placeholders {
            let name = placeholder.lastPathComponent
            let original = placeholder.deletingLastPathComponent().appendingPathComponent(
                String(name.dropFirst().dropLast(".icloud".count))
            )
            if fileManager.fileExists(atPath: original.path) {
                throw FolderError.unresolvedVersions(original.path)
            }
            try beginDownload(original)
            var available = false
            for _ in 0..<60 {
                if fileManager.fileExists(atPath: original.path) {
                    available = true
                    break
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard available else { throw FolderError.unreadable(original.path) }
        }

        let archive = try LampSyncArchive.create(from: folder, fileManager: fileManager)
        for entry in archive.entries {
            let url = folder.appendingPathComponent(entry.path)
            if NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty == false {
                throw FolderError.unresolvedVersions(entry.path)
            }
        }
        return archive
    }

    /// Completes an interrupted batch only while each visible file is still
    /// either the old or intended new body. Other edits are never overwritten.
    public static func recoverIncompletePublication(
        from folder: URL,
        fileManager: FileManager = .default,
        downloadItem: ((URL) throws -> Void)? = nil
    ) async throws -> LampSyncArchive {
        let current = try await captureContents(
            from: folder, fileManager: fileManager, downloadItem: downloadItem
        )
        guard let sealData = current.entries.first(where: { $0.path == snapshotPath })?.data,
              let seal = try? JSONDecoder().decode(SnapshotSeal.self, from: sealData),
              seal.formatVersion == 1 else {
            throw FolderError.incompletePublication(folder.path)
        }
        if seal.matches(current.entries) { return current }
        guard
              let pendingFiles = seal.pendingFiles,
              let stagedPath = seal.pendingArchivePath,
              stagedPath.hasPrefix(stagedArchivePrefix),
              stagedPath.hasSuffix(".lampsync"),
              !stagedPath.contains("/"),
              UUID(uuidString: String(stagedPath
                  .dropFirst(stagedArchivePrefix.count).dropLast(".lampsync".count))) != nil,
              let stagedDigest = seal.pendingArchiveSHA256 else {
            throw FolderError.incompletePublication(folder.path)
        }
        let stageURL = folder.appendingPathComponent(stagedPath)
        guard (try? fileManager.destinationOfSymbolicLink(atPath: stageURL.path)) == nil,
              let stageData = try? Data(contentsOf: stageURL),
              LampSyncContentRevision.digest(for: stageData) == stagedDigest,
              let staged = try? LampSyncArchive.decode(compressedData: stageData),
              !staged.entries.contains(where: { $0.path == snapshotPath }) else {
            throw FolderError.incompletePublication(folder.path)
        }

        let old = Dictionary(seal.files.map { ($0.path, $0.sha256) },
            uniquingKeysWith: { first, _ in first })
        let next = Dictionary(pendingFiles.map { ($0.path, $0.sha256) },
            uniquingKeysWith: { first, _ in first })
        let stagedEntries = Dictionary(uniqueKeysWithValues: staged.entries.map { ($0.path, $0) })
        let visible = Dictionary(uniqueKeysWithValues: current.entries
            .filter { $0.path != snapshotPath }.map { ($0.path, $0) })
        guard next.count == pendingFiles.count,
              old.count == seal.files.count,
              Set(next.keys) == Set(old.keys).union(stagedEntries.keys),
              Set(visible.keys).isSubset(of: Set(next.keys)),
              staged.entries.allSatisfy({
                  next[$0.path] == LampSyncContentRevision.digest(for: $0.data)
              }),
              next.allSatisfy({ path, digest in
                  stagedEntries[path] != nil || old[path] == digest
              }),
              next.allSatisfy({ path, digest in
                  let actual = visible[path].map { LampSyncContentRevision.digest(for: $0.data) }
                  return actual == old[path] || actual == digest
              }) else {
            throw FolderError.incompletePublication(folder.path)
        }

        for entry in staged.entries where
            visible[entry.path].map({ LampSyncContentRevision.digest(for: $0.data) })
                != next[entry.path] {
            try write(
                entry, to: folder, matching: visible[entry.path]?.data,
                fileManager: fileManager
            )
        }
        let completed = try await captureContents(
            from: folder, fileManager: fileManager, downloadItem: downloadItem
        )
        guard seal.matchesPending(completed.entries) else {
            throw FolderError.incompletePublication(folder.path)
        }
        let finalSeal = try JSONEncoder().encode(SnapshotSeal(entries: completed.entries))
        try write(
            .init(path: snapshotPath, data: finalSeal, modifiedAt: Date()),
            to: folder, matching: sealData, fileManager: fileManager
        )
        try? fileManager.removeItem(at: stageURL)
        return try await capture(
            from: folder, fileManager: fileManager, downloadItem: downloadItem
        )
    }

    public static func publish(
        _ outgoing: LampSyncArchive,
        to folder: URL,
        replacing observed: LampSyncArchive,
        fileManager: FileManager = .default,
        downloadItem: ((URL) throws -> Void)? = nil
    ) async throws {
        try outgoing.validateDestinations(in: folder, fileManager: fileManager)
        guard !outgoing.entries.contains(where: { $0.path == snapshotPath }) else {
            throw FolderError.conflict(snapshotPath)
        }
        let current = try await capture(
            from: folder, fileManager: fileManager, downloadItem: downloadItem
        )
        guard current.entries == observed.entries else {
            throw FolderError.conflict(folder.path)
        }

        var previousData = Dictionary(uniqueKeysWithValues: observed.entries.map {
            ($0.path, $0.data)
        })
        // Existing files that are absent from outgoing are retained, matching
        // the folder publisher's existing non-deleting behavior.
        var finalEntries = Dictionary(uniqueKeysWithValues: observed.entries
            .filter { $0.path != snapshotPath }.map { ($0.path, $0) })
        for entry in outgoing.entries { finalEntries[entry.path] = entry }
        let finalContents = Array(finalEntries.values)
        let stageData = try outgoing.compressedData()
        let stagedPath = "\(stagedArchivePrefix)\(UUID().uuidString).lampsync"
        try write(
            .init(path: stagedPath, data: stageData, modifiedAt: Date()),
            to: folder, matching: nil, fileManager: fileManager
        )
        // Publish both complete signatures before changing payloads. A reader
        // accepts the old or new complete set, but rejects every mixed prefix.
        let pendingSeal = try JSONEncoder().encode(SnapshotSeal(
            entries: observed.entries,
            pendingEntries: finalContents,
            pendingArchivePath: stagedPath,
            pendingArchiveSHA256: LampSyncContentRevision.digest(for: stageData)
        ))
        do {
            try write(
                .init(path: snapshotPath, data: pendingSeal, modifiedAt: Date()),
                to: folder, matching: previousData[snapshotPath], fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: folder.appendingPathComponent(stagedPath))
            throw error
        }
        previousData[snapshotPath] = pendingSeal

        for entry in outgoing.entries {
            try write(entry, to: folder, matching: previousData[entry.path], fileManager: fileManager)
        }

        let finalSeal = try JSONEncoder().encode(SnapshotSeal(entries: finalContents))
        try write(
            .init(path: snapshotPath, data: finalSeal, modifiedAt: Date()),
            to: folder, matching: previousData[snapshotPath], fileManager: fileManager
        )
        try? fileManager.removeItem(at: folder.appendingPathComponent(stagedPath))
    }

    private static func write(
        _ entry: LampSyncArchive.Entry,
        to folder: URL,
        matching previousData: Data?,
        fileManager: FileManager
    ) throws {
        let destination = folder.appendingPathComponent(entry.path).standardizedFileURL
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try LampSyncArchive(entries: [entry]).rejectSymbolicLinks(
            for: entry.path, in: folder, fileManager: fileManager
        )

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try LampSyncArchive(entries: [entry]).rejectSymbolicLinks(
                    for: entry.path, in: folder, fileManager: fileManager
                )
                if NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL)?
                    .isEmpty == false {
                    throw FolderError.unresolvedVersions(entry.path)
                }
                let placeholder = coordinatedURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(coordinatedURL.lastPathComponent).icloud")
                if fileManager.fileExists(atPath: placeholder.path) {
                    throw FolderError.conflict(entry.path)
                }
                let existing = fileManager.fileExists(atPath: coordinatedURL.path)
                    ? try Data(contentsOf: coordinatedURL) : nil
                guard existing == previousData else {
                    throw FolderError.conflict(entry.path)
                }
                try entry.data.write(to: coordinatedURL, options: .atomic)
                try fileManager.setAttributes(
                    [.modificationDate: entry.modifiedAt],
                    ofItemAtPath: coordinatedURL.path
                )
            }
        }
        if let result { try result.get() }
        else {
            throw (coordinationError as Error?) ?? FolderError.unreadable(entry.path)
        }
    }
}
