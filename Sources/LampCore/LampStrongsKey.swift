import Foundation

/// Lexical key comparison shared by reader links, dictionary lookups and search.
public enum LampStrongsKey {
    private static let untranslatedEnglishMarkers: Set<String> = ["H853"]

    /// Keeps the language and suffix while removing case and numeric zero padding.
    /// String operations avoid treating two overflowing numbers as the same key.
    public static func normalized(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let prefix: String
        if trimmed.hasPrefix("TH") {
            prefix = "TH"
        } else if trimmed.hasPrefix("H") || trimmed.hasPrefix("G") {
            prefix = String(trimmed.prefix(1))
        } else {
            prefix = ""
        }
        let rest = trimmed.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return trimmed }
        let unpadded = digits.drop { $0 == "0" }
        return prefix + (unpadded.isEmpty ? "0" : String(unpadded))
            + String(rest.dropFirst(digits.count))
    }

    /// Bare dictionary numbers may answer a prefixed Strong's key. Hebrew,
    /// Greek, morphology keys and disambiguating suffixes remain distinct.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftPrefixed = left.hasPrefix("H") || left.hasPrefix("G")
        let rightPrefixed = right.hasPrefix("H") || right.hasPrefix("G")
        guard leftPrefixed != rightPrefixed else { return false }
        let bare = leftPrefixed ? right : left
        guard bare.first?.isASCII == true, bare.first?.isNumber == true else { return false }
        return (leftPrefixed ? String(left.dropFirst()) : left)
            == (rightPrefixed ? String(right.dropFirst()) : right)
    }

    public static func hasAnnotations<S: Sequence>(_ rawKeys: S) -> Bool
    where S.Element == String? {
        rawKeys.contains {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Expands legacy lists, removes duplicate keys, and suppresses source-language
    /// markers that don't represent a word in the English translation.
    public static func readerLookupKeys(_ rawKeys: [String]) -> [String] {
        var seen = Set<String>()
        return rawKeys.flatMap {
            $0.split { $0 == "," || $0 == ";" || $0 == "|" || $0.isWhitespace }
        }.map { normalized(String($0)) }.filter {
            !$0.isEmpty && !untranslatedEnglishMarkers.contains($0)
                && seen.insert($0).inserted
        }
    }
}
