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

    public static func visible<Item>(
        _ items: [Item], hiddenIDs: Set<String>, preferredIDs: [String] = [],
        id: (Item) -> String
    ) -> [Item] {
        ordered(items.filter { !hiddenIDs.contains(id($0)) }, preferredIDs: preferredIDs, id: id)
    }
}
