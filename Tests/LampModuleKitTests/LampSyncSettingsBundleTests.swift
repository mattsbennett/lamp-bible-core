import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncSettingsBundleTests {
    private func bundle() throws -> LampSyncSettingsBundle {
        var manifest = LampSyncLibraryManifest()
        manifest = try manifest.recordingWrite("Notes/notes.lamp", revision: "\"1\"", replacing: nil, at: 5)
        manifest = try manifest.removing("Translations/kjv.lamp", at: 7, revision: "\"2\"")
        return LampSyncSettingsBundle(
            userSettings: Data("settings".utf8),
            macSettings: Data("plist".utf8),
            preferences: .init(fields: ["reader.fontSize": .init(value: .number(18))]),
            personalDeletions: Data("{}".utf8),
            manifest: manifest
        )
    }

    @Test func aBundleSurvivesTheRoundTrip() throws {
        let original = try bundle()
        let encoded = try original.encoded()
        #expect(LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: encoded)) == .bundle)
        #expect(try LampSyncSettingsBundle.decode(encoded) == original)
        // The same bundle always encodes to the same bytes.
        #expect(try original.encoded() == encoded)
    }

    @Test func anOldArchiveReaderRefusesTheBundle() throws {
        let encoded = try bundle().encoded()
        #expect {
            try LampSyncArchive.decode(compressedData: encoded)
        } throws: { error in
            guard case LampSyncArchive.ArchiveError.unsupportedVersion(3) = error else { return false }
            return true
        }
    }

    @Test func anArchiveIsRecognisedFromItsHeaderAlone() throws {
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: "manifest.json", data: Data(repeating: 7, count: 1 << 20), modifiedAt: Date(timeIntervalSince1970: 0)),
        ])
        let packed = try archive.compressedData()
        #expect(LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: packed)) == .archive)
        #expect(throws: LampSyncSettingsBundle.BundleError.isArchive) {
            try LampSyncSettingsBundle.decode(packed)
        }
    }

    @Test func damageIsNotMistakenForAnArchive() {
        #expect(throws: LampSyncSettingsBundle.BundleError.damaged) {
            try LampSyncSettingsBundle.decode(Data("not zlib at all".utf8))
        }
    }
}
