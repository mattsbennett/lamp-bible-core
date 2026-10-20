import Foundation

/// Owns the iOS settings database entry inside the shared archive. Mac does
/// not edit that database, so its full archive rebuild must retain the exact
/// entry it read before publishing against that archive revision.
public enum LampSyncSettingsArchive {
    public static let path = LampSyncLayout.userSettingsPath
    public static let legacyManifestPath = "Settings/legacy-ios-settings.json"

    public enum SettingsArchiveError: Error, LocalizedError, Equatable {
        case unversionedLegacyFile
        case unsupportedManifest(Int)
        case invalidManifest
        case missingSettingsData
        case changedLegacyFile

        public var errorDescription: String? {
            switch self {
            case .unversionedLegacyFile:
                "The legacy settings file has no strong revision for a safe migration."
            case .unsupportedManifest(let version):
                "Unsupported legacy settings manifest version: \(version)."
            case .invalidManifest:
                "The legacy settings manifest does not match the archive."
            case .missingSettingsData:
                "The settings manifest has no database entry."
            case .changedLegacyFile:
                "The older client's settings file changed after the archive was published."
            }
        }
    }

    public struct LegacyManifest: Codable, Equatable, Sendable {
        public static let currentFormatVersion = 1

        public let formatVersion: Int
        public let archiveSHA256: String
        public let legacyBaseRevision: String?
        public let legacyBaseSHA256: String?

        public init(archiveData: Data, observedLegacy: LampSyncRemoteFile?) throws {
            if let observedLegacy,
               !LampWebDAVStorage.isStrongETag(observedLegacy.revision ?? "") {
                throw SettingsArchiveError.unversionedLegacyFile
            }
            formatVersion = Self.currentFormatVersion
            archiveSHA256 = LampSyncContentRevision.digest(for: archiveData)
            legacyBaseRevision = observedLegacy?.revision
            legacyBaseSHA256 = observedLegacy.map { LampSyncContentRevision.digest(for: $0.data) }
        }

        public func validate(archiveData: Data) throws {
            guard formatVersion == Self.currentFormatVersion else {
                throw SettingsArchiveError.unsupportedManifest(formatVersion)
            }
            guard archiveSHA256 == LampSyncContentRevision.digest(for: archiveData),
                  (legacyBaseRevision == nil) == (legacyBaseSHA256 == nil),
                  legacyBaseRevision.map(LampWebDAVStorage.isStrongETag) ?? true else {
                throw SettingsArchiveError.invalidManifest
            }
        }
    }

    public static func data(in archive: LampSyncArchive) throws -> Data? {
        _ = try archive.portableBackupManifest()
        return archive.entries.first(where: { $0.path == path })?.data
    }

    /// Settings publication may rebuild checksums while preserving every
    /// unrelated file. Compare the actual bytes so a later preference merge
    /// cannot silently switch to a different set of modules.
    public static func preservesOtherContents(
        from observed: LampSyncArchive?,
        to current: LampSyncArchive?
    ) -> Bool {
        let excluded = Set([path, legacyManifestPath])
        let original = Dictionary(uniqueKeysWithValues: (observed?.entries ?? [])
            .filter { !excluded.contains($0.path) }
            .map { ($0.path, $0.data) })
        var updated = Dictionary(uniqueKeysWithValues: (current?.entries ?? [])
            .filter { !excluded.contains($0.path) }
            .map { ($0.path, $0.data) })
        if observed == nil {
            // Creating a settings-only archive also creates its manifest.
            updated.removeValue(forKey: LampPortableBackupLayout.manifestPath)
        }
        return original == updated
    }

    public static func legacyManifest(in archive: LampSyncArchive) throws -> LegacyManifest? {
        _ = try archive.portableBackupManifest()
        guard let entry = archive.entries.first(where: { $0.path == legacyManifestPath }) else {
            return nil
        }
        guard let settingsData = try data(in: archive) else {
            throw SettingsArchiveError.missingSettingsData
        }
        let manifest = try JSONDecoder().decode(LegacyManifest.self, from: entry.data)
        try manifest.validate(archiveData: settingsData)
        return manifest
    }

    public static func preservingRemoteEntry(
        in outgoing: LampSyncArchive,
        from observed: LampSyncArchive?
    ) throws -> LampSyncArchive {
        let stripped = LampSyncArchive(
            formatVersion: outgoing.formatVersion,
            entries: outgoing.entries.filter {
                $0.path != path && $0.path != legacyManifestPath
            }
        )
        try stripped.validate()
        guard let observed,
              let entry = observed.entries.first(where: { $0.path == path }) else {
            return stripped
        }
        _ = try observed.portableBackupManifest()
        let withSettings = try stripped.replacingEntry(
            at: path,
            with: entry.data,
            modifiedAt: entry.modifiedAt
        )
        guard let manifestEntry = observed.entries.first(where: {
            $0.path == legacyManifestPath
        }) else { return withSettings }
        _ = try legacyManifest(in: observed)
        return try withSettings.replacingEntry(
            at: legacyManifestPath,
            with: manifestEntry.data,
            modifiedAt: manifestEntry.modifiedAt
        )
    }

    /// Add the current settings database to an existing archive, or create a
    /// valid settings-only archive when no Mac archive has been published yet.
    public static func replacingData(
        _ data: Data,
        in archive: LampSyncArchive?,
        observedLegacy: LampSyncRemoteFile? = nil,
        modifiedAt: Date = Date()
    ) throws -> LampSyncArchive {
        let base: LampSyncArchive
        if let archive {
            _ = try archive.portableBackupManifest()
            base = archive
        } else {
            let manifest = LampPortableBackupManifest(
                generatedAt: modifiedAt,
                summary: .init(
                    moduleCount: 0,
                    noteDocumentCount: 0,
                    highlightDocumentCount: 0,
                    devotionalDocumentCount: 0
                )
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            base = LampSyncArchive(formatVersion: 1, entries: [
                .init(
                    path: LampPortableBackupLayout.manifestPath,
                    data: try encoder.encode(manifest),
                    modifiedAt: modifiedAt
                )
            ])
        }
        let withSettings = try base.replacingEntry(
            at: path,
            with: data,
            modifiedAt: modifiedAt
        )
        let manifest = try LegacyManifest(
            archiveData: data,
            observedLegacy: observedLegacy
        )
        return try withSettings.replacingEntry(
            at: legacyManifestPath,
            with: JSONEncoder().encode(manifest),
            modifiedAt: modifiedAt
        )
    }

    private static func strongToken(_ revision: String) -> String? {
        LampWebDAVStorage.isStrongETag(revision)
            ? LampSyncConditionalWrite.token(for: revision) : nil
    }
}
