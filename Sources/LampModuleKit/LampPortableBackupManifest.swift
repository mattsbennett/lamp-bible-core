import Foundation

/// The manifest stored inside a portable backup and the shared sync archive.
/// Its JSON shape matches version 1 backups already written by the Mac app.
public struct LampPortableBackupManifest: Codable, Equatable, Sendable {
    public struct Summary: Codable, Equatable, Sendable {
        public let moduleCount: Int
        public let noteDocumentCount: Int
        public let highlightDocumentCount: Int
        public let devotionalDocumentCount: Int

        public init(
            moduleCount: Int,
            noteDocumentCount: Int,
            highlightDocumentCount: Int,
            devotionalDocumentCount: Int
        ) {
            self.moduleCount = moduleCount
            self.noteDocumentCount = noteDocumentCount
            self.highlightDocumentCount = highlightDocumentCount
            self.devotionalDocumentCount = devotionalDocumentCount
        }
    }

    public enum ManifestError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case invalidCounts

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported portable backup version: \(version)."
            case .invalidCounts:
                "The portable backup manifest contains invalid counts."
            }
        }
    }

    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let generatedAt: Date
    public let summary: Summary

    public init(
        formatVersion: Int = currentFormatVersion,
        generatedAt: Date,
        summary: Summary
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.summary = summary
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ManifestError.unsupportedVersion(formatVersion)
        }
        guard summary.moduleCount >= 0,
              summary.noteDocumentCount >= 0,
              summary.highlightDocumentCount >= 0,
              summary.devotionalDocumentCount >= 0 else {
            throw ManifestError.invalidCounts
        }
    }
}
