import Foundation

/// Kinds of personal content whose deletions sync between devices.
public enum LampPersonalItemKind: String, CaseIterable, Sendable {
    case devotional
    case note
    case highlightSet
    case highlight
    case highlightTheme
}

/// When each personal item was last saved on a device and when it was deleted.
///
/// Sync merges content as a union, so on its own a deletion is undone by the
/// next device that still has a copy. Kept beside the content, this record lets
/// each device tell a copy that predates a deletion — dropped — from a change
/// made after it — kept. Times are milliseconds since 1970.
public struct LampPersonalDeletionLedger: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var presentSince: Int64?
        public var deletedAt: Int64?

        public init(presentSince: Int64? = nil, deletedAt: Int64? = nil) {
            self.presentSince = presentSince
            self.deletedAt = deletedAt
        }

        /// Whether the item was deleted after the copy at hand: the later of
        /// its last recorded save and `itemModified` (in seconds, as content
        /// records it), when known.
        public func isDeleted(itemModified: Int?) -> Bool {
            guard let deletedAt else { return false }
            let modified = itemModified.map { Int64($0) * 1_000 }
            let presence = max(presentSince ?? .min, modified ?? .min)
            return deletedAt >= presence
        }

        func merged(with other: Entry) -> Entry {
            Entry(
                presentSince: Self.later(presentSince, other.presentSince),
                deletedAt: Self.later(deletedAt, other.deletedAt)
            )
        }

        private static func later(_ a: Int64?, _ b: Int64?) -> Int64? {
            switch (a, b) {
            case let (a?, b?): max(a, b)
            case let (a?, nil): a
            case let (nil, b): b
            }
        }
    }

    public private(set) var entries: [LampPersonalItemKind: [String: Entry]] = [:]

    public init() {}

    public var isEmpty: Bool { entries.values.allSatisfy(\.isEmpty) }

    public var hasDeletions: Bool {
        entries.values.contains { $0.values.contains { $0.deletedAt != nil } }
    }

    public func entry(_ kind: LampPersonalItemKind, _ key: String) -> Entry? {
        entries[kind]?[key]
    }

    public func isDeleted(_ kind: LampPersonalItemKind, _ key: String, itemModified: Int?) -> Bool {
        entry(kind, key)?.isDeleted(itemModified: itemModified) ?? false
    }

    public mutating func set(_ entry: Entry, kind: LampPersonalItemKind, key: String) {
        entries[kind, default: [:]][key] = entry
    }

    public mutating func merge(_ other: LampPersonalDeletionLedger) {
        for (kind, items) in other.entries {
            for (key, entry) in items {
                set(self.entry(kind, key)?.merged(with: entry) ?? entry, kind: kind, key: key)
            }
        }
    }

    // MARK: - File format

    private struct File: Codable {
        var formatVersion: Int
        var items: [String: [String: Entry]]
    }

    public static let formatVersion = 1

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(
            formatVersion: Self.formatVersion,
            items: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
        ))
    }

    /// Kinds this version doesn't know are passed over, so a later version's
    /// additions don't stop the rest being read.
    public static func decode(_ data: Data) throws -> LampPersonalDeletionLedger {
        let file = try JSONDecoder().decode(File.self, from: data)
        var ledger = LampPersonalDeletionLedger()
        for (rawKind, items) in file.items {
            guard let kind = LampPersonalItemKind(rawValue: rawKind) else { continue }
            for (key, entry) in items { ledger.set(entry, kind: kind, key: key) }
        }
        return ledger
    }
}
