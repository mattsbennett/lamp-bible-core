import Foundation
import Testing
@testable import LampModuleKit

/// A 2.3 commentary as a current phone reads it, until step 6's readers
/// draw blocks: a model of its decoding and its taps, after iOS
/// `ModuleModels.swift` (`AnnotatedText`, `FootnoteRef`, `CommentaryFootnote`)
/// and `CommentaryRenderer.swift`, held to every row a 2.3 volume builds.
/// Ten reviews of step 4's commit 5 each found one more place a note was
/// cited and the phone could not open it; this asks the phone, over every
/// place and every way a note can be cited (RichModulesPlan.md, step 4,
/// Rules A and B).
struct CommentaryOlderPhoneTests {
    /// The annotation types the phone decodes; any other is passed over.
    private static let phoneTypes: Set<String> = [
        "footnote", "scripture", "strongs", "greek", "hebrew", "crossref", "abbrev",
        "page", "lexicon-ref", "bold", "italic", "emphasis", "media",
    ]

    private struct Annotation { let type: String; let start: Int; let end: Int; let id: String?; let sv: Int? }
    private struct Text { let text: String; let annotations: [Annotation]; let markers: [(id: String, offset: Int)] }

    /// A text as the phone decodes one: its words a string, each annotation
    /// of a type it knows read or passed over alone, its markers all or none.
    private static func phoneText(_ value: Any?) -> Text? {
        guard let object = value as? [String: Any], let text = object["text"] as? String else { return nil }
        var annotations: [Annotation] = []
        for value in (object["annotations"] as? [Any]) ?? [] {
            guard let annotation = value as? [String: Any], let type = annotation["type"] as? String,
                  phoneTypes.contains(type),
                  let start = LampCommentaryBlocks.wholeNumber(annotation["start"]),
                  let end = LampCommentaryBlocks.wholeNumber(annotation["end"]),
                  annotation["id"] == nil || annotation["id"] is NSNull || annotation["id"] is String
            else { continue }
            let data = annotation["data"] as? [String: Any]
            annotations.append(Annotation(type: type, start: start, end: end, id: annotation["id"] as? String, sv: data?["sv"] as? Int))
        }
        var markers: [(id: String, offset: Int)] = []
        if let references = object["footnote_refs"] {
            guard let list = references as? [Any] else { return nil }
            for value in list {
                guard let reference = value as? [String: Any], let id = reference["id"] as? String,
                      let offset = LampCommentaryBlocks.wholeNumber(reference["offset"]) else { return nil }
                markers.append((id, offset))
            }
        }
        return Text(text: text, annotations: annotations, markers: markers)
    }

    /// A row's notes as the phone decodes them: all, or none.
    private static func phoneNotes(_ json: String?) -> [(id: String, content: Text)]? {
        guard let json else { return [] }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] else { return nil }
        var notes: [(id: String, content: Text)] = []
        for value in list {
            guard let note = value as? [String: Any], let id = note["id"] as? String,
                  let content = phoneText(note["content"]) else { return nil }
            notes.append((id, content))
        }
        return notes
    }

    private static func parsed(_ json: String?) -> Any? {
        json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    /// The notes a text's taps open: a footnote span with an `id` over words
    /// it covers, and each marker.
    private static func taps(_ text: Text) -> [String] {
        let length = text.text.unicodeScalars.count
        let spans = text.annotations.filter { $0.type == "footnote" && $0.start >= 0 && $0.start < $0.end && $0.end <= length }
            .compactMap(\.id)
        return spans + text.markers.map(\.id)
    }

    /// The text as the phone draws it: each marker inserted, from the
    /// highest offset down, as `[id]`.
    private static func drawn(_ text: Text) -> String {
        var scalars = Array(text.text.unicodeScalars)
        for marker in text.markers.enumerated().sorted(by: { $0.element.offset != $1.element.offset ? $0.element.offset > $1.element.offset : $0.offset < $1.offset }) {
            let offset = min(max(marker.element.offset, 0), scalars.count)
            scalars.insert(contentsOf: "[\(marker.element.id)]".unicodeScalars, at: offset)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Every row: each text column and its notes decode; every tap opens a
    /// note on the row, every note on the row is opened by one, once, and is
    /// the volume's; and every passage is tappable.
    private static func holdRowsToThePhone(_ builder: CommentaryUnitBuilder, definitions: [String: String]) {
        #expect(builder.issues.filter { $0.severity == .error }.isEmpty, "\(builder.issues)")
        for row in builder.units {
            let columns = [row.introductionJSON, row.translationJSON, row.commentaryJSON]
            var opened: [String] = []
            for column in columns where column != nil {
                guard let text = phoneText(parsed(column)) else {
                    Issue.record("\(row.id): a text the phone cannot read: \(column!)")
                    continue
                }
                opened += taps(text)
                let length = text.text.unicodeScalars.count
                for annotation in text.annotations where ["scripture", "crossref"].contains(annotation.type)
                    && annotation.start >= 0 && annotation.start < annotation.end && annotation.end <= length {
                    #expect(annotation.sv != nil, "\(row.id): a passage the phone cannot open")
                }
            }
            guard let notes = phoneNotes(row.footnotesJSON) else {
                Issue.record("\(row.id): notes the phone cannot read: \(row.footnotesJSON ?? "")")
                continue
            }
            let carried = notes.map(\.id)
            #expect(Set(carried).count == carried.count, "\(row.id): a note twice")
            #expect(Set(opened).isSubset(of: Set(carried)), "\(row.id): taps \(opened), carries \(carried)")
            #expect(Set(carried).isSubset(of: Set(opened)), "\(row.id): carries \(carried), taps \(opened)")
            for note in notes {
                #expect(note.content.text == definitions[note.id], "\(row.id): \(note.id) is not the volume's")
            }
        }
    }

    /// Every place a 2.3 unit's text can cite a note, in every form it can.
    @Test func everyCitationOpensItsNoteOnItsRow() throws {
        var definitions: [String: String] = [:]
        var counter = 0
        /// A text citing a fresh note `form`'s way, and a passage given by
        /// `refs` alone.
        func citing(_ form: String, plain: Bool) -> String {
            counter += 1
            let id = "n\(counter)"
            definitions[id] = "Note \(counter)."
            let passage = #"{"type": "scripture", "start": 2, "end": 3, "data": {"refs": [{"sv": 43003016}]}}"#
            switch form {
            case "marker":
                return #"{"text": "abc", "annotations": [\#(passage)], "footnote_refs": [{"id": "\#(id)", "offset": 1}]}"#
            case "id" where plain:
                return #"{"text": "abc", "annotations": [\#(passage), {"type": "footnote", "start": 0, "end": 1, "id": "\#(id)"}]}"#
            default:
                return #"{"text": "abc", "annotations": [\#(passage), {"type": "footnote", "start": 0, "end": 1, "data": {"footnoteId": "\#(id)"}}]}"#
            }
        }
        func paragraph(_ text: String) -> String { #"[{"type": "paragraph", "content": \#(text)}]"# }
        func inBlocks(_ form: String) -> [String] {
            [
                paragraph(citing(form, plain: false)),
                #"[{"type": "list", "items": [{"content": \#(citing(form, plain: false))}]}]"#,
                #"[{"type": "table", "rows": [{"cells": [{"column": 0, "content": \#(citing(form, plain: false))}]}]}]"#,
                #"[{"type": "figure", "caption": \#(citing(form, plain: false)), "children": [], "notes": [\#(citing(form, plain: false))]}]"#,
            ]
        }
        var chapters: [String] = []
        for (index, form) in ["marker", "id", "data"].enumerated() {
            let blockForm = form == "id" ? "data" : form
            let blocksVariants = inBlocks(blockForm)
            let verses = blocksVariants.enumerated().map { offset, blocks in
                #"{"sv": \#(43_000_000 + (index + 1) * 1_000 + 10 + offset), "blocks": \#(blocks)}"#
            } + [
                #"{"sv": \#(43_000_000 + (index + 1) * 1_000 + 1), "translation": \#(citing(form, plain: true)), "commentary": \#(citing(form, plain: true))}"#,
            ]
            chapters.append(#"""
            {"chapter": \#(index + 1), "introduction": \#(citing(form, plain: true)),
             "sections": [{"id": "s\#(index)", "sv": \#(43_000_000 + (index + 1) * 1_000 + 1), "introduction": \#(citing(form, plain: true)),
               "pericopae": [{"id": "p\#(index)", "sv": \#(43_000_000 + (index + 1) * 1_000 + 1), "introduction": \#(citing(form, plain: true)),
                 "translation": \#(citing(form, plain: true)), "blocks": \#(paragraph(citing(blockForm, plain: false))),
                 "verses": [\#(verses.joined(separator: ","))]}]},
              {"id": "b\#(index)", "sv": \#(43_000_000 + (index + 1) * 1_000 + 2), "blocks": \#(paragraph(citing(blockForm, plain: false)))}],
             "verses": [{"sv": \#(43_000_000 + (index + 1) * 1_000 + 5), "commentary": \#(citing(form, plain: true))}]}
            """#)
        }
        let footnotes = "[" + definitions.sorted { $0.key < $1.key }.map { #"{"id": "\#($0.key)", "content": {"text": "\#($0.value)"}}"# }.joined(separator: ",") + "]"
        var builder = CommentaryUnitBuilder(
            moduleID: "M", bookNumber: 43,
            footnotes: try #require(try JSONSerialization.jsonObject(with: Data(footnotes.utf8)) as? [Any]), rich: true
        )
        try builder.append(chapters: try #require(try JSONSerialization.jsonObject(with: Data("[\(chapters.joined(separator: ","))]".utf8)) as? [Any]))
        #expect(builder.units.count > 20)
        Self.holdRowsToThePhone(builder, definitions: definitions)

        // A source-tracked volume's entries, with and without a label to trim.
        definitions = [:]
        counter = 0
        var entries: [String] = []
        for form in ["marker", "id", "data"] {
            entries.append(#"{"type": "commentary", "sv": 43001001, "source": {}, "content": \#(citing(form, plain: true))}"#)
            let labelled = citing(form, plain: true).replacingOccurrences(of: #""text": "abc""#, with: #""text": "9 abc""#)
                .replacingOccurrences(of: #""start": 2, "end": 3"#, with: #""start": 4, "end": 5"#)
                .replacingOccurrences(of: #""start": 0, "end": 1"#, with: #""start": 2, "end": 3"#)
                .replacingOccurrences(of: #""offset": 1"#, with: #""offset": 3"#)
            entries.append(#"{"type": "commentary", "sv": 43001002, "displayPrefixLength": 2, "source": {}, "content": \#(labelled)}"#)
            entries.append(#"{"type": "commentary", "sv": 43001003, "source": {}, "blocks": \#(paragraph(citing(form == "id" ? "data" : form, plain: false)))}"#)
        }
        let pericopeIntroduction = citing("marker", plain: true)
        let trackedNotes = "[" + definitions.sorted { $0.key < $1.key }.map { #"{"id": "\#($0.key)", "content": {"text": "\#($0.value)"}}"# }.joined(separator: ",") + "]"
        var tracked = CommentaryUnitBuilder(
            moduleID: "M", bookNumber: 43,
            footnotes: try #require(try JSONSerialization.jsonObject(with: Data(trackedNotes.utf8)) as? [Any]),
            sourceOrdered: true, rich: true
        )
        try tracked.append(chapters: try #require(try JSONSerialization.jsonObject(with: Data(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "introduction": \#(pericopeIntroduction), "content": [\#(entries.joined(separator: ","))]}]}]"#.utf8)) as? [Any]))
        Self.holdRowsToThePhone(tracked, definitions: definitions)
    }

    /// B1 adds and never takes away: given twice it is the same, and a text
    /// as 2.2 writes one comes out as it went in.
    @Test func rulesForEveryTextOnlyAdd() throws {
        var issues: [ModuleValidationIssue] = []
        let older = try #require(try JSONSerialization.jsonObject(with: Data(#"{"text": "John 3:16", "annotations": [{"type": "scripture", "start": 0, "end": 9, "data": {"sv": 43003016}}, {"type": "footnote", "start": 0, "end": 4, "id": "1"}], "footnote_refs": [{"id": "1", "offset": 4}]}"#.utf8)) as? [String: Any])
        let once = LampCommentaryBlocks.writtenForOlderReaders(older, path: "", issues: &issues)
        #expect((once as NSDictionary) == (older as NSDictionary))
        let added = LampCommentaryBlocks.writtenForOlderReaders(
            ["text": "x", "annotations": [["type": "footnote", "start": 0, "end": 1, "data": ["footnoteId": "2"]]]], path: "", issues: &issues
        )
        #expect((LampCommentaryBlocks.writtenForOlderReaders(added, path: "", issues: &issues) as NSDictionary) == (added as NSDictionary))
        #expect(issues.isEmpty)
        // What would blank the phone's text is refused.
        _ = LampCommentaryBlocks.writtenForOlderReaders(["text": 3], path: "/a", issues: &issues)
        _ = LampCommentaryBlocks.writtenForOlderReaders(["text": "x", "footnote_refs": [["id": 1, "offset": 0]]], path: "/b", issues: &issues)
        #expect(issues.map(\.path) == ["/a", "/b"])
    }

    /// B2: what the phone draws of the older copy is what the resolver draws
    /// of the projection, over texts made at random with pages marked at a
    /// point, markers sharing a place, markers at a page, and spans across a
    /// page.
    @Test func theOlderCopyDrawsAsTheProjectionDoes() {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<2_000 {
            let length = 1 + next(10)
            let text = String((0..<length).map { _ in next(4) == 0 ? " " : Character(UnicodeScalar(97 + next(26))!) })
            var annotations: [LampBookAnnotation] = []
            for _ in 0..<next(4) {
                let at = next(length + 1)
                annotations.append(LampBookAnnotation(type: "page", start: at, end: at, data: LampBookAnnotationData(pageNumber: "\(next(99))")))
            }
            for _ in 0..<next(3) {
                let start = next(length), end = start + 1 + next(length - start)
                annotations.append(LampBookAnnotation(type: next(2) == 0 ? "bold" : "scripture", start: start, end: end,
                                                      data: LampBookAnnotationData(startReference: 43_003_016)))
            }
            var shuffler = SeededGenerator(seed: &seed)
            annotations.shuffle(using: &shuffler)
            let references = (0..<next(4)).map { index in LampBookFootnoteReference(id: "\(index + 1)", offset: next(length + 1)) }
            let projection = LampBookAnnotatedText(text: text, annotations: annotations, footnoteReferences: references)
            let numbers = Dictionary(uniqueKeysWithValues: references.map { ($0.id, Int($0.id)!) })
            let resolved = String(LampBookTextResolver.resolve(projection, footnoteNumbers: numbers, containingKind: "commentary").characters)
            let copy = Self.phoneText(LampCommentaryBlocks.olderReadersCopy(of: projection))
            #expect(copy.map(Self.drawn) == resolved, "\(projection)")
            // Every span still over the words it was, its pieces together.
            let copyText = copy?.text ?? ""
            for annotation in copy?.annotations ?? [] where annotation.type != "page" {
                let scalars = Array(copyText.unicodeScalars)
                #expect(annotation.start >= 0 && annotation.start <= annotation.end && annotation.end <= scalars.count)
                #expect(!String(String.UnicodeScalarView(scalars[annotation.start..<annotation.end])).contains("[p."))
            }
        }
    }
}

/// The random order a test shuffles by, from its own seed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: inout UInt64) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        state = seed
    }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
