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
        #expect(merged.publishable.fields["reader.fontSize"] == remote.fields["reader.fontSize"])
        #expect(merged.publishable.fields["reader.defaultTranslationID"]?.value == .string("KJV"))
        #expect(merged.publishable.fields["reader.defaultTranslationID"]?.revision != base.fields["reader.defaultTranslationID"]?.revision)
        #expect(merged.publishable.fields["future.preference"] == remote.fields["future.preference"])

        let roundTrip = try JSONDecoder().decode(
            LampSharedPreferenceLedger.self,
            from: JSONEncoder().encode(merged.publishable)
        )
        #expect(roundTrip == merged.publishable)
    }

    @Test func reportsConcurrentEditToOneField() throws {
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18), revision: "00000000-0000-0000-0000-000000000001"),
        ])
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(20), revision: "00000000-0000-0000-0000-000000000002"),
        ])
        // Both devices moved this field away from what they agreed, and
        // nothing here can say which was meant. It is set aside rather than
        // refused: the rest of the sync is not held hostage to one number.
        let disputed = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(22)],
            base: base,
            remote: remote
        )
        #expect(disputed.disputed == ["reader.fontSize"])
        // Published: the server's own value, so publishing changes nothing
        // for it and the other device's edit survives.
        #expect(disputed.publishable.fields["reader.fontSize"] == remote.fields["reader.fontSize"])
        // Applied: nothing, so this device keeps what its user set.
        #expect(disputed.applicable.fields["reader.fontSize"] == nil)
        // Recorded: what they last agreed, so it is still disputed next time
        // rather than quietly settled in someone's favour.
        #expect(disputed.baseline.fields["reader.fontSize"] == base.fields["reader.fontSize"])
        let sameValue = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(20)],
            base: base,
            remote: remote
        )
        #expect(sameValue.publishable.fields["reader.fontSize"] == remote.fields["reader.fontSize"])
        #expect(sameValue.disputed.isEmpty)
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
        #expect(merged.publishable.fields["reader.defaultTranslationID"]?.value == nil)
        defaults.set("BSBs", forKey: "reader.defaultTranslationID")
        try merged.applicable.apply(to: defaults)
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
    // MARK: - A client that has recorded nothing yet

    /// The deadlock this replaced. With no baseline, every local value looks
    /// new, so any difference from the server read as two people editing at
    /// once. The merge refused, nothing was recorded, and the next pass had
    /// no baseline either — silently, for good, with the client's
    /// preferences never syncing.
    @Test func aClientWithNoBaselineAdoptsTheServersValue() throws {
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(19), revision: UUID().uuidString),
        ])

        let merged = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(18)], base: nil, remote: remote
        )

        #expect(merged.publishable.fields["reader.fontSize"]?.value == .number(19))
    }

    /// A value only this client holds is contributed, not dropped: the server
    /// has nothing to say about it, so there is nothing to defer to.
    @Test func aClientWithNoBaselineContributesWhatTheServerLacks() throws {
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(19), revision: UUID().uuidString),
        ])

        let merged = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(18), "reader.showStrongsHints": .boolean(true)],
            base: nil,
            remote: remote
        )

        #expect(merged.publishable.fields["reader.fontSize"]?.value == .number(19))
        #expect(merged.publishable.fields["reader.showStrongsHints"]?.value == .boolean(true))
    }

    @Test func theFirstClientOfAllKeepsItsOwnValues() throws {
        let merged = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(18)], base: nil, remote: nil
        )

        #expect(merged.publishable.fields["reader.fontSize"]?.value == .number(18))
    }

    /// With a baseline, a genuine simultaneous edit is still a disagreement
    /// — both sides moved the same field away from what they agreed, and
    /// nothing here can say which was meant — but it is set aside rather
    /// than refused. Refusing aborted the entire sync over one scalar, with
    /// nothing anywhere able to resolve it.
    @Test func aRealSimultaneousEditIsSetAsideRatherThanRefused() throws {
        let agreed = UUID().uuidString
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18), revision: agreed),
        ])
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(20), revision: UUID().uuidString),
        ])

        let merged = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(19)], base: base, remote: remote
        )

        #expect(merged.disputed == ["reader.fontSize"])
        #expect(merged.publishable.fields["reader.fontSize"]?.value == .number(20))
        #expect(merged.applicable.fields["reader.fontSize"] == nil)
        #expect(merged.baseline.fields["reader.fontSize"]?.value == .number(18))
    }

    /// Everything else still syncs while one field is in dispute, which is
    /// the whole point: a disagreement about a font size stopped a library.
    @Test func otherFieldsStillMergeAroundADisputedOne() throws {
        let agreed = UUID().uuidString
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(18), revision: agreed),
            "reader.defaultTranslationID": .init(value: .string("BSBs"), revision: agreed),
        ])
        let remote = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number(20), revision: UUID().uuidString),
            "reader.defaultTranslationID": .init(value: .string("BSBs"), revision: agreed),
        ])

        let merged = try LampSharedPreferenceLedger.merge(
            local: [
                "reader.fontSize": .number(19),
                "reader.defaultTranslationID": .string("ESVs"),
            ],
            base: base,
            remote: remote
        )

        #expect(merged.disputed == ["reader.fontSize"])
        // Only this device touched the translation, so it goes up as usual.
        #expect(merged.publishable.fields["reader.defaultTranslationID"]?.value == .string("ESVs"))
        #expect(merged.applicable.fields["reader.defaultTranslationID"]?.value == .string("ESVs"))
    }

}
