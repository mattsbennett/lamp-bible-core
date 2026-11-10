import Foundation
import Testing
@testable import LampModuleKit

/// The AI features switch: one key, off by default, carried between devices
/// and in a backup, so one choice covers every device.
struct LampAIFeaturesPreferenceTests {
    @Test func itIsOffUntilSomeoneTurnsItOn() {
        #expect(LampPreferenceDefaults.aiFeaturesEnabled == false)
    }

    @Test func itIsAShareablePreference() throws {
        #expect(LampSharedPreferenceLedger.sharedKeys.contains(LampPreferenceDefaults.aiFeaturesKey))
        #expect(LampPortableSettingsCodec.syncedKeys.contains(LampPreferenceDefaults.aiFeaturesKey))

        let suite = "LampAIFeaturesPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LampPreferenceDefaults.aiFeaturesKey)
        let values = try LampSharedPreferenceLedger.explicitValues(from: defaults)
        #expect(values[LampPreferenceDefaults.aiFeaturesKey] == .boolean(true))
    }

    @Test func anUnsetSwitchIsNotSent() throws {
        // Only a choice someone made travels: a device that has never been
        // asked must not switch another device off by default.
        let suite = "LampAIFeaturesPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let values = try LampSharedPreferenceLedger.explicitValues(from: defaults)
        #expect(values[LampPreferenceDefaults.aiFeaturesKey] == nil)
    }

    @Test func aStringIsRejected() {
        let ledger = LampSharedPreferenceLedger(fields: [
            LampPreferenceDefaults.aiFeaturesKey: .init(value: .string("yes")),
        ])
        #expect(throws: (any Error).self) { try ledger.validate() }
    }
}
