import Foundation
import GRDB
import LampModuleKit
import Testing

/// Item 3d of `Documentation/ScalabilityPlan.md`: whether a bulk import
/// should drop its search index and rebuild it afterwards instead of paying a
/// trigger per row. The plan left it open "only if a measurement says import
/// time matters", and this is that measurement.
///
/// Here rather than on the phone, where the schema lives, for one reason: a
/// simulator test's output reaches neither `xcodebuild`'s console nor a file
/// this machine can find, and the environment variable that would gate it is
/// not forwarded either. What is being measured is FTS5's own behaviour on
/// the phone's schema, which is the same SQLite here. The phone's figures
/// will be larger; the ratio is what decides the item. iOS carries the same
/// schema in `ImportIndexMeasurementTests`, which asserts that the index says
/// the same thing whichever way it was filled.
///
/// Skipped unless `LAMP_SCALE=1`. Nothing asserts a timing.
struct SearchIndexImportMeasurementTests {
    private static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["LAMP_SCALE"] == "1"
    }

    private func verses(_ count: Int) -> [(Int, String)] {
        let words = [
            "lamp", "unto", "feet", "light", "path", "shepherd", "pastures", "waters",
            "restoreth", "soul", "paths", "righteousness", "valley", "shadow", "death",
            "comfort", "table", "enemies", "anointest", "oil", "cup", "runneth", "mercy",
        ]
        return (0..<count).map { index in
            var text = ""
            for step in 0..<18 { text += words[(index &* 7 &+ step &* 3) % words.count] + " " }
            return (index, text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func timed(_ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure { try body() }
        return Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    /// The phone's `translation_verses` and its external-content index, with
    /// the triggers its migrations install.
    private func makeSchema(_ queue: DatabaseQueue, triggers: Bool) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_verses (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    translation_id TEXT NOT NULL,
                    reference INTEGER NOT NULL,
                    text TEXT NOT NULL);
                CREATE VIRTUAL TABLE translation_verses_fts USING fts5(
                    text, content='translation_verses', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2');
                """)
            guard triggers else { return }
            try db.execute(sql: """
                CREATE TRIGGER translation_verses_fts_insert AFTER INSERT ON translation_verses BEGIN
                    INSERT INTO translation_verses_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER translation_verses_fts_update AFTER UPDATE ON translation_verses BEGIN
                    UPDATE translation_verses_fts SET text = new.text WHERE rowid = new.id;
                END;
                CREATE TRIGGER translation_verses_fts_delete AFTER DELETE ON translation_verses BEGIN
                    DELETE FROM translation_verses_fts WHERE rowid = old.id;
                END;
                """)
        }
    }

    private func insert(_ rows: [(Int, String)], into queue: DatabaseQueue) throws {
        try queue.write { db in
            for (reference, text) in rows {
                try db.execute(
                    sql: """
                        INSERT INTO translation_verses (translation_id, reference, text)
                        VALUES (?, ?, ?)
                        """,
                    arguments: ["t1", reference, text]
                )
            }
        }
    }

    private func matches(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM translation_verses_fts
                    WHERE translation_verses_fts MATCH ?
                    """,
                arguments: ["shepherd"]
            ) ?? -1
        }
    }

    private func withDatabase<T>(_ body: (DatabaseQueue) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-index-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        defer {
            try? queue.close()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        return try body(queue)
    }

    /// The rebuild is over the **whole content table**, not over the import,
    /// so what it costs depends on how much is installed already. Measured
    /// with a library of other translations in place, which is the case that
    /// decides whether the trade holds.
    @Test(.enabled(if: enabled()))
    func measuresTheRebuildAgainstAnAlreadyFullLibrary() throws {
        let importing = 31_000
        let rows = verses(importing)
        for installed in [0, 1, 3, 6] {
            try withDatabase { queue in
                try makeSchema(queue, triggers: false)
                // What is already there, indexed, before this import starts.
                for _ in 0..<installed { try insert(rows, into: queue) }
                try queue.write { db in
                    try db.execute(sql: """
                        INSERT INTO translation_verses_fts(translation_verses_fts)
                        VALUES ('rebuild')
                        """)
                }
                let inserting = try timed { try insert(rows, into: queue) }
                let rebuilding = try timed {
                    try queue.write { db in
                        try db.execute(sql: """
                            INSERT INTO translation_verses_fts(translation_verses_fts)
                            VALUES ('rebuild')
                            """)
                    }
                }
                // Every translation's verses are still findable, which is the
                // property an index rebuilt wholesale has to hold.
                let all = try matches(queue)
                #expect(all == (installed + 1) * 24_260)

                // And a third way: index only the rows this import added, in
                // one statement. That is O(the import) rather than O(the
                // table), and it is not the per-row work the triggers do.
                let onlyTheNewRows = try withDatabase { second -> Double in
                    try makeSchema(second, triggers: false)
                    for _ in 0..<installed { try insert(rows, into: second) }
                    try second.write { db in
                        try db.execute(sql: """
                            INSERT INTO translation_verses_fts(translation_verses_fts)
                            VALUES ('rebuild')
                            """)
                    }
                    let mark = try second.read {
                        try Int.fetchOne(
                            $0, sql: "SELECT COALESCE(max(id), 0) FROM translation_verses"
                        ) ?? 0
                    }
                    try insert(rows, into: second)
                    // Not `id > mark`: a table without AUTOINCREMENT can
                    // reuse a rowid freed by the replacement's delete, and
                    // such a row would land below the mark and never be
                    // indexed. What is unindexed is the thing to ask for, and
                    // the index's own shadow table says it.
                    let ms = try timed {
                        try second.write { db in
                            try db.execute(sql: """
                                INSERT INTO translation_verses_fts(rowid, text)
                                SELECT id, text FROM translation_verses
                                WHERE id NOT IN (SELECT rowid FROM translation_verses_fts_docsize)
                                """)
                        }
                    }
                    #expect(mark >= 0)
                    #expect(try matches(second) == all)
                    return ms
                }
                print("""
                    SCALE installedAlready=\(installed) importing=\(importing)                     insertWithoutTriggers=\(String(format: "%.0f", inserting))ms                     rebuildAfterwards=\(String(format: "%.0f", rebuilding))ms                     indexOnlyTheNewRows=\(String(format: "%.0f", onlyTheNewRows))ms totalWithRebuild=\(String(format: "%.0f", inserting + rebuilding))ms totalWithNewRowsOnly=\(String(format: "%.0f", inserting + onlyTheNewRows))ms
                    """)
            }
        }
    }

    @Test(.enabled(if: enabled()))
    func measuresWhatTheSearchIndexCostsABulkImport() throws {
        let sizes = ProcessInfo.processInfo.environment["LAMP_SCALE_VERSES"]
            .map { $0.split(separator: ",").compactMap { Int($0) } }
            .flatMap { $0.isEmpty ? nil : $0 } ?? [31_000]

        for count in sizes {
            let rows = verses(count)

            // As an import does now: a trigger per row.
            let (withTriggers, indexed, hits) = try withDatabase { queue in
                try makeSchema(queue, triggers: true)
                let ms = try timed { try insert(rows, into: queue) }
                let indexed = try queue.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM translation_verses_fts") ?? -1
                }
                return (ms, indexed, try matches(queue))
            }

            // What 3d proposes: the rows go in with no index attached, then
            // the index is made in one pass.
            let (withoutTriggers, rebuild, rebuiltIndexed, rebuiltHits) = try withDatabase { queue in
                try makeSchema(queue, triggers: false)
                let inserting = try timed { try insert(rows, into: queue) }
                let rebuilding = try timed {
                    try queue.write { db in
                        try db.execute(sql: """
                            INSERT INTO translation_verses_fts(translation_verses_fts)
                            VALUES ('rebuild')
                            """)
                    }
                }
                let indexed = try queue.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM translation_verses_fts") ?? -1
                }
                return (inserting, rebuilding, indexed, try matches(queue))
            }

            // Whichever way, the index has to say the same thing.
            #expect(indexed == count)
            #expect(rebuiltIndexed == count)
            #expect(hits > 0)
            #expect(rebuiltHits == hits)

            print("""
                SCALE verses=\(count) \
                insertWithTriggers=\(String(format: "%.0f", withTriggers))ms \
                insertWithoutTriggers=\(String(format: "%.0f", withoutTriggers))ms \
                rebuildAfterwards=\(String(format: "%.0f", rebuild))ms \
                dropAndRebuildTotal=\(String(format: "%.0f", withoutTriggers + rebuild))ms \
                matches=\(hits)
                """)
        }
    }
}

/// The last of Phase 0's measurements: how big the settings bundle gets on the
/// wire. `Documentation/ScalabilityPlan.md`'s Phase 4 holds streaming
/// extraction and a smaller manifest for "only if iOS reports low memory, or
/// Phase 0's remaining measurements show a multi-MB bundle", and nobody had
/// measured the bundle.
///
/// Skipped unless `LAMP_SCALE=1`. Nothing asserts a size.
struct SyncBundleSizeMeasurementTests {
    private static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["LAMP_SCALE"] == "1"
    }

    @Test(.enabled(if: enabled()))
    func measuresTheSettingsBundleAtSize() throws {
        // A library at the sizes the plan worries about: modules, writings
        // with their media, decks, and a workspace tree per writing.
        for (modules, writings, perWriting) in [(50, 250, 54), (200, 1_000, 54)] {
            var manifest = LampSyncLibraryManifest()
            var at: Int64 = 1_000
            func record(_ path: String) throws {
                at += 1
                manifest = try manifest.recordingWrite(
                    path, revision: "\"r\(at)\"", replacing: nil, at: at
                )
            }
            for module in 0..<modules {
                try record("Translations/translation-\(module).lamp")
            }
            for writing in 0..<writings {
                try record("Writing/writing-\(writing).lamp")
                for file in 0..<perWriting {
                    try record("Workspaces/Writings/w\(writing)/Revisions/\(file).json")
                }
            }
            var bundle = LampSyncSettingsBundle()
            bundle.manifest = manifest
            let bytes = try bundle.encoded().count
            print("""
                SCALE modules=\(modules) writings=\(writings) \
                members=\(manifest.paths.count) bundleBytes=\(bytes) \
                bundleMB=\(String(format: "%.1f", Double(bytes) / 1_048_576))
                """)
        }
    }
}
