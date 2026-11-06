import Foundation
import GRDB
import LampModuleKit
import Testing

struct LampSearchWordsTests {
    /// A database put together outside the compiler, as the bundle is, has
    /// its words listed by `lamp-module search-words`, and `verify` tells
    /// one whose index was written since from one listed as it is.
    @Test func aDatabaseBuiltElsewhereHasItsWordsListed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-words-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE t (id INTEGER PRIMARY KEY, text TEXT NOT NULL);
                CREATE VIRTUAL TABLE t_fts USING fts5(text, content='t', content_rowid='id');
                INSERT INTO t (text) VALUES ('Faith works'), ('Unfaithful'), ('ὁ λόγος');
                INSERT INTO t_fts(t_fts) VALUES('rebuild');
                """)
        }
        try queue.close()
        #expect(try LampSearchWords.lists(inDatabaseAt: url).map(\.isCurrent) == [false], "none until listed")

        let listed = try LampSearchWords.listWords(inDatabaseAt: url)
        #expect(listed.map(\.index) == ["t_fts"])
        #expect(listed.map(\.words) == [5])
        #expect(try LampSearchWords.lists(inDatabaseAt: url).map(\.isCurrent) == [true])

        let reopened = try DatabaseQueue(path: url.path)
        let words = try reopened.read { db in
            try LampSearchWords.words(holding: "λογ", index: "t_fts", in: db)
        }
        #expect(words == ["λόγοσ"], "folded to be found, kept as the index holds it")
        try reopened.write { db in
            try db.execute(sql: "INSERT INTO t (text) VALUES ('Hope')")
            try db.execute(sql: "INSERT INTO t_fts(rowid, text) VALUES (last_insert_rowid(), 'Hope')")
        }
        try reopened.close()
        #expect(try LampSearchWords.lists(inDatabaseAt: url).map(\.isCurrent) == [false], "written since")
        #expect(throws: (any Error).self) {
            try LampSearchWords.listWords(inDatabaseAt: url.appendingPathExtension("missing"))
        }
    }
}
