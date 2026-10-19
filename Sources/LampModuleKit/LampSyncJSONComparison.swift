import Foundation

/// Whether two stored JSON columns say the same thing.
///
/// The same entry is spelled differently by the two clients: this package
/// writes JSON with sorted keys and an empty list where there is nothing,
/// while the phone writes declaration order and leaves the column null.
/// Compared as text, identical notes and writings read as edited on both
/// devices — which is reported to the person as a conflict over something
/// neither of them changed, and, worse, invites each client to re-publish
/// its own spelling of an entry the other just published.
///
/// So these columns are compared by value. Key order carries no meaning in
/// JSON, and nothing, null and empty all mean the same absence here.
public enum LampSyncJSONComparison {
    public static func sameValue(_ one: String?, _ other: String?) -> Bool {
        switch (canonical(one), canonical(other)) {
        case (.nothing, .nothing):
            true
        case (.value(let a), .value(let b)):
            a == b
        case (.text(let a), .text(let b)):
            // Not JSON at all. Whatever it is, it is compared as written
            // rather than guessed at.
            a == b
        default:
            false
        }
    }

    private enum Canonical: Equatable {
        case nothing
        case value(Data)
        case text(String)
    }

    private static func canonical(_ stored: String?) -> Canonical {
        guard let stored,
              let trimmed = Optional(
                  stored.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              !trimmed.isEmpty, trimmed != "null" else {
            return .nothing
        }
        guard let parsed = try? JSONSerialization.jsonObject(
            with: Data(trimmed.utf8), options: [.fragmentsAllowed]
        ) else {
            // Exactly as stored, including surrounding whitespace. Trimming
            // it here would be a normalisation of something whose meaning
            // this type does not know: leading spaces make a Markdown code
            // block, and an edit that only indented a line would read as no
            // edit at all. Comparing text exactly can at worst cost a
            // needless republish; normalising it can drop someone's change.
            return .text(stored)
        }
        if let array = parsed as? [Any], array.isEmpty { return .nothing }
        if let object = parsed as? [String: Any], object.isEmpty { return .nothing }
        guard let data = try? JSONSerialization.data(
            withJSONObject: parsed, options: [.sortedKeys, .fragmentsAllowed]
        ) else {
            return .text(trimmed)
        }
        return .value(data)
    }
}
