import Foundation

extension LampBook {
    /// What a search of the library looks at in a book: everything the
    /// library holds about it that a reader might remember it by, not its
    /// text. `genreName` is the name the catalog gives its genre, which the
    /// book itself carries only as an id.
    public func librarySearchFields(genreName: String? = nil) -> [String] {
        [title, subtitle, author, editor, publisher, description, edition, isbn, genreName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            + tags
            + (year.map { [String($0)] } ?? [])
    }

    /// Whether this book answers a search of the library. Each word typed
    /// must be found, but not all in the same field, so "Roberts Christendom"
    /// finds a book by its author and title together. Words are matched where
    /// a word starts, as every other search in Lamp matches them; a quoted
    /// phrase must stand whole, and an empty query matches every book.
    public func matchesLibrarySearch(_ query: LampSearchQuery, genreName: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = librarySearchFields(genreName: genreName)
        return query.terms.allSatisfy { term in fields.contains { term.matches($0) } }
    }
}
