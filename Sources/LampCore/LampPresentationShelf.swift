import Foundation

/// What a list of the library's decks shows: those a search and a filter
/// leave, in the order chosen, and how many each filter would show for the
/// search as it stands, so a filter's count agrees with the decks beneath
/// it. The Mac's Presentations section and the phone's deck library ask the
/// same questions of the same decks, so they answer them here.
public struct LampPresentationShelf: Equatable, Sendable {
    public struct Deck: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        /// The writing it was built from, if any, and that writing's title
        /// where the library still has it.
        public let writingID: String?
        public let writingTitle: String?
        /// When its file was last written (`LampPresentationDeckStore.modificationDate`).
        public let modified: Date

        public init(id: String, title: String, writingID: String?, writingTitle: String?, modified: Date) {
            self.id = id
            self.title = title
            self.writingID = writingID
            self.writingTitle = writingTitle
            self.modified = modified
        }

        /// A deck as the list shows it, its writing's title looked up by id.
        public init(_ deck: LampPresentationDeck, modified: Date, writingTitle: (String) -> String?) {
            let writingID = deck.source?.kind == .devotional ? deck.source?.id : nil
            self.init(
                id: deck.id,
                title: deck.title,
                writingID: writingID,
                writingTitle: writingID.flatMap(writingTitle),
                modified: modified
            )
        }
    }

    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case fromWriting = "From Writing"
        case standalone = "Standalone"
        public var id: Self { self }

        public func includes(_ deck: Deck) -> Bool {
            switch self {
            case .all: true
            case .fromWriting: deck.writingID != nil
            case .standalone: deck.writingID == nil
            }
        }
    }

    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recent = "Recently Changed"
        case title = "Title"
        public var id: Self { self }
    }

    public var decks: [Deck]

    public init(decks: [Deck]) {
        self.decks = decks
    }

    /// Whether a deck's title, or its writing's, holds the search's words.
    public static func matches(_ deck: Deck, query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty
            || deck.title.localizedCaseInsensitiveContains(words)
            || deck.writingTitle?.localizedCaseInsensitiveContains(words) == true
    }

    public func count(of filter: Filter, query: String) -> Int {
        decks.filter { filter.includes($0) && Self.matches($0, query: query) }.count
    }

    public func shown(filter: Filter, sort: Sort, query: String) -> [Deck] {
        Self.sorted(decks.filter { filter.includes($0) && Self.matches($0, query: query) }, by: sort)
    }

    /// Most recently changed first, or by title; ties by title, so the order
    /// is the same every time.
    public static func sorted(_ decks: [Deck], by sort: Sort) -> [Deck] {
        decks.sorted { a, b in
            if sort == .recent, a.modified != b.modified { return a.modified > b.modified }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

extension LampPresentationDeckStore {
    /// When a deck's file was last written: what "recently changed" means,
    /// since a deck records no date of its own. By the store's own file
    /// name, which differs from the id for some ids.
    public func modificationDate(ofDeck id: String) -> Date {
        (try? deckFileURL(for: id).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
