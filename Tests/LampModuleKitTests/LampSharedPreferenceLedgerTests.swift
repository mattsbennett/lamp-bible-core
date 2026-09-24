import Foundation
import Testing
@testable import LampModuleKit

struct LampSharedPreferenceLedgerTests {
    @Test func sharedStateKeepsSourceBasesSeparateAndRejectsInvalidCache() throws {
        let suite = "preference-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "shared-preference-bases"
        let first = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18))
        ])
        let second = LampSharedPreferenceLedger(fields: [
            "plans.reminder.hour": .init(value: .integer(8))
        ])
        try LampSyncPreferenceState.remember(first, for: "ios", in: defaults, key: key)
        try LampSyncPreferenceState.remember(second, for: "mac", in: defaults, key: key)
        #expect(LampSyncPreferenceState.cached(for: "ios", in: defaults, key: key) == first)
        #expect(LampSyncPreferenceState.cached(for: "mac", in: defaults, key: key) == second)
        #expect(LampSyncPreferenceState.cached(for: "ios", in: defaults, key: "other") == nil)

        var states = try #require(defaults.dictionary(forKey: key))
        states["ios"] = Data("invalid".utf8)
        defaults.set(states, forKey: key)
        #expect(LampSyncPreferenceState.cached(for: "ios", in: defaults, key: key) == nil)
        #expect(LampSyncPreferenceState.cached(for: "mac", in: defaults, key: key) == second)
    }

    @Test func sharedStateReplacesOnlyPreferenceArchiveEntry() throws {
        let archive = try LampSyncSettingsArchive.replacingData(Data("settings".utf8), in: nil)
            .replacingEntry(at: "Modules/example.lamp", with: Data("module".utf8))
        let ledger = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(19))
        ])
        let updated = try LampSyncPreferenceState.replacing(ledger, in: archive)
        #expect(try LampSyncPreferenceState.ledger(in: updated) == ledger)
        #expect(updated.entries.first { $0.path == "Modules/example.lamp" }?.data
            == Data("module".utf8))
        #expect(try LampSyncSettingsArchive.data(in: updated) == Data("settings".utf8))
    }

    @Test func mergesIndependentChangesAndPreservesUnknownFields() throws {
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18), revision: "00000000-0000-0000-0000-000000000001"),
            "reader.defaultTranslationID": .init(value: .string("BSBs"), revision: "00000000-0000-0000-0000-000000000002"),
        ])
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(20), revision: "00000000-0000-0000-0000-000000000003"),
            "reader.defaultTranslationID": try #require(base.fields["reader.defaultTranslationID"]),
            "future.preference": .init(value: .string("keep"), revision: "00000000-0000-0000-0000-000000000004"),
        ])
        let merged = try LampSharedPreferenceLedger.merge(
            local: [
                "reader.fontSize": .number(18),
                "reader.defaultTranslationID": .string("KJV"),
            ],
            base: base,
            remote: remote
        )
        #expect(merged.fields["reader.fontSize"] == remote.fields["reader.fontSize"])
        #expect(merged.fields["reader.defaultTranslationID"]?.value == .string("KJV"))
        #expect(merged.fields["reader.defaultTranslationID"]?.revision != base.fields["reader.defaultTranslationID"]?.revision)
        #expect(merged.fields["future.preference"] == remote.fields["future.preference"])

        let roundTrip = try JSONDecoder().decode(
            LampSharedPreferenceLedger.self,
            from: JSONEncoder().encode(merged)
        )
        #expect(roundTrip == merged)
    }

    @Test func reportsConcurrentEditToOneField() throws {
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18), revision: "00000000-0000-0000-0000-000000000001"),
        ])
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(20), revision: "00000000-0000-0000-0000-000000000002"),
        ])
        #expect(throws: LampSharedPreferenceLedger.LedgerError.self) {
            try LampSharedPreferenceLedger.merge(
                local: ["reader.fontSize": .number(22)],
                base: base,
                remote: remote
            )
        }
        let sameValue = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(20)],
            base: base,
            remote: remote
        )
        #expect(sameValue.fields["reader.fontSize"] == remote.fields["reader.fontSize"])
        #expect(throws: LampSharedPreferenceLedger.LedgerError.self) {
            try LampSharedPreferenceLedger(fields: [
                "plans.reminder.hour": .init(value: .integer(28)),
            ]).validate()
        }
    }

    @Test func recordsAndAppliesAResetAsATombstone() throws {
        let suite = "preference-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = LampSharedPreferenceLedger(fields: [
            "reader.defaultTranslationID": .init(
                value: .string("BSBs"),
                revision: "00000000-0000-0000-0000-000000000001"
            ),
        ])
        let merged = try LampSharedPreferenceLedger.merge(
            local: [:], base: base, remote: base
        )
        #expect(merged.fields["reader.defaultTranslationID"]?.value == nil)
        defaults.set("BSBs", forKey: "reader.defaultTranslationID")
        try merged.apply(to: defaults)
        #expect(defaults.object(forKey: "reader.defaultTranslationID") == nil)
    }

    @Test func projectsOnlySupportedPreferenceTypes() throws {
        let suite = "preference-projection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(19.5, forKey: "reader.fontSize")
        defaults.set(true, forKey: "reader.showStrongsHints")
        defaults.set(8, forKey: "plans.reminder.hour")
        defaults.set("private", forKey: "sync.webdav.password")

        let values = try LampSharedPreferenceLedger.explicitValues(from: defaults)
        #expect(values["reader.fontSize"] == .number(19.5))
        #expect(values["reader.showStrongsHints"] == .boolean(true))
        #expect(values["plans.reminder.hour"] == .integer(8))
        #expect(values["sync.webdav.password"] == nil)

        let registeredSuite = "preference-registered-\(UUID().uuidString)"
        let registered = try #require(UserDefaults(suiteName: registeredSuite))
        defer { registered.removePersistentDomain(forName: registeredSuite) }
        registered.register(defaults: ["reader.fontSize": 20.0])
        #expect(try LampSharedPreferenceLedger.explicitValues(
            from: registered,
            storedIn: registeredSuite
        ).isEmpty)
    }
}
