import Foundation

/// Reads a folder as one observed snapshot, then publishes each file only if
/// its locally visible bytes still match that snapshot. The files form an
/// ordered batch, not one atomic transaction across devices.
public enum LampSyncFolderPublisher {
    /// A visible sidecar lets this publisher's readers detect a stopped batch.
    /// It is deliberately outside the portable backup manifest format.
    public static let snapshotPath = "lamp-sync-snapshot.json"

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
            return LampSyncFolderPublisher.sealAccepts(
                committed: files, pending: pendingFiles, observed: Self.files(in: entries)
            )
        }

        private static func files(in entries: [LampSyncArchive.Entry]) -> [File] {
            entries.filter { $0.path != snapshotPath }.map {
                File(path: $0.path, sha256: LampSyncContentRevision.digest(for: $0.data))
            }.sorted { $0.path < $1.path }
        }
    }

    /// Whether the visible files are a snapshot the seal vouches for: the
    /// committed set, or the complete pending set of a batch that stopped.
    /// (`Verification/SyncMerge.lean`: `folderSealAccepts`.)
    static func sealAccepts<Files: Equatable>(
        committed: Files, pending: Files?, observed: Files
    ) -> Bool {
        observed == committed || pending == observed
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

}
