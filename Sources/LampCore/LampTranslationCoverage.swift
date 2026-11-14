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

    private static func counts(_ rows: [Row]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for row in rows {
            counts[row["book"]] = row["chapter_count"] ?? 0
        }
        return counts
    }
}
