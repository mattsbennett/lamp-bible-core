import Foundation

/// Portable, versioned file snapshot used by remote and folder sync.
/// Version 1 archives remain readable; version 2 records a digest for every file.
public struct LampSyncArchive: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let data: Data
        public let modifiedAt: Date
        public let sha256: String?

        public init(path: String, data: Data, modifiedAt: Date, sha256: String? = nil) {
            self.path = path
            self.data = data
            self.modifiedAt = modifiedAt
            self.sha256 = sha256
        }
    }

    public struct SyncableContents: Sendable {
        public let modules: [Entry]
        public let compatibilityManifest: LampCompatibilityManifest?
    }

    public enum ArchiveError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case unsafePath(String)
        case duplicatePath(String)
        case checksumMismatch(String)
        case missingBackupManifest
        case unreadableDirectory(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported sync archive version: \(version)."
            case .unsafePath(let path):
                "Unsafe path in sync archive: \(path)."
            case .duplicatePath(let path):
                "Duplicate path in sync archive: \(path)."
            case .checksumMismatch(let path):
                "Sync archive data is damaged: \(path)."
            case .missingBackupManifest:
                "The sync archive has no portable backup manifest."
            case .unreadableDirectory(let path):
                "Cannot read sync directory: \(path)."
            }
        }
    }

    public static let currentFormatVersion = 2
    private static let compatibleDirectories = Set(LampSyncContentKind.allCases.map(\.rawValue))

    public let formatVersion: Int
    public let entries: [Entry]

    public init(formatVersion: Int = currentFormatVersion, entries: [Entry]) {
        self.formatVersion = formatVersion
        self.entries = entries
    }

    public static func create(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> LampSyncArchive {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ArchiveError.unreadableDirectory(directory.path)
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isDirectoryKey,
                .isRegularFileKey, .isSymbolicLinkKey,
            ],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw ArchiveError.unreadableDirectory(directory.path) }
        let prefix = directory.standardizedFileURL.path + "/"
        let entries = try enumerator.compactMap { item -> Entry? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey, .isDirectoryKey,
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(prefix) else {
                throw ArchiveError.unsafePath(url.path)
            }
            let relativePath = String(standardizedPath.dropFirst(prefix.count))
            let components = relativePath.split(separator: "/")
            if components.first != Substring(LampPortableBackupLayout.mediaDirectory),
               components.contains(where: { $0.hasPrefix(".") }) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                return nil
            }
            if values.isSymbolicLink == true {
                throw ArchiveError.unsafePath(relativePath)
            }
            guard values.isRegularFile == true else { return nil }
            let data = try Data(contentsOf: url)
            return Entry(
                path: relativePath,
                data: data,
                modifiedAt: values.contentModificationDate ?? Date(),
                sha256: LampSyncContentRevision.digest(for: data)
            )
        }
        if let enumerationError { throw enumerationError }
        let archive = LampSyncArchive(entries: entries.sorted { $0.path < $1.path })
        try archive.validate()
        return archive
    }

    /// The packed archive, built on disk and read back through a mapping.
    public func compressedData() throws -> Data {
        let file = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: file) }
        try writeCompressed(to: file)
        // The mapping keeps the bytes readable after the file is removed.
        return try Data(contentsOf: file, options: .alwaysMapped)
    }

    /// Packs the archive into `url` one entry at a time, so its JSON (a third
    /// larger than the bodies, which are base64 in it) is never in memory
    /// whole beside the entries and their packed form.
    public func writeCompressed(to url: URL) throws {
        try validate()
        let json = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: json) }
        guard FileManager.default.createFile(atPath: json.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: json.path])
        }
        let handle = try FileHandle(forWritingTo: json)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        // The synthesized shape, written by hand around entries encoded one
        // at a time: `{"formatVersion":…,"entries":[…]}`.
        try handle.write(contentsOf: Data(#"{"formatVersion":\#(formatVersion),"entries":["#.utf8))
        for (index, entry) in entries.enumerated() {
            try autoreleasepool {
                if index > 0 { try handle.write(contentsOf: Data(",".utf8)) }
                try handle.write(contentsOf: encoder.encode(entry))
            }
        }
        try handle.write(contentsOf: Data("]}".utf8))
        try handle.close()
        try LampZlib.compress(fileAt: json, to: url)
    }

    /// Unpacks to a scratch file and decodes from a mapping of it, so the
    /// unpacked JSON never sits in memory beside the compressed body and the
    /// decoded entries. Holding all three for a library-sized archive is what
    /// got the iOS app stopped by the system.
    public static func decode(compressedData: Data) throws -> LampSyncArchive {
        let json = LampSyncScratchFile.url()
        defer { try? FileManager.default.removeItem(at: json) }
        try LampZlib.decompress(compressedData, to: json)
        let archive = try JSONDecoder().decode(
            LampSyncArchive.self, from: Data(contentsOf: json, options: .alwaysMapped)
        )
        try archive.validate()
        return archive
    }

    /// Decodes an archive saved to disk, reading it through a mapping.
    public static func decode(compressedFileAt url: URL) throws -> LampSyncArchive {
        try decode(compressedData: Data(contentsOf: url, options: .alwaysMapped))
    }

    /// Replace one file without changing the other archive payloads. Rebuild
    /// checksums when upgrading an older version 1 archive.
    public func replacingEntry(
        at path: String,
        with data: Data,
        modifiedAt: Date = Date()
    ) throws -> LampSyncArchive {
        try validate()
        var updated = entries.filter { $0.path != path }
        updated.append(Entry(path: path, data: data, modifiedAt: modifiedAt))
        let archive = LampSyncArchive(entries: updated.map { entry in
            Entry(
                path: entry.path,
                data: entry.data,
                modifiedAt: entry.modifiedAt,
                sha256: LampSyncContentRevision.digest(for: entry.data)
            )
        }.sorted { $0.path < $1.path })
        try archive.validate()
        return archive
    }

    public func portableBackupManifest() throws -> LampPortableBackupManifest {
        try validate()
        guard let entry = entries.first(where: {
            $0.path == LampPortableBackupLayout.manifestPath
        }) else {
            throw ArchiveError.missingBackupManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LampPortableBackupManifest.self, from: entry.data)
        try manifest.validate()
        return manifest
    }

    public func portableModuleEntries() throws -> [Entry] {
        _ = try portableBackupManifest()
        return entries.filter { Self.isPortableModulePath($0.path) }
    }

    /// Module files mirrored inside the archive for clients that still use
    /// the WebDAV folder layout. Their path after `Compatibility/` is the same
    /// path written to the legacy WebDAV folders.
    public func compatibleModuleEntries() throws -> [Entry] {
        _ = try portableBackupManifest()
        return entries.filter { Self.isCompatibleModulePath($0.path) }
    }

    public func syncableModuleEntries() throws -> [Entry] {
        _ = try portableBackupManifest()
        return orderedSyncableModuleEntries()
    }

    public func compatibilityManifest() throws -> LampCompatibilityManifest? {
        _ = try portableBackupManifest()
        return try decodedCompatibilityManifest()
    }

    public func syncableContents() throws -> SyncableContents {
        _ = try portableBackupManifest()
        return SyncableContents(
            modules: orderedSyncableModuleEntries(),
            compatibilityManifest: try decodedCompatibilityManifest()
        )
    }

    private func orderedSyncableModuleEntries() -> [Entry] {
        // Installed translations and other modules must be available before
        // compatible personal modules that may reference them.
        entries.filter { Self.isPortableModulePath($0.path) }
            + entries.filter { Self.isCompatibleModulePath($0.path) }
    }

    private func decodedCompatibilityManifest() throws -> LampCompatibilityManifest? {
        guard let entry = entries.first(where: {
            $0.path == LampPortableBackupLayout.compatibilityManifestPath
        }) else { return nil }
        let manifest = try JSONDecoder().decode(LampCompatibilityManifest.self, from: entry.data)
        try manifest.validatePayloads(in: entries)
        return manifest
    }

    private static func isPortableModulePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count == 2
            && components[0] == Substring(LampPortableBackupLayout.modulesDirectory)
            && components[1].lowercased().hasSuffix(".lamp")
    }

    static func isCompatibleModulePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count == 3
            && components[0] == Substring(LampPortableBackupLayout.compatibleDirectory)
            && compatibleDirectories.contains(String(components[1]))
            && components[2].lowercased().hasSuffix(".lamp")
    }

    public func extract(
        to directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validate()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateDestinations(in: directory, fileManager: fileManager)
        for entry in entries {
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rejectSymbolicLinks(for: entry.path, in: directory, fileManager: fileManager)
            try entry.data.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: entry.modifiedAt],
                ofItemAtPath: destination.path
            )
        }
    }

    func validateDestinations(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        try validate()
        let root = directory.standardizedFileURL.path + "/"
        // Check every destination before writing any file. A pre-existing link
        // inside the extraction directory must not redirect archive data outside it.
        for entry in entries {
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(root) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            try rejectSymbolicLinks(for: entry.path, in: directory, fileManager: fileManager)
        }
    }

    public func validate() throws {
        guard formatVersion == 1 || formatVersion == Self.currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(formatVersion)
        }
        var seen = Set<String>()
        for entry in entries {
            let segments = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"),
                  !entry.path.contains("\\"),
                  !entry.path.contains("\0"),
                  !segments.isEmpty,
                  segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            guard seen.insert(entry.path).inserted else {
                throw ArchiveError.duplicatePath(entry.path)
            }
            if formatVersion == Self.currentFormatVersion {
                guard entry.sha256 == LampSyncContentRevision.digest(for: entry.data) else {
                    throw ArchiveError.checksumMismatch(entry.path)
                }
            }
        }
        for entry in entries {
            let components = entry.path.split(separator: "/")
            for index in 1..<components.count where seen.contains(components.prefix(index).joined(separator: "/")) {
                throw ArchiveError.unsafePath(entry.path)
            }
        }
    }

    func rejectSymbolicLinks(
        for path: String,
        in directory: URL,
        fileManager: FileManager
    ) throws {
        var componentURL = directory
        for component in path.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: componentURL.path)) != nil {
                throw ArchiveError.unsafePath(path)
            }
        }
    }
}
