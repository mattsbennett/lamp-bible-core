import Foundation

/// Stores the last shared preference ledger applied by one sync source.
/// Callers choose a namespaced key so existing installations retain their
/// saved bases while both platforms use the same validation and encoding.
public enum LampSyncPreferenceState {
    public static func decode(_ data: Data) throws -> LampSharedPreferenceLedger {
        let ledger = try JSONDecoder().decode(LampSharedPreferenceLedger.self, from: data)
        try ledger.validate()
        return ledger
    }

    public static func encode(_ ledger: LampSharedPreferenceLedger) throws -> Data {
        try ledger.validate()
        return try JSONEncoder().encode(ledger)
    }

    public static func ledger(in archive: LampSyncArchive) throws -> LampSharedPreferenceLedger? {
        guard let entry = archive.entries.first(where: {
            $0.path == LampPortableBackupLayout.sharedPreferencesPath
        }) else { return nil }
        return try decode(entry.data)
    }

    public static func replacing(
        _ ledger: LampSharedPreferenceLedger,
        in archive: LampSyncArchive
    ) throws -> LampSyncArchive {
        try archive.replacingEntry(
            at: LampPortableBackupLayout.sharedPreferencesPath,
            with: encode(ledger)
        )
    }

    public static func cached(
        for source: String,
        in defaults: UserDefaults,
        key: String
    ) -> LampSharedPreferenceLedger? {
        guard let states = defaults.dictionary(forKey: key),
              let data = states[source] as? Data else { return nil }
        return try? decode(data)
    }

    public static func remember(
        _ ledger: LampSharedPreferenceLedger,
        for source: String,
        in defaults: UserDefaults,
        key: String
    ) throws {
        let data = try encode(ledger)
        var states = defaults.dictionary(forKey: key) ?? [:]
        states[source] = data
        defaults.set(states, forKey: key)
    }
}
