import Foundation
import Testing
@testable import LampModuleKit

struct LampCompatibilityManifestTests {
    @Test func validatesCommittedPayloadAndRejectsStaleOrDamagedMetadata() throws {
        let backup = LampPortableBackupManifest(
            generatedAt: .distantPast,
            summary: .init(
                moduleCount: 0,
                noteDocumentCount: 1,
                highlightDocumentCount: 0,
                devotionalDocumentCount: 0
            )
        )
        let backupEncoder = JSONEncoder()
        backupEncoder.dateEncodingStrategy = .iso8601
        let payload = Data("notes module".utf8)
        let record = LampCompatibilityManifest.File(
            path: "Notes/notes.lamp",
            data: payload,
            baseRevision: "\"old-revision\""
        )
        let manifest = LampCompatibilityManifest(files: [record])
        let entries: [LampSyncArchive.Entry] = [
            .init(
                path: LampPortableBackupLayout.manifestPath,
                data: try backupEncoder.encode(backup),
                modifiedAt: .distantPast
            ),
            .init(
                path: LampPortableBackupLayout.compatibilityManifestPath,
                data: try JSONEncoder().encode(manifest),
                modifiedAt: .distantPast
            ),
            .init(
                path: "Compatibility/Notes/notes.lamp",
                data: payload,
                modifiedAt: .distantPast
            ),
        ]
        let archive = LampSyncArchive(formatVersion: 1, entries: entries)
        #expect(try archive.compatibilityManifest()?.baseRevision(for: "Notes/notes.lamp") == "\"old-revision\"")
        #expect(manifest.supersedes(path: "Notes/notes.lamp", revision: "\"old-revision\""))
        #expect(!manifest.supersedes(path: "Notes/notes.lamp", revision: "\"new-revision\""))
        #expect(!manifest.supersedes(path: "Notes/notes.lamp", revision: nil))

        var damaged = entries
        damaged[2] = .init(
            path: damaged[2].path,
            data: Data("changed".utf8),
            modifiedAt: .distantPast
        )
        #expect(throws: LampCompatibilityManifest.ManifestError.self) {
            try LampSyncArchive(formatVersion: 1, entries: damaged).compatibilityManifest()
        }

        let weak = LampCompatibilityManifest(files: [
            .init(path: "Notes/notes.lamp", data: payload, baseRevision: "W/\"old-revision\"")
        ])
        #expect(throws: LampCompatibilityManifest.ManifestError.self) {
            try weak.validate(against: archive)
        }
    }
}
