import Foundation
import Testing
@testable import LampModuleKit

/// A block is read whole, or what of it is not is named, by path and never
/// by value (`LampBookUnread`).
struct LampBookUnreadTests {
    /// Every property the book schema names for a block and what it holds,
    /// each given once: the model reads them all.
    private static let full = #"""
    [
      {"type": "paragraph", "id": "p1", "content": {
        "text": "See John 3:16, and the note.",
        "annotations": [
          {"type": "scripture", "start": 4, "end": 13, "text": "John 3:16", "data": {
            "sv": 43003016, "ev": 43003017, "refs": [{"sv": 43003016, "ev": 43003018, "label": "John 3:16-18"}],
            "target": {"kind": "commentary", "module": "N", "sv": 43003016, "ev": 43003017, "suffix": "a", "unit": "u1", "anchor": "b1"}
          }},
          {"type": "link", "start": 19, "end": 27, "data": {"url": "https://example.org", "target": {"kind": "book", "module": "B", "section": "s", "anchor": "a"}}},
          {"type": "link", "start": 0, "end": 3, "data": {"target": {"kind": "commentary", "module": "N", "book": 43, "section": "intro"}}},
          {"type": "strongs", "start": 0, "end": 3, "data": {"strongs": "G25", "source": "x"}},
          {"type": "emphasis", "start": 0, "end": 3, "data": {"style": "bold"}},
          {"type": "footnote", "start": 0, "end": 3, "data": {"footnoteId": "1"}},
          {"type": "page", "start": 0, "end": 0, "data": {"pageNum": 4}},
          {"type": "media", "start": 0, "end": 3, "data": {"mediaId": "m1", "mediaType": "image"}}
        ],
        "footnote_refs": [{"id": "1", "offset": 3}]
      }},
      {"type": "heading", "level": 2, "content": {"text": "A heading"}},
      {"type": "list", "listType": "bullet", "items": [
        {"content": {"text": "One"}, "children": [{"content": {"text": "Nested"}}]}
      ]},
      {"type": "table", "columnCount": 2, "rows": [
        {"label": "good", "cells": [
          {"column": 0, "colSpan": 1, "rowSpan": 2, "header": true, "align": "center", "label": "k", "content": {"text": "King"}},
          {"column": 1, "content": {"text": "Years"}}
        ]}
      ], "legend": [{"label": "good", "title": "Good"}]},
      {"type": "image", "mediaId": "m1", "alignment": "center", "caption": {"text": "A map"}},
      {"type": "audio", "mediaId": "a1", "showWaveform": true, "autoplay": false, "caption": "A reading"},
      {"type": "figure", "id": "f1", "role": "chart", "title": "Kings", "subtitle": {"text": "931 BC"},
       "caption": {"text": "From Rehoboam", "annotations": [{"type": "bold", "start": 5, "end": 13}], "footnote_refs": [{"id": "1", "offset": 4}]},
       "children": [{"type": "image", "mediaId": "m1", "children": []}, {"type": "paragraph", "content": {"text": "Intro"}}],
       "notes": [{"text": "A note"}],
       "legend": [{"label": "good", "title": "Good"}]}
    ]
    """#

    private func blocks(_ json: String) throws -> [Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
    }

    private func unread(_ block: Any) -> [String] {
        LampBookUnread.paths(inBlock: block)
    }

    @Test func aBlockGivenEveryPropertyTheSchemaNamesIsReadWhole() throws {
        for (index, block) in try blocks(Self.full).enumerated() {
            #expect(unread(block) == [], "block \(index)")
        }
    }

    /// The fixture gives every property the schema names, wherever the
    /// schema names it: so one the schema adds is in the fixture, and read
    /// or reported, before the model can drop it unseen.
    ///
    /// The fixture and the schema are walked together from `contentBlock`,
    /// each `$ref` followed and every branch a property can be declared in
    /// merged; every definition the fixture reaches must have each of its
    /// properties given somewhere it is written. Listed by hand, definition
    /// by definition, four reviews in turn found one the list missed — a
    /// figure's children, a conditional branch, an annotation's data in a
    /// branch, a caption's `textValue`. Found by Codex.
    @Test func theFixtureGivesEveryPropertyTheSchemaNames() throws {
        let schemaURL = SchemaFilesTests.schemasURL.appendingPathComponent("book_schema.json")
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        let definitions = try #require(schema["definitions"] as? [String: Any])
        func definitionName(_ node: Any?) -> String? {
            ((node as? [String: Any])?["$ref"] as? String).flatMap {
                $0.hasPrefix("#/definitions/") ? String($0.dropFirst("#/definitions/".count)) : nil
            }
        }
        func resolved(_ node: Any?) -> [String: Any] {
            if let name = definitionName(node) { return resolved(definitions[name]) }
            return node as? [String: Any] ?? [:]
        }
        // The properties a node declares itself, by name, with their
        // schemas — its own and its inline branches' — and the definitions
        // its branches refer to, each visited as itself at the same value:
        // credited to the node, a `figureChild` owed every block property.
        func declared(_ node: Any?) -> (own: [String: Any], referred: [String]) {
            let object = resolved(node)
            var own = object["properties"] as? [String: Any] ?? [:]
            var referred: [String] = []
            let branches = ["allOf", "anyOf", "oneOf"].flatMap { object[$0] as? [Any] ?? [] }
                + ["if", "then", "else"].compactMap { object[$0] }
            for branch in branches {
                if let name = definitionName(branch) {
                    referred.append(name)
                } else {
                    let nested = declared(branch)
                    // A property two branches both declare is both: kept as
                    // the first, an annotation's `data` in a branch lost
                    // what that branch added.
                    own.merge(nested.own) { first, second in ["allOf": [first, second]] }
                    referred += nested.referred
                }
            }
            return (own, referred)
        }
        // Every schema an array's entries are held to: its own and each
        // branch's. The first alone missed a field a later branch's items
        // declared. Found by Codex.
        func items(_ node: Any?) -> [Any] {
            let object = resolved(node)
            let branches = ["allOf", "anyOf", "oneOf"].flatMap { object[$0] as? [Any] ?? [] }
                + ["if", "then", "else"].compactMap { object[$0] }
            return [object["items"]].compactMap { $0 } + branches.flatMap(items)
        }
        // What is owed, from the schema alone: every place a block can hold
        // an object — a definition, or a property or an array's entries
        // under one — and the properties declared there. Found from the
        // fixture, a place the fixture left empty owed nothing: emptied, a
        // figure's children no longer asked for a child. Found by Codex.
        var named: [String: Set<String>] = [:]
        func require(_ node: Any?, at place: String) {
            let place = definitionName(node) ?? place
            guard named[place] == nil else { return }
            let (names, referred) = declared(node)
            // Not one that can hold nothing — a figure child's `children`,
            // at most none — which no fixture could give.
            named[place] = Set(names.filter { resolved($0.value)["maxItems"] as? Int != 0 }.keys)
            for name in referred { require(["$ref": "#/definitions/\(name)"], at: name) }
            for (key, property) in names { require(property, at: "\(place).\(key)") }
            // Every branch's item schema as one, so neither is passed over
            // as a place already walked. Found by Codex.
            let itemSchemas = items(node)
            if !itemSchemas.isEmpty { require(["allOf": itemSchemas], at: "\(place)[]") }
        }
        require(["$ref": "#/definitions/contentBlock"], at: "contentBlock")

        func holdsNothing(_ value: Any) -> Bool {
            value is NSNull || (value as? String)?.isEmpty == true
                || (value as? [Any])?.isEmpty == true || (value as? [String: Any])?.isEmpty == true
        }
        // A definition is owed once, wherever it is written: a caption's
        // annotated text is held by the paragraphs' as well. So the fixture
        // gives a caption annotations and markers of its own, which the
        // round trip then reads (found by Codex); a place-by-place debt for
        // every use of a shared definition is not kept, since the model reads
        // each definition by one type wherever it is used.
        // What the fixture gives, at the same places.
        var given: [String: Set<String>] = [:]
        func visit(_ value: Any, _ node: Any?, at place: String) {
            let place = definitionName(node) ?? place
            let (names, referred) = declared(node)
            for name in referred { visit(value, ["$ref": "#/definitions/\(name)"], at: name) }
            if let object = value as? [String: Any] {
                // Given only where it holds something: `""`, `null`, `[]` and
                // `{}` are what the unread check passes over, so a property
                // given only so is never shown to be read. Found by Codex.
                given[place, default: []].formUnion(object.filter { !holdsNothing($0.value) }.keys)
                for (key, nested) in object {
                    if let property = names[key] { visit(nested, property, at: "\(place).\(key)") }
                }
            } else if let array = value as? [Any] {
                let itemSchemas = items(node)
                for entry in array where !itemSchemas.isEmpty {
                    visit(entry, ["allOf": itemSchemas], at: "\(place)[]")
                }
            }
        }
        for block in try blocks(Self.full) {
            visit(block, ["$ref": "#/definitions/contentBlock"], at: "contentBlock")
        }
        #expect(named["contentBlock"]?.isEmpty == false)
        for (place, names) in named.sorted(by: { $0.key < $1.key }) where !names.isEmpty {
            let lacking = names.subtracting(given[place] ?? [])
            #expect(lacking.isEmpty, "\(place): the fixture lacks \(lacking.sorted())")
        }
        // Reached, so held to the schema: each definition a block holds.
        #expect(Set(["contentBlock", "annotatedText", "annotation", "linkTarget", "verseRange",
                     "footnoteReference", "listItem", "tableRow", "tableCell", "legendEntry", "textValue"])
            .isSubset(of: named.keys), "\(named.keys.sorted())")
    }

    /// A key the model has no place for, at each depth it can be written,
    /// is named where it was written.
    @Test func whatTheModelDoesNotCarryIsNamedByPath() throws {
        let block = #"""
        {"type": "figure", "zz": 1, "caption": {"text": "c", "zz": 1},
         "children": [
           {"type": "table", "zz": 1, "rows": [{"zz": 1, "cells": [{"column": 0, "zz": 1, "content": {"text": "x",
             "annotations": [{"type": "scripture", "start": 0, "end": 1, "zz": 1, "data": {"sv": 43003016, "zz": 1,
               "refs": [{"sv": 43003016, "zz": 1}], "target": {"sv": 43003016, "zz": 1}}}],
             "footnote_refs": [{"id": "1", "offset": 0, "zz": 1}]}}]}],
            "legend": [{"label": "l", "title": "t", "zz": 1}]},
           {"type": "list", "items": [{"content": {"text": "a"}, "items": [{"content": {"text": "b"}}], "zz": 1}]}
         ]}
        """#
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(block.utf8)))
        let cell = "/children/0/rows/0/cells/0"
        let annotation = "\(cell)/content/annotations/0"
        #expect(Set(unread(raw)) == [
            "/zz", "/caption/zz",
            "/children/0/zz", "/children/0/rows/0/zz", "\(cell)/zz",
            "\(annotation)/zz", "\(annotation)/data/zz", "\(annotation)/data/refs/0/zz",
            "\(annotation)/data/target/zz",
            "\(cell)/content/footnote_refs/0/zz",
            "/children/0/legend/0/zz",
            // Sub-items written as `items`, which a list item nests as
            // `children`.
            "/children/1/items/0/items", "/children/1/items/0/zz",
        ], "\(unread(raw))")
    }

    @Test func whatTheModelCannotReadIsNamedToo() throws {
        // A field written as the wrong kind of value, a child a figure does
        // not hold, a `null` among entries, and a block that is none at all.
        let figure = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"type": "figure", "id": 7, "children": [{"type": "figure", "children": []}, {"type": "paragraph", "content": {"text": "a"}}],
         "notes": [{"text": "n"}, null]}
        """#.utf8)))
        #expect(Set(unread(figure)) == ["/id", "/children", "/notes"], "\(unread(figure))")
        #expect(unread(["type": 3]) == [""])
        #expect(LampBookUnread.paths(inBlock: "words", at: "/blocks/2") == ["/blocks/2"])
        // A word where a list belongs, read as an empty one; but a number
        // read as its string is carried. Found by Codex.
        #expect(unread(["type": "figure", "children": [], "notes": "a note"]) == ["/notes"])
        #expect(unread(["type": "paragraph", "content": ["text": "a", "annotations": [
            ["type": "page", "start": 0, "end": 0, "data": ["pageNum": 4]],
        ]]]) == [])
        // Two keys one as `String`s are two keys: a dropped one is named
        // whatever the other holds. Found by Codex.
        // Compared by bytes, which `String` equality would not tell apart,
        // and each spelling the one dropped in turn. Found by Codex.
        for (composed, decomposed, dropped) in [("1", #""""#, "caf\u{e9}"), (#""""#, "1", "cafe\u{301}")] {
            for json in [#"{"type": "paragraph", "content": {"text": "a", "caf\u00e9": \#(composed), "cafe\u0301": \#(decomposed)}}"#,
                         #"{"type": "paragraph", "content": {"text": "a", "cafe\u0301": \#(decomposed), "caf\u00e9": \#(composed)}}"#] {
                let twice = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)))
                #expect(unread(twice).map { Array($0.utf8) } == [Array("/content/\(dropped)".utf8)], "\(json)")
            }
        }
        // A number JSON cannot write, where a block belongs, is named, not a
        // crash. Found by Codex.
        let infinite = try #require(try JSONSerialization.jsonObject(with: Data("-1e500".utf8), options: .fragmentsAllowed))
        #expect(LampBookUnread.paths(inBlock: infinite, at: "/blocks/0") == ["/blocks/0"])
        // A key holding nothing loses nothing.
        #expect(unread(["type": "paragraph", "content": ["text": "a"], "notes": [], "legend": NSNull()]) == [])
        // Keys are escaped as a JSON pointer escapes them, a delimiter before
        // a combining mark too. Found by Codex.
        #expect(unread(["type": "paragraph", "a/b~c": 1]) == ["/a~1b~0c"])
        #expect(unread(["type": "paragraph", "a/\u{301}~\u{301}": 1]) == ["/a~1\u{301}~0\u{301}"])
        // An empty string is nothing to lose: a target's `suffix: ""`, which
        // the model reads as none. Found by Codex.
        #expect(unread(["type": "paragraph", "content": ["text": "a", "annotations": [
            ["type": "link", "start": 0, "end": 1, "data": ["target": ["kind": "commentary", "module": "N", "sv": 43003016, "suffix": ""]]],
        ]]]) == [])
    }
}
