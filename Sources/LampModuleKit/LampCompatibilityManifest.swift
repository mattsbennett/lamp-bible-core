import Foundation

/// Records the WebDAV folder revision that the archive superseded for each
/// compatibility file. Readers can ignore a folder file still at that revision.
public struct LampCompatibilityManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let baseRevision: String?
        public let sha256: String

        public init(path: String, data: Data, baseRevision: String?) {
            self.path = path
            self.baseRevision = baseRevision
            self.sha256 = LampSyncContentRevision.digest(for: data)
        }
    }

    public enum ManifestError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case duplicatePath(String)
        case missingPayload(String)
        case checksumMismatch(String)
        case invalidRevision(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported compatibility manifest version: \(version)."
            case .duplicatePath(let path):
                "Duplicate compatibility path: \(path)."
            case .missingPayload(let path):
                "Missing compatibility payload: \(path)."
            case .checksumMismatch(let path):
                "Compatibility payload is damaged: \(path)."
            case .invalidRevision(let path):
                "Compatibility file has no strong base revision: \(path)."
            }
        }
    }

    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let files: [File]

    public init(files: [File]) {
        self.formatVersion = Self.currentFormatVersion
        self.files = files
    }

    public func baseRevision(for path: String) -> String? {
        files.first(where: { $0.path == path })?.baseRevision
    }

    public func supersedes(path: String, revision: String?) -> Bool {
        guard let revision, let baseRevision = baseRevision(for: path) else {
            return false
        }
        return baseRevision == revision
    }

    public func validate(against archive: LampSyncArchive) throws {
        _ = try archive.portableBackupManifest()
        try validatePayloads(in: archive.entries)
    }

    func validatePayloads(in entries: [LampSyncArchive.Entry]) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ManifestError.unsupportedVersion(formatVersion)
        }
        let prefix = LampPortableBackupLayout.compatibleDirectory + "/"
        let payloads = Dictionary(uniqueKeysWithValues: entries
            .filter { LampSyncArchive.isCompatibleModulePath($0.path) }
            .map {
            (String($0.path.dropFirst(prefix.count)), $0.data)
        })
        var seen = Set<String>()
        for file in files {
            guard seen.insert(file.path).inserted else {
                throw ManifestError.duplicatePath(file.path)
            }
            guard let payload = payloads[file.path] else {
                throw ManifestError.missingPayload(file.path)
            }
            guard file.sha256 == File(path: file.path, data: payload, baseRevision: nil).sha256 else {
                throw ManifestError.checksumMismatch(file.path)
            }
            if let revision = file.baseRevision,
               !LampWebDAVStorage.isStrongETag(revision) {
                throw ManifestError.invalidRevision(file.path)
            }
        }
        for path in payloads.keys where !seen.contains(path) {
            throw ManifestError.missingPayload(path)
        }
    }
}
