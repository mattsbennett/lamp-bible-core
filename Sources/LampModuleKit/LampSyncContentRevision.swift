import CryptoKit
import Foundation

/// A revision derived from the complete file body for providers that do not
/// supply an opaque server revision. Equal tokens mean equal bytes, subject to
/// SHA-256 collision resistance; this is not an atomic write precondition.
public enum LampSyncContentRevision {
    public static func digest(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func token(for data: Data) -> String {
        "sha256:" + digest(for: data)
    }

    public static func matchesDigest(_ expected: String?, observed: Data?) -> Bool {
        switch (expected, observed) {
        case (nil, nil): true
        case (let expected?, let observed?): digest(for: observed) == expected
        default: false
        }
    }

    public static func matchesToken(_ expected: String?, observed: Data?) -> Bool {
        switch (expected, observed) {
        case (nil, nil): true
        case (let expected?, let observed?): token(for: observed) == expected
        default: false
        }
    }

    /// Media has no stored merge base. It may be created or repeated with
    /// identical bytes, but a different existing body needs reconciliation.
    public static func allowsUnbasedWrite(_ data: Data, over observed: Data?) -> Bool {
        observed == nil || observed == data
    }
}
