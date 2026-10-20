import Foundation
import Testing

/// Holds `Verification/coverage.json` to the code and to the model.
///
/// The manifest names every shared sync source, the Lean rules that model
/// its decisions, the conformance tables that hold it to them, and what is
/// deliberately left unmodelled. A new sync source with no entry fails here,
/// so new sync behaviour cannot arrive without someone deciding how it is
/// verified. So does an entry for a file that is gone, or a rule the model no
/// longer defines, or a definition in the model that nothing holds to code.
/// None of this needs Lean, so it runs everywhere.
struct SyncVerificationCoverageTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let rules: [String]?
            let conformance: [String]?
            let boundary: String?
        }
        struct ModelOnly: Decodable {
            let systemModels: [String: String]
            let counterexamples: [String: String]
        }
        let patterns: [String]
        let sources: [String: Entry]
        let platformPatterns: [String]
        let platformSources: [String: Entry]
        let modelOnly: ModelOnly
    }

    /// One top-level declaration in the model, before its conformance tables.
    private struct Declaration {
        let kind: String
        let name: String
        let text: String
        /// The namespace it sits in, below the model's own.
        let namespace: String?
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

    /// The model's declarations, and the text of its conformance tables.
    ///
    /// A declaration starts at a line in the first column with a keyword, and
    /// runs until the next line in the first column.
    private func modelDeclarations() throws -> (declarations: [Declaration], tables: String) {
        let lines = try String(contentsOf: SyncModel.modelURL, encoding: .utf8).components(separatedBy: "\n")
        let marker = try #require(lines.firstIndex { $0.hasPrefix("/-! ## Conformance tables") })
        let keywords: Set<String> = ["def", "theorem", "structure", "inductive", "abbrev", "instance", "lemma"]
        var declarations: [Declaration] = []
        var namespace: String?
        var current: (kind: String, name: String, lines: [String], namespace: String?)?
        func flush() {
            if let current {
                declarations.append(Declaration(
                    kind: current.kind, name: current.name,
                    text: current.lines.joined(separator: "\n"), namespace: current.namespace
                ))
            }
            current = nil
        }
        for line in lines[..<marker] {
            if line.isEmpty || line.first!.isWhitespace {
                current?.lines.append(line)
                continue
            }
            flush()
            var words = line.split(separator: " ").map(String.init)
            if words.first == "namespace", words.count > 1, words[1] != "LampSyncVerification" { namespace = words[1] }
            if words.first == "end", words.count > 1, words[1] == namespace { namespace = nil }
            while let first = words.first, first == "private" || first == "protected" || first.hasPrefix("@[") {
                words.removeFirst()
            }
            guard let kind = words.first, keywords.contains(kind) else { continue }
            current = (kind, words.count > 1 ? words[1] : "", [line], namespace)
        }
        flush()
        return (declarations, lines[marker...].joined(separator: "\n"))
    }

    /// The identifiers in Lean text; a dotted name is its parts.
    private func identifiers(in text: String) -> Set<String> {
        var found = Set<String>()
        var word = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "'" {
                word.append(character)
            } else if !word.isEmpty {
                found.insert(word)
                word = ""
            }
        }
        if !word.isEmpty { found.insert(word) }
        return found
    }

    /// Files matching `pattern`, a path whose last component is a shell
    /// wildcard, relative to this package.
    private func files(matching pattern: String) throws -> [String] {
        let directory = (pattern as NSString).deletingLastPathComponent
        let name = (pattern as NSString).lastPathComponent
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: Self.root.appendingPathComponent(directory).path
        )
        return contents.filter { fnmatch(name, $0, 0) == 0 }.map { "\(directory)/\($0)" }
    }

    /// Whether the sibling repository a `../repository/...` path points into
    /// is checked out beside this one.
    private func siblingIsPresent(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.count > 2, components[0] == ".." else { return false }
        return FileManager.default.fileExists(
            atPath: Self.root.appendingPathComponent("../\(components[1])").standardizedFileURL.path
        )
    }

    /// The apps' sync files, matched by the same kind of pattern, wherever
    /// those repositories are checked out beside this one — so sync logic
    /// written into an app cannot arrive unaccounted for either.
    @Test func everyAppSyncSourceHasAnEntry() throws {
        let manifest = try manifest()
        let found = try Set(manifest.platformPatterns.filter(siblingIsPresent).flatMap(files(matching:)))
        let unlisted = found.subtracting(manifest.platformSources.keys).sorted()
        #expect(unlisted.isEmpty, """
            App sync sources with no platformSources entry in Verification/coverage.json: \(unlisted). \
            Move a new decision into core and model it, or say why the file makes none.
            """)
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
        for path in manifest.platformSources.keys where siblingIsPresent(path) {
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

    /// Every definition in the model is held to something: reached from a
    /// source's rules, a conformance table, a system model, or a listed
    /// counterexample, directly or through the definitions those use. A rule
    /// whose code is removed loses its entry, and then fails here until it
    /// goes from the model too — which is how the model once kept a hundred
    /// and fifty rules for code that no longer existed. A theorem goes with
    /// the definitions it is about, so only definitions are checked.
    @Test func everyDefinitionIsHeldToSomething() throws {
        let manifest = try manifest()
        let (declarations, tables) = try modelDeclarations()
        let byName = Dictionary(grouping: declarations.filter { !$0.name.isEmpty }, by: \.name)
        var reached = Set<String>()
        var frontier: [String] = []
        func reach(_ names: some Sequence<String>) {
            for name in names where byName[name] != nil && reached.insert(name).inserted {
                frontier.append(name)
            }
        }
        let entries = Array(manifest.sources.values) + Array(manifest.platformSources.values)
        reach(entries.flatMap { $0.rules ?? [] })
        reach(identifiers(in: tables))
        reach(manifest.modelOnly.counterexamples.keys)
        reach(declarations.filter { $0.namespace.map { manifest.modelOnly.systemModels[$0] != nil } ?? false }.map(\.name))
        while let name = frontier.popLast() {
            for declaration in byName[name] ?? [] { reach(identifiers(in: declaration.text)) }
        }
        let unheld = declarations.filter { declaration in
            guard declaration.kind != "theorem", declaration.kind != "lemma",
                  declaration.kind != "instance", !declaration.name.isEmpty,
                  !reached.contains(declaration.name) else { return false }
            // A function on a type goes with the type.
            if let dot = declaration.name.firstIndex(of: "."),
               reached.contains(String(declaration.name[..<dot])) { return false }
            return true
        }.map(\.name)
        #expect(unheld.isEmpty, """
            Definitions in SyncMerge.lean that nothing holds to code: \(unheld.sorted()). \
            Name each in the coverage entry of the source it models, list it as a counterexample \
            under modelOnly, or remove it with the code it described.
            """)
        let names = Set(declarations.map(\.name))
        let unknown = manifest.modelOnly.counterexamples.keys.filter { !names.contains($0) }
        #expect(unknown.isEmpty, "Counterexamples the model does not define: \(unknown.sorted())")
        let namespaces = Set(declarations.compactMap(\.namespace))
        let missing = manifest.modelOnly.systemModels.keys.filter { !namespaces.contains($0) }
        #expect(missing.isEmpty, "System models the model does not have: \(missing.sorted())")
    }

    /// A Swift comment that cites a model rule names one the model has. A
    /// citation outlives its rule silently otherwise, and tells the next
    /// reader the code does something the model no longer says — as one did,
    /// and a peer reasoned from it to a bug that could not happen.
    ///
    /// A citation is a backticked lower-case name on a comment line that
    /// mentions the model or puts the name in parentheses. A conformance
    /// table's name is one; a Swift name of that spelling in the sources or
    /// the tests is not one.
    @Test func everyCitedRuleIsInTheModel() throws {
        let manifest = try manifest()
        let names = try Set(modelDeclarations().declarations.map(\.name)).union(modelNames())
            .union(SyncModelConformanceTests.checkedRules)
        var paths = Set(manifest.sources.keys)
        paths.formUnion(manifest.platformSources.keys.filter(siblingIsPresent))
        for directory in ["Sources", "Tests"] {
            let root = Self.root.appendingPathComponent(directory).path
            for case let path as String in FileManager.default.enumerator(atPath: root) ?? .init()
            where path.hasSuffix(".swift") {
                paths.insert("\(directory)/\(path)")
            }
        }
        var comments: [(path: String, line: String)] = []
        var code = Set<String>()
        for path in paths {
            guard let text = try? String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") {
                    comments.append((path, trimmed))
                } else {
                    code.formUnion(identifiers(in: String(line)))
                }
            }
        }
        let backticked = try NSRegularExpression(pattern: "`([a-z][A-Za-z0-9_']*)`")
        var stale: [String] = []
        for (path, line) in comments where line.contains("SyncMerge") || line.contains("(`") {
            let range = NSRange(line.startIndex..., in: line)
            for match in backticked.matches(in: line, range: range) {
                guard let cited = Range(match.range(at: 1), in: line).map({ String(line[$0]) }) else { continue }
                if !names.contains(cited) && !code.contains(cited) { stale.append("\(path): \(cited)") }
            }
        }
        #expect(stale.isEmpty, "Comments citing rules the model does not define: \(stale.sorted())")
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
