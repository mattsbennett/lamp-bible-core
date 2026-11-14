import Foundation
import GRDB
import LampModuleKit

/// Which books a translation holds and how many chapters each, read from
/// the books it lists. One answer for both apps: the Mac lists installed
/// modules with it, the phone reads its own databases with it.
///
/// The listed `chapter_count` is read rather than the highest chapter in
/// the verses: it is one row a book instead of a scan of every verse, and
/// in every bundled translation the two agree, as an import writes the
/// list from the module's own books.
public enum LampTranslationCoverage {
    /// Book number to chapter count, from `translation_books` for
    /// `translationID` in the bundle's layout, or from a single
    /// translation's `books` table. Empty where the file has neither.
    public static func chapterCounts(in db: Database, translationID: String?) throws -> [Int: Int] {
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        return try chapterCounts(in: db, tables: tables, translationID: translationID)
    }

    /// Every translation's chapter counts in a file of several, as the
    /// bundle is, in one read.
    public static func chapterCountsByTranslation(in db: Database) throws -> [String: [Int: Int]] {
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        return try chapterCountsByTranslation(in: db, tables: tables)
    }

    static func chapterCounts(in db: Database, tables: Set<String>, translationID: String?) throws -> [Int: Int] {
        // The several-translation layout first: the bundle also has a
        // `books` table, the canonical list, which counts no chapters.
        if tables.contains("translation_books"), let translationID {
            return counts(try Row.fetchAll(
                db,
                sql: "SELECT book_number AS book, chapter_count FROM translation_books WHERE translation_id = ?",
                arguments: [translationID]
            ))
        }
        if tables.contains("books"),
           try LampModuleText.columnNames(in: db, table: "books").contains("chapter_count") {
            return counts(try Row.fetchAll(db, sql: "SELECT id AS book, chapter_count FROM books"))
        }
        return [:]
    }

    static func chapterCountsByTranslation(in db: Database, tables: Set<String>) throws -> [String: [Int: Int]] {
        guard tables.contains("translation_books") else { return [:] }
        var byTranslation: [String: [Int: Int]] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT translation_id, book_number, chapter_count FROM translation_books"
        ) {
            let id: String = row["translation_id"]
            byTranslation[id, default: [:]][row["book_number"]] = row["chapter_count"] ?? 0
        }
        return byTranslation
    }

    /// Book number to the translation's own name for each book, from the
    /// same lists as `chapterCounts`: "Génesis" in a Spanish translation.
    /// A book listed without a name is left out, for the caller to name.
    public static func bookNames(in db: Database, translationID: String?) throws -> [Int: String] {
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        let rows: [Row]
        if tables.contains("translation_books"), let translationID {
            rows = try Row.fetchAll(
                db,
                sql: "SELECT book_number AS book, name FROM translation_books WHERE translation_id = ?",
                arguments: [translationID]
            )
        } else if tables.contains("books"),
                  try LampModuleText.columnNames(in: db, table: "books").contains("chapter_count") {
            rows = try Row.fetchAll(db, sql: "SELECT id AS book, name FROM books")
        } else {
            return [:]
        }
        var names: [Int: String] = [:]
        for row in rows {
            guard let name: String = row["name"],
                  !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  names[row["book"]] == nil else { continue }
            names[row["book"]] = name
        }
        return names
    }

    /// Where a translation reads a place from, given its `chapterCounts`:
    /// the place itself where it has the book, at its last chapter where it
    /// numbers fewer; else the first book it has in the same testament, or
    /// its first book at all, at chapter 1. So switching to the Brenton
    /// Septuagint in Matthew 5 opens Genesis 1. Nil when it holds no book.
    public static func landing(
        book: Int,
        chapter: Int,
        chapterCounts: [Int: Int]
    ) -> (book: Int, chapter: Int)? {
        if let count = chapterCounts[book] {
            return (book, min(max(chapter, 1), max(count, 1)))
        }
        let held = chapterCounts.keys.sorted()
        let isNewTestament = book >= 40
        guard let fallback = held.first(where: { ($0 >= 40) == isNewTestament }) ?? held.first else {
            return nil
        }
        return (fallback, 1)
    }

    /// The translation to offer a place in, for a reader sent to it in one
    /// that lacks the book: one of `candidates` that `covers` it, in the
    /// same language as `language` first (by primary subtag, so "es" is
    /// "es-ES"), else the first in the order given.
    public static func alternative<Translation>(
        having book: Int,
        near language: String?,
        among candidates: [Translation],
        language languageOf: (Translation) -> String?,
        covers: (Translation) -> Bool
    ) -> Translation? {
        let having = candidates.filter(covers)
        let own = LampTranslationLanguages.primary(language)
        return having.first { own != nil && LampTranslationLanguages.primary(languageOf($0)) == own }
            ?? having.first
    }

    private static func counts(_ rows: [Row]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for row in rows {
            counts[row["book"]] = row["chapter_count"] ?? 0
        }
        return counts
    }
}
