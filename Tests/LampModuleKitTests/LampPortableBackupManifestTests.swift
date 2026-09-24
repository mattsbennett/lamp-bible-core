import Foundation
import Testing
@testable import LampModuleKit

struct LampPortableBackupManifestTests {
    @Test func decodesExistingVersionOneManifest() throws {
        let data = Data(#"""
            {"formatVersion":1,"generatedAt":"2026-01-01T00:00:00Z","summary":{
              "moduleCount":2,"noteDocumentCount":3,
              "highlightDocumentCount":4,"devotionalDocumentCount":5
            }}
            """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LampPortableBackupManifest.self, from: data)
        try manifest.validate()
        #expect(manifest.summary.moduleCount == 2)
        #expect(manifest.summary.devotionalDocumentCount == 5)
    }

    @Test func rejectsUnknownVersionBeforeImport() throws {
        let manifest = LampPortableBackupManifest(
            formatVersion: 9,
            generatedAt: .distantPast,
            summary: .init(
                moduleCount: 0, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        #expect(throws: LampPortableBackupManifest.ManifestError.self) {
            try manifest.validate()
        }
    }
}
