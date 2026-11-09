import Foundation
import GRDB
import LampModuleKit

/// A Strong's analysis read straight from databases: a translation's verses,
/// and the Strong's index where it holds the translation as it now stands.
///
/// The library opens a file for each module, and the phone keeps its bundled
/// and imported translations in two databases of its own, so each opens its
/// own and hands the reads here. The two then analyse a key the same way: over
/// the same book range, keeping verse text only when asked, and measured
/// against the same totals.
///
/// With a current index, `indexed(key:…)` gives the totals and the key's
/// verses, `addVerses(_:to:from:in:)` reads only those, and the analyzer's
/// `analysis(verseCounts:)` asks the index how many verses hold each
/// companion. Without one, `addEveryVerse(to:…)` reads every tagged verse in
/// range, and `analysis()` counts them itself. The analysis is the same.
public enum LampStrongsAnalysisReader {
    /// Where a translation's tagged verses are: a module's own `verses`
    /// table, or its rows of a `translation_verses` table several share.
    public struct VerseSource: Equatable, Sendable {
        public let table: String
        /// The translation's rows, where the table holds several.
        public let translationID: String?

        public init(table: String, translationID: String?) {
            self.table = table
            self.translationID = translationID
        }

        /// The tagged verses of `translationID` in `db`, or nil where it holds
        /// no verses with tags to analyse.
        public static func find(in db: Database, translationID: String) throws -> VerseSource? {
            let tables = try LampModuleText.tableNames(in: db)
            let source: VerseSource
            if tables.contains("verses"), tables.contains("books") {
                source = VerseSource(table: "verses", translationID: nil)
            } else if tables.contains("translation_verses") {
                source = VerseSource(table: "translation_verses", translationID: translationID)
            } else {
                return nil
            }
            return try LampModuleText.columnNames(in: db, table: source.table).contains("annotations_json")
                ? source : nil
        }

        /// The `WHERE` opening that keeps to the translation's rows, with its
        /// argument.
        fileprivate var translationCondition: (sql: String, arguments: StatementArguments) {
            translationID.map { ("translation_id = ? AND ", [$0]) } ?? ("", [])
        }
    }

    /// What the index holds for a key: the totals it is measured against,
    /// and the verses holding it.
    public struct Indexed: Equatable, Sendable {
        public let corpus: LampStrongsCorpus
        public let references: [Int]

        public init(corpus: LampStrongsCorpus, references: [Int]) {
            self.corpus = corpus
            self.references = references
        }
    }

    /// The key's totals and verses in range from the index in `db`, or nil
    /// when the index holds no current index of the translation, one built
    /// from its tags as `fingerprint` describes them, and its verses must be
    /// read. Read together, so the two can't come from different builds.
    public static func indexed(
        key: String,
        translationID: String,
        fingerprint: String,
        bookRange: ClosedRange<Int>? = nil,
        in db: Database
    ) throws -> Indexed? {
        guard try LampStrongsIndex.isCurrent(translationID: translationID, fingerprint: fingerprint, in: db) else {
            return nil
        }
        return Indexed(
            corpus: try LampStrongsIndex.corpus(for: key, translationID: translationID, bookRange: bookRange, in: db),
            references: try LampStrongsIndex.references(of: key, translationID: translationID, bookRange: bookRange, in: db)
        )
    }

    /// Reads the verses at `references`, the ones holding the key, into
    /// `analyzer`, five hundred at a time.
    public static func addVerses(
        _ references: [Int],
        to analyzer: inout LampStrongsAnalyzer,
        from source: VerseSource,
        in db: Database
    ) throws {
        let (translationSQL, translationArguments) = source.translationCondition
        for start in stride(from: 0, to: references.count, by: 500) {
            let batch = Array(references[start..<min(start + 500, references.count)])
            var arguments = translationArguments
            arguments += StatementArguments(batch)
            for row in try Row.fetchAll(db, sql: """
                SELECT ref, text, annotations_json FROM \(source.table)
                WHERE \(translationSQL)ref IN (\(Array(repeating: "?", count: batch.count).joined(separator: ", ")))
                """, arguments: arguments) {
                analyzer.add(reference: row["ref"], text: (row["text"] as String?) ?? "", annotationsJSON: row["annotations_json"])
            }
        }
    }

    /// Reads every tagged verse in range into `analyzer`, for a translation
    /// the index holds no current index of. A verse's text is kept only where
    /// it holds the key.
    public static func addEveryVerse(
        to analyzer: inout LampStrongsAnalyzer,
        bookRange: ClosedRange<Int>? = nil,
        from source: VerseSource,
        in db: Database
    ) throws {
        let (translationSQL, translationArguments) = source.translationCondition
        var arguments = translationArguments
        arguments += [bookRange?.lowerBound ?? Int.min, bookRange?.upperBound ?? Int.max]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT ref, text, annotations_json FROM \(source.table)
            WHERE \(translationSQL)book BETWEEN ? AND ? AND annotations_json IS NOT NULL
            """, arguments: arguments)
        while let row = try rows.next() {
            analyzer.add(reference: row["ref"], text: (row["text"] as String?) ?? "", annotationsJSON: row["annotations_json"])
        }
    }
}

extension LampVersification {
    /// How the translation `translationID` in `db` numbers its verses: the
    /// scheme it declares, with the departures from it that its row lists.
    /// A module's own `translation_meta`, or its row of a `translations`
    /// table several share. English, as Lamp has always read a translation,
    /// where it declares none or one Lamp doesn't know.
    public static func declared(in db: Database, translationID: String) throws -> LampVersification {
        let tables = try LampModuleText.tableNames(in: db)
        var scheme: String?
        var departures: String?
        if tables.contains("translation_meta") {
            scheme = try Row.fetchOne(db, sql: "SELECT versification FROM translation_meta LIMIT 1")?["versification"]
        } else if tables.contains("translations") {
            let columns = try LampModuleText.columnNames(in: db, table: "translations")
            if columns.contains("versification") {
                let hasDepartures = columns.contains("versification_mappings")
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT versification\(hasDepartures ? ", versification_mappings" : "") FROM translations WHERE id = ?",
                    arguments: [translationID]
                )
                scheme = row?["versification"]
                departures = hasDepartures ? row?["versification_mappings"] : nil
            }
        }
        let numbering = standard(Scheme(moduleValue: scheme) ?? .english)
        guard let data = departures?.data(using: .utf8),
              let lines = try? JSONDecoder().decode([String].self, from: data),
              !lines.isEmpty
        else { return numbering }
        return numbering.departing(by: lines)
    }
}

extension LampDictionarySense {
    /// A dictionary entry's senses from its `senses_json`, read as the
    /// library reads them, for an app reading a dictionary the library
    /// doesn't open: either spelling of each field, plain text from
    /// annotated text, the links in it, and the Hebrew a sense renders in the
    /// Septuagint, padded numbers normalized.
    public static func senses(fromJSON json: String?) -> [LampDictionarySense] {
        LampLibrary.dictionarySenses(from: json)
    }
}
