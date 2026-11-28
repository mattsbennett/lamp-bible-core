import Foundation
import Testing
@testable import LampModuleKit

/// A 2.3 volume's front matter and media, planned in memory (step 4,
/// commit 7): front-matter sections as rows of their own, each read whole;
/// media read whole against the book schema's `mediaReference`.
struct CommentaryFrontMatterTests {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func build(
        chapters: String = "[]", frontMatter: String? = nil, media: String? = nil, rich: Bool = true, sourceOrdered: Bool = false
    ) throws -> CommentaryUnitBuilder {
        var builder = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, sourceOrdered: sourceOrdered, rich: rich)
        try builder.append(chapters: try json(chapters) as? [Any] ?? [])
        builder.append(frontMatter: try frontMatter.map(json), media: try media.map(json))
        return builder
    }

    private func errors(_ builder: CommentaryUnitBuilder) -> [String] {
        builder.issues.filter { $0.severity == .error }.map(\.path)
    }

    private static let paragraph = #"[{"type": "paragraph", "content": {"text": "Words of the introduction."}}]"#
    private static let image = #"{"id": "m1", "type": "image", "filename": "one.png", "mimeType": "image/png"}"#

    /// Each section a row, in reading order: its id, title, depth and parent,
    /// its blocks as written, and its words for search.
    @Test func eachFrontMatterSectionIsARowOfItsOwn() throws {
        let built = try build(frontMatter: #"""
        {"sections": [{"id": "intro", "title": "Introduction", "blocks": \#(Self.paragraph),
                       "sections": [{"id": "author", "title": "Author", "blocks": [], "sections": [{"id": "date", "title": "Date"}]}]},
                      {"id": "outline", "title": "Outline", "blocks": [{"type": "list", "items": [{"content": {"text": "One"}}]}]}]}
        """#)
        #expect(built.issues.isEmpty, "\(built.issues)")
        let rows = built.frontMatterRows
        #expect(rows.map(\.sectionID) == ["intro", "author", "date", "outline"])
        #expect(rows.map(\.depth) == [0, 1, 2, 0])
        #expect(rows.map(\.orderIndex) == [0, 1, 2, 3])
        #expect(rows.map(\.parentID) == [nil, rows[0].id, rows[1].id, nil])
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(rows[0].searchText.contains("Introduction") && rows[0].searchText.contains("Words of the introduction."))
        #expect(rows[0].blocksJSON.contains("Words of the introduction."))
        #expect(rows[2].blocksJSON == "[]")
        #expect(rows[3].searchText.contains("One"))
        // A 2.2 volume's front matter is not read as sections.
        let older = try build(frontMatter: #"{"sections": [{"id": "x"}]}"#, media: "7", rich: false)
        #expect(older.issues.isEmpty && older.frontMatterRows.isEmpty)
    }

    /// What a section gives is read whole, and refused where written.
    @Test func aFrontMatterSectionIsReadWhole() throws {
        func paths(_ frontMatter: String) throws -> [String] { errors(try build(frontMatter: frontMatter)) }
        // An id once in its book, nested sections too; words, not empty, no
        // NUL; given.
        #expect(try paths(#"{"sections": [{"id": "a", "title": "A"}, {"id": "b", "title": "B", "sections": [{"id": "a", "title": "C"}]}]}"#)
            == ["/frontMatter/sections/1/sections/0/id"])
        #expect(try paths(#"{"sections": [{"id": "é", "title": "A"}, {"id": "é", "title": "B"}]}"#).isEmpty)
        for id in [#""""#, #""a\u0000b""#, "7"] {
            #expect(try paths(#"{"sections": [{"id": \#(id), "title": "A"}]}"#) == ["/frontMatter/sections/0/id"], "\(id)")
        }
        #expect(try paths(#"{"sections": [{"title": "A"}]}"#) == ["/frontMatter/sections/0/id"])
        // A title, of words.
        #expect(try paths(#"{"sections": [{"id": "a"}]}"#) == ["/frontMatter/sections/0/title"])
        #expect(try paths(#"{"sections": [{"id": "a", "title": "  "}]}"#) == ["/frontMatter/sections/0/title"])
        // No field nothing reads: a verse, say.
        #expect(try paths(#"{"sections": [{"id": "a", "title": "A", "sv": 43001001}]}"#) == ["/frontMatter/sections/0/sv"])
        #expect(try paths(#"{"preface": {"text": "x"}}"#) == ["/frontMatter/preface"])
        // A 2.2 volume's front-matter fields, each refused: none is read as
        // a row. Found by Codex.
        #expect(try paths(#"{"text": "t", "dedication": "d", "introduction": {"text": "i"}, "bibliography": [], "content": [], "editorPreface": {"text": "e"}, "authorPreface": {"text": "a"}}"#)
            == ["/frontMatter/authorPreface", "/frontMatter/bibliography", "/frontMatter/content", "/frontMatter/dedication", "/frontMatter/editorPreface", "/frontMatter/introduction", "/frontMatter/text"])
        // Lists and objects where they are lists and objects.
        #expect(try paths(#"{"sections": {"id": "a", "title": "A"}}"#) == ["/frontMatter/sections"])
        #expect(try paths(#"{"sections": [7]}"#) == ["/frontMatter/sections/0"])
        #expect(try paths(#"[]"#) == ["/frontMatter"])
        // Its blocks as a unit's are: a field no block reads is refused.
        #expect(try paths(#"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "paragraph", "content": {"text": "x"}, "colour": "red"}]}]}"#)
            == ["/frontMatter/sections/0/blocks/0/colour"])
    }

    /// Front matter carries no notes, so a note cited there is refused
    /// (Rule A), as a span or a marker, at any depth.
    @Test func frontMatterCitesNoNote() throws {
        let span = #"{"type": "paragraph", "content": {"text": "x", "annotations": [{"type": "footnote", "start": 0, "end": 1, "id": "n"}]}}"#
        let marker = #"{"type": "paragraph", "content": {"text": "x", "footnote_refs": [{"id": "n", "offset": 1}]}}"#
        let nested = #"{"type": "figure", "title": "F", "children": [\#(span)]}"#
        for block in [span, marker, nested] {
            let built = try build(frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [\#(block)]}]}"#)
            #expect(errors(built).contains("/frontMatter/sections/0/blocks"), "\(built.issues)")
        }
        let empty = try build(frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "paragraph", "content": {"text": "x", "footnote_refs": []}}]}]}"#)
        #expect(errors(empty).isEmpty, "\(empty.issues)")
    }

    /// One volume's block ids are one set, front matter and units together.
    @Test func aBlockIdIsOnceInAVolume() throws {
        let built = try build(
            chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "id": "b1", "content": {"text": "x"}}]}]}]"#,
            frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "paragraph", "id": "b1", "content": {"text": "y"}}]}]}"#
        )
        #expect(errors(built) == ["/frontMatter/sections/0/blocks/0/id"], "\(built.issues)")
    }

    /// Media read whole: each entry's fields of the kind the book schema
    /// says, its id once, its file one plain name in the module's media folder that
    /// sync carries, as written and with no scheme, once as a Mac or phone
    /// tells names apart.
    @Test func mediaIsReadWhole() throws {
        func paths(_ media: String) throws -> [String] { errors(try build(media: media)) }
        let full = #"{"id": "a", "type": "audio", "filename": "a.m4a", "mimeType": "audio/mp4", "size": 0, "duration": 1.5, "waveform": [0, 0.5, 1], "transcription": "t", "created": 1700000000}"#
        let built = try build(media: "[\(Self.image), \(full)]")
        #expect(built.issues.isEmpty, "\(built.issues)")
        #expect(built.media.count == 2)
        #expect(try paths("{}") == ["/media"])
        #expect(try paths("[7]") == ["/media/0"])
        #expect(try paths("[\(Self.image), \(Self.image.replacingOccurrences(of: "one.png", with: "two.png"))]") == ["/media/1/id"])
        func entry(_ change: String, _ to: String) -> String {
            "[" + Self.image.replacingOccurrences(of: change, with: to) + "]"
        }
        #expect(try paths(entry(#""type": "image""#, #""type": "video""#)) == ["/media/0/type"])
        // One plain name, in no folder: each looser rule let one more name
        // through that sync could not carry or a volume could not hold
        // beside another. Found by Codex.
        for filename in ["../one.png", "/one.png", "https:/host/one.png", "one%2Fone.png", #"maps\\one.png"#, "", "maps/one.png", "maps//one.png", ".hidden.png",
                         "maps/", "one two.png", "\u{e9}.png", "a:b.png", "maps/\u{301}x", String(repeating: "a", count: 252) + ".png"] {
            #expect(try paths(entry("one.png", filename)) == ["/media/0/filename"], "\(filename)")
        }
        #expect(try paths(entry("one.png", String(repeating: "a", count: 251) + ".png")).isEmpty)
        // Once, as a Mac or phone tells names apart.
        #expect(try paths("[\(Self.image), \(Self.image.replacingOccurrences(of: #""m1""#, with: #""m2""#).replacingOccurrences(of: "one.png", with: "ONE.png"))]")
            == ["/media/1/filename"])
        #expect(try paths(entry(#", "mimeType": "image/png""#, "")) == ["/media/0/mimeType"])
        for (key, value) in [("size", "-1"), ("size", "1.5"), ("size", "true"), ("width", "0"), ("height", "\"2\""),
                             ("duration", "-1"), ("duration", "\"1\""), ("waveform", "[2]"), ("waveform", "[true]"),
                             ("waveform", "\"x\""), ("alt", "3"), ("transcription", "[]"), ("created", "1.5")] {
            #expect(try paths(entry(#""mimeType": "image/png""#, #""mimeType": "image/png", "\#(key)": \#(value)"#)) == ["/media/0/\(key)"], "\(key) \(value)")
        }
        #expect(try paths(entry(#""mimeType": "image/png""#, #""mimeType": "image/png", "url": "https://x.org/a.png""#)) == ["/media/0/url"])
    }

    /// A picture a block names that no media entry lists is drawn as
    /// nothing: warned of, in a unit and in front matter.
    @Test func aPictureNoEntryListsIsWarnedOf() throws {
        let block = #"{"type": "image", "mediaId": "missing"}"#
        let built = try build(
            chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [\#(block)]}]}]"#,
            frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "image", "mediaId": "m1"}, \#(block)]}]}"#,
            media: "[\(Self.image)]"
        )
        #expect(errors(built).isEmpty, "\(built.issues)")
        #expect(built.issues.filter { $0.severity == .warning }.map(\.path)
            == ["/chapters/0/verses/0/blocks/0", "/frontMatter/sections/0/blocks/1"], "\(built.issues)")
    }

    /// A 2.3 volume is a Bible book's; a picture a plain text or a note
    /// names is checked as a block's is. Found by Codex.
    @Test func aVolumesBookAndPlainTextPicturesAreChecked() throws {
        var outside = CommentaryUnitBuilder(moduleID: "M", bookNumber: 67, rich: true)
        try outside.append(chapters: [])
        #expect(errors(outside) == ["/bookNumber"])
        let named = #"{"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "missing"}}]}"#
        let built = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(named)}]}]"#, media: "[\(Self.image)]")
        #expect(built.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0/commentary/annotations/0/data"], "\(built.issues)")
        let both = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "translation": \#(named), "commentary": \#(named)}]}]"#, media: "[\(Self.image)]")
        #expect(Set(both.issues.map(\.path)) == ["/chapters/0/verses/0/translation/annotations/0/data", "/chapters/0/verses/0/commentary/annotations/0/data"])
        let tracked = try build(chapters: #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "content": \#(named)}]}]}]"#, media: "[\(Self.image)]", sourceOrdered: true)
        #expect(tracked.issues.map(\.path) == ["/chapters/0/pericopae/0/content/0/content/annotations/0/data"], "\(tracked.issues)")
        // A chapter's introduction at its own path; an annotation naming no
        // media, one naming a sound for a picture, and an id on a passage,
        // which names nothing. Found by Codex.
        let intro = try build(chapters: #"[{"chapter": 1, "introduction": \#(named)}]"#, media: "[\(Self.image)]")
        #expect(intro.issues.map(\.path) == ["/chapters/0/introduction/annotations/0/data"], "\(intro.issues)")
        let sound = #"{"id": "s1", "type": "audio", "filename": "talk.m4a", "mimeType": "audio/mp4"}"#
        let kinds = try build(
            chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {}}, {"type": "media", "start": 0, "end": 3, "data": {"mediaId": "s1", "mediaType": "image"}}, {"type": "scripture", "start": 0, "end": 3, "data": {"sv": 43001001, "mediaId": ""}}]}, "blocks": null}, {"sv": 43001002, "blocks": [{"type": "image", "mediaId": "s1"}, {"type": "audio", "mediaId": "s1"}]}]}]"#,
            media: "[\(Self.image), \(sound)]"
        )
        #expect(kinds.issues.map { "\($0.severity) \($0.path)" } == [
            "error /chapters/0/verses/0/commentary/annotations/0/data",
            "warning /chapters/0/verses/0/commentary/annotations/1/data",
            "warning /chapters/0/verses/1/blocks/0",
        ], "\(kinds.issues)")
        // A kind that is neither; an entry whose blocks are null keeps its
        // content. Found by Codex.
        let badKind = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "s1", "mediaType": "Image"}}]}}]}]"#, media: "[\(sound)]")
        #expect(badKind.issues.map(\.path) == ["/chapters/0/verses/0/commentary/annotations/0/data/mediaType"], "\(badKind.issues)")
        let nullBlocks = try build(chapters: #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "blocks": null, "content": {"text": "kept"}}]}]}]"#, sourceOrdered: true)
        #expect(nullBlocks.issues.isEmpty, "\(nullBlocks.issues)")
        #expect(nullBlocks.units.contains { $0.commentaryJSON?.contains("kept") == true })
        // A kind told before its id is looked for; a marker's stray `type`
        // is no picture. Found by Codex.
        let videoMissing = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "none", "mediaType": "video"}}]}}]}]"#)
        #expect(videoMissing.issues.map { "\($0.severity) \($0.path)" } == ["error /chapters/0/verses/0/commentary/annotations/0/data/mediaType"], "\(videoMissing.issues)")
        let strayType = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "footnote_refs": [{"id": "n", "offset": 1, "type": "image"}]}}]}]"#)
        #expect(!strayType.issues.contains { $0.message.contains("mediaId") }, "\(strayType.issues)")
        let numberKind = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "s1", "mediaType": 7}}]}}]}]"#, media: "[\(sound)]")
        // A kind given as a number leaves the annotation one no reader
        // decodes: told once, by the older reader's rule.
        #expect(numberKind.issues.map(\.path) == ["/chapters/0/verses/0"], "\(numberKind.issues)")
        let blockKind = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "list", "items": [{"content": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "s1", "mediaType": "video"}}]}}]}]}]}]"#, media: "[\(sound)]")
        #expect(blockKind.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0"], "\(blockKind.issues)")
        // Unreadable; front matter's older fields citing a note; an entry's
        // media told at its place as written, before a label's trim. Found
        // by Codex.
        let noEnd = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "data": {"mediaId": "s1"}}]}}]}]"#, media: "[\(sound)]")
        #expect(noEnd.issues.map(\.path) == ["/chapters/0/verses/0"], "\(noEnd.issues)")
        let trimmed = try build(chapters: #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "displayPrefixLength": 2, "content": {"text": "1 see", "annotations": [{"type": "bold", "start": 0, "end": 1}, {"type": "media", "start": 2, "end": 5, "data": {"mediaId": "none"}}]}}]}]}]"#, sourceOrdered: true)
        #expect(trimmed.issues.map(\.path) == ["/chapters/0/pericopae/0/content/0/content/annotations/1/data"], "\(trimmed.issues)")
        // A caption the phone does not read; a preface's and a content
        // entry's pictures; a sibling's picture beside a block that will not
        // decode. Found by Codex.
        let caption = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "s1", "caption": 4}}]}}]}]"#, media: "[\(sound)]")
        #expect(errors(caption) == ["/chapters/0/verses/0"], "\(caption.issues)")
        let sibling = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": 3}, {"type": "image"}]}]}]"#)
        #expect(errors(sibling).contains("/chapters/0/verses/0/blocks/1"), "\(sibling.issues)")
        // A picture at a point, the schema's inline form, is no dead link;
        // a figure child at the place it is written, past one the model
        // drops. Found by Codex.
        let point = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "see", "annotations": [{"type": "media", "start": 1, "end": 1, "data": {"mediaId": "s1"}}]}}]}]}]"#, media: "[\(sound)]")
        #expect(point.issues.isEmpty, "\(point.issues)")
        let dropped = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "figure", "title": "F", "children": [{"type": "audio", "mediaId": "s1"}, {"type": "image"}]}]}]}]"#, media: "[\(sound)]")
        #expect(errors(dropped).contains("/chapters/0/verses/0/blocks/0/children/1"), "\(dropped.issues)")
        // Ids as plain as filenames; a picture's span within a trimmed
        // label. Found by Codex.
        for id in [#""\u00e9""#, #""a b""#, #""a/b""#, #"".a""#] {
            #expect(try errors(build(media: "[" + Self.image.replacingOccurrences(of: #""m1""#, with: id) + "]")) == ["/media/0/id"], "\(id)")
        }
        let inLabel = try build(chapters: #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "displayPrefixLength": 2, "content": {"text": "1 see", "annotations": [{"type": "media", "start": 0, "end": 1, "data": {"mediaId": "s1"}}]}}]}]}]"#, media: "[\(sound)]", sourceOrdered: true)
        #expect(inLabel.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/pericopae/0/content/0/content/annotations/0"], "\(inLabel.issues)")
        // Only what the trim drops: nothing where none is trimmed, a point
        // inside the label, not one at its boundary. Found by Codex.
        func trimming(_ length: Int, at offset: Int) throws -> [String] {
            try build(chapters: #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "displayPrefixLength": \#(length), "content": {"text": "1 see", "annotations": [{"type": "media", "start": \#(offset), "end": \#(offset), "data": {"mediaId": "s1"}}]}}]}]}]"#, media: "[\(sound)]", sourceOrdered: true).issues.map(\.message)
        }
        #expect(try trimming(0, at: 0).isEmpty)
        #expect(try trimming(2, at: 1).contains { $0.contains("label") })
        #expect(try trimming(2, at: 2).isEmpty)
        // A picture on a block that draws none; a section's blocks null.
        // Found by Codex.
        let onFigure = try build(frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "figure", "title": "Map", "mediaId": "m1", "children": []}]}, {"id": "b", "title": "B", "blocks": null}]}"#, media: "[\(Self.image)]")
        #expect(errors(onFigure) == ["/frontMatter/sections/0/blocks/0/mediaId"], "\(onFigure.issues)")
        // An empty one names nothing. Found by Codex.
        let emptyOnParagraph = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "mediaId": "", "content": {"text": "x"}}]}]}]"#)
        #expect(errors(emptyOnParagraph).isEmpty, "\(emptyOnParagraph.issues)")
        // Front matter and media told though a chapter cannot be built.
        let broken = #"{"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"}, "book": "John", "bookNumber": 43, "chapters": [{"chapter": 1, "verses": [{"commentary": {"text": "x"}}]}], "media": [{"id": "m1", "type": "image", "filename": "../x.png", "mimeType": "image/png"}]}"#
        let inspected = try ModuleJSONInspector().inspect(Data(broken.utf8)).issues.map(\.path)
        #expect(inspected.contains("/chapters/0/verses/0/sv") && inspected.contains("/media/0/filename"), "\(inspected)")
        let outOfRange = broken.replacingOccurrences(of: #""bookNumber": 43"#, with: #""bookNumber": 67"#)
            .replacingOccurrences(of: #""chapters": [{"chapter": 1, "verses": [{"commentary": {"text": "x"}}]}]"#, with: #""chapters": {}"#)
        #expect(try ModuleJSONInspector().inspect(Data(outOfRange.utf8)).issues.filter { $0.path == "/bookNumber" && $0.severity == .error }.count == 1)
        // A fraction told once, and its chapters not judged by its whole part.
        for number in ["67.5", "42.5", "67"] {
            let volume = broken.replacingOccurrences(of: #""bookNumber": 43"#, with: #""bookNumber": \#(number)"#)
            let found = try ModuleJSONInspector().inspect(Data(volume.utf8)).issues
            #expect(found.filter { $0.path == "/bookNumber" && $0.severity == .error }.count == 1, "\(number) \(found)")
            #expect(!found.contains { $0.path.hasPrefix("/chapters") && $0.severity == .error && $0.path != "/chapters/0/verses/0/sv" }, "\(number) \(found)")
        }
        let noBook = broken.replacingOccurrences(of: #""bookNumber": 43, "#, with: "")
        #expect(try ModuleJSONInspector().inspect(Data(noBook.utf8)).issues.map(\.path).contains("/media/0/filename"))
        let noList = broken.replacingOccurrences(of: #""chapters": [{"chapter": 1, "verses": [{"commentary": {"text": "x"}}]}]"#, with: #""chapters": {}"#)
        #expect(try ModuleJSONInspector().inspect(Data(noList.utf8)).issues.map(\.path).contains("/media/0/filename"))
        // Outside its text; a point at its end is within it. Found by Codex.
        let pastText = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "See", "annotations": [{"type": "media", "start": 5, "end": 6, "data": {"mediaId": "s1"}}, {"type": "media", "start": 3, "end": 3, "data": {"mediaId": "s1"}}]}}]}]"#, media: "[\(sound)]")
        #expect(pastText.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0/commentary/annotations/0"], "\(pastText.issues)")
        let pastWithKind = #"{"text": "See", "annotations": [{"type": "media", "start": 5, "end": 6, "data": {"mediaId": "s1", "mediaType": "video"}}]}"#
        let pastAndKind = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(pastWithKind)}]}]"#, media: "[\(sound)]")
        #expect(Set(pastAndKind.issues.map { "\($0.severity) \($0.path)" })
            == ["warning /chapters/0/verses/0/commentary/annotations/0", "error /chapters/0/verses/0/commentary/annotations/0/data/mediaType"], "\(pastAndKind.issues)")
        let pastInBlock = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "See", "annotations": [{"type": "media", "start": 5, "end": 6, "data": {"mediaId": "s1"}}]}}]}]}]"#, media: "[\(sound)]")
        #expect(pastInBlock.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0/blocks/0"], "\(pastInBlock.issues)")
        let clipped = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "See", "annotations": [{"type": "media", "start": 1, "end": 4, "data": {"mediaId": "s1"}}]}}]}]}]"#, media: "[\(sound)]")
        #expect(clipped.issues.isEmpty, "\(clipped.issues)")
        let inBlock = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "see", "annotations": [{"type": "media", "start": 0, "end": 3, "data": {"mediaId": "none"}}]}}]}]}]"#)
        #expect(inBlock.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0/blocks/0"], "\(inBlock.issues)")
        // A book that is no whole number, compiled or inspected.
        let volume = #"{"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"}, "book": "John", "bookNumber": 43.5, "chapters": []}"#
        let root = try #require(try json(volume) as? [String: Any])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try LampModuleCompiler().compileCommentary(root: root, databaseURL: url, moduleID: "R")
            Issue.record("book 43.5 compiled")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "/bookNumber")
        }
        #expect(try ModuleJSONInspector().inspect(Data(volume.utf8)).issues.contains { $0.path == "/bookNumber" && $0.severity == .error })
    }

    /// Front matter's blocks are read by the newer reader alone: a passage
    /// given by its `refs`, with an `ev` and no `sv`, is one it opens.
    /// Found by Codex.
    @Test func frontMatterIsNotHeldToTheOlderReader() throws {
        let refs = #"{"type": "paragraph", "content": {"text": "see", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {"refs": [{"sv": 43003016}], "ev": 43003017}}]}}"#
        let front = try build(frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [\#(refs)]}]}"#)
        #expect(errors(front).isEmpty, "\(front.issues)")
        let unit = try build(chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [\#(refs)]}]}]"#)
        #expect(!errors(unit).isEmpty, "\(unit.issues)")
    }

    /// An image or audio block names its media. Found by Codex.
    @Test func anImageNamesItsMedia() throws {
        let built = try build(
            chapters: #"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "image"}]}]}]"#,
            frontMatter: #"{"sections": [{"id": "a", "title": "A", "blocks": [{"type": "figure", "title": "F", "children": [{"type": "image"}]}]}]}"#
        )
        #expect(errors(built) == ["/chapters/0/verses/0/blocks/0", "/frontMatter/sections/0/blocks/0/children/0"], "\(built.issues)")
    }

    /// A series' volumes share one media folder: one id is one entry, and
    /// one file is one id's, whichever volume names it.
    @Test func aSeriesGivesEachMediaOneWay() throws {
        let one = try #require(try json(Self.image) as? [String: Any])
        var media = LampModuleCompiler.SeriesMedia()
        try media.add([one], from: "A.json")
        try media.add([one], from: "B.json")
        var changed = one
        changed["mimeType"] = "image/jpeg"
        #expect(throws: ModuleCompilationError.self) { try media.add([changed], from: "C.json") }
        var other = one
        other["id"] = "m2"
        other["filename"] = "ONE.png"
        do {
            try media.add([other], from: "D.json")
            Issue.record("one file for two ids was added")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "D.json: /media/0/filename")
        }
        // Spelled two ways in bytes. Found by Codex.
        var spelled = one
        spelled["alt"] = "\u{e9}"
        var media2 = LampModuleCompiler.SeriesMedia()
        try media2.add([spelled], from: "A.json")
        spelled["alt"] = "e\u{301}"
        #expect(throws: ModuleCompilationError.self) { try media2.add([spelled], from: "B.json") }
    }
}
