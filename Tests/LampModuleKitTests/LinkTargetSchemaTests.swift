import Foundation
import Testing
@testable import LampModuleKit

/// A schema's `linkTarget` held to the target's own rule,
/// `LampLinkTarget.destination(in:)` (step 4, commit 9): every target a
/// matrix of fields can make is one the schema admits exactly when the
/// reader would open it. The book schema admitted `sv` 2000001, chapter 0 of
/// Exodus, which `destination(in:)` refuses.
struct LinkTargetSchemaTests {
    /// The one difference draft-07 cannot state: a schema compares no field
    /// with another, so a range ending before it starts is admitted, and
    /// refused by the reader (and warned of by the inspector, as a link that
    /// opens nothing). Only that: the same target opens with its ends
    /// swapped. Exempted on its order alone, an end refused for its own
    /// sake hid behind it. Found by Codex.
    private static func onlyTheReaderCanRefuse(_ target: [String: Any]) throws -> Bool {
        guard let start = target["sv"] as? Int, let end = target["ev"] as? Int, end < start else { return false }
        var swapped = target
        swapped["sv"] = end
        swapped["ev"] = start
        let data = try JSONSerialization.data(withJSONObject: swapped)
        return (try? JSONDecoder().decode(LampLinkTarget.self, from: data))?.destination(in: "book") != nil
    }

    @Test func theBookSchemasLinkTargetIsTheReadersRule() throws {
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL("book_schema.json"))) as? [String: Any]
        )
        let evaluator = DraftSevenEvaluator(root: schema)
        let linkTarget: [String: Any] = ["$ref": "#/definitions/linkTarget"]
        // Every keyword the schema reaches read, before any target is: met
        // only on the way, one in a branch never taken went unread. Found
        // by Codex.
        try evaluator.audit(linkTarget)

        let pools: [(String, [Any?])] = [
            ("kind", [nil, "commentary", "book", ""]),
            ("module", [nil, "M", ""]),
            ("sv", [nil, 43_003_016, 2_000_001, 67_001_001, 19_003_000, "43003016"]),
            // A chapter-0 end after a valid start, and an empty suffix, which
            // the reader reads as none. Found by Codex.
            ("ev", [nil, 43_003_017, 43_003_010, 2_000_001, 44_000_001]),
            ("suffix", [nil, "a", ""]),
            ("unit", [nil, "u", ""]),
            ("book", [nil, 43, 67, 0]),
            ("section", [nil, "s", ""]),
            ("anchor", [nil, "b", ""]),
        ]
        var targets: [[String: Any]] = [[:]]
        for (key, values) in pools {
            targets = targets.flatMap { target in
                values.map { value in
                    var next = target
                    if let value { next[key] = value }
                    return next
                }
            }
        }
        var mismatches: [String] = []
        var routes: Set<String> = []
        for target in targets {
            let admitted = try evaluator.validates(target, against: linkTarget)
            let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
            let destination = (try? JSONDecoder().decode(LampLinkTarget.self, from: data))?.destination(in: "book")
            switch destination {
            case .commentaryPassage: routes.insert("passage")
            case .commentaryFrontMatter: routes.insert("front matter")
            case .bookSection: routes.insert("book section")
            case nil: break
            }
            if admitted != (destination != nil), try !(admitted && Self.onlyTheReaderCanRefuse(target)) {
                mismatches.append("\(String(decoding: data, as: UTF8.self)): schema \(admitted), reader \(destination != nil)")
            }
        }
        // Each route opened somewhere, or the matrix says nothing of it.
        #expect(routes == ["passage", "front matter", "book section"], "\(routes)")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(targets.count):\n\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    /// Every book's verse bounds, which the matrix samples only a few of: at
    /// each edge of chapter 0 and of the book, for a start and an end. Found
    /// by Codex.
    @Test func everyBooksVerseBoundsAreTheReaders() throws {
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL("book_schema.json"))) as? [String: Any]
        )
        let evaluator = DraftSevenEvaluator(root: schema)
        let linkTarget: [String: Any] = ["$ref": "#/definitions/linkTarget"]
        var mismatches: [String] = []
        for book in 0...67 {
            let base = book * 1_000_000
            for verse in [base + 999, base + 1_000, base + 1_001, base + 999_999, base + 1_000_000] {
                for target: [String: Any] in [
                    ["kind": "commentary", "module": "M", "sv": verse],
                    // From the first verse a range can start at, so an end
                    // the reader opens is in a range it opens. Found by Codex.
                    ["kind": "commentary", "module": "M", "sv": 1_001_000, "ev": verse],
                ] {
                    let admitted = try evaluator.validates(target, against: linkTarget)
                    let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
                    let opened = (try? JSONDecoder().decode(LampLinkTarget.self, from: data))?.destination(in: "book") != nil
                    if admitted != opened, try !(admitted && Self.onlyTheReaderCanRefuse(target)) {
                        mismatches.append("\(String(decoding: data, as: UTF8.self)): schema \(admitted), reader \(opened)")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    /// Every field of a target each route opens, given as each kind of JSON
    /// value in turn: the schema admits it exactly when the reader opens
    /// it. Found by Codex: a `suffix` of `true` was never offered.
    @Test func everyFieldOfTheWrongKindIsTheReadersToo() throws {
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL("book_schema.json"))) as? [String: Any]
        )
        let evaluator = DraftSevenEvaluator(root: schema)
        let linkTarget: [String: Any] = ["$ref": "#/definitions/linkTarget"]
        let routes: [[String: Any]] = [
            ["kind": "commentary", "module": "M", "sv": 43_003_016, "ev": 43_003_017, "suffix": "a", "unit": "u", "anchor": "b"],
            ["kind": "commentary", "module": "M", "book": 43, "section": "s", "anchor": "b"],
            ["kind": "book", "module": "B", "section": "s", "anchor": "b"],
        ]
        let kinds: [Any] = ["x", 7, 7.5, true, NSNull(), [1], ["a": 1]]
        var mismatches: [String] = []
        for route in routes {
            for key in route.keys.sorted() {
                // And a fraction within the field's own bounds: 7.5 is in
                // none of them. Found by Codex.
                let near: [Any] = (route[key] as? Int).map { [Double($0) + 0.5] } ?? []
                for value in kinds + near {
                    var target = route
                    target[key] = value
                    let admitted = try evaluator.validates(target, against: linkTarget)
                    let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
                    let opened = (try? JSONDecoder().decode(LampLinkTarget.self, from: data))?.destination(in: "book") != nil
                    if admitted != opened { mismatches.append("\(String(decoding: data, as: UTF8.self)): schema \(admitted), reader \(opened)") }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    /// The evaluator reads the keywords the schema uses, and refuses one it
    /// does not know, so it cannot pass a schema by not reading it.
    @Test func theEvaluatorReadsWhatItIsGiven() throws {
        let evaluator = DraftSevenEvaluator(root: [:])
        #expect(try evaluator.validates(5, against: ["type": "integer", "minimum": 1, "maximum": 9]))
        #expect(try !evaluator.validates(5.5, against: ["type": "integer"]))
        #expect(try !evaluator.validates(true, against: ["type": "integer"]))
        #expect(try !evaluator.validates(["a": 1], against: ["required": ["b"]]))
        #expect(try !evaluator.validates(["a": 1], against: ["dependencies": ["a": ["b"]]]))
        #expect(try !evaluator.validates(3, against: ["oneOf": [["minimum": 1], ["minimum": 2]]]))
        #expect(try evaluator.validates(3, against: ["anyOf": [["minimum": 9], ["maximum": 4]]]))
        #expect(try !evaluator.validates(["a": 1], against: ["not": ["required": ["a"]]]))
        #expect(try !evaluator.validates("", against: ["type": "string", "minLength": 1]))
        #expect(try !evaluator.validates("x", against: ["enum": ["y"]]))
        #expect(try !evaluator.validates("x", against: ["const": "y"]))
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.validates(1, against: ["pattern": "x"]) }
        // Every branch read, taken or not; a `$ref` alone, as draft-07 reads
        // it, an assertion beside it refused. Found by Codex.
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["anyOf": [["minimum": 1], ["multipleOf": 2]]]) }
        // A keyword it knows, in a form it does not read. Found by Codex.
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["not": ["const": ["section": "s"]]]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["dependencies": ["a": ["required": ["b"]]]]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["enum": [["a": 1]]]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["oneOf": ["minimum": 1]]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["properties": [["a": 1]]]) }
        // A number where a schema goes; a `$ref` with an empty part. Found by
        // Codex.
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["not": 1]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try evaluator.audit(["$ref": 3]) }
        #expect(throws: DraftSevenEvaluator.Unread.self) { try DraftSevenEvaluator(root: ["definitions": ["x": [:]]]).audit(["$ref": "#/definitions//x"]) }
        let withDefinitions = DraftSevenEvaluator(root: ["definitions": ["small": ["maximum": 3]]])
        #expect(throws: DraftSevenEvaluator.Unread.self) { try withDefinitions.validates(1, against: ["$ref": "#/definitions/small", "minimum": 2]) }
        #expect(try withDefinitions.validates(2, against: ["$ref": "#/definitions/small", "description": "d"]))
    }

    private static func schemaURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas").appendingPathComponent(name)
    }
}

/// The draft-07 keywords a module schema's `linkTarget` uses, evaluated as
/// the specification says; any other keyword is refused, not skipped.
struct DraftSevenEvaluator {
    struct Unread: Error { let keyword: String }

    let root: [String: Any]

    private static let annotations: Set<String> = ["description", "title", "$comment", "default", "examples"]

    private static let known: Set<String> = [
        "$ref", "type", "enum", "const", "minimum", "maximum", "minLength", "properties", "required",
        "dependencies", "oneOf", "anyOf", "allOf", "not",
    ]

    /// Every keyword in `schema` and every schema it reaches is one this
    /// evaluator reads, whatever an instance would take.
    func audit(_ schema: Any) throws {
        var seen: Set<String> = []
        try audit(schema, seen: &seen)
    }

    private func audit(_ schema: Any, seen: inout Set<String>) throws {
        // A boolean, not a number read as one. Found by Codex.
        if Self.isBool(schema) { return }
        guard let schema = schema as? [String: Any] else { throw Unread(keyword: "a schema that is no object") }
        for key in schema.keys where !Self.annotations.contains(key) && !Self.known.contains(key) { throw Unread(keyword: key) }
        // Each in the form read: a scalar to compare, a number to bound, a
        // list of names. Found by Codex.
        func scalar(_ value: Any) -> Bool { value is String || Self.number(value) != nil }
        if let given = schema["const"], !scalar(given) { throw Unread(keyword: "const that is no string or number") }
        if let given = schema["enum"], !((given as? [Any])?.allSatisfy(scalar) ?? false) { throw Unread(keyword: "enum of other than strings and numbers") }
        for key in ["minimum", "maximum"] where schema[key] != nil && Self.number(schema[key]!) == nil { throw Unread(keyword: "\(key) that is no number") }
        if let given = schema["minLength"], !(given is Int) { throw Unread(keyword: "minLength that is no integer") }
        if let given = schema["type"], !(given is String) { throw Unread(keyword: "type that is no single name") }
        if let given = schema["required"], !(given is [String]) { throw Unread(keyword: "required that is no list of names") }
        if let given = schema["dependencies"] {
            guard let dependencies = given as? [String: Any], dependencies.values.allSatisfy({ $0 is [String] }) else {
                throw Unread(keyword: "dependencies with a schema")
            }
        }
        if let given = schema["$ref"] {
            // A reference in words, or none is read. Found by Codex.
            guard let reference = given as? String else { throw Unread(keyword: "$ref that is no string") }
            if schema.keys.contains(where: { $0 != "$ref" && !Self.annotations.contains($0) }) { throw Unread(keyword: "an assertion beside $ref") }
            guard seen.insert(reference).inserted else { return }
            try audit(resolve(reference), seen: &seen)
        }
        // A branch in a form not read is refused, not passed over. Found by
        // Codex.
        if let given = schema["properties"] {
            guard let properties = given as? [String: Any] else { throw Unread(keyword: "properties that is no object") }
            for value in properties.values { try audit(value, seen: &seen) }
        }
        for key in ["oneOf", "anyOf", "allOf"] where schema[key] != nil {
            guard let branches = schema[key] as? [Any], !branches.isEmpty else { throw Unread(keyword: "\(key) that is no list of schemas") }
            for value in branches { try audit(value, seen: &seen) }
        }
        if let negated = schema["not"] { try audit(negated, seen: &seen) }
    }

    private func resolve(_ reference: String) throws -> Any {
        guard reference.hasPrefix("#/") else { throw Unread(keyword: "$ref \(reference)") }
        var target: Any = root
        // Each part as written, an empty one too. Found by Codex.
        for part in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            guard let next = (target as? [String: Any])?[String(part)] else { throw Unread(keyword: "$ref \(reference)") }
            target = next
        }
        return target
    }

    func validates(_ value: Any, against schema: Any) throws -> Bool {
        if Self.isBool(schema) { return (schema as! NSNumber).boolValue }
        guard let schema = schema as? [String: Any] else { throw Unread(keyword: "a schema that is no object") }
        // A `$ref` stands alone in draft-07: an assertion beside it is
        // ignored by a validator, so is refused here rather than applied.
        if let reference = schema["$ref"] {
            if schema.keys.contains(where: { $0 != "$ref" && !Self.annotations.contains($0) }) { throw Unread(keyword: "an assertion beside $ref") }
            guard let reference = reference as? String else { throw Unread(keyword: "$ref") }
            return try validates(value, against: resolve(reference))
        }
        for key in schema.keys.sorted() where !Self.annotations.contains(key) {
            guard try check(key, schema[key]!, value, schema) else { return false }
        }
        return true
    }

    private func check(_ keyword: String, _ argument: Any, _ value: Any, _ schema: [String: Any]) throws -> Bool {
        let object = value as? [String: Any]
        switch keyword {
        case "type":
            return Self.isOfType(value, argument as? String ?? "")
        case "enum":
            return (argument as? [Any] ?? []).contains { Self.equal($0, value) }
        case "const":
            return Self.equal(argument, value)
        case "minimum":
            guard let number = Self.number(value) else { return true }
            return number >= (argument as? NSNumber)!.doubleValue
        case "maximum":
            guard let number = Self.number(value) else { return true }
            return number <= (argument as? NSNumber)!.doubleValue
        case "minLength":
            guard let string = value as? String else { return true }
            return string.unicodeScalars.count >= (argument as? Int)!
        case "properties":
            guard let object else { return true }
            for (key, subschema) in argument as? [String: Any] ?? [:] {
                if let given = object[key], try !validates(given, against: subschema) { return false }
            }
            return true
        case "required":
            guard let object else { return true }
            return (argument as? [String] ?? []).allSatisfy { object[$0] != nil }
        case "dependencies":
            guard let object else { return true }
            for (key, needed) in argument as? [String: Any] ?? [:] where object[key] != nil {
                guard let needed = needed as? [String] else { throw Unread(keyword: "dependencies with a schema") }
                if !needed.allSatisfy({ object[$0] != nil }) { return false }
            }
            return true
        case "oneOf":
            return try (argument as? [Any] ?? []).filter { try validates(value, against: $0) }.count == 1
        case "anyOf":
            return try (argument as? [Any] ?? []).contains { try validates(value, against: $0) }
        case "allOf":
            return try (argument as? [Any] ?? []).allSatisfy { try validates(value, against: $0) }
        case "not":
            return try !validates(value, against: argument)
        default:
            throw Unread(keyword: keyword)
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isBool(value) else { return nil }
        return number.doubleValue
    }

    private static func isOfType(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "integer": return number(value).map { $0 == $0.rounded() } ?? false
        case "number": return number(value) != nil
        case "string": return value is String
        case "boolean": return isBool(value)
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = number(a), let b = number(b) { return a == b }
        return false
    }
}
