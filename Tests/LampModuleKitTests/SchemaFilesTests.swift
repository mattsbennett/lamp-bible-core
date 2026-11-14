import Foundation
import Testing
@testable import LampModuleKit

/// `Schemas/` holds the JSON Schemas for module JSON. The inspector and the
/// compilers are a separate reading of the same contract, so these tests keep
/// the two from drifting apart: every kind core compiles has a schema, the
/// examples published beside the schemas compile, and what a schema requires
/// of a commentary, the inspector requires too.
struct SchemaFilesTests {
    static let schemasURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Schemas")

    static let examples = ["commentary_example.json", "commentary_simple_example.json"]

    /// The schema file for each module kind, by the name the schemas use.
    static let schemaFiles: [LampModuleKind: String] = [
        .translation: "translation_schema.json",
        .dictionary: "lexicon_schema.json",
        .commentary: "commentary_schema.json",
        .book: "book_schema.json",
        .devotional: "devotional_schema.json",
        .notes: "notes_schema.json",
        .plan: "plan_schema.json",
        .highlights: "highlight_schema.json",
        .quiz: "quiz_schema.json",
    ]

    private static func object(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: schemasURL.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name)")
    }

    @Test func everyModuleKindHasASchema() throws {
        for kind in LampModuleKind.allCases {
            let name = try #require(Self.schemaFiles[kind], "no schema named for \(kind)")
            let schema = try Self.object(name)
            #expect(schema["$schema"] as? String == "http://json-schema.org/draft-07/schema#", "\(name)")
            #expect(!((schema["required"] as? [String]) ?? []).isEmpty, "\(name) requires nothing")
        }
    }

    @Test func everySchemaFileParses() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.schemasURL.path)
            .filter { $0.hasSuffix("_schema.json") }
        #expect(names.count >= Self.schemaFiles.count)
        for name in names {
            let schema = try Self.object(name)
            #expect(schema["$schema"] as? String == "http://json-schema.org/draft-07/schema#", "\(name)")
        }
    }

    @Test(arguments: examples)
    func examplesInspectAndCompile(_ name: String) throws {
        let data = try Data(contentsOf: Self.schemasURL.appendingPathComponent(name))
        let inspection = try ModuleJSONInspector().inspect(data, sourceFilename: name)
        #expect(inspection.kind == .commentary)
        #expect(inspection.issues.filter { $0.severity == .error }.isEmpty, "\(inspection.issues)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try LampModuleCompiler().compile(
            data: data,
            sourceFilename: name,
            destinationURL: directory.appendingPathComponent("\(inspection.metadata.id ?? "example").lamp")
        )
        #expect(result.kind == .commentary)
        #expect((result.tableCounts["commentary_units"] ?? 0) > 0)
    }

    /// A commentary missing a field its schema requires, at the top or in
    /// `meta`, is one the inspector refuses.
    @Test(arguments: examples)
    func theInspectorRequiresWhatTheCommentarySchemaRequires(_ name: String) throws {
        let schema = try Self.object("commentary_schema.json")
        let topRequired = try #require(schema["required"] as? [String])
        let meta = try #require((schema["properties"] as? [String: Any])?["meta"] as? [String: Any])
        let metaRequired = try #require(meta["required"] as? [String])
        let example = try Self.object(name)

        for key in topRequired {
            var root = example
            root.removeValue(forKey: key)
            let inspection = ModuleJSONInspector().inspect(root: root, sourceFilename: name)
            #expect(!inspection.canCompile, "\(name) without \(key) still compiles")
        }
        for key in metaRequired {
            var root = example
            var exampleMeta = try #require(root["meta"] as? [String: Any])
            exampleMeta.removeValue(forKey: key)
            root["meta"] = exampleMeta
            let inspection = ModuleJSONInspector().inspect(root: root, sourceFilename: name)
            #expect(!inspection.canCompile, "\(name) without meta.\(key) still compiles")
        }
    }
}
