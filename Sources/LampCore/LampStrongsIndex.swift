import CryptoKit
import Foundation
import GRDB

/// Which verses of a translation tag which Strong's keys, kept in a cache
/// database so a key search reads the verses that hold the key and no others.
///
/// Searching the annotations, even by a key's letter and number, read every
/// verse whose tags held a key beginning with it: "G25" begins "G2532",
/// "and", so 5,793 of the KJV's verses were read to find the 109 that tag
/// G25. The index answers from a table keyed by translation, key and verse.
///
/// It also keeps what an analysis measures every key against, each chapter's
/// tags and tagged verses by language, so an analysis reads only the verses
/// that hold its key rather than every verse of the translation.
///
/// Like the analyzer it takes what each app reads: a writable cache database,
/// and each translation's verse rows. So the phone's bundled and user
/// databases and the Mac's module files build one index the same way, read
/// by the reader `LampStrongsSearch.holdsKey` confirms with.
public enum LampStrongsIndex {
    /// Raised when what the index holds changes, so every index built before
    /// it is rebuilt rather than read.
    public static let formatVersion = 1

    public static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS strongs_index_translations (
                translation_id TEXT PRIMARY KEY,
                fingerprint TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS strongs_verses (
                translation_id TEXT NOT NULL,
                key TEXT NOT NULL,
                ref INTEGER NOT NULL,
                PRIMARY KEY (translation_id, key, ref)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS strongs_chapter_tags (
                translation_id TEXT NOT NULL,
                language TEXT NOT NULL,
                book INTEGER NOT NULL,
                chapter INTEGER NOT NULL,
                tags INTEGER NOT NULL,
                verses INTEGER NOT NULL,
                PRIMARY KEY (translation_id, language, book, chapter)
            ) WITHOUT ROWID;
            """)
    }

    /// A digest of a translation's tags, each verse's reference and
    /// annotations in order, with the index's format, so an index built from
    /// any other tags no longer matches: the module reinstalled, or its tags
    /// corrected in place. Counting them would not do, since a tag moved from
    /// one word to the next changes no count and no length.
    ///
    /// `table` holds the translation's verses; `translationID` picks its rows
    /// from a table several translations share. It reads every verse, so ask
    /// it once for each translation and keep the answer until it changes.
    public static func fingerprint(table: String, translationID: String?, in db: Database) throws -> String {
        let condition = translationID == nil ? "" : "AND translation_id = ?"
        let arguments: StatementArguments = translationID.map { [$0] } ?? []
        var hasher = SHA256()
        let rows = try Row.fetchCursor(db, sql: """
            SELECT ref, annotations_json FROM \(table)
            WHERE annotations_json IS NOT NULL \(condition)
            ORDER BY ref
            """, arguments: arguments)
        while let row = try rows.next() {
            let reference: Int = row["ref"]
            let annotations: String = row["annotations_json"]
            hasher.update(data: Data("\(reference)\u{1F}\(annotations)\u{1E}".utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "v\(formatVersion):\(digest)"
    }

    /// Whether the index holds the translation as `fingerprint` describes it.
    public static func isCurrent(translationID: String, fingerprint: String, in db: Database) throws -> Bool {
        try String.fetchOne(db, sql: """
            SELECT fingerprint FROM strongs_index_translations WHERE translation_id = ?
            """, arguments: [translationID]) == fingerprint
    }

    /// Clears a translation from the index, its fingerprint first, so an
    /// index half built is never read as whole.
    public static func remove(translationID: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM strongs_index_translations WHERE translation_id = ?", arguments: [translationID])
        try db.execute(sql: "DELETE FROM strongs_verses WHERE translation_id = ?", arguments: [translationID])
        try db.execute(sql: "DELETE FROM strongs_chapter_tags WHERE translation_id = ?", arguments: [translationID])
    }

    /// Indexes one verse: a row for each key its tags hold, and its tags in
    /// its chapter's count for their language, Greek, Hebrew, and either.
    public static func add(reference: Int, annotationsJSON: String?, translationID: String, in db: Database) throws {
        guard let annotationsJSON else { return }
        var keys: [String] = []
        var seen = Set<String>()
        var tags: [Character: Int] = [:]
        LampStrongsAnalyzer.forEachTag(in: annotationsJSON) { raw in
            let key = LampStrongsKey.normalized(raw)
            guard let first = key.first else { return }
            if first == "G" || first == "H" { tags[first, default: 0] += 1 }
            if seen.insert(key).inserted { keys.append(key) }
        }
        let verse = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO strongs_verses (translation_id, key, ref) VALUES (?, ?, ?)
            """)
        for key in keys {
            try verse.execute(arguments: [translationID, key, reference])
        }
        let either = tags.values.reduce(0, +)
        guard either > 0 else { return }
        let (book, chapter, _) = LampBibleReferenceFormatter.components(of: reference)
        let chapterTags = try db.cachedStatement(sql: """
            INSERT INTO strongs_chapter_tags (translation_id, language, book, chapter, tags, verses)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT (translation_id, language, book, chapter)
            DO UPDATE SET tags = tags + excluded.tags, verses = verses + 1
            """)
        for (language, count) in tags.map({ (String($0.key), $0.value) }) + [("*", either)] {
            try chapterTags.execute(arguments: [translationID, language, book, chapter, count])
        }
    }

    /// Marks a translation's index whole, as of `fingerprint`.
    public static func finish(translationID: String, fingerprint: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO strongs_index_translations (translation_id, fingerprint) VALUES (?, ?)
            """, arguments: [translationID, fingerprint])
    }

    /// The verses of a translation that tag `key`, in canonical order.
    public static func references(
        of key: String,
        translationID: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int? = nil,
        in db: Database
    ) throws -> [Int] {
        guard let (condition, arguments) = query(key, translationID, bookRange) else { return [] }
        var bound = arguments
        if let limit { bound += [limit] }
        return try Int.fetchAll(db, sql: """
            SELECT DISTINCT ref FROM strongs_verses WHERE \(condition) ORDER BY ref \(limit == nil ? "" : "LIMIT ?")
            """, arguments: bound)
    }

    /// How many verses of a translation tag `key`.
    public static func count(
        of key: String,
        translationID: String,
        bookRange: ClosedRange<Int>? = nil,
        in db: Database
    ) throws -> Int {
        guard let (condition, arguments) = query(key, translationID, bookRange) else { return 0 }
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT ref) FROM strongs_verses WHERE \(condition)
            """, arguments: arguments) ?? 0
    }

    /// What an analysis of `key` measures against in range: the tags of its
    /// language in each chapter, Greek or Hebrew, or either for a key that
    /// names no language, and the verses holding any of them.
    public static func corpus(
        for key: String,
        translationID: String,
        bookRange: ClosedRange<Int>? = nil,
        in db: Database
    ) throws -> LampStrongsCorpus {
        let first = LampStrongsKey.normalized(key).first
        let language = first == "G" || first == "H" ? String(first!) : "*"
        var chapterWords: [Int: [Int: Int]] = [:]
        var verses = 0
        for row in try Row.fetchAll(db, sql: """
            SELECT book, chapter, tags, verses FROM strongs_chapter_tags
            WHERE translation_id = ? AND language = ? AND book BETWEEN ? AND ?
            """, arguments: [translationID, language, bookRange?.lowerBound ?? Int.min, bookRange?.upperBound ?? Int.max]) {
            chapterWords[row["book"] as Int, default: [:]][row["chapter"] as Int] = row["tags"]
            verses += row["verses"] as Int
        }
        return LampStrongsCorpus(chapterWords: chapterWords, taggedVerseCount: verses)
    }

    /// How many verses in range hold each of `keys`, as stored: the
    /// companions of an analysis are judged by them.
    public static func verseCounts(
        of keys: [String],
        translationID: String,
        bookRange: ClosedRange<Int>? = nil,
        in db: Database
    ) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: keys.count, by: 500) {
            let batch = Array(keys[start..<min(start + 500, keys.count)])
            var arguments: StatementArguments = [translationID]
            arguments += StatementArguments(batch)
            arguments += [
                bookRange.map { $0.lowerBound * 1_000_000 } ?? Int.min,
                bookRange.map { ($0.upperBound + 1) * 1_000_000 - 1 } ?? Int.max,
            ]
            for row in try Row.fetchAll(db, sql: """
                SELECT key, COUNT(*) AS verses FROM strongs_verses
                WHERE translation_id = ? AND key IN (\(Array(repeating: "?", count: batch.count).joined(separator: ", ")))
                  AND ref BETWEEN ? AND ?
                GROUP BY key
                """, arguments: arguments) {
                counts[row["key"] as String] = row["verses"] as Int
            }
        }
        return counts
    }

    private static func query(
        _ key: String,
        _ translationID: String,
        _ bookRange: ClosedRange<Int>?
    ) -> (String, StatementArguments)? {
        let forms = storedForms(of: key)
        guard !forms.isEmpty else { return nil }
        var arguments: StatementArguments = [translationID]
        arguments += StatementArguments(forms)
        arguments += [
            bookRange.map { $0.lowerBound * 1_000_000 } ?? Int.min,
            bookRange.map { ($0.upperBound + 1) * 1_000_000 - 1 } ?? Int.max,
        ]
        let placeholders = Array(repeating: "?", count: forms.count).joined(separator: ", ")
        return ("translation_id = ? AND key IN (\(placeholders)) AND ref BETWEEN ? AND ?", arguments)
    }

    /// The keys a row may be stored under for `key` to find it, as
    /// `LampStrongsKey.matches` compares keys: one with its language also
    /// finds its bare number, and a bare number either language's.
    static func storedForms(of key: String) -> [String] {
        let normalized = LampStrongsKey.normalized(key)
        guard let first = normalized.first else { return [] }
        if first.isNumber { return [normalized, "G" + normalized, "H" + normalized] }
        if first == "G" || first == "H", normalized.dropFirst().first?.isNumber == true {
            return [normalized, String(normalized.dropFirst())]
        }
        return [normalized]
    }
}
