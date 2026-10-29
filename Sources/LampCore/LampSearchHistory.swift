import Foundation
import LampModuleKit

/// The searches someone ran, newest first, kept on each device rather than
/// synced: what one person looked for on a phone is not a list to bring to
/// the desk.
///
/// A search is kept when it found something and said something: two or more
/// characters of words, or a Strong's key. A search that found nothing is
/// not worth running again from a list, and one by its filters alone is
/// quicker to choose again than to find. Each entry keeps its filters, so
/// running it again asks what was asked.
public struct LampSearchHistory: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var query: String
        /// The kinds searched; nil for every kind.
        public var kinds: Set<LampModuleKind>?
        /// The modules searched; nil for every module.
        public var moduleIDs: Set<String>?
        /// A translation the search was confined to, as a search of one
        /// Bible is.
        public var translationID: String?
        public var bookRange: ClosedRange<Int>?
        public var strongsKey: String?
        public var highlightColors: Set<String>?
        public var devotionalCriteria: LampDevotionalSearchCriteria?
        public var searchedAt: Date

        public init(
            query: String,
            kinds: Set<LampModuleKind>? = nil,
            moduleIDs: Set<String>? = nil,
            translationID: String? = nil,
            bookRange: ClosedRange<Int>? = nil,
            strongsKey: String? = nil,
            highlightColors: Set<String>? = nil,
            devotionalCriteria: LampDevotionalSearchCriteria? = nil,
            searchedAt: Date = Date()
        ) {
            self.query = query
            self.kinds = kinds
            self.moduleIDs = moduleIDs
            self.translationID = translationID
            self.bookRange = bookRange
            self.strongsKey = strongsKey
            self.highlightColors = highlightColors
            self.devotionalCriteria = devotionalCriteria?.isEmpty == false ? devotionalCriteria : nil
            self.searchedAt = searchedAt
        }

        /// The same search, whenever it ran: its words, case and spacing
        /// aside, and every filter.
        public var id: String {
            let words = query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            let filters: [String] = [
                kinds.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "*",
                moduleIDs.map { $0.sorted().joined(separator: ",") } ?? "*",
                translationID ?? "",
                bookRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "",
                strongsKey.map(LampStrongsKey.normalized) ?? "",
                highlightColors.map { $0.map { LampHighlightSearch.normalizedColor($0) }.sorted().joined(separator: ",") } ?? "",
                devotionalCriteria.map { criteria in
                    [criteria.date ?? "", criteria.monthDay ?? "",
                     (criteria.tags ?? []).sorted().joined(separator: ","),
                     (criteria.categories ?? []).sorted().joined(separator: ",")].joined(separator: ";")
                } ?? "",
            ]
            return ([words] + filters).joined(separator: "|")
        }

        /// Whether this search says enough to be worth keeping.
        public var isWorthKeeping: Bool {
            query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                || strongsKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    public static let capacity = 20

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.prefix(Self.capacity))
    }

    /// Keeps `entry` when it found something and is worth keeping, moving a
    /// search run before to the top with its new time. Returns whether it
    /// was kept.
    @discardableResult
    public mutating func record(_ entry: Entry, resultCount: Int) -> Bool {
        guard resultCount > 0, entry.isWorthKeeping else { return false }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.capacity))
        return true
    }

    public mutating func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
    }

    public mutating func clear() {
        entries = []
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    /// The history `data` holds, an entry this app cannot read passed by
    /// rather than losing the rest, and nothing at all from data that is not
    /// a history.
    public static func decoded(from data: Data) -> LampSearchHistory {
        struct Readable: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws {
                entry = try? Entry(from: decoder)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let entries = (try? decoder.decode([Readable].self, from: data))?.compactMap(\.entry) ?? []
        return LampSearchHistory(entries: entries)
    }
}
