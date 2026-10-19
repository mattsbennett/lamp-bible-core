import Foundation
import Testing

/// Holds `Verification/coverage.json` to the code and to the model.
///
/// The manifest names every shared sync source, the Lean rules that model
/// its decisions, the conformance tables that hold it to them, and what is
/// deliberately left unmodelled. A new sync source with no entry fails here,
/// so new sync behaviour cannot arrive without someone deciding how it is
/// verified. So does an entry for a file that is gone, or a rule the model no
/// longer defines. None of this needs Lean, so it runs everywhere.
struct SyncVerificationCoverageTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let rules: [String]?
            let conformance: [String]?
            let boundary: String?
        }
        let patterns: [String]
        let sources: [String: Entry]
        let platformSources: [String: Entry]
    }

    private static let root = SyncModel.packageRoot

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: Self.root.appendingPathComponent("Verification/coverage.json"))
        )
    }

    /// Names the model defines: its definitions, theorems and types.
    private func modelNames() throws -> Set<String> {
        let model = try String(contentsOf: SyncModel.modelURL, encoding: .utf8)
        var names = Set<String>()
        for line in model.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 2)
            guard words.count >= 2,
                  ["def", "theorem", "structure", "inductive", "abbrev"].contains(String(words[0]))
            else { continue }
            names.insert(String(words[1]))
        }
        return names
    }

    /// Files matching `pattern`, which is a path whose last component may
    /// hold one `*`.
    private func files(matching pattern: String) throws -> [String] {
        let directory = (pattern as NSString).deletingLastPathComponent
        let name = (pattern as NSString).lastPathComponent
        let parts = name.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: Self.root.appendingPathComponent(directory).path
        )
        return contents.filter { file in
            parts.count == 1 ? file == name
                : file.hasPrefix(parts[0]) && file.hasSuffix(parts[1]) && file.count >= name.count - 1
        }
        .map { "\(directory)/\($0)" }
    }

    @Test func everySyncSourceHasAnEntry() throws {
        let manifest = try manifest()
        let found = try Set(manifest.patterns.flatMap(files(matching:)))
        let unlisted = found.subtracting(manifest.sources.keys).sorted()
        #expect(unlisted.isEmpty, """
            Sync sources with no entry in Verification/coverage.json: \(unlisted). \
            Model the decision in SyncMerge.lean and name its rules, or say why it is not modelled.
            """)
    }

    @Test func everyEntryNamesAFileThatExists() throws {
        let manifest = try manifest()
        let gone = manifest.sources.keys.filter {
            !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent($0).path)
        }
        #expect(gone.isEmpty, "Entries for files that no longer exist: \(gone.sorted())")
        // A sibling app repository is checked only where it is checked out.
        for path in manifest.platformSources.keys {
            let components = path.split(separator: "/")
            guard components.count > 2, components[0] == ".." else { continue }
            let repository = Self.root.appendingPathComponent("../\(components[1])").standardizedFileURL
            guard FileManager.default.fileExists(atPath: repository.path) else { continue }
            let file = Self.root.appendingPathComponent(path).standardizedFileURL
            #expect(FileManager.default.fileExists(atPath: file.path), "No such platform source: \(path)")
        }
    }

    @Test func everyEntryIsModelledOrSaysWhyNot() throws {
        let manifest = try manifest()
        for (path, entry) in manifest.sources.merging(manifest.platformSources, uniquingKeysWith: { a, _ in a }) {
            #expect(!(entry.rules ?? []).isEmpty || entry.boundary?.isEmpty == false,
                    "\(path) names no rules and gives no reason")
        }
    }

    @Test func everyNamedRuleIsInTheModel() throws {
        let manifest = try manifest()
        let names = try modelNames()
        for (path, entry) in manifest.sources.merging(manifest.platformSources, uniquingKeysWith: { a, _ in a }) {
            let unknown = (entry.rules ?? []).filter { !names.contains($0) }
            #expect(unknown.isEmpty, "\(path) names rules the model does not define: \(unknown)")
        }
    }

    /// Every conformance table is claimed by the source it holds to the
    /// model, and every claim is a table the conformance tests check.
    @Test func everyConformanceTableBelongsToASource() throws {
        let manifest = try manifest()
        let claimed = Set(manifest.sources.values.flatMap { $0.conformance ?? [] })
        let checked = SyncModelConformanceTests.checkedRules
        #expect(claimed.subtracting(checked).isEmpty, "Unknown tables claimed: \(claimed.subtracting(checked).sorted())")
        #expect(checked.subtracting(claimed).isEmpty, "Tables no source claims: \(checked.subtracting(claimed).sorted())")
    }
}
