import Foundation
import Testing
@testable import LampModuleKit

struct LampPortableSettingsCodecTests {
    @Test func roundTripsAllowedPreferencesAndIgnoresUnknownKeys() throws {
        let sourceName = "portable-settings-source-\(UUID().uuidString)"
        let destinationName = "portable-settings-destination-\(UUID().uuidString)"
        let source = try #require(UserDefaults(suiteName: sourceName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        defer {
            source.removePersistentDomain(forName: sourceName)
            destination.removePersistentDomain(forName: destinationName)
        }
        source.set(19.5, forKey: "reader.fontSize")
        source.set(["hidden-module"], forKey: "modules.hiddenIDs")
        source.set("private", forKey: "sync.webdav.password")

        let encoded = try LampPortableSettingsCodec.encode(from: source)
        let decoded = try LampPortableSettingsCodec.decode(encoded)
        #expect(decoded["reader.fontSize"] as? Double == 19.5)
        #expect(decoded["modules.hiddenIDs"] as? [String] == ["hidden-module"])
        #expect(decoded["sync.webdav.password"] == nil)

        try LampPortableSettingsCodec.apply(encoded, to: destination)
        #expect(destination.double(forKey: "reader.fontSize") == 19.5)
        #expect(destination.stringArray(forKey: "modules.hiddenIDs") == ["hidden-module"])
        #expect(destination.object(forKey: "sync.webdav.password") == nil)

        destination.set(21.0, forKey: "reader.fontSize")
        try LampPortableSettingsCodec.apply(
            encoded,
            to: destination,
            excluding: LampSharedPreferenceLedger.sharedKeys
        )
        #expect(destination.double(forKey: "reader.fontSize") == 21.0)
        #expect(destination.stringArray(forKey: "modules.hiddenIDs") == ["hidden-module"])

        let legacy = try PropertyListSerialization.data(
            fromPropertyList: [
                "reader.defaultTranslationID": "BSBs",
                "future.setting": "ignored",
            ],
            format: .binary,
            options: 0
        )
        let legacySettings = try LampPortableSettingsCodec.decode(legacy)
        #expect(legacySettings["reader.defaultTranslationID"] as? String == "BSBs")
        #expect(legacySettings["future.setting"] == nil)
    }

    @Test func rejectsMalformedPortableSettings() throws {
        #expect(throws: Error.self) {
            try LampPortableSettingsCodec.decode(Data("not a plist".utf8))
        }
        let array = try PropertyListSerialization.data(
            fromPropertyList: ["wrong root"], format: .binary, options: 0
        )
        #expect(throws: LampPortableSettingsCodec.CodecError.self) {
            try LampPortableSettingsCodec.decode(array)
        }
    }
}
