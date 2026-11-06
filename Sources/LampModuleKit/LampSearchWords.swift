import Foundation
import GRDB

/// The words of a database's full-text indexes, kept beside them, so that a
/// search for part of a word (`*faith`) can find the words holding it, the
/// way "unfaithful" holds "faith", and ask the index for those. An index
/// finds only the words a term starts; reading every text instead took a
/// tenth of a second and more on a large commentary, unranked, where the
/// list answers in a few milliseconds, and costs about 1.5 MB beside one.
///
/// Each list is stamped with its index as it was when made. An index written
/// since, as the phone's are when a module is installed or a note edited,
/// has no list until one is made again, and a search reads the text.
///
/// A list is kept in its index's own database, or, for a file that mustn't
/// be written, as a Mac library's synced module files mustn't, in another
/// attached to it as `derivedSchema`; a search looks in both.
public enum LampSearchWords {
    /// More words than this holding a fragment cost an index more to be
    /// asked for than reading the text does.
    public static let wordLimit = 200

    /// The name a database of lists for another is attached by.
    public static let derivedSchema = "lamp_words"

    /// An index's words as read, folded, and the index they were read from.
    public struct Vocabulary: Sendable {
        public let index: String
        let structure: Data
        let words: [(term: String, folded: String?)]
    }

    /// Makes the list of `index`'s words, replacing any, stamped with the
    /// index as it is now, in `db` or the database attached to it as
    /// `lists`. In a write, on a connection that may change `db`, since the
    /// words are read through a table of its own.
    public static func rebuild(index: String, in db: Database, into lists: String = "main") throws {
        if let vocabulary = try vocabulary(of: index, in: db) { try write(vocabulary, in: db, into: lists) }
    }

    /// `index`'s words, read and folded, for `write` to keep, so that a
    /// database other writers share is held for the writing alone; nil
    /// where it has no such index. On a connection that may write, as
    /// `writeWithoutTransaction` gives, since the words are read through a
    /// temporary table, which a read-only one refuses.
    public static func vocabulary(of index: String, in db: Database) throws -> Vocabulary? {
        guard try db.tableExists("\(index)_data", in: "main") else { return nil }
        let table = "temp.\"lamp_words_\(index)\""
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        try db.execute(sql: "CREATE VIRTUAL TABLE \(table) USING fts5vocab(main, \"\(index)\", row)")
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS \(table)") }
        // The words and the stamp in one read, so they agree.
        var stamp: Data?
        var terms: [String] = []
        try db.inSavepoint {
            stamp = try Data.fetchOne(db, sql: "SELECT block FROM main.\"\(index)_data\" WHERE id = \(structureRecord)")
            terms = try String.fetchAll(db, sql: "SELECT term FROM \(table)")
            return .commit
        }
        guard let structure = stamp else { return nil }
        // Each as a search folds it, where that differs from the index's
        // own: the tokenizer lowercases Greek but keeps its accents.
        return Vocabulary(index: index, structure: structure, words: terms.map { term in
            let folded = folded(term)
            return (term, folded == term ? nil : folded)
        })
    }

    /// Keeps `vocabulary` as the list of its index's words, in `db` or the
    /// database attached to it as `lists`, if the index is still as it was
    /// read; whether it was. In a write.
    @discardableResult
    public static func write(_ vocabulary: Vocabulary, in db: Database, into lists: String = "main") throws -> Bool {
        let index = vocabulary.index
        guard try Data.fetchOne(db, sql: "SELECT block FROM main.\"\(index)_data\" WHERE id = \(structureRecord)")
            == vocabulary.structure else { return false }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "\(lists)".search_words (
                fts TEXT NOT NULL, term TEXT NOT NULL, folded TEXT, PRIMARY KEY (fts, term)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS "\(lists)".search_word_lists (
                fts TEXT PRIMARY KEY, structure BLOB NOT NULL
            );
            """)
        try db.execute(sql: "DELETE FROM \"\(lists)\".search_words WHERE fts = ?", arguments: [index])
        let insert = try db.makeStatement(sql: "INSERT INTO \"\(lists)\".search_words (fts, term, folded) VALUES (?, ?, ?)")
        for word in vocabulary.words {
            try insert.execute(arguments: [index, word.term, word.folded])
        }
        try db.execute(
            sql: "INSERT OR REPLACE INTO \"\(lists)\".search_word_lists (fts, structure) VALUES (?, ?)",
            arguments: [index, vocabulary.structure]
        )
        return true
    }

    /// The full-text indexes of `db`.
    public static func indexes(in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'
            """)
    }

    /// Makes the list of every full-text index in `db`.
    public static func rebuildAll(in db: Database) throws {
        for index in try indexes(in: db) { try rebuild(index: index, in: db) }
    }

    /// Lists the words of every full-text index of the SQLite database at
    /// `url`, as the compiler does for each module it builds, for one put
    /// together another way, as the bundle is: after the last write to any of
    /// its indexes, since each list answers only for its index as it was
    /// then. Each index, and how many words it holds.
    public static func listWords(inDatabaseAt url: URL) throws -> [(index: String, words: Int)] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try DatabaseQueue(path: url.path).write { db in
            try rebuildAll(in: db)
            return try indexes(in: db).map { index in
                (index, try Int.fetchOne(db, sql: "SELECT count(*) FROM search_words WHERE fts = ?", arguments: [index]) ?? 0)
            }
        }
    }

    /// Each full-text index of the SQLite database at `url`, and whether it
    /// has a list of its words as it now is. One without is still searched,
    /// a search for part of a word reading its text.
    public static func lists(inDatabaseAt url: URL) throws -> [(index: String, isCurrent: Bool)] {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration).read { db in
            try indexes(in: db).map { ($0, try isCurrent(index: $0, in: db)) }
        }
    }

    /// The words of `index` holding `fragment`, case and accents aside, as
    /// the index holds them, or nil where they can't be had from it: there
    /// is no list of the index as it is now, `fragment` would be more than
    /// one of its words, or more than `limit` hold it.
    public static func words(
        holding fragment: String,
        index: String,
        in db: Database,
        limit: Int = wordLimit
    ) throws -> [String]? {
        let folded = folded(fragment)
        guard !folded.isEmpty, folded.allSatisfy({ $0.isLetter || $0.isNumber }),
              let lists = try listSchema(for: index, in: db)
        else { return nil }
        let words = try String.fetchAll(db, sql: """
            SELECT term FROM "\(lists)".search_words WHERE fts = ? AND instr(COALESCE(folded, term), ?) > 0 LIMIT ?
            """, arguments: [index, folded, limit + 1])
        return words.count > limit ? nil : words
    }

    /// Whether `db`, or unless `ownListsOnly` a database of lists attached
    /// to it, has a list of `index`'s words as the index is now.
    public static func isCurrent(index: String, in db: Database, ownListsOnly: Bool = false) throws -> Bool {
        try listSchema(for: index, in: db, ownListsOnly: ownListsOnly) != nil
    }

    /// Where `db` keeps a list of `index`'s words as the index is now: in
    /// itself, or in the database of lists attached to it.
    private static func listSchema(for index: String, in db: Database, ownListsOnly: Bool = false) throws -> String? {
        guard try db.tableExists("\(index)_data", in: "main") else { return nil }
        let attached = Set(try Row.fetchAll(db, sql: "PRAGMA database_list").compactMap { $0["name"] as String? })
        for lists in ownListsOnly ? ["main"] : ["main", derivedSchema] where attached.contains(lists) {
            guard try Bool.fetchOne(db, sql: """
                SELECT 1 FROM "\(lists)".sqlite_master WHERE type = 'table' AND name = 'search_word_lists'
                """) == true else { continue }
            if try Bool.fetchOne(db, sql: """
                SELECT l.structure = d.block
                FROM "\(lists)".search_word_lists l JOIN main."\(index)_data" d ON d.id = \(structureRecord)
                WHERE l.fts = ?
                """, arguments: [index]) == true {
                return lists
            }
        }
        return nil
    }

    /// `text` without case or accents, as a search compares words: λόγος
    /// as λογοσ, since the index lowercases a final sigma to σ.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ς", with: "σ")
    }

    /// The row of an FTS5 index's data that records its segments, and so
    /// changes with every write to it.
    private static let structureRecord = 10
}
