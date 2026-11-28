import Foundation
import Testing
@testable import LampModuleKit

/// A commentary 2.3 unit whose body is given as blocks (step 4, commit 5):
/// built in memory, its row what today's form of the same body builds, its
/// projection what an older reader can show, and what would be lost
/// refused where it is written.
struct CommentaryRichUnitTests {
    private func json(_ text: String) throws -> [Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
    }

    private func build(_ chapters: String, rich: Bool, footnotes: String = "[]", sourceOrdered: Bool = false) throws -> CommentaryUnitBuilder {
        var builder = CommentaryUnitBuilder(
            moduleID: "M", bookNumber: 43, footnotes: try json(footnotes), sourceOrdered: sourceOrdered, rich: rich
        )
        try builder.append(chapters: try json(chapters))
        return builder
    }

    private func object(_ text: String?) -> NSDictionary? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
    }

    /// A row's fields as an older reader sees them, its JSON compared parsed.
    private func shape(_ row: CommentaryUnitRow, notes: Bool = true) -> [String] {
        func parsed(_ text: String?) -> String {
            text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "∅"
        }
        return [
            row.id, row.unitType, "\(row.chapter)", "\(row.startVerse)", "\(row.endVerse ?? 0)", "\(row.level)",
            row.parentID ?? "∅", row.title ?? "∅", row.suffix ?? "∅",
            parsed(row.introductionJSON), parsed(row.translationJSON), parsed(row.commentaryJSON),
            notes ? parsed(row.footnotesJSON) : "-", row.searchText, notes ? row.footnotesText : "-",
        ]
    }

    private static let text = #"{"text": "In the beginning was the Word.", "annotations": [{"type": "bold", "start": 25, "end": 29}], "footnote_refs": [{"id": "1", "offset": 29}]}"#

    /// One paragraph given as blocks builds the row its 2.2 form builds, but
    /// for the blocks kept beside it.
    @Test func oneParagraphAsBlocksIsTheRowItsOlderFormGives() throws {
        // The note it cites, defined once, as a 2.3 volume defines notes; a
        // 2.3 row carries it, where a 2.2 verse carries its chapter's.
        let note = #"[{"id": "1", "content": {"text": "A note."}}]"#
        let older = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(Self.text)}]}]"#, rich: false)
        let blocks = #"[{"type": "paragraph", "content": \#(Self.text)}]"#
        let richer = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": \#(blocks)}]}]"#, rich: true, footnotes: note)
        #expect(richer.issues.isEmpty, "\(richer.issues)")
        #expect(richer.units.map { shape($0, notes: false) } == older.units.map { shape($0, notes: false) })
        #expect(richer.units.first?.footnotesJSON?.contains("A note.") == true)
        #expect(older.units.first?.blocksJSON == nil)
        #expect(object(richer.units.first?.blocksJSON.map { #"{"b": \#($0)}"# }) == object(#"{"b": \#(blocks)}"#))

        // A section's body, where an older reader shows a section's: its
        // introduction; and the id it declares.
        let olderSection = try build(#"[{"chapter": 1, "sections": [{"id": "prologue", "title": "Prologue", "sv": 43001001, "introduction": \#(Self.text)}]}]"#, rich: false)
        let richerSection = try build(#"[{"chapter": 1, "sections": [{"id": "prologue", "title": "Prologue", "sv": 43001001, "blocks": \#(blocks)}]}]"#, rich: true, footnotes: note)
        #expect(richerSection.units.map { shape($0, notes: false) } == olderSection.units.map { shape($0, notes: false) })
        #expect(richerSection.units.first?.declaredID == "prologue")
        #expect(olderSection.units.first?.declaredID == nil)

        // A source-tracked entry, the note it cites with it.
        let footnotes = #"[{"id": "1", "content": {"text": "A note."}}]"#
        func pericope(_ entry: String) -> String {
            #"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "ev": 43001005, "content": [{"type": "commentary", "sv": 43001001, "source": {"volumeId": "M", "sourceFile": "f", "lineStart": 1, "lineEnd": 1}, \#(entry)}]}]}]"#
        }
        // Both 2.3: a 2.3 entry on its own verse ends there, where a 2.2 one
        // takes its passage's end.
        let olderEntry = try build(pericope(#""content": \#(Self.text)"#), rich: true, footnotes: footnotes, sourceOrdered: true)
        let richerEntry = try build(pericope(#""blocks": \#(blocks)"#), rich: true, footnotes: footnotes, sourceOrdered: true)
        #expect(richerEntry.issues.isEmpty, "\(richerEntry.issues)")
        #expect(richerEntry.units.map { shape($0) } == olderEntry.units.map { shape($0) })
        #expect(richerEntry.units.last?.footnotesJSON?.contains("A note.") == true)
        #expect(richerEntry.units.first?.declaredID == "p")

        // A volume of an earlier version is built as it always was: its
        // `blocks` are not read.
        let unread = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": \#(blocks)}]}]"#, rich: false)
        #expect(unread.units.first?.blocksJSON == nil)
        #expect(unread.units.first?.commentaryJSON == nil)
    }

    /// The stored projection is the projection of the stored blocks, in the
    /// form an older reader takes: one object, never an array.
    @Test func theStoredProjectionIsTheStoredBlocksProjected() throws {
        let built = try build(#"""
        [{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [
          {"type": "paragraph", "content": {"text": "First.", "annotations": [{"type": "link", "start": 0, "end": 5, "data": {"target": {"sv": 43001002}}}]}},
          {"type": "list", "items": [{"content": {"text": "One"}, "children": [{"content": {"text": "Two"}}]}]},
          {"type": "figure", "id": "f1", "title": "A chart", "children": [{"type": "table", "rows": [{"cells": [{"column": 0, "content": {"text": "Asa"}}, {"column": 1, "content": {"text": "41"}}]}]}], "notes": [{"text": "A note"}]}
        ]}]}]
        """#, rich: true)
        #expect(built.issues.isEmpty, "\(built.issues)")
        let row = try #require(built.units.first)
        let blocks = LampPortableBookJSON.decodeArray(row.blocksJSON, as: LampBookContentBlock.self).items
        let expected = LampCommentaryBlocks.legacyForm(of: LampBookDrawnText.projection(
            of: blocks, figures: .asParts, keeping: LampCommentaryBlocks.keptByOlderReaders
        ))
        #expect(object(row.commentaryJSON) == (expected as NSDictionary))
        #expect(row.commentaryJSON?.hasPrefix("{") == true)
        // A link an older reader does not know is left out; the figure's
        // words are in it, its table a row of columns.
        #expect(object(row.commentaryJSON)?["annotations"] == nil)
        let text = try #require(object(row.commentaryJSON)?["text"] as? String)
        #expect(text == "First.\n\nOne\nTwo\n\nA chart\nAsa\(LampBookDrawnText.cellSeparator)41\nA note")
        #expect(row.searchText.contains("A chart") && row.searchText.contains("41"))
    }

    /// What a reader would lose or misread is refused where it is written;
    /// a link that opens nothing is a warning.
    @Test func whatWouldBeLostIsRefusedWhereItIsWritten() throws {
        let built = try build(#"""
        [{"chapter": 1, "verses": [
          {"sv": 43001001, "commentary": {"text": "x"}, "blocks": [{"type": "paragraph", "content": {"text": "y"}}]},
          {"sv": 43001002, "blocks": [{"type": "paragraph", "content": {"text": "y"}, "zz": 1}]},
          {"sv": 43001003, "blocks": [{"type": "paragraph", "title": "T", "content": {"text": "y"}}]},
          {"sv": 43001004, "blocks": [{"type": "paragraph", "id": "a", "content": {"text": "y"}}, {"type": "figure", "children": [{"type": "paragraph", "id": "a", "content": {"text": "z"}}]}]},
          {"sv": 43001005, "blocks": {"type": "paragraph"}},
          {"sv": 43001006, "blocks": [{"type": "paragraph", "content": {"text": "see", "annotations": [{"type": "link", "start": 0, "end": 3, "data": {"target": {"kind": "book", "section": "s"}}}]}}]}
        ]}]
        """#, rich: true)
        let errors = Set(built.issues.filter { $0.severity == .error }.map(\.path))
        let verses = "/chapters/0/verses"
        #expect(errors == [
            "\(verses)/0/commentary", "\(verses)/1/blocks/0/zz", "\(verses)/2/blocks/0/title",
            "\(verses)/3/blocks/1/children/0/id", "\(verses)/4/blocks",
        ], "\(built.issues)")
        #expect(built.issues.filter { $0.severity == .warning }.map(\.path) == ["\(verses)/5/blocks/0"])

        // A source-tracked entry: blocks only on a commentary entry, and
        // never with a label to trim.
        let entries = try build(#"""
        [{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [
          {"type": "heading", "source": {}, "blocks": [{"type": "paragraph", "content": {"text": "h"}}]},
          {"type": "commentary", "displayPrefixLength": 2, "source": {}, "blocks": [{"type": "paragraph", "content": {"text": "1 c"}}]},
          {"type": "commentary", "source": {}, "content": {"text": "c"}, "blocks": [{"type": "paragraph", "content": {"text": "c"}}]}
        ]}]}]
        """#, rich: true, sourceOrdered: true)
        let entry = "/chapters/0/pericopae/0/content"
        #expect(Set(entries.issues.map(\.path)) == ["\(entry)/0/blocks", "\(entry)/1/displayPrefixLength", "\(entry)/2/content"], "\(entries.issues)")
        // And a pericope's own blocks beside its entries.
        let both = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [], "blocks": [{"type": "paragraph", "content": {"text": "c"}}]}]}]"#, rich: true)
        #expect(both.issues.map(\.path) == ["/chapters/0/pericopae/0/content"])
    }

    /// Found reviewing commit 5 (by Codex): a figure's children are held to
    /// the same rule; a source-tracked pericope's blocks go on its entries;
    /// a note cited by an inline span alone goes with the entry citing it;
    /// and nothing a file gives stops the process.
    @Test func whatReviewFoundIsHeldToo() throws {
        let child = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "figure", "children": [{"type": "table", "title": "T", "rows": []}]}]}]}]"#, rich: true)
        #expect(child.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0/children/0/title"], "\(child.issues)")

        let tracked = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "c"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(tracked.issues.map(\.path) == ["/chapters/0/pericopae/0/blocks"])

        // Each entry carries the notes it cites, by a span or a marker.
        let footnotes = #"[{"id": "1", "content": {"text": "Cited by a span."}}, {"id": "2", "content": {"text": "Cited by a marker."}}]"#
        let spans = try build(#"""
        [{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [
          {"type": "commentary", "sv": 43001001, "source": {}, "blocks": [{"type": "paragraph", "content": {"text": "first", "annotations": [{"type": "footnote", "start": 0, "end": 5, "data": {"footnoteId": "1"}}]}}]},
          {"type": "commentary", "sv": 43001002, "source": {}, "content": {"text": "second", "footnote_refs": [{"id": "2", "offset": 6}]}}
        ]}]}]
        """#, rich: true, footnotes: footnotes, sourceOrdered: true)
        #expect(spans.issues.isEmpty, "\(spans.issues)")
        let rows = spans.units.filter { $0.unitType == "verse" }
        #expect(rows.count == 2)
        #expect(rows.first?.footnotesJSON?.contains("Cited by a span.") == true, "\(rows.map(\.footnotesJSON))")
        #expect(rows.first?.footnotesJSON?.contains("Cited by a marker.") != true)
        #expect(rows.last?.footnotesJSON?.contains("Cited by a marker.") == true)

        // A source-tracked 2.3 volume's sections, verses and introductions
        // are refused, not left out unseen.
        let skipped = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": []}], "sections": [{"sv": 43001001}], "pericopae": []}]"#, rich: true, sourceOrdered: true)
        #expect(Set(skipped.issues.map(\.path)) == ["/chapters/0/verses", "/chapters/0/sections"])
        let introducedChapter = try build(#"[{"chapter": 1, "introduction": {"text": "i"}, "pericopae": []}]"#, rich: true, sourceOrdered: true)
        #expect(introducedChapter.issues.map(\.path) == ["/chapters/0/introduction"])

        // Words in a cell the layout hides are warned of, in a figure too.
        let hiddenCell = try build(#"""
        [{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "figure", "children": [{"type": "table", "columnCount": 2, "rows": [
          {"cells": [{"column": 0, "colSpan": 2, "content": {"text": "wide"}}, {"column": 1, "content": {"text": "hidden"}}]}
        ]}]}]}]}]
        """#, rich: true)
        #expect(hiddenCell.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0/children/0"], "\(hiddenCell.issues)")
        #expect(hiddenCell.issues.first?.severity == .warning)
        // A marker alone in a hidden cell is warned of too. Found by Codex.
        let hiddenMarker = try build(#"""
        [{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "table", "columnCount": 2, "rows": [
          {"cells": [{"column": 0, "colSpan": 2, "content": {"text": "wide"}}, {"column": 1, "content": {"text": "", "footnote_refs": [{"id": "1", "offset": 0}]}}]}
        ]}]}]}]
        """#, rich: true)
        #expect(hiddenMarker.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0"], "\(hiddenMarker.issues)")

        // A section's or verse's blocks bring the notes they cite to their
        // row; a verse keeps its printed range as its title.
        let cited = try build(#"""
        [{"chapter": 1, "sections": [{"id": "s", "sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "x", "footnote_refs": [{"id": "1", "offset": 1}]}}]}],
          "verses": [{"sv": 43001001, "ev": 43001009, "title": "1:1, 9", "blocks": [{"type": "paragraph", "content": {"text": "y", "annotations": [{"type": "footnote", "start": 0, "end": 1, "data": {"footnoteId": "1"}}]}}]}]}]
        """#, rich: true, footnotes: #"[{"id": "1", "content": {"text": "The volume's note."}}]"#)
        #expect(cited.issues.isEmpty, "\(cited.issues)")
        #expect(cited.units.map { $0.footnotesJSON?.contains("The volume's note.") == true } == [true, true])
        #expect(cited.units.last?.title == "1:1, 9")
        // A note cited inside a trimmed label is not cited by the text the
        // row holds.
        let labelled = try build(#"""
        [{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [
          {"type": "commentary", "sv": 43001001, "displayPrefixLength": 2, "source": {}, "content": {"text": "1 first", "annotations": [{"type": "footnote", "start": 2, "end": 7, "id": "9"}]}}
        ]}]}]
        """#, rich: true, footnotes: #"[{"id": "9", "content": {"text": "The note."}}]"#, sourceOrdered: true)
        #expect(labelled.units.contains { $0.footnotesJSON?.contains("The note.") == true }, "\(labelled.units.map(\.footnotesJSON))")
        let figured = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "figure", "children": [], "content": {"text": "drawn nowhere"}}]}]}]"#, rich: true)
        #expect(figured.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0/content"])
        let underlined = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "under", "annotations": [{"type": "emphasis", "start": 0, "end": 5, "data": {"style": "underline"}}, {"type": "emphasis", "start": 0, "end": 2, "data": {"style": "italic"}}]}}]}]}]"#, rich: true)
        let underlinedJSON = try #require(object(underlined.units.first?.commentaryJSON))
        #expect((underlinedJSON["annotations"] as? [[String: Any]])?.count == 1)
        // And the italic one written as `italic`, which the oldest phone
        // reading 2.3 knows. Found by Codex.
        #expect((underlinedJSON["annotations"] as? [[String: Any]])?.first?["type"] as? String == "italic")

        // A text no reader draws, wherever it is given: a table's caption,
        // bare or in a figure. Found by Codex.
        let captioned = try build(#"""
        [{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [
          {"type": "table", "caption": "Kings", "rows": [{"cells": [{"column": 0, "content": {"text": "Asa"}}]}]},
          {"type": "figure", "caption": "Drawn", "children": [{"type": "table", "caption": "Not drawn", "rows": []}]}
        ]}]}]
        """#, rich: true)
        #expect(Set(captioned.issues.map(\.path)) == ["/chapters/0/verses/0/blocks/0/caption", "/chapters/0/verses/0/blocks/1/children/0/caption"], "\(captioned.issues)")
        // A pericope's introduction and translation cite notes too.
        let introduced = try build(#"""
        [{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001,
          "introduction": {"text": "i", "footnote_refs": [{"id": "a", "offset": 1}]},
          "translation": {"text": "t", "footnote_refs": [{"id": "b", "offset": 1}]},
          "blocks": [{"type": "paragraph", "content": {"text": "c"}}]}]}]
        """#, rich: true, footnotes: #"[{"id": "a", "content": {"text": "Note A."}}, {"id": "b", "content": {"text": "Note B."}}]"#)
        let pericopeNotes = try #require(introduced.units.first?.footnotesJSON)
        #expect(pericopeNotes.contains("Note A.") && pericopeNotes.contains("Note B."), "\(pericopeNotes)")

        // A pericope given as entries does not hide verses beside them.
        let beside = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [], "verses": [{"sv": 43001001, "blocks": []}]}]}]"#, rich: true)
        // Content entries refused too, outside a source-tracked volume.
        #expect(beside.issues.map(\.path) == ["/chapters/0/pericopae/0/content"])
        // In a source-tracked volume, the verses beside its entries.
        let besideTracked = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [], "verses": [{"sv": 43001001, "blocks": []}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(besideTracked.issues.map(\.path) == ["/chapters/0/pericopae/0/verses"])

        // A chapter no reference can hold, and a span ending before it starts
        // in a label's trim: told, not a trap.
        let huge = try json(#"[{"chapter": 1000000000000000000, "pericopae": [{"id": "p"}]}]"#)
        var builder = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, rich: true)
        #expect(throws: ModuleCompilationError.self) { try builder.append(chapters: huge) }
        let trimmed = try build(#"""
        [{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [
          {"type": "commentary", "sv": 43001001, "displayPrefixLength": 2, "source": {}, "content": {"text": "1 words", "annotations": [
            {"type": "bold", "start": 6, "end": 4, "text": "x"}, {"type": "bold", "start": -9223372036854775807, "end": 5, "text": "y"}
          ], "footnote_refs": [{"id": "1", "offset": -9223372036854775807}]}}
        ]}]}]
        """#, rich: false, sourceOrdered: true)
        #expect(trimmed.units.count == 2)
        let inspected = try ModuleJSONInspector().inspect(Data(#"""
        {"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"},
         "book": "John", "bookNumber": 43, "chapters": [{"chapter": 1000000000000000000, "pericopae": [{"id": "p"}]}]}
        """#.utf8))
        #expect(!inspected.canCompile)
    }

    /// Rule A: a 2.3 volume defines each note once, in its top-level list,
    /// and a row carries exactly the notes its own texts cite. Each way to
    /// break it is refused once, where it is written.
    @Test func eachNoteIsDefinedOnceAndCarriedWhereCited() throws {
        let note = #"{"id": "n", "content": {"text": "A note."}}"#
        let cite = #"{"text": "x", "footnote_refs": [{"id": "n", "offset": 1}]}"#
        let chapters = #"""
        [{"chapter": 1, "footnotes": [\#(note)],
          "sections": [{"id": "s", "sv": 43001001, "footnotes": [\#(note)], "introduction": \#(cite),
            "pericopae": [{"id": "p", "sv": 43001001, "footnotes": [\#(note)], "footnoteIds": ["n"],
              "verses": [{"sv": 43001001, "footnotes": [\#(note)], "commentary": \#(cite)}]}]}]}]
        """#
        let scoped = try build(chapters, rich: true, footnotes: "[\(note)]")
        #expect(Set(scoped.issues.map(\.path)) == [
            "/chapters/0/footnotes", "/chapters/0/sections/0/footnotes",
            "/chapters/0/sections/0/pericopae/0/footnotes", "/chapters/0/sections/0/pericopae/0/footnoteIds",
            "/chapters/0/sections/0/pericopae/0/verses/0/footnotes",
        ], "\(scoped.issues)")
        // An entry's own notes too.
        let entry = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "footnotes": [\#(note)], "content": \#(cite)}]}]}]"#, rich: true, footnotes: "[\(note)]", sourceOrdered: true)
        #expect(entry.issues.map(\.path) == ["/chapters/0/pericopae/0/content/0/footnotes"])

        // A duplicate, a definition with no id, and one whose content an
        // older reader cannot read; a citation with no definition; and a
        // definition no row cites.
        let volume = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "xy", "footnote_refs": [{"id": "n", "offset": 1}, {"id": "missing", "offset": 2}]}}]}]"#, rich: true,
                               footnotes: #"[\#(note), \#(note), {"content": {"text": "no id"}}, {"id": "bad", "content": {"words": "x"}}, {"id": "unused", "content": {"text": "never cited"}}]"#)
        #expect(Set(volume.issues.map(\.path)) == [
            // The unreadable one is cited by no row either.
            "/footnotes/1/id", "/footnotes/2", "/footnotes/3/content", "/footnotes/3", "/footnotes/4", "/chapters/0/verses/0",
        ], "\(volume.issues)")
        // Carried once, in the order first cited, written as an older reader
        // opens it; a 2.2 volume carries what it always did.
        let twice = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "translation": \#(cite), "commentary": {"text": "y", "annotations": [{"type": "footnote", "start": 0, "end": 1, "data": {"footnoteId": "n"}}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(twice.issues.isEmpty, "\(twice.issues)")
        let carriedJSON = try #require(twice.units.first?.footnotesJSON)
        let carried = try #require(try JSONSerialization.jsonObject(with: Data(carriedJSON.utf8)) as? [[String: Any]])
        #expect(carried.map { $0["id"] as? String } == ["n"])
        let olderWay = try build(#"[{"chapter": 1, "footnotes": [\#(note)], "verses": [{"sv": 43001001, "commentary": {"text": "y"}}]}]"#, rich: false)
        #expect(olderWay.units.first?.footnotesJSON?.contains("A note.") == true)

        // Found reviewing the rules (by Codex): a citation counts only where
        // the phone draws it; notes are carried in reading order; a text the
        // phone would blank is refused; a 2.3 pericope's plain body is kept.
        let unseen = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "footnote_refs": [{"id": "n", "offset": 8}], "annotations": [{"type": "footnote", "start": 1, "end": 1, "id": "n"}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(Set(unseen.issues.map(\.path)) == ["/footnotes/0", "/chapters/0/verses/0"], "\(unseen.issues)")
        let ordered = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "a long enough text", "footnote_refs": [{"id": "late", "offset": 15}], "annotations": [{"type": "footnote", "start": 1, "end": 2, "data": {"footnoteId": "early"}}]}}]}]"#, rich: true,
                                footnotes: #"[{"id": "late", "content": {"text": "L"}}, {"id": "early", "content": {"text": "E"}}]"#)
        let orderedNotes = try #require(try JSONSerialization.jsonObject(with: Data((ordered.units.first?.footnotesJSON ?? "[]").utf8)) as? [[String: Any]])
        #expect(orderedNotes.map { $0["id"] as? String } == ["early", "late"])
        let blanking = try build(#"""
        [{"chapter": 1, "verses": [
          {"sv": 43001001, "commentary": "words"},
          {"sv": 43001002, "commentary": {"text": "x", "footnote_refs": {"id": "n", "offset": 0}}},
          {"sv": 43001003, "commentary": {"text": "x", "footnote_refs": [{"id": "n", "offset": 1.5}]}}
        ]}]
        """#, rich: true)
        #expect(Set(blanking.issues.map(\.path)) == ["/chapters/0/verses/0", "/chapters/0/verses/1", "/chapters/0/verses/2"], "\(blanking.issues)")
        let pericopeBody = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "commentary": {"text": "The body."}}]}]"#, rich: true)
        #expect(pericopeBody.units.first?.commentaryJSON?.contains("The body.") == true)
        #expect(pericopeBody.units.first?.searchText.contains("The body.") == true)
        // A marker checked before its label is trimmed; a body beside the
        // entries refused; a bad note refused once, at its definition.
        let trimmedMarker = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "displayPrefixLength": 2, "source": {}, "content": {"text": "1 words", "footnote_refs": [{"id": "n", "offset": 3.5}]}}]}]}]"#, rich: true, footnotes: "[\(note)]", sourceOrdered: true)
        #expect(trimmedMarker.issues.contains { $0.path == "/chapters/0/pericopae/0/content/0" && $0.message.contains("whole-number offset") }, "\(trimmedMarker.issues)")
        let beside = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "commentary": {"text": "own"}, "content": []}]}]"#, rich: true)
        // Content entries refused too, outside a source-tracked volume.
        #expect(beside.issues.map(\.path) == ["/chapters/0/pericopae/0/content"])
        let besideEntries = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "commentary": {"text": "own"}, "content": []}]}]"#, rich: true, sourceOrdered: true)
        #expect(besideEntries.issues.map(\.path) == ["/chapters/0/pericopae/0/commentary"])
        let badNote = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(cite)}, {"sv": 43001002, "commentary": \#(cite)}]}]"#, rich: true,
                                footnotes: #"[{"id": "n", "content": {"text": "x", "footnote_refs": [{"id": 3, "offset": 0}]}}]"#)
        #expect(Set(badNote.issues.map(\.path)) == ["/footnotes/0/content"], "\(badNote.issues)")
        // A marker at `true`, which Foundation reads as 1; a source-tracked
        // pericope's own body; entries not a list; the legacy note fields,
        // even empty; and a value JSON cannot store. Found by Codex.
        let booleanOffset = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "footnote_refs": [{"id": "n", "offset": true}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(booleanOffset.issues.contains { $0.path == "/chapters/0/verses/0" && $0.message.contains("whole-number offset") }, "\(booleanOffset.issues)")
        let trackedBody = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "commentary": {"text": "lost"}}]}]"#, rich: true, sourceOrdered: true)
        #expect(trackedBody.issues.map(\.path) == ["/chapters/0/pericopae/0/commentary"])
        let oneEntry = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": {"type": "commentary", "source": {}, "content": {"text": "lost"}}}]}]"#, rich: true, sourceOrdered: true)
        #expect(oneEntry.issues.map(\.path) == ["/chapters/0/pericopae/0/content"])
        let emptyLegacy = try build(#"[{"chapter": 1, "footnotes": [], "pericopae": [{"id": "p", "sv": 43001001, "footnoteIds": [], "commentary": {"text": "x"}}]}]"#, rich: true)
        #expect(Set(emptyLegacy.issues.map(\.path)) == ["/chapters/0/footnotes", "/chapters/0/pericopae/0/footnoteIds"])
        var listed = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, rich: true)
        listed.hasTopLevelFootnoteIDs = true
        try listed.append(chapters: [])
        #expect(listed.issues.map(\.path) == ["/footnoteIds"])
        let infinite = try #require(try JSONSerialization.jsonObject(with: Data(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "bold", "start": 0, "end": 1, "data": {"x": -1e500}}]}}]}]"#.utf8)) as? [Any])
        var unstorable = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, rich: true)
        try unstorable.append(chapters: infinite)
        #expect(unstorable.issues.map(\.path) == ["/chapters/0/verses/0"], "\(unstorable.issues)")
        // A span the phone cannot read is no citation, and is refused; a unit
        // list given as one object; note fields inside a block. Found by
        // Codex.
        let numericID = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "footnote", "start": 0, "end": 1, "id": 7, "data": {"footnoteId": "n"}}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(Set(numericID.issues.map(\.path)) == ["/chapters/0/verses/0", "/footnotes/0"], "\(numericID.issues)")
        let single = try build(#"[{"chapter": 1, "pericopae": {"id": "p", "sv": 43001001, "commentary": {"text": "x"}}}]"#, rich: true)
        #expect(single.issues.map(\.path) == ["/chapters/0/pericopae"])
        let inBlock = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "x"}, "footnotes": []}]}]}]"#, rich: true)
        #expect(inBlock.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0/footnotes"], "\(inBlock.issues)")
        // `implicit` as words; a NUL before block words in search; and
        // metadata that names a unit list, which is no unit list. Found by
        // Codex.
        let implicitWords = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "footnote", "start": 0, "end": 1, "id": "n", "implicit": "false"}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(Set(implicitWords.issues.map(\.path)) == ["/chapters/0/verses/0", "/footnotes/0"], "\(implicitWords.issues)")
        let nul = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "translation": {"text": "a\u0000b"}, "blocks": [{"type": "paragraph", "content": {"text": "findable"}}]}]}]"#, rich: true)
        #expect(nul.units.first?.searchText.contains("\0") == false)
        #expect(nul.units.first?.searchText.contains("findable") == true)
        let metadata = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "classification": {"verses": "1–5"}, "content": {"text": "x"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(metadata.issues.isEmpty, "\(metadata.issues)")
        // A span naming two notes; a note citing a note. Found by Codex.
        let twoNotes = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "footnote", "start": 0, "end": 1, "id": "n", "data": {"footnoteId": "m"}}]}}]}]"#, rich: true,
                                 footnotes: #"[\#(note), {"id": "m", "content": {"text": "M"}}]"#)
        #expect(twoNotes.issues.map(\.path) == ["/chapters/0/verses/0"], "\(twoNotes.issues)")
        let nestedNote = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(cite)}]}]"#, rich: true,
                                   footnotes: #"[{"id": "n", "content": {"text": "see", "footnote_refs": [{"id": "m", "offset": 3}]}}, {"id": "m", "content": {"text": "M"}}]"#)
        #expect(Set(nestedNote.issues.map(\.path)) == ["/footnotes/0/content", "/footnotes/1"], "\(nestedNote.issues)")
        // Verses beside entries given as one object; a note span naming no
        // note in words. Found by Codex.
        let verseObject = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [], "verses": {"sv": 43001001, "blocks": []}}]}]"#, rich: true)
        // Content entries refused too, outside a source-tracked volume.
        #expect(verseObject.issues.map(\.path) == ["/chapters/0/pericopae/0/content", "/chapters/0/pericopae/0/verses"], "\(verseObject.issues)")
        let noName = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "footnote", "start": 0, "end": 1, "data": {"footnoteId": 4}}]}}]}]"#, rich: true)
        #expect(noName.issues.map(\.path) == ["/chapters/0/verses/0"], "\(noName.issues)")
        // An end with no start, refused, not replaced; a marker outside its
        // text; a null content, none. Found by Codex.
        let endless = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "scripture", "start": 0, "end": 1, "data": {"ev": 43003020, "refs": [{"sv": 43003016}]}}]}}]}]"#, rich: true)
        #expect(endless.issues.map(\.path) == ["/chapters/0/verses/0"], "\(endless.issues)")
        let outside = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "footnote_refs": [{"id": "n", "offset": 8}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(outside.issues.contains { $0.path == "/chapters/0/verses/0" && $0.message.contains("outside its text") }, "\(outside.issues)")
        let nullContent = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": null, "verses": [{"sv": 43001001, "commentary": {"text": "kept"}}]}]}]"#, rich: true)
        #expect(nullContent.issues.isEmpty, "\(nullContent.issues)")
        #expect(nullContent.units.contains { $0.commentaryJSON?.contains("kept") == true })
        let pastEnd = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [{"type": "footnote", "start": 1, "end": 9, "id": "n"}]}}]}]"#, rich: true, footnotes: "[\(note)]")
        #expect(pastEnd.issues.contains { $0.path == "/chapters/0/verses/0" && $0.message.contains("covers no words") }, "\(pastEnd.issues)")
        let nullBeside = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": null, "commentary": {"text": "one body"}}]}]"#, rich: true)
        #expect(nullBeside.issues.isEmpty, "\(nullBeside.issues)")
        // A page at the trim kept at 0; a note JSON cannot store, told at its
        // definition. Found by Codex.
        let boundary = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "sv": 43001001, "displayPrefixLength": 2, "source": {}, "content": {"text": "1 Text", "annotations": [{"type": "page", "start": 2, "end": 2, "data": {"pageNum": "4"}}]}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(boundary.units.last?.commentaryJSON?.contains("page") == true, "\(boundary.units.map(\.commentaryJSON))")
        let infiniteNote = try #require(try JSONSerialization.jsonObject(with: Data(#"[{"id": "n", "content": {"text": "x", "annotations": [{"type": "bold", "start": 0, "end": 1, "data": {"x": -1e500}}]}}]"#.utf8)) as? [Any])
        var unstorableNote = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, footnotes: infiniteNote, rich: true)
        try unstorableNote.append(chapters: try json(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(cite)}]}]"#))
        #expect(unstorableNote.issues.contains { $0.path == "/footnotes/0" }, "\(unstorableNote.issues)")
        // A legend's titles reach an older reader and search; a legend where
        // none is drawn is refused. Found by Codex.
        let legend = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "table", "rows": [{"label": "g", "cells": [{"column": 0, "content": {"text": "Asa"}}]}], "legend": [{"label": "g", "title": "Good king"}]}, {"type": "paragraph", "content": {"text": "p"}, "legend": [{"label": "x", "title": "Undrawn"}]}]}]}]"#, rich: true)
        #expect(legend.issues.map(\.path) == ["/chapters/0/verses/0/blocks/1/legend"], "\(legend.issues)")
        let legendOnly = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "table", "rows": [{"label": "g", "cells": [{"column": 0, "content": {"text": "Asa"}}]}], "legend": [{"label": "g", "title": "Good king"}]}]}]}]"#, rich: true)
        #expect(legendOnly.units.first?.commentaryJSON?.contains("Good king") == true)
        #expect(legendOnly.units.first?.searchText.contains("Good king") == true)
        #expect(!LampBookDrawnText.text(ofContentJSON: #"[{"type": "table", "rows": [], "legend": [{"label": "g", "title": "Good king"}]}]"#).contains("Good king"))
        // A table's legend in a figure, too. Found by Codex.
        let figureLegend = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "figure", "title": "Kings", "children": [{"type": "table", "rows": [{"label": "g", "cells": [{"column": 0, "content": {"text": "Asa"}}]}], "legend": [{"label": "g", "title": "Good king"}]}]}]}]}]"#, rich: true)
        #expect(figureLegend.issues.isEmpty, "\(figureLegend.issues)")
        #expect(figureLegend.units.first?.commentaryJSON?.contains("Good king") == true)
        // A chapter's blocks are read by nothing: refused. An emphasis with
        // no style is italic to the oldest phone. Found by Codex.
        let chapterBlocks = try build(#"[{"chapter": 1, "blocks": [{"type": "paragraph", "content": {"text": "lost"}}], "verses": []}]"#, rich: true)
        #expect(chapterBlocks.issues.map(\.path) == ["/chapters/0/blocks"])
        let plainEmphasis = LampCommentaryBlocks.olderReadersCopy(of: LampBookAnnotatedText(text: "word", annotations: [LampBookAnnotation(type: "emphasis", start: 0, end: 4)]))
        #expect((plainEmphasis["annotations"] as? [[String: Any]])?.first?["type"] as? String == "italic")
        // A span outside its block text is refused, as in plain text; a web
        // link over no words is warned of. Found by Codex.
        let outsideBlock = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "footnote", "start": 5, "end": 6, "data": {"footnoteId": "n"}}]}}]}]}]"#, rich: true)
        #expect(outsideBlock.issues.contains { $0.path == "/chapters/0/verses/0/blocks/0" && $0.message.contains("covers no words") }, "\(outsideBlock.issues)")
        let deadURL = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "link", "start": 1, "end": 1, "data": {"url": "https://x.org"}}]}}]}]}]"#, rich: true)
        #expect(deadURL.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0/blocks/0"], "\(deadURL.issues)")
        // A row's note searched by its content's words; a broken address
        // warned of; an entry's missing content told at its path. Found by
        // Codex.
        let topText = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(cite)}]}]"#, rich: true,
                                footnotes: #"[{"id": "n", "text": "", "content": {"text": "Searchable note."}}]"#)
        #expect(topText.units.first?.footnotesText == "Searchable note.", "\(String(describing: topText.units.first?.footnotesText))")
        let brokenURL = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "link", "start": 0, "end": 3, "data": {"url": "https://[broken"}}]}}]}]}]"#, rich: true)
        #expect(brokenURL.issues.map(\.severity) == [.warning], "\(brokenURL.issues)")
        do {
            _ = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}}]}]}]"#, rich: true, sourceOrdered: true)
            Issue.record("an entry with no content built")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "/chapters/0/pericopae/0/content/0/content")
        }
        // A passage whose later `refs` entry the phone cannot read; a link
        // naming no place. Found by Codex.
        let badRefs = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": [{"type": "scripture", "start": 0, "end": 1, "data": {"refs": [{"sv": 43003016}, {"sv": "John"}]}}]}}]}]"#, rich: true)
        #expect(badRefs.issues.map(\.path) == ["/chapters/0/verses/0"], "\(badRefs.issues)")
        let nowhere = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "link", "start": 0, "end": 3}]}}]}]}]"#, rich: true)
        #expect(nowhere.issues.map(\.severity) == [.warning], "\(nowhere.issues)")
        let pointPassage = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "scripture", "start": 1, "end": 1, "data": {"sv": 43003016}}]}}]}]}]"#, rich: true)
        #expect(pointPassage.issues.map(\.severity) == [.warning], "\(pointPassage.issues)")
        let objectAnnotations = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x", "annotations": {"type": "footnote", "start": 0, "end": 1, "id": "n"}}}]}]"#, rich: true)
        #expect(objectAnnotations.issues.map(\.path) == ["/chapters/0/verses/0"], "\(objectAnnotations.issues)")
        let reversed = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {"refs": [{"sv": 43003020, "ev": 43003016}]}}]}}]}]}]"#, rich: true)
        #expect(reversed.issues.map(\.severity).contains(.warning), "\(reversed.issues)")
        let relative = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "link", "start": 0, "end": 3, "data": {"url": "chapter.html"}}]}}]}]}]"#, rich: true)
        #expect(relative.issues.map(\.severity) == [.warning], "\(relative.issues)")
        // A label's length a whole count within its text; dead links in plain
        // text and in a note. Found by Codex.
        let longLabel = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "displayPrefixLength": 9, "source": {}, "content": {"text": "1 words"}}, {"type": "commentary", "displayPrefixLength": 1.5, "source": {}, "content": {"text": "1 words"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(Set(longLabel.issues.map(\.path)) == ["/chapters/0/pericopae/0/content/0/displayPrefixLength", "/chapters/0/pericopae/0/content/1/displayPrefixLength"], "\(longLabel.issues)")
        let plainDead = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {}}]}}]}]"#, rich: true)
        #expect(plainDead.issues.map { "\($0.severity) \($0.path)" } == ["warning /chapters/0/verses/0"], "\(plainDead.issues)")
        let noteDead = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(cite)}]}]"#, rich: true,
                                 footnotes: #"[{"id": "n", "content": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {}}]}}]"#)
        #expect(noteDead.issues.map { "\($0.severity) \($0.path)" } == ["warning /footnotes/0/content"], "\(noteDead.issues)")
        // A note span inside the trimmed label; one broken link told once; a
        // skipped annotation hiding none; a passage in no chapter. Found by
        // Codex.
        let inLabel = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "displayPrefixLength": 2, "source": {}, "content": {"text": "1 words", "annotations": [{"type": "footnote", "start": 0, "end": 1, "id": "n"}]}}]}]}]"#, rich: true, footnotes: "[\(note)]", sourceOrdered: true)
        #expect(inLabel.issues.contains { $0.message.contains("within the label") }, "\(inLabel.issues)")
        let once = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {"sv": 2000001}}]}}]}]}]"#, rich: true)
        #expect(once.issues.map(\.path) == ["/chapters/0/verses/0/blocks/0"], "\(once.issues)")
        let hidden = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [null, {"type": "scripture", "start": 0, "end": 3, "data": {}}]}}]}]"#, rich: true)
        #expect(hidden.issues.map(\.severity).contains(.warning), "\(hidden.issues)")
        // A passage running past its plain text; one bad marker told once.
        // Found by Codex.
        let passagePastEnd = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 9, "data": {"sv": 43003016}}]}}]}]"#, rich: true)
        #expect(passagePastEnd.issues.map(\.severity) == [.warning], "\(passagePastEnd.issues)")
        let toldOnce = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "content": {"text": "words", "footnote_refs": [{"id": 7, "offset": 1}]}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(toldOnce.issues.filter { $0.severity == .error }.count == 1, "\(toldOnce.issues)")
        // An entry on its own verse ends there, not at its passage's end.
        // Found by Codex.
        let ownVerse = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "ev": 43001010, "content": [{"type": "commentary", "sv": 43001003, "source": {}, "content": {"text": "words"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(ownVerse.units.first { $0.startVerse == 43001003 }.map { $0.endVerse == nil } == true, "\(ownVerse.units.map { ($0.startVerse, $0.endVerse) })")
        // A null `sv` inherits both ends; a heading's bad marker is told; a
        // target's passage is checked too. Found by Codex.
        let nullVerse = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "ev": 43001010, "content": [{"type": "commentary", "sv": null, "source": {}, "content": {"text": "words"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(nullVerse.units.last?.endVerse == 43001010, "\(nullVerse.units.map { ($0.startVerse, $0.endVerse) })")
        let badHeading = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "heading", "source": {}, "content": {"text": "Title", "footnote_refs": {"id": "n", "offset": 1}}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(badHeading.issues.contains { $0.path == "/chapters/0/pericopae/0/content/0" && $0.severity == .error }, "\(badHeading.issues)")
        let targetBackwards = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "blocks": [{"type": "paragraph", "content": {"text": "abc", "annotations": [{"type": "scripture", "start": 0, "end": 3, "data": {"sv": 43003020, "ev": 43003016, "target": {"kind": "commentary", "sv": 43003020}}}]}}]}]}]"#, rich: true)
        #expect(targetBackwards.issues.map(\.severity) == [.warning], "\(targetBackwards.issues)")
        // A paragraph entry's body as blocks; a link that will not decode.
        // Found by Codex.
        let paragraphEntry = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "paragraph", "source": {}, "blocks": [{"type": "paragraph", "content": {"text": "words"}}]}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(paragraphEntry.issues.isEmpty, "\(paragraphEntry.issues)")
        #expect(paragraphEntry.units.last?.blocksJSON != nil)
        let numericURL = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [{"type": "link", "start": 0, "end": 3, "data": {"url": 7}}]}}]}]"#, rich: true)
        #expect(numericURL.issues.map(\.severity) == [.warning], "\(numericURL.issues)")
        // A 2.3 text given empty, with no words, is told. Found by Codex.
        let emptyText = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {}}]}]"#, rich: true)
        #expect(emptyText.issues.map(\.path) == ["/chapters/0/verses/0"], "\(emptyText.issues)")
        // An offset past any text's length, which the phone's encoded-span
        // reading overflows on. Found by Codex.
        let huge = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "abc", "annotations": [{"type": "bold", "start": 0, "end": 9223372036854775807}]}}]}]"#, rich: true)
        #expect(huge.issues.contains { $0.severity == .error && $0.message.contains("past any text") }, "\(huge.issues)")
        do {
            _ = try build(#"[{"chapter": 1, "verses": [{"commentary": {"text": "x"}}]}]"#, rich: true)
            Issue.record("a verse with no sv built")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "/chapters/0/verses/0/sv")
        }
        // A 2.2 introduction at chapter -1 builds as it did; a 2.3 title's
        // NUL is a space. Found by Codex.
        let minusOne = try build(#"[{"chapter": -1, "pericopae": [{"id": "p", "content": []}]}]"#, rich: false)
        #expect(minusOne.units.first?.startVerse == 43 * 1_000_000 - 1_000 + 1)
        let nulTitle = try build(#"[{"chapter": 1, "verses": [{"sv": 43001001, "title": "1:1\u0000a", "commentary": {"text": "x"}}]}]"#, rich: true)
        #expect(nulTitle.units.first?.title == "1:1 a")
        var nullIssues: [ModuleValidationIssue] = []
        let nulled = LampCommentaryBlocks.writtenForOlderReaders(
            ["text": "x", "annotations": [["type": "footnote", "start": 0, "end": 1, "id": NSNull(), "data": ["footnoteId": "n"]],
                                        ["type": "crossref", "start": 0, "end": 1, "data": ["sv": NSNull(), "refs": [["sv": 1_001_001]]]]]],
            path: "", issues: &nullIssues
        )
        let nulledAnnotations = (nulled["annotations"] as? [[String: Any]]) ?? []
        #expect(nulledAnnotations.first?["id"] as? String == "n")
        #expect((nulledAnnotations.last?["data"] as? [String: Any])?["sv"] as? Int == 1_001_001)
        let listless = try ModuleJSONInspector().inspect(Data(#"""
        {"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"},
         "book": "John", "bookNumber": 43, "footnotes": {"id": "n", "content": {"text": "x"}}, "chapters": []}
        """#.utf8))
        #expect(listless.issues.contains { $0.path == "/footnotes" })
    }

    /// The projection as an older reader opens it: a passage given by `refs`
    /// alone gains its first as `sv`, an inline note span its note's `id`,
    /// and a page marked at a point is written out as its label, later
    /// offsets moved past it, a note marker at the same place kept before
    /// it.
    @Test func theProjectionIsWrittenAsAnOlderReaderOpensIt() throws {
        // An `ev` beside no `sv` is not replaced by the first passage.
        let orphan = LampCommentaryBlocks.legacyForm(of: LampBookAnnotatedText(text: "John", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 4, data: LampBookAnnotationData(
                endReference: 43_003_020, references: [LampBookVerseRange(startReference: 43_003_016)]
            )),
        ]))
        let orphanData = (orphan["annotations"] as? [[String: Any]])?.first?["data"] as? [String: Any]
        // Kept as written, and refused where a unit gives it (an end with no
        // start), not replaced. Found by Codex.
        #expect(orphanData?["sv"] == nil && orphanData?["ev"] as? Int == 43_003_020, "\(String(describing: orphanData))")
        // A cross-reference, opened as a passage is. Found by Codex.
        let crossref = LampCommentaryBlocks.legacyForm(of: LampBookAnnotatedText(text: "cf.", annotations: [
            LampBookAnnotation(type: "crossref", start: 0, end: 3, data: LampBookAnnotationData(
                references: [LampBookVerseRange(startReference: 1_001_001)]
            )),
        ]))
        #expect(((crossref["annotations"] as? [[String: Any]])?.first?["data"] as? [String: Any])?["sv"] as? Int == 1_001_001)

        let projection = LampBookAnnotatedText(
            text: "See them.",
            annotations: [
                LampBookAnnotation(type: "scripture", start: 0, end: 3, data: LampBookAnnotationData(
                    references: [LampBookVerseRange(startReference: 43_003_016, endReference: 43_003_018)]
                )),
                LampBookAnnotation(type: "footnote", start: 4, end: 8, data: LampBookAnnotationData(footnoteID: "2")),
                LampBookAnnotation(type: "page", start: 4, end: 4, data: LampBookAnnotationData(pageNumber: "7")),
                LampBookAnnotation(type: "page", start: 4, end: 4, data: LampBookAnnotationData(pageNumber: "8")),
                LampBookAnnotation(type: "bold", start: 4, end: 8),
            ],
            footnoteReferences: [LampBookFootnoteReference(id: "1", offset: 4), LampBookFootnoteReference(id: "3", offset: 9)]
        )
        let legacy = LampCommentaryBlocks.legacyForm(of: projection)
        let text = try #require(legacy["text"] as? String)
        #expect(text == "See [p. 7] [p. 8] them.")
        let annotations = try #require(legacy["annotations"] as? [[String: Any]])
        let scripture = annotations[0]["data"] as? [String: Any]
        #expect(scripture?["sv"] as? Int == 43_003_016 && scripture?["ev"] as? Int == 43_003_018)
        #expect(annotations[1]["id"] as? String == "2")
        let spans = annotations.map { "\($0["type"]!) \($0["start"]!)-\($0["end"]!)" }
        #expect(spans == ["scripture 0-3", "footnote 18-22", "page 4-10", "page 11-17", "bold 18-22"], "\(spans)")
        let scalars = Array(text.unicodeScalars)
        #expect(String(String.UnicodeScalarView(scalars[4..<10])) == "[p. 7]")

        // A page marked inside a passage's span: the span kept either side of
        // its label, not over it. Found by Codex.
        let inside = LampCommentaryBlocks.legacyForm(of: LampBookAnnotatedText(text: "John 3:16", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 9, data: LampBookAnnotationData(startReference: 43_003_016)),
            LampBookAnnotation(type: "page", start: 5, end: 5, data: LampBookAnnotationData(pageNumber: "2")),
        ]))
        #expect(inside["text"] as? String == "John [p. 2] 3:16")
        let insideSpans = ((inside["annotations"] as? [[String: Any]]) ?? []).map { "\($0["type"]!) \($0["start"]!)-\($0["end"]!)" }
        #expect(Set(insideSpans) == ["scripture 0-5", "page 5-11", "scripture 12-16"], "\(insideSpans)")
        // Neither half keeps the words the whole span was. Found by Codex.
        let labelledSpan = LampCommentaryBlocks.legacyForm(of: LampBookAnnotatedText(text: "John 3:16", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 9, text: "John 3:16", data: LampBookAnnotationData(startReference: 43_003_016)),
            LampBookAnnotation(type: "page", start: 5, end: 5, data: LampBookAnnotationData(pageNumber: "2")),
        ]))
        #expect(((labelledSpan["annotations"] as? [[String: Any]]) ?? []).allSatisfy { $0["text"] == nil })
        // Both halves where the span stood among the rest: a reader applies
        // them in order, and a note after it must stay over its half. Found
        // by Codex.
        let ordered = LampCommentaryBlocks.legacyForm(of: LampBookAnnotatedText(text: "John 3:16", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 9, data: LampBookAnnotationData(startReference: 43_003_016)),
            LampBookAnnotation(type: "page", start: 5, end: 5, data: LampBookAnnotationData(pageNumber: "2")),
            LampBookAnnotation(type: "footnote", start: 7, end: 9, data: LampBookAnnotationData(footnoteID: "1")),
        ]))
        let orderedTypes = ((ordered["annotations"] as? [[String: Any]]) ?? []).map { "\($0["type"]!) \($0["start"]!)" }
        #expect(orderedTypes == ["scripture 0", "scripture 12", "page 5", "footnote 14"], "\(orderedTypes)")
        #expect((legacy["footnote_refs"] as? [[String: Any]])?.map { $0["offset"] as? Int } == [4, 23])
    }

    /// A 2.3 unit is filed and ordered by its own verse, each unit's units
    /// beneath it; a 2.2 volume is written list by list, as it was.
    @Test func aUnitIsFiledAndOrderedByItsOwnVerse() throws {
        let chapters = #"""
        [{"chapter": 1,
          "sections": [{"title": "Late", "sv": 43001020, "pericopae": [{"title": "Under late", "sv": 43001021}]},
                       {"title": "At five", "sv": 43001005}],
          "pericopae": [{"title": "Passage at five", "sv": 43001005, "verses": [{"sv": 43001007, "commentary": {"text": "seven"}}, {"sv": 43001006, "commentary": {"text": "six"}}]}],
          "verses": [{"sv": 43001005, "commentary": {"text": "five"}}, {"sv": 43001002, "commentary": {"text": "two"}},
                     {"sv": 43002003, "commentary": {"text": "in chapter two"}}]}]
        """#
        func order(_ builder: CommentaryUnitBuilder) -> [String] {
            builder.units.map { "\($0.unitType) \($0.startVerse % 1_000_000) \($0.title ?? JSONSupport.plainText(object($0.commentaryJSON)))" }
        }
        let rich = try build(chapters, rich: true)
        #expect(rich.issues.isEmpty, "\(rich.issues)")
        #expect(order(rich) == [
            "verse 1002 two",
            "section 1005 At five", "pericope 1005 Passage at five", "verse 1005 five", "verse 1006 six", "verse 1007 seven",
            "section 1020 Late", "pericope 1021 Under late",
            "verse 2003 in chapter two",
        ], "\(order(rich))")
        #expect(rich.units.last?.chapter == 2)
        #expect(rich.units.map(\.orderIndex) == Array(rich.units.indices))
        // Each keeps its parent wherever it falls.
        let passage = rich.units.first { $0.title == "Passage at five" }?.id
        #expect(rich.units.filter { $0.parentID == passage && passage != nil }.count == 2)
        // A subsection starting in a later chapter than its section is
        // filed and ordered in its own chapter, among that chapter's notes,
        // as the study Bible's outline is; a heading before a note at one
        // verse though the note is written first. Found by Codex.
        let outline = try build(#"""
        [{"chapter": 1, "sections": [{"title": "Whole", "sv": 43001001, "ev": 43002025,
                                       "subsections": [{"title": "Second half", "sv": 43002012}, {"title": "At two one", "sv": 43002001}]}],
          "verses": [{"sv": 43002001, "commentary": {"text": "note at two one"}}]},
         {"chapter": 2, "verses": [{"sv": 43002005, "commentary": {"text": "five"}}, {"sv": 43002015, "commentary": {"text": "fifteen"}}]}]
        """#, rich: true)
        #expect(outline.issues.isEmpty, "\(outline.issues)")
        #expect(order(outline) == [
            "section 1001 Whole",
            "section 2001 At two one", "verse 2001 note at two one", "verse 2005 five", "section 2012 Second half", "verse 2015 fifteen",
        ], "\(order(outline))")
        // A unit placed by verse gives its verse, and content entries are a
        // source-tracked volume's: a place guessed from a parent was left
        // unstored, or put a child above its parent. Found by Codex; refused
        // on the planner's advice.
        let unanchored = try build(#"[{"chapter": 1, "sections": [{"title": "Late", "sv": 43001020, "subsections": [{"title": "Inner"}]}], "verses": [{"sv": 43001005, "commentary": {"text": "five"}}]}]"#, rich: true)
        #expect(unanchored.issues.map(\.path) == ["/chapters/0/sections/0/subsections/0/sv"], "\(unanchored.issues)")
        // A child starting before its parent, in its chapter or an earlier
        // one: refused, after three rounds of outlines it misled. Found by
        // Codex.
        let earlier = try build(#"[{"chapter": 1, "pericopae": [{"title": "Later", "sv": 43002001, "verses": [{"sv": 43001002, "commentary": {"text": "two"}}]}]}]"#, rich: true)
        #expect(earlier.issues.map(\.path) == ["/chapters/0/pericopae/0/verses/0/sv"], "\(earlier.issues)")
        let anchored = try build(#"[{"chapter": 1, "sections": [{"title": "Later", "sv": 43001020, "subsections": [{"title": "Inner", "sv": 43001002}]}]}]"#, rich: true)
        #expect(anchored.issues.map(\.path) == ["/chapters/0/sections/0/subsections/0/sv"], "\(anchored.issues)")
        let nestedHeading = try build(#"[{"chapter": 1, "sections": [{"title": "S", "sv": 43001020, "pericopae": [{"title": "P", "content": [{"type": "heading", "content": {"text": "H"}}]}]}]}]"#, rich: true)
        #expect(nestedHeading.issues.map(\.path) == ["/chapters/0/sections/0/pericopae/0/sv", "/chapters/0/sections/0/pericopae/0/content"], "\(nestedHeading.issues)")
        let explicitUnderMoved = try build(#"[{"chapter": 1, "verses": [{"sv": 43001022, "commentary": {"text": "twenty-two"}}], "sections": [{"title": "S", "sv": 43001020, "pericopae": [{"title": "P", "sv": 43001020, "verses": [{"sv": 43001025, "commentary": {"text": "twenty-five"}}]}]}]}]"#, rich: true)
        #expect(order(explicitUnderMoved) == ["section 1020 S", "pericope 1020 P", "verse 1022 twenty-two", "verse 1025 twenty-five"], "\(order(explicitUnderMoved))")
        let headingEntry = try build(#"[{"chapter": 1, "pericopae": [{"title": "Passage", "sv": 43001003, "content": [{"type": "heading", "content": {"text": "Heading"}}]}]}]"#, rich: true)
        #expect(headingEntry.issues.map(\.path) == ["/chapters/0/pericopae/0/content"], "\(headingEntry.issues)")
        let noteFirst = try build(#"[{"chapter": 1, "verses": [{"sv": 43002001, "commentary": {"text": "note"}}]}, {"chapter": 2, "sections": [{"title": "Heading", "sv": 43002001}]}]"#, rich: true)
        #expect(order(noteFirst) == ["section 2001 Heading", "verse 2001 note"], "\(order(noteFirst))")
        #expect(outline.units.filter { $0.unitType == "section" && $0.level == 2 }.allSatisfy { $0.chapter == 2 && $0.parentID == outline.units.first?.id })
        let older = try build(chapters, rich: false)
        #expect(order(older) == [
            "section 1020 Late", "pericope 1021 Under late", "section 1005 At five",
            "pericope 1005 Passage at five", "verse 1007 seven", "verse 1006 six",
            "verse 1005 five", "verse 1002 two", "verse 2003 in chapter two",
        ], "\(order(older))")
        #expect(older.units.last?.chapter == 1)
        // A source-tracked volume keeps its printed order, returning to an
        // earlier passage.
        let printed = try build(#"[{"chapter": 1, "pericopae": [{"id": "b", "sv": 43001009, "content": []}, {"id": "a", "sv": 43001001, "content": []}]}]"#, rich: true, sourceOrdered: true)
        #expect(printed.units.map(\.startVerse) == [43001009, 43001001])
        // Every chapter's units together: a note on 2:20 written in chapter
        // 1 after the note on 2:2 in chapter 2, a chapter's introduction
        // before its units; a source-tracked pericope's verses as printed.
        // Found by Codex.
        let across = try build(#"[{"chapter": 1, "verses": [{"sv": 43002020, "commentary": {"text": "a"}}]}, {"chapter": 2, "introduction": {"text": "i"}, "verses": [{"sv": 43002002, "commentary": {"text": "b"}}]}]"#, rich: true)
        #expect(across.units.map { $0.startVerse % 1_000_000 } == [2001, 2002, 2020], "\(order(across))")
        let printedVerses = try build(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "verses": [{"sv": 43001009, "commentary": {"text": "a"}}, {"sv": 43001001, "commentary": {"text": "b"}}]}]}]"#, rich: true, sourceOrdered: true)
        #expect(printedVerses.units.map { $0.startVerse % 1_000_000 } == [1001, 1009, 1001], "\(order(printedVerses))")
        // A 2.2 volume's first fault is the one it was: a section's inner
        // fault before a later verse that is no object.
        do {
            _ = try build(#"[{"chapter": 1, "sections": [{"title": "t", "subsections": [5]}], "verses": [7]}]"#, rich: false)
            Issue.record("built")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "/chapters/sections/subsections")
        }
    }

    /// The order of a 2.3 volume's rows, over generated volumes: sections
    /// nested three deep, passages and notes, children at and after their
    /// parents' verses and in later chapters, and ties of verse and
    /// kind. Held to: the rows sorted by (chapter, introduction first,
    /// verse, kind) and otherwise as written; each filed in its verse's
    /// chapter; each under the parent it is written under.
    @Test func everyVolumesRowsAreInTheOrderAReaderShows() throws {
        var seed: UInt64 = 0x5EED_0006
        func next(_ bound: Int) -> Int {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
        for _ in 0..<500 {
            // What each written unit is, in the order written: its label, its
            // parent's, its place.
            var written: [(label: String, parent: String?, chapter: Int, introduction: Int, verse: Int, rank: Int)] = []
            var count = 0
            // Every verse of the grid, in order; a child's at or after its
            // parent's.
            let grid = (1...3).flatMap { chapter in (0..<4).map { 43_000_000 + chapter * 1_000 + $0 } }
            func verse(from least: Int?) -> Int {
                let first = least.flatMap { grid.firstIndex(of: $0) } ?? 0
                return grid[first + next(grid.count - first)]
            }
            var startOf: [String: Int] = [:]
            func note(_ parent: String?) -> [String: Any] {
                count += 1
                let label = "n\(count)", sv = verse(from: parent.flatMap { startOf[$0] })
                written.append((label, parent, sv / 1_000 % 1_000, 1, sv, 3))
                return ["sv": sv, "suffix": label, "commentary": ["text": label]]
            }
            func passage(_ parent: String?) -> [String: Any] {
                count += 1
                let label = "p\(count)", sv = verse(from: parent.flatMap { startOf[$0] })
                startOf[label] = sv
                written.append((label, parent, sv / 1_000 % 1_000, 1, sv, 2))
                return ["sv": sv, "title": label, "verses": (0..<next(3)).map { _ in note(label) }]
            }
            func section(_ parent: String?, depth: Int) -> [String: Any] {
                count += 1
                let label = "s\(count)", sv = verse(from: parent.flatMap { startOf[$0] })
                startOf[label] = sv
                written.append((label, parent, sv / 1_000 % 1_000, 1, sv, 1))
                return [
                    "sv": sv, "title": label,
                    "subsections": depth < 3 ? (0..<next(3)).map { _ in section(label, depth: depth + 1) } : [],
                    "pericopae": (0..<next(2)).map { _ in passage(label) },
                ]
            }
            var chapters: [[String: Any]] = []
            for number in 1...3 {
                var chapter: [String: Any] = ["chapter": number]
                if next(3) == 0 {
                    count += 1
                    written.append(("i\(count)", nil, number, 0, 43_000_000 + number * 1_000 + 1, 0))
                    chapter["introduction"] = ["text": "i\(count)"]
                }
                chapter["sections"] = (0..<next(3)).map { _ in section(nil, depth: 1) }
                chapter["pericopae"] = (0..<next(2)).map { _ in passage(nil) }
                chapter["verses"] = (0..<next(4)).map { _ in note(nil) }
                chapters.append(chapter)
            }
            var builder = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, rich: true)
            try builder.append(chapters: chapters)
            #expect(builder.issues.isEmpty, "\(builder.issues)")
            func label(_ row: CommentaryUnitRow) -> String {
                row.unitType == "verse" ? (row.suffix ?? "") : row.level == 0 ? JSONSupport.plainText(object(row.introductionJSON)) : (row.title ?? "")
            }
            let expected = written.enumerated().sorted {
                ($0.element.chapter, $0.element.introduction, $0.element.verse, $0.element.rank, $0.offset)
                    < ($1.element.chapter, $1.element.introduction, $1.element.verse, $1.element.rank, $1.offset)
            }.map(\.element.label)
            let rows = builder.units
            #expect(rows.map(label) == expected)
            #expect(rows.map(\.orderIndex) == Array(rows.indices))
            let labelByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, label($0)) })
            let parentByLabel = Dictionary(uniqueKeysWithValues: written.map { ($0.label, $0.parent) })
            for row in rows {
                #expect(row.level == 0 || row.chapter == row.startVerse / 1_000 % 1_000)
                #expect(row.parentID.flatMap { labelByID[$0] } == parentByLabel[label(row)] ?? nil)
            }
        }
    }

    /// What a 2.3 unit gives is read whole: a verse a whole number in its
    /// book, a passage that does not end before it starts, one note on a
    /// passage, one id at a verse, and no field nothing reads.
    @Test func aUnitIsReadWhole() throws {
        func paths(_ chapters: String, sourceOrdered: Bool = false) throws -> [String] {
            try build(chapters, rich: true, sourceOrdered: sourceOrdered).issues.filter { $0.severity == .error }.map(\.path)
        }
        let text = #"{"text": "x"}"#
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001.5, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/sv"])
        #expect(try paths(#"[{"chapter": 1, "sections": [{"sv": "John 1", "title": "t"}]}]"#) == ["/chapters/0/sections/0/sv"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 44001001, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/sv"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"sv": 43001005, "ev": 43001002, "title": "t"}]}]"#) == ["/chapters/0/pericopae/0/ev"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "sv": 43001002.5, "source": {}, "content": \#(text)}]}]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/0/content/0/sv"])
        // A verse in no chapter, outside chapter 0; an end before the start
        // the row takes; a source-tracked chapter's unread field, given
        // empty. Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43000001, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/sv"])
        #expect(try paths(#"[{"chapter": 0, "verses": [{"sv": 43000001, "commentary": \#(text)}]}]"#).isEmpty)
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001009, "content": [{"type": "commentary", "ev": 43001002, "source": {}, "content": \#(text)}]}]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/0/content/0/ev"])
        #expect(Set(try paths(#"[{"chapter": 2, "sections": [{"title": "t", "ev": 43001005}]}]"#)) == ["/chapters/0/sections/0/sv", "/chapters/0/sections/0/ev"])
        #expect(try paths(#"[{"chapter": 1, "blocks": [], "pericopae": []}]"#, sourceOrdered: true) == ["/chapters/0/blocks"])
        // A suffix with a NUL, stored as the shorter one; an entry in chapter
        // 0 of a pericope written there and filed in chapter 1. Found by
        // Codex.
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "suffix": "a\u0000b", "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/suffix"])
        #expect(try paths(#"[{"chapter": 0, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "sv": 43000001, "source": {}, "content": \#(text)}]}]}]"#, sourceOrdered: true).isEmpty)
        // Its verses too; a printed order where none is kept; a unit's
        // fault told before a later sibling stops the build. Found by Codex.
        #expect(try paths(#"[{"chapter": 0, "pericopae": [{"title": "p", "sv": 43000001, "verses": [{"sv": 43000002, "commentary": \#(text)}]}]}]"#).isEmpty)
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"title": "p", "sv": 43001001, "sourceOrder": 3}]}]"#) == ["/chapters/0/pericopae/0/sourceOrder"])
        // An end in a later book; not an earlier one, nor chapter 0 of the
        // later; a heading pericope's provenance. Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "ev": 44009031}]}]"#).isEmpty)
        #expect(Set(try paths(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "ev": 42009031}]}]"#)) == ["/chapters/0/sections/0/ev"])
        #expect(try paths(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "ev": 44000031}]}]"#) == ["/chapters/0/sections/0/ev"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "sourceChapter": 1, "basis": "chapter-heading", "content": []}]}]"#, sourceOrdered: true).isEmpty)
        // A split heading's prose and offset, which may be its only copy.
        // Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "remainder": "r", "textEnd": 4, "content": []}]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/0/remainder", "/chapters/0/pericopae/0/textEnd"])
        // A key told at the path that names it; one fault for entries
        // outside a source-tracked volume. Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "notes/extra~": 1}]"#) == ["/chapters/0/notes~1extra~0"])
        #expect(try paths(#"[{"chapter": 1, "notes/x": 1}]"#, sourceOrdered: true) == ["/chapters/0/notes~1x"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"title": "t", "sv": 43001001, "commentary": \#(text), "content": []}]}]"#) == ["/chapters/0/pericopae/0/content"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"title": "t", "sv": 43001001, "content": {}}]}]"#) == ["/chapters/0/pericopae/0/content"])
        // A chapter that is no whole number, either way a volume is built;
        // a section printed at another level than its nesting is kept.
        // Found by Codex.
        for sourceOrdered in [false, true] {
            do {
                _ = try build(#"[{"chapter": 0.5, "pericopae": []}]"#, rich: true, sourceOrdered: sourceOrdered)
                Issue.record("chapter 0.5 built")
            } catch ModuleCompilationError.invalidValue(let path, _) {
                #expect(path == "/chapters/0/chapter")
            }
        }
        #expect(try paths(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "level": 2}]}]"#).isEmpty)
        // A chapter its book has not, which an introduction's verse is made
        // from. Found by Codex.
        do {
            _ = try build(#"[{"chapter": 22, "introduction": \#(text)}]"#, rich: true)
            Issue.record("chapter 22 of John built")
        } catch ModuleCompilationError.invalidValue(let path, _) {
            #expect(path == "/chapters/0/chapter")
        }
        #expect(try paths(#"[{"chapter": 21, "introduction": \#(text)}]"#).isEmpty)
        // A chapter the book has not; a split heading's prose outside a
        // source-tracked volume. Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43022001, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/sv"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43021025, "commentary": \#(text)}]}]"#).isEmpty)
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"title": "t", "sv": 43001001, "remainder": "lost"}]}]"#) == ["/chapters/0/pericopae/0/remainder"])
        // An entry's note and a verse note on one passage, either written
        // first; entries on one verse, as one printed note. Found by Codex.
        let entry = #"{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "sv": 43001002, "source": {}, "content": \#(text)}, {"type": "commentary", "sv": 43001002, "source": {}, "content": \#(text)}]}"#
        let verses = #"{"id": "q", "sv": 43001001, "verses": [{"sv": 43001002, "commentary": \#(text)}]}"#
        #expect(try paths(#"[{"chapter": 1, "pericopae": [\#(entry), \#(verses)]}]"#, sourceOrdered: true) == ["/chapters/0/pericopae/1/verses/0"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [\#(verses), \#(entry)]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/1/content/0", "/chapters/0/pericopae/1/content/1"])
        // Outside a source-tracked volume, the entries alone are told.
        #expect(try paths(#"[{"chapter": 1, "pericopae": [\#(entry), \#(verses)]}]"#) == ["/chapters/0/pericopae/0/content"])
        // An index entry, a suffix that is no string, a printed order that is
        // no whole number. Found by Codex.
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "index", "source": {}, "content": \#(text)}]}]}]"#, sourceOrdered: true) == ["/chapters/0/pericopae/0/content/0"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "suffix": 1, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/0/suffix"])
        // Suffixes and ids compared byte for byte; an id with a NUL. Found by
        // Codex.
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "suffix": "\u00e9", "commentary": \#(text)}, {"sv": 43001001, "suffix": "e\u0301", "commentary": \#(text)}]}]"#).isEmpty)
        #expect(try paths(#"[{"chapter": 1, "sections": [{"id": "\u00e9", "sv": 43001001, "title": "a"}, {"id": "e\u0301", "sv": 43001001, "title": "b"}]}]"#).isEmpty)
        #expect(try paths(#"[{"chapter": 1, "sections": [{"id": "a\u0000b", "sv": 43001001, "title": "a"}]}]"#) == ["/chapters/0/sections/0/id"])
        #expect(try paths(#"[{"chapter": 1, "sections": [{"id": "", "sv": 43001001, "title": "a"}]}]"#) == ["/chapters/0/sections/0/id"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": 123, "sv": 43001001, "title": "a"}]}]"#) == ["/chapters/0/pericopae/0/id"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(text)}, {"sv": 43001001, "ev": 43001001, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/1"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "sourceOrder": "2", "content": []}, {"id": "q", "sv": 43001002, "sourceOrder": 1.5, "content": []}]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/0/sourceOrder", "/chapters/0/pericopae/1/sourceOrder"])
        var stopped = CommentaryUnitBuilder(moduleID: "M", bookNumber: 43, rich: true)
        #expect(throws: ModuleCompilationError.self) {
            try stopped.append(chapters: try json(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "introduction": \#(text), "blocks": []}], "verses": [7]}]"#))
        }
        #expect(stopped.issues.contains { $0.path.hasPrefix("/chapters/0/sections/0") }, "\(stopped.issues)")
        // One note on a passage; a suffix tells two apart.
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(text)}, {"sv": 43001001, "commentary": \#(text)}]}]"#) == ["/chapters/0/verses/1"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(text)}, {"sv": 43001001, "suffix": "b", "commentary": \#(text)}, {"sv": 43001001, "ev": 43001002, "commentary": \#(text)}]}]"#).isEmpty)
        // One id at a verse; the same id at another verse is another unit.
        #expect(try paths(#"[{"chapter": 1, "sections": [{"id": "s", "sv": 43001001, "title": "a"}], "pericopae": [{"id": "s", "sv": 43001001, "title": "b"}]}]"#) == ["/chapters/0/pericopae/0/id"])
        #expect(try paths(#"[{"chapter": 1, "sections": [{"id": "s", "sv": 43001001, "title": "a"}, {"id": "s", "sv": 43001009, "title": "b"}]}]"#).isEmpty)
        // A field nothing reads, in each kind of unit.
        #expect(try paths(#"[{"chapter": 1, "blocks": [], "notes": 1}]"#) == ["/chapters/0/blocks", "/chapters/0/notes"])
        #expect(try paths(#"[{"chapter": 1, "sections": [{"title": "t", "sv": 43001001, "verses": []}]}]"#) == ["/chapters/0/sections/0/verses"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"title": "t", "sv": 43001001, "subtitle": "u"}]}]"#) == ["/chapters/0/pericopae/0/subtitle"])
        #expect(try paths(#"[{"chapter": 1, "verses": [{"sv": 43001001, "commentary": \#(text), "id": "v"}]}]"#) == ["/chapters/0/verses/0/id"])
        #expect(try paths(#"[{"chapter": 1, "pericopae": [{"id": "p", "sv": 43001001, "content": [{"type": "commentary", "source": {}, "content": \#(text), "note": "x"}]}]}]"#, sourceOrdered: true)
            == ["/chapters/0/pericopae/0/content/0/note"])
        // What a section, pericope, verse and entry may give, all read.
        #expect(try paths(#"""
        [{"chapter": 1, "introduction": \#(text),
          "sections": [{"id": "s", "title": "t", "sv": 43001001, "ev": 43001009, "level": 1, "introduction": \#(text),
                        "subsections": [{"title": "u", "sv": 43001002}], "pericopae": [{"title": "p", "sv": 43001003}]}],
          "pericopae": [{"id": "p", "title": "t", "sv": 43001004, "introduction": \#(text), "translation": \#(text), "commentary": \#(text),
                         "verses": [{"sv": 43001004, "suffix": "a", "title": "1:4a", "translation": \#(text), "commentary": \#(text)}]}]}]
        """#).isEmpty)
        // A 2.2 volume is built as it was, its unread fields unread.
        #expect(try build(#"[{"chapter": 1, "verses": [{"sv": 43001001.5, "id": "v", "commentary": \#(text)}, {"sv": 43001001, "commentary": \#(text)}]}]"#, rich: false).issues.isEmpty)
    }

    /// A unit the builder refused stops the compile, and the inspection of
    /// the same volume says why.
    @Test func aRefusedUnitStopsTheCompileAndTheInspectionSaysWhy() throws {
        let volume = #"""
        {"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"},
         "book": "John", "bookNumber": 43,
         "chapters": [{"chapter": 1, "verses": [{"sv": 43001001, "commentary": {"text": "x"}, "blocks": [{"type": "paragraph", "content": {"text": "y"}}]}]}]}
        """#
        let root = try #require(try JSONSerialization.jsonObject(with: Data(volume.utf8)) as? [String: Any])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rich-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ModuleCompilationError.self) {
            _ = try LampModuleCompiler().compileCommentary(root: root, databaseURL: url, moduleID: "R")
        }
        let inspection = try ModuleJSONInspector().inspect(Data(volume.utf8))
        #expect(inspection.issues.contains { $0.path == "/chapters/0/verses/0/commentary" && $0.severity == .error })
        // Still refused for its version, until this build reads 2.3.
        #expect(inspection.issues.contains { $0.path == "/meta/schemaVersion" })
    }
}
