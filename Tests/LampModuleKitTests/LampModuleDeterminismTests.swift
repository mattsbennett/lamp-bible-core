import Foundation
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

    @Test func compilingTheSameSourceTwiceGivesTheSameBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("determinism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var digests: [String] = []
        for run in 0..<2 {
            // The compiler requires the file to be named for the module.
            let runDirectory = directory.appendingPathComponent("run\(run)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: runDirectory, withIntermediateDirectories: true
            )
            let output = runDirectory.appendingPathComponent("TEST.lamp")
            _ = try LampModuleCompiler().compile(
                data: source, sourceFilename: "TEST.json", destinationURL: output
            )
            digests.append(
                LampSyncContentRevision.digest(
                    for: try Data(contentsOf: output, options: .mappedIfSafe)
                )
            )
        }

        #expect(digests[0] == digests[1])
    }
}
