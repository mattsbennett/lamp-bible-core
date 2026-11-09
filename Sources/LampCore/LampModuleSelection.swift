import Foundation

/// Visibility and stable preference ordering, independent of platform storage.
public enum LampModuleSelection {
    public static func identifiers(in storedList: String) -> [String] {
        var seen = Set<String>()
        return storedList.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Missing preferences are ignored; new items retain the caller's default
    /// order. Multiple entries from the same dictionary stay together without
    /// dropping any of them or duplicating items for repeated preference IDs.
    public static func ordered<Item>(
        _ items: [Item], preferredIDs: [String], id: (Item) -> String
    ) -> [Item] {
        var ranks: [String: Int] = [:]
        for (rank, identifier) in preferredIDs.enumerated() where ranks[identifier] == nil {
            ranks[identifier] = rank
        }
        return items.enumerated().sorted {
            let left = ranks[id($0.element)] ?? Int.max
            let right = ranks[id($1.element)] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    /// The Greek dictionaries a reader who has chosen none falls back to, in
    /// order, ahead of the caller's ordinary by-name order.
    ///
    /// Strong's first: its plain definitions and KJV renderings read without
    /// Greek, which is who the default is for. TBESG next, whose Abbott-Smith
    /// entries assume the language. Everything else keeps the caller's order,
    /// so a newly bundled dictionary can never take the default by sorting
    /// early in the alphabet — which is what Dodson had been doing.
    public static let preferredGreekDictionaryIDs = ["strongs_greek", "tbesg"]

    public static func visible<Item>(
        _ items: [Item], hiddenIDs: Set<String>, preferredIDs: [String] = [],
        id: (Item) -> String
    ) -> [Item] {
        ordered(items.filter { !hiddenIDs.contains(id($0)) }, preferredIDs: preferredIDs, id: id)
    }
}
