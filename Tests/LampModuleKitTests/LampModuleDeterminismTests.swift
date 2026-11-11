import Foundation
import GRDB
import Testing
@testable import LampModuleKit

/// Whether compiling the same source twice produces the same bytes.
///
/// This decides whether a publisher can ask "has this module changed?" by
/// comparing what it would upload against what the server holds. If a
/// re-export differs byte for byte while saying the same thing, every pass
/// uploads every module, every device then sees everything as changed, and
/// no amount of comparing digests upstream can help.
struct LampModuleDeterminismTests {
    private let source = Data(#"""
    {
      "meta": {
        "schemaVersion": "1.0",
        "id": "TEST",
        "type": "translation",
        "name": "Test Translation",
        "abbreviation": "TST",
        "language": "en"
      },
      "books": [{
        "id": "Gen",
        "name": "Genesis",
        "number": 1,
        "testament": "OT",
        "chapters": [{
          "chapter": 1,
          "verses": [{
            "v": 1,
            "ref": 1001001,
            "content": {"text": "In the beginning"}
          }]
        }]
      }]
    }
    """#.utf8)

    /// A dictionary, whose senses carry whatever an author wrote rather than
    /// a fixed set of keys (core d08d007). Carrying unknown keys puts their
    /// order in the hands of the source, so this is the kind that would show
    /// it: `JSONSupport.jsonString` sorts keys, and this is what holds it to
    /// that. The sense below is deliberately written out of alphabetical
    /// order, with keys the compiler has no name for.
    private let dictionarySource = Data(#"""
    {
      "meta": {
        "schemaVersion": "2.1",
        "id": "DETERM",
        "type": "dictionary",
        "name": "Determinism",
        "keyType": "strongs"
      },
      "entries": [{
        "key": "G18",
        "lemma": "agathos",
        "senses": [{
          "septuagintHebrew": [{"lemma": "טוֹב", "strongs": "H2896"}],
          "zeta": "last by name",
          "definition": "good",
          "alpha": {"nested": ["b", "a"]},
          "short_definition": "good"
        }]
      }]
    }
    """#.utf8)

    @Test func compilingTheSameSourceTwiceGivesTheSameBytes() throws {
        try #expect(digests(of: source, named: "TEST").0 == digests(of: source, named: "TEST").1)
    }

    @Test func aDictionaryCarryingUnknownSenseKeysCompilesToTheSameBytes() throws {
        let (first, second) = try digests(of: dictionarySource, named: "DETERM")
        #expect(first == second)
    }

    /// The property that makes the above hold, asserted directly, because
    /// comparing two digests **cannot** be trusted to catch its absence.
    ///
    /// Swift seeds dictionary ordering per process, so two compiles in one
    /// test run agree with each other whether or not the keys are sorted.
    /// Measured: with `.sortedKeys` removed from `JSONSupport.jsonString`,
    /// the digest comparison above failed on two runs out of three and
    /// passed on the third. A guard that catches a fault two times in three
    /// is not a guard, and the fault it misses is every module re-uploading
    /// on every sync pass. So this reads the stored JSON and checks the
    /// order itself, which holds in every run.
    @Test func aSensesKeysAreStoredInSortedOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("determinism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("DETERM.lamp")
        _ = try LampModuleCompiler().compile(
            data: dictionarySource, sourceFilename: "DETERM.json", destinationURL: output
        )

        let body = try (Data(contentsOf: output) as NSData).decompressed(using: .zlib) as Data
        let databaseURL = directory.appendingPathComponent("DETERM.sqlite")
        try body.write(to: databaseURL)
        let senses: String = try #require(
            try DatabaseQueue(path: databaseURL.path).read { db in
                try String.fetchOne(db, sql: "SELECT senses_json FROM dictionary_entries")
            }
        )

        // Written out of order in the fixture, and stored in this one.
        let sorted = ["alpha", "definition", "septuagintHebrew", "shortDefinition", "zeta"]
        let positions = sorted.map { senses.range(of: "\"\($0)\":")?.lowerBound }
        #expect(!positions.contains(where: { $0 == nil }), "a key the author wrote is not stored: \(senses)")
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), "senses_json keys are not in sorted order: \(senses)")
    }

    /// Compiles `source` twice, in directories of its own, and digests each
    /// archive. The compiler requires the file to be named for the module.
    private func digests(of source: Data, named id: String) throws -> (String, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("determinism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var digests: [String] = []
        for run in 0..<2 {
            let runDirectory = directory.appendingPathComponent("run\(run)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: runDirectory, withIntermediateDirectories: true
            )
            let output = runDirectory.appendingPathComponent("\(id).lamp")
            _ = try LampModuleCompiler().compile(
                data: source, sourceFilename: "\(id).json", destinationURL: output
            )
            digests.append(
                LampSyncContentRevision.digest(
                    for: try Data(contentsOf: output, options: .mappedIfSafe)
                )
            )
        }
        return (digests[0], digests[1])
    }
}
