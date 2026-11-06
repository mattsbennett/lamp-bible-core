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
public enum LampSearchWords {
    /// More words than this holding a fragment cost an index more to be
    /// asked for than reading the text does.
    public static let wordLimit = 200

    /// Makes the list of `index`'s words, replacing any, stamped with the
    /// index as it is now. In a write, on a connection that may change
    /// `db`, since the words are read through a table of its own.
    public static func rebuild(index: String, in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS search_words (
                fts TEXT NOT NULL, term TEXT NOT NULL, folded TEXT, PRIMARY KEY (fts, term)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS search_word_lists (
                fts TEXT PRIMARY KEY, structure BLOB NOT NULL
            );
            """)
        try db.execute(sql: "DELETE FROM search_words WHERE fts = ?", arguments: [index])
        let vocabulary = "temp.\"lamp_words_\(index)\""
        try db.execute(sql: "DROP TABLE IF EXISTS \(vocabulary)")
        try db.execute(sql: "CREATE VIRTUAL TABLE \(vocabulary) USING fts5vocab(main, \"\(index)\", row)")
        let terms = try String.fetchAll(db, sql: "SELECT term FROM \(vocabulary)")
        try db.execute(sql: "DROP TABLE \(vocabulary)")
        // Each as a search folds it, where that differs from the index's
        // own: the tokenizer lowercases Greek but keeps its accents.
        let insert = try db.makeStatement(sql: "INSERT INTO search_words (fts, term, folded) VALUES (?, ?, ?)")
        for term in terms {
            let folded = folded(term)
            try insert.execute(arguments: [index, term, folded == term ? nil : folded])
        }
        try db.execute(sql: """
            INSERT OR REPLACE INTO search_word_lists (fts, structure)
            SELECT ?, block FROM "\(index)_data" WHERE id = \(structureRecord)
            """, arguments: [index])
    }

    /// Makes the list of every full-text index in `db`.
    public static func rebuildAll(in db: Database) throws {
        let indexes = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'
            """)
        for index in indexes { try rebuild(index: index, in: db) }
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
              try isCurrent(index: index, in: db)
        else { return nil }
        let words = try String.fetchAll(db, sql: """
            SELECT term FROM search_words WHERE fts = ? AND instr(COALESCE(folded, term), ?) > 0 LIMIT ?
            """, arguments: [index, folded, limit + 1])
        return words.count > limit ? nil : words
    }

    /// Whether `db` has a list of `index`'s words as the index is now.
    public static func isCurrent(index: String, in db: Database) throws -> Bool {
        try db.tableExists("search_word_lists") && Bool.fetchOne(db, sql: """
            SELECT l.structure = d.block
            FROM search_word_lists l JOIN "\(index)_data" d ON d.id = \(structureRecord)
            WHERE l.fts = ?
            """, arguments: [index]) == true
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
