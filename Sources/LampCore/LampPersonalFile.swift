import Foundation

/// What every file the reader's own content travels in has in common.
///
/// Small, and worth having apart all the same: the way a value is spelled
/// is the contract between two apps. Two encoders that disagree about key
/// order or an escaped slash make each device decide the other's file is
/// new and upload its own in reply — a sync that never settles, from a
/// difference nobody would call a bug on either side.
public enum LampPersonalFile {
    /// JSON written the one way: keys sorted, slashes unescaped, a bare
    /// value allowed.
    public static func jsonFragment(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
