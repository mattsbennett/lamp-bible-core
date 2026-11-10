import Foundation
import GRDB

/// A kind of long-form book, by which the library groups its books: First
/// Principles, Bible Exposition, History and the rest, each in a group such as
/// "Bible and Faith" or "Wider Reading".
///
/// A book module carries only its genre's id (`LampBook.genre`). The names,
/// their order and their groups travel in the bundle's `book_genres` table,
/// so a book built before a genre was renamed still files under its new name.
public struct LampBookGenre: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let groupID: String
    public let groupName: String
    /// Where it stands in the catalog, which is the order genres are shown in.
    public let sortOrder: Int

    public init(id: String, name: String, groupID: String, groupName: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.groupName = groupName
        self.sortOrder = sortOrder
    }

    /// The catalog in a bundle database, in its order; empty for a bundle
    /// built before books had genres.
    public static func catalog(in db: Database) throws -> [LampBookGenre] {
        guard try LampModuleText.tableNames(in: db).contains("book_genres") else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT id, name, group_id, group_name, sort_order FROM book_genres ORDER BY sort_order, name
            """).map { row in
                LampBookGenre(
                    id: row["id"], name: row["name"], groupID: row["group_id"],
                    groupName: row["group_name"], sortOrder: row["sort_order"]
                )
            }
    }

    /// One run of books under a heading.
    public struct Section<Book>: Identifiable {
        /// The genre's id, or `other` for books without a known genre.
        public let id: String
        public let title: String
        /// The genre's group, for a heading above a run of its genres; nil
        /// for "Other Books".
        public let group: String?
        public let books: [Book]
    }

    /// `books` under their genres, in catalog order, each keeping the order it
    /// was given in. Empty genres are left out. A book with no genre, or one
    /// the catalog does not name, goes under "Other Books" at the end, so a
    /// book is never hidden for want of a genre.
    public static func grouped<Book>(
        _ books: [Book],
        genre: (Book) -> String?,
        catalog: [LampBookGenre]
    ) -> [Section<Book>] {
        let known = Set(catalog.map(\.id))
        var byGenre: [String: [Book]] = [:]
        var other: [Book] = []
        for book in books {
            if let id = genre(book), known.contains(id) {
                byGenre[id, default: []].append(book)
            } else {
                other.append(book)
            }
        }
        var sections = catalog.compactMap { genre -> Section<Book>? in
            guard let books = byGenre[genre.id], !books.isEmpty else { return nil }
            return Section(id: genre.id, title: genre.name, group: genre.groupName, books: books)
        }
        if !other.isEmpty {
            sections.append(Section(id: "other", title: "Other Books", group: nil, books: other))
        }
        return sections
    }
}
