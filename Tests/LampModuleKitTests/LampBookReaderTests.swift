import Foundation
import Testing
@testable import LampModuleKit

private func annotation(
    _ type: String,
    _ start: Int,
    _ end: Int,
    _ data: LampBookAnnotationData? = nil
) -> LampBookAnnotation {
    LampBookAnnotation(type: type, start: start, end: end, data: data)
}

/// The text of each run carrying `key`, in order.
private func runs<K: AttributedStringKey>(
    of key: K.Type,
    in value: AttributedString
) -> [(String, K.Value)] where K.Value: Sendable {
    value.runs[key].compactMap { attribute, range in
        attribute.map { (String(value[range].characters), $0) }
    }
}

struct LampBookTextResolverTests {
    @Test func annotationsSayWhatEachStretchIs() throws {
        let text = "See John 3:16, the Logos, and grace upon grace in the word."
        let content = LampBookAnnotatedText(text: text, annotations: [
            annotation("scripture", 4, 13, LampBookAnnotationData(startReference: 43_003_016)),
            annotation("greek", 19, 24, LampBookAnnotationData(strongs: "G3056")),
            annotation("emphasis", 30, 46, LampBookAnnotationData(style: "italic")),
            annotation("emphasis", 30, 35, LampBookAnnotationData(style: "bold")),
            annotation("emphasis", 54, 58, LampBookAnnotationData(style: "underline")),
            annotation("link", 50, 53, LampBookAnnotationData(url: "https://example.org")),
        ])

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: [:])

        #expect(String(value.characters) == text)
        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: value).map { $0.0 } == ["John 3:16"])
        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: value).first?.1
            == LampBookPassage(start: 43_003_016))
        #expect(runs(of: LampBookTextAttributes.OriginalLanguage.self, in: value).map { $0.0 } == ["Logos"])
        #expect(runs(of: LampBookTextAttributes.OriginalLanguage.self, in: value).first?.1
            == LampBookOriginalLanguage(kind: .greek, strongs: "G3056"))
        #expect(runs(of: LampBookTextAttributes.Underline.self, in: value).map { $0.0 } == ["word"])
        #expect(runs(of: AttributeScopes.FoundationAttributes.LinkAttribute.self, in: value).map { $0.0 }
            == ["the"])
        // Bold inside italics is both.
        let emphasis = runs(of: AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self, in: value)
        #expect(emphasis.map { $0.0 } == ["grace", " upon grace"])
        #expect(emphasis.first?.1 == [.emphasized, .stronglyEmphasized])
        #expect(emphasis.last?.1 == [.emphasized])
    }

    @Test func originalLanguageWordsWithoutAStrongsKeyAreStillMarked() throws {
        // As a commentary's converter emits most of its Greek and Hebrew: no
        // data, or an encoding note without a key.
        let content = LampBookAnnotatedText(text: "λόγος and חֶסֶד", annotations: [
            annotation("greek", 0, 5),
            annotation("hebrew", 10, 15, LampBookAnnotationData(strongs: "")),
        ])

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: [:])

        #expect(runs(of: LampBookTextAttributes.OriginalLanguage.self, in: value).map { $0.1 } == [
            LampBookOriginalLanguage(kind: .greek),
            LampBookOriginalLanguage(kind: .hebrew),
        ])
    }

    @Test func offsetsCountUnicodeScalarsNotCharacters() throws {
        // "café" with its accent as a separate scalar, then pointed Hebrew:
        // each is fewer Characters than scalars, so Character offsets would
        // land later than the converter meant.
        let decomposed = "cafe\u{301} and "
        let hebrew = "בְּרֵאשִׁית "
        let text = decomposed + hebrew + "Gen 1:1 ends."
        let referenceStart = (decomposed + hebrew).unicodeScalars.count
        #expect(referenceStart != (decomposed + hebrew).count)
        let content = LampBookAnnotatedText(
            text: text,
            annotations: [
                annotation("emphasis", 6, 9, LampBookAnnotationData(style: "bold")),
                annotation("scripture", referenceStart, referenceStart + 7,
                           LampBookAnnotationData(startReference: 1_001_001)),
            ],
            footnoteReferences: [LampBookFootnoteReference(id: "n1", offset: 5)]
        )

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: ["n1": 4])

        #expect(runs(of: AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self, in: value)
            .map { $0.0 } == ["and"])
        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: value).map { $0.0 } == ["Gen 1:1"])
        // After the accent, not inside "café".
        #expect(String(value.characters).hasPrefix("cafe\u{301}[4] and"))
    }

    @Test func markersGoWhereTheBookPlacesThemNumberedAsTheBookNumbersThem() throws {
        let content = LampBookAnnotatedText(
            text: "First. Second.",
            annotations: [annotation("footnote", 7, 13, LampBookAnnotationData(footnoteID: "linked"))],
            footnoteReferences: [
                LampBookFootnoteReference(id: "b", offset: 6),
                LampBookFootnoteReference(id: "c", offset: 6),
                LampBookFootnoteReference(id: "linked", offset: 14),
                LampBookFootnoteReference(id: "unlisted", offset: 99),
            ]
        )

        let value = LampBookTextResolver.resolve(
            content,
            footnoteNumbers: ["b": 12, "c": 13, "linked": 14]
        )

        // A marker past the end goes at the end; one for a note the book
        // doesn't list has no number.
        #expect(String(value.characters) == "First.[12][13] Second.[14][•]")
        let marks = runs(of: LampBookTextAttributes.Footnote.self, in: value)
        #expect(marks.map { $0.0 } == ["[12]", "[13]", "Second", "[14]", "[•]"])
        #expect(marks.map { $0.1 } == [
            LampBookFootnoteMark(id: "b", number: 12, isMarker: true),
            LampBookFootnoteMark(id: "c", number: 13, isMarker: true),
            LampBookFootnoteMark(id: "linked", number: 14, isMarker: false),
            LampBookFootnoteMark(id: "linked", number: 14, isMarker: true),
            LampBookFootnoteMark(id: "unlisted", number: nil, isMarker: true),
        ])
    }

    @Test func spansFromBadOffsetsAreLeftOutAndOnlyAnOverlongEndIsCut() throws {
        let scripture = LampBookAnnotationData(startReference: 43_001_001)
        let content = LampBookAnnotatedText(text: "In the beginning", annotations: [
            annotation("scripture", -1, 2, scripture),
            annotation("scripture", 6, 3, scripture),
            annotation("scripture", 16, 20, scripture),
            annotation("scripture", 7, 99, scripture),
        ])

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: [:])

        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: value).map { $0.0 } == ["beginning"])
        #expect(String(value.characters) == "In the beginning")
    }

    @Test func pageMarkersGoWhereEachPageStartsSpacedFromTheWords() throws {
        // A roman page at the start; page 12 at "Christadelphian", after the
        // space; page 13 straight after that word, with the footnote that
        // ends page 12 at the same place.
        let text = "disagreed with Christadelphian teaching"
        let content = LampBookAnnotatedText(
            text: text,
            annotations: [
                annotation("page", 0, 0, LampBookAnnotationData(pageNumber: "xii")),
                annotation("page", 15, 15, LampBookAnnotationData(pageNumber: "12")),
                annotation("page", 30, 30, LampBookAnnotationData(pageNumber: "13")),
                annotation("page", -1, -1, LampBookAnnotationData(pageNumber: "0")),
                annotation("page", 4, 4),
                annotation("page", 99, 99, LampBookAnnotationData(pageNumber: "14")),
            ],
            footnoteReferences: [LampBookFootnoteReference(id: "n", offset: 30)]
        )

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: ["n": 3])

        // A start past the end goes at the end; the spaces a marker brings
        // are marked with it.
        #expect(String(value.characters)
            == "[p. xii] disagreed with [p. 12] Christadelphian[3] [p. 13] teaching [p. 14]")
        #expect(runs(of: LampBookTextAttributes.Page.self, in: value).map { $0.0 }
            == ["[p. xii] ", "[p. 12] ", " [p. 13]", " [p. 14]"])
        #expect(runs(of: LampBookTextAttributes.Page.self, in: value).map { $0.1 } == ["xii", "12", "13", "14"])
    }

    @Test func attributesSurviveTheTripThroughNSAttributedStringGivenTheScope() throws {
        let content = LampBookAnnotatedText(
            text: "Read Rom 6:23.",
            annotations: [annotation("scripture", 5, 13, LampBookAnnotationData(startReference: 45_006_023))],
            footnoteReferences: [LampBookFootnoteReference(id: "n", offset: 14)]
        )
        let value = LampBookTextResolver.resolve(content, footnoteNumbers: ["n": 2])

        let converted = try NSAttributedString(value, including: \.lampBook)
        let back = try AttributedString(converted, including: \.lampBook)

        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: back).first?.1
            == LampBookPassage(start: 45_006_023))
        #expect(runs(of: LampBookTextAttributes.Footnote.self, in: back).first?.1
            == LampBookFootnoteMark(id: "n", number: 2, isMarker: true))
    }

    @Test func footnotesAreNumberedByTheirPlaceInTheBook() {
        let footnotes = ["a", "b", "a", "c"].map {
            LampBookFootnote(id: $0, content: .plain($0))
        }
        #expect(LampBookFootnoteNumbering.numbers(for: footnotes) == ["a": 1, "b": 2, "c": 4])
    }

    @Test func anAnnotationCitesItsOwnRangeThenEachOfItsRefs() {
        let cited = annotation("scripture", 0, 4, LampBookAnnotationData(
            startReference: 45_003_023,
            references: [
                LampBookVerseRange(startReference: 45_003_023),
                LampBookVerseRange(startReference: 45_006_023, endReference: 45_006_024),
            ]
        ))
        let passages = LampBookPassage.passages(of: cited)
        #expect(passages == [
            LampBookPassage(start: 45_003_023),
            LampBookPassage(start: 45_006_023, end: 45_006_024),
        ])
        #expect(passages.map { $0.verseURL?.absoluteString } == [
            "lampbible://verse/45003023",
            "lampbible://verse/45006023/45006024",
        ])
    }
}

struct LampBookSectionIndexTests {
    @Test func indexesHeadingsCitationsAndFootnotesInReadingOrder() {
        func text(
            _ value: String,
            _ annotations: [LampBookAnnotation] = [],
            notes: [LampBookFootnoteReference] = []
        ) -> LampBookAnnotatedText {
            LampBookAnnotatedText(text: value, annotations: annotations, footnoteReferences: notes)
        }
        let romans = LampBookAnnotationData(
            startReference: 45_003_023,
            references: [LampBookVerseRange(startReference: 45_006_023)]
        )
        let john = LampBookAnnotationData(startReference: 43_003_016)
        let blocks = [
            LampBookContentBlock(type: "heading", content: text("  Sin and Death  "), level: 1),
            LampBookContentBlock(type: "paragraph", content: text(
                "All have sinned; see John.",
                [annotation("scripture", 21, 25, john), annotation("scripture", 0, 3, romans)],
                notes: [LampBookFootnoteReference(id: "n2", offset: 16)]
            )),
            LampBookContentBlock(type: "heading", content: text("Entry"), level: 4),
            LampBookContentBlock(type: "heading", content: text("Untitled level"), level: nil),
            LampBookContentBlock(type: "heading", content: text("   ")),
            LampBookContentBlock(type: "list", items: [LampBookListItem(
                content: text("Item", notes: [LampBookFootnoteReference(id: "n1", offset: 4)]),
                children: [LampBookListItem(content: text("John again", [annotation("scripture", 0, 4, john)]))]
            )]),
            LampBookContentBlock(type: "table", rows: [LampBookTableRow(cells: [
                LampBookTableCell(content: text("Cell", [annotation("footnote", 0, 4,
                    LampBookAnnotationData(footnoteID: "n2"))]), column: 0),
                // Cells the readers leave out — a second at one column, one
                // at a negative column — cite nothing a reader can see.
                LampBookTableCell(content: text("Shadowed", [annotation("footnote", 0, 8,
                    LampBookAnnotationData(footnoteID: "n9"))]), column: 0),
                LampBookTableCell(content: text("Behind", [annotation("scripture", 0, 6, john)]), column: -1),
            ])]),
            // Rows on a block the readers do not draw as a table are not read.
            LampBookContentBlock(type: "paragraph", content: text("Prose"), rows: [LampBookTableRow(cells: [
                LampBookTableCell(content: text("Stray", [annotation("footnote", 0, 5,
                    LampBookAnnotationData(footnoteID: "n8"))]), column: 0),
            ])]),
        ]

        let index = LampBookSectionIndex(blocks: blocks)

        #expect(index.headings == [
            .init(blockIndex: 0, level: 1, title: "Sin and Death"),
            .init(blockIndex: 2, level: 4, title: "Entry"),
            .init(blockIndex: 3, level: 2, title: "Untitled level"),
        ])
        #expect(index.passages == [
            LampBookPassage(start: 45_003_023),
            LampBookPassage(start: 45_006_023),
            LampBookPassage(start: 43_003_016),
        ])
        #expect(index.footnoteIDs == ["n2", "n1"])
        #expect(index.annotatedTexts.map(\.text) == [
            "  Sin and Death  ", "All have sinned; see John.", "Entry", "Untitled level", "   ",
            "Item", "John again", "Cell", "Prose",
        ])
    }
}

struct LampBookTableLayoutTests {
    private func cell(_ text: String, _ column: Int, span: Int = 1, header: Bool = false) -> LampBookTableCell {
        LampBookTableCell(content: LampBookAnnotatedText(text: text), column: column, columnSpan: span, isHeader: header)
    }

    @Test func theColumnCountComesFromEveryRowNotTheOneBeingLaidOut() {
        let rows = [
            LampBookTableRow(cells: [cell("a", 0)]),
            LampBookTableRow(cells: [cell("b", 0), cell("c", 2)]),
        ]
        #expect(LampBookTableLayout.resolvedColumnCount(declared: nil, rows: rows) == 3)
        #expect(LampBookTableLayout.resolvedColumnCount(declared: 4, rows: rows) == 4)
        #expect(LampBookTableLayout.resolvedColumnCount(declared: nil, rows: []) == 1)
    }

    /// A table is laid out with no more than `maximumColumnCount` columns,
    /// however far a cell reaches.
    ///
    /// A cell whose `column` plus `colSpan` passed the largest integer
    /// stopped any reader that opened its section, and a merely very wide
    /// one had it lay out a gap per empty column, a view each per row.
    @Test func atableIsLaidOutWithinItsBound() {
        let bound = LampBookTableLayout.maximumColumnCount
        let overflowing = [LampBookTableRow(cells: [cell("a", 0), cell("far", 1, span: .max)])]
        #expect(LampBookTableLayout.resolvedColumnCount(declared: nil, rows: overflowing) == bound)
        let distant = [LampBookTableRow(cells: [cell("a", 0), cell("distant", 1_000_000)])]
        #expect(LampBookTableLayout.resolvedColumnCount(declared: nil, rows: distant) == bound)
        #expect(LampBookTableLayout.resolvedColumnCount(declared: .max, rows: []) == bound)

        // A count passed straight in is held to the bound too, so no caller
        // can ask for a row of a million gaps.
        let placements = LampBookTableLayout.placements(of: distant[0], columnCount: 1_000_000)
        #expect(placements.count == bound)
        #expect(placements.compactMap(\.cell).map(\.content.text) == ["a"])
        let spanned = LampBookTableLayout.placements(of: overflowing[0], columnCount: .max)
        #expect(spanned.map(\.span) == [1, bound - 1])
        #expect(LampBookTableLayout.columnWeights(rows: distant, columnCount: .max).count == bound)

        // A cell at a negative column is never placed, so however far its
        // span reaches it does not widen the table. Found by Codex.
        let behind = [LampBookTableRow(cells: [cell("a", 0), cell("b", 1), cell("before", -1, span: 67)])]
        #expect(LampBookTableLayout.resolvedColumnCount(declared: 2, rows: behind) == 2)

        // Real tables are untouched: the widest bundled one reaches 24.
        let wide = [LampBookTableRow(cells: (0..<24).map { cell("c\($0)", $0) })]
        #expect(LampBookTableLayout.resolvedColumnCount(declared: nil, rows: wide) == 24)
    }

    @Test func cellsGoToTheColumnsTheyName() {
        // A cell merged down from the row above is missing from this row. Its
        // neighbours keep their own columns, and so stay under their headings,
        // only because the converter kept each cell's true column: renumbered
        // in turn, they would shift left with nothing to report it.
        let row = LampBookTableRow(cells: [
            cell("Campbell", 1),
            cell("outside", 5),
            cell("second claim", 1),
            cell("wide", 2, span: 4),
        ])
        let placements = LampBookTableLayout.placements(of: row, columnCount: 4)
        #expect(placements.map(\.column) == [0, 1, 2])
        #expect(placements.map(\.span) == [1, 1, 2])
        #expect(placements.map { $0.cell?.content.text } == [nil, "Campbell", "wide"])
    }

    private func spanning(_ text: String, _ column: Int, span: Int = 1, rows: Int) -> LampBookTableCell {
        LampBookTableCell(content: LampBookAnnotatedText(text: text), column: column, columnSpan: span, rowSpan: rows)
    }

    /// A row's placements as (column, span, text or "·" for a gap or "↑n"
    /// for a slot row n's cell covers, rows reached).
    private func shape(_ row: [LampBookTableLayout.Placement]) -> [String] {
        row.map { placement in
            let what = placement.cell?.content.text ?? placement.coveringRow.map { "↑\($0)" } ?? "·"
            return "\(placement.column)+\(placement.span) \(what) \(placement.rowSpan)"
        }
    }

    /// A cell reaches down the rows it says, over its column in each, so a
    /// reader draws it once and the rows below keep their other cells.
    @Test func aCellReachesDownOverTheRowsBelowIt() {
        let rows = [
            LampBookTableRow(cells: [spanning("king", 0, rows: 3), cell("Judah", 1), cell("Israel", 2)]),
            LampBookTableRow(cells: [cell("Asa", 1), cell("Baasha", 2)]),
            LampBookTableRow(cells: [cell("Jehoshaphat", 1), cell("Ahab", 2)]),
        ]
        let grid = LampBookTableLayout.grid(of: rows, columnCount: 3)
        #expect(grid.map(shape) == [
            ["0+1 king 3", "1+1 Judah 1", "2+1 Israel 1"],
            ["0+1 ↑0 1", "1+1 Asa 1", "2+1 Baasha 1"],
            ["0+1 ↑0 1", "1+1 Jehoshaphat 1", "2+1 Ahab 1"],
        ])

        // Across columns and down rows at once.
        let block = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("both", 0, span: 2, rows: 2), cell("c", 2)]),
            LampBookTableRow(cells: [cell("d", 2)]),
            LampBookTableRow(cells: [cell("e", 2)]),
        ], columnCount: 3)
        // And no further than it says, with nothing below to stop it.
        #expect(block.map(shape) == [
            ["0+2 both 2", "2+1 c 1"],
            ["0+2 ↑0 1", "2+1 d 1"],
            ["0+1 · 1", "1+1 · 1", "2+1 e 1"],
        ])

        // Laid out alone, a row knows nothing of the cell above.
        #expect(shape(LampBookTableLayout.placements(of: rows[1], columnCount: 3))
            == ["0+1 · 1", "1+1 Asa 1", "2+1 Baasha 1"])
    }

    /// A blank cell under a span is the placeholder a converter leaves there,
    /// and is covered; a cell with words, or with an annotation, stops the
    /// span above it, so no words are hidden. Both happen in the bundled
    /// books.
    @Test func aSpanCoversBlankCellsAndStopsAboveWords() {
        // A header across seven columns and two rows, with a blank cell left
        // at the last column of the second.
        let header = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("Witnesses", 0, span: 7, rows: 2)]),
            LampBookTableRow(cells: [cell(" ", 6)]),
            LampBookTableRow(cells: [cell("a", 0)]),
        ], columnCount: 7)
        #expect(header.map(shape)[0...1] == [["0+7 Witnesses 2"], ["0+7 ↑0 1"]])

        // A blank cell reaching past the span: covered where the span is, a
        // gap where it is not.
        let past = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("two", 0, span: 2, rows: 2)]),
            LampBookTableRow(cells: [cell("", 1, span: 2)]),
        ], columnCount: 3)
        #expect(past.map(shape) == [["0+2 two 2", "2+1 · 1"], ["0+2 ↑0 1", "2+1 · 1"]])

        // Words under the span: the span stops above them.
        let worded = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("merged", 0, span: 2, rows: 2), cell("x", 2)]),
            LampBookTableRow(cells: [cell("own words", 1), cell("y", 2)]),
        ], columnCount: 3)
        #expect(worded.map(shape) == [
            ["0+2 merged 1", "2+1 x 1"],
            ["0+1 · 1", "1+1 own words 1", "2+1 y 1"],
        ])

        // A cell with no words but a footnote is no placeholder: its marker
        // is drawn.
        let marked = LampBookTableCell(
            content: LampBookAnnotatedText(text: "", annotations: [
                LampBookAnnotation(type: "footnote", start: 0, end: 0, data: nil),
            ]),
            column: 0
        )
        let footnoted = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("merged", 0, rows: 2)]),
            LampBookTableRow(cells: [marked]),
        ], columnCount: 1)
        #expect(footnoted[0][0].rowSpan == 1)
        #expect(footnoted[1][0].cell == marked)

        // Nor is one whose marker is a footnote reference rather than an
        // annotation: the resolver draws both. Found by Codex.
        let referenced = LampBookTableCell(
            content: LampBookAnnotatedText(text: " ", footnoteReferences: [LampBookFootnoteReference(id: "1", offset: 0)]),
            column: 0
        )
        let byReference = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [spanning("merged", 0, rows: 2)]),
            LampBookTableRow(cells: [referenced]),
        ], columnCount: 1)
        #expect(byReference[0][0].rowSpan == 1)
        #expect(byReference[1][0].cell == referenced)

        // Nor one with no text that a legend names, nor an empty header:
        // each is drawn as more than its place. Found by Codex.
        for held in [
            LampBookTableCell(content: LampBookAnnotatedText(text: ""), column: 0, label: "good-king"),
            LampBookTableCell(content: LampBookAnnotatedText(text: ""), column: 0, isHeader: true),
            // A vowel point alone, on a space: one character, whitespace by
            // its first scalar, and drawn. Found by Codex.
            LampBookTableCell(content: LampBookAnnotatedText(text: " \u{05B8}"), column: 0),
        ] {
            let grid = LampBookTableLayout.grid(of: [
                LampBookTableRow(cells: [spanning("merged", 0, rows: 2)]),
                LampBookTableRow(cells: [held]),
            ], columnCount: 1)
            #expect(grid[0][0].rowSpan == 1)
            #expect(grid[1][0].cell == held)
        }
    }

    /// A span stops at the table's end, however many rows it says: one of
    /// the largest integer, below the first row, overflowed counting its last.
    @Test func aSpanStopsAtTheTablesEnd() {
        let grid = LampBookTableLayout.grid(of: [
            LampBookTableRow(cells: [cell("a", 0)]),
            LampBookTableRow(cells: [spanning("all", 0, rows: .max), cell("b", 1)]),
            LampBookTableRow(cells: [cell("c", 1), spanning("last", 2, rows: 5)]),
        ], columnCount: 3)
        #expect(grid.map(shape) == [
            ["0+1 a 1", "1+1 · 1", "2+1 · 1"],
            ["0+1 all 2", "1+1 b 1", "2+1 · 1"],
            ["0+1 ↑1 1", "1+1 c 1", "2+1 last 1"],
        ])
        #expect(LampBookTableLayout.grid(of: [], columnCount: 3).isEmpty)
    }

    /// Over tables made at random: each row covers every column once; a
    /// covered slot sits under the cell that reaches it; and the cells with
    /// words are those each row laid out alone holds, where it holds them —
    /// which search and the section index are built from.
    @Test func theGridKeepsEveryRowsWordsWhereTheRowAlonePutsThem() {
        var seed: UInt64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<2_000 {
            let columnCount = 1 + next(6)
            let rows = (0..<(1 + next(6))).map { _ in
                LampBookTableRow(cells: (0..<next(5)).map { _ in
                    LampBookTableCell(
                        content: LampBookAnnotatedText(text: next(3) == 0 ? "" : "w\(next(100))"),
                        column: next(columnCount + 1) - (next(10) == 0 ? 2 : 0),
                        columnSpan: 1 + next(3),
                        rowSpan: 1 + next(4)
                    )
                })
            }
            let grid = LampBookTableLayout.grid(of: rows, columnCount: columnCount)
            #expect(grid.count == rows.count)
            for (index, line) in grid.enumerated() {
                #expect(line.map(\.column) == line.map(\.column).sorted())
                #expect(line.map(\.span).reduce(0, +) == columnCount, "\(rows)")
                for (placement, nextPlacement) in zip(line, line.dropFirst()) {
                    #expect(placement.column + placement.span == nextPlacement.column, "\(rows)")
                }
                for placement in line {
                    guard let from = placement.coveringRow else { continue }
                    let origin = grid[from].first { $0.column == placement.column && $0.cell != nil }
                    #expect(origin?.span == placement.span)
                    #expect((origin?.rowSpan ?? 0) > index - from, "\(rows)")
                }
                let worded = { (placements: [LampBookTableLayout.Placement]) in
                    placements.compactMap { placement in
                        placement.cell.flatMap { LampBookTableLayout.isBlank($0) ? nil : "\(placement.column)+\(placement.span) \($0.content.text)" }
                    }
                }
                #expect(
                    worded(line) == worded(LampBookTableLayout.placements(of: rows[index], columnCount: columnCount)),
                    "\(rows)"
                )
            }
        }
    }

    @Test func aColumnOfTermsBesideOneOfDefinitionsTakesLessOfTheWidth() throws {
        let rows = [
            LampBookTableRow(cells: [cell("Formal Definitions", 0, span: 2, header: true)]),
            LampBookTableRow(cells: [
                cell("Natural immortality", 0),
                cell(String(repeating: "The soul is a supernatural force. ", count: 6), 1),
            ]),
        ]
        let weights = LampBookTableLayout.columnWeights(rows: rows, columnCount: 2)
        #expect(abs(weights.reduce(0, +) - 1) < 1e-9)
        #expect(weights[0] < weights[1])
        // Not below its floor of 0.6 ÷ 2, before the weights are scaled to 1.
        #expect(weights[0] > 0.2)
        let third: Double = 1.0 / 3
        #expect(LampBookTableLayout.columnWeights(rows: [], columnCount: 3) == [third, third, third])
    }
}

/// A section's searchable words are the words its readers draw, block by
/// block, as `BookModuleView` and `BookModulesView` draw them.
struct LampBookDrawnTextTests {
    private func text(_ json: String) -> String { LampBookDrawnText.text(ofContentJSON: json) }

    @Test func eachBlockGivesTheWordsItsTypeDraws() {
        #expect(text(#"""
        [
          {"type": "heading", "level": 2, "content": {"text": "Heading words"}},
          {"type": "paragraph", "content": {"text": "Paragraph words"}},
          {"type": "blockquote", "content": {"text": "Quoted words"}},
          {"type": "list", "listType": "bullet", "items": [
            {"content": {"text": "First item"}, "children": [{"content": {"text": "Nested item"}}]},
            {"content": {"text": "Second item"}}
          ]},
          {"type": "image", "mediaId": "m1", "caption": "Picture caption"},
          {"type": "audio", "mediaId": "m2", "caption": {"text": "Recording caption"}},
          {"type": "thematic-break"},
          {"type": "callout", "content": {"text": "Unknown kind's words"}}
        ]
        """#) == "Heading words Paragraph words Quoted words First item Nested item Second item Picture caption Recording caption Unknown kind's words")
    }

    /// What a block carries but its type does not draw is not searched: rows
    /// on a paragraph, items on a heading, a caption on a quotation.
    @Test func whatABlocksTypeDoesNotDrawIsNotSearched() {
        #expect(text(#"""
        [
          {"type": "paragraph", "content": {"text": "Shown"},
           "rows": [{"cells": [{"column": 0, "content": {"text": "Stray cell"}}]}],
           "items": [{"content": {"text": "Stray item"}}], "caption": "Stray caption"}
        ]
        """#) == "Shown")
    }

    /// A block the readers cannot decode, and so leave out, is not searched
    /// either.
    @Test func ablockTheReadersCannotReadIsNotSearched() {
        #expect(text(#"""
        [
          {"type": "paragraph", "content": {"text": "Kept"}},
          {"type": "table", "rows": [{"cells": [{"column": 0, "colSpan": 1.5, "content": {"text": "Unreadable"}}]}]},
          {"content": {"text": "No type"}}
        ]
        """#) == "Kept")
    }
}

/// What a figure, a row and a cell bring to the shared block model, and what
/// a reader that knew none of it still reads.
struct LampBookRichBlockTests {
    private func blocks(_ json: String) -> [LampBookContentBlock] {
        LampPortableBookJSON.decodeArray(json, as: LampBookContentBlock.self).items
    }

    @Test func afigureIsReadWithItsParts() throws {
        let figure = try #require(blocks(#"""
        [{"type": "figure", "id": "map-01-02", "role": "map",
          "title": {"text": "The Table of Nations", "annotations": [{"type": "smallcaps", "start": 4, "end": 9}]},
          "subtitle": "c. 2200 B.C.", "caption": {"text": "Peoples descended from Noah."},
          "children": [
            {"type": "image", "mediaId": "m1"},
            {"type": "heading", "level": 4, "id": "part-2", "content": {"text": "Part two"}},
            {"type": "table", "columnCount": 2, "rows": [{"label": "good-king", "cells": [
              {"column": 0, "align": "center", "label": "reign-start", "content": {"text": "Asa"}},
              {"column": 1, "content": {"text": "41 years"}}]}]},
            {"type": "figure", "children": []},
            {"type": "audio", "mediaId": "a1", "caption": "A recording"}
          ],
          "notes": [{"text": "Dates are approximate."}],
          "legend": [{"label": "good-king", "title": "Good"}]}]
        """#).first)
        #expect(figure.id == "map-01-02")
        #expect(figure.role == "map")
        #expect(figure.title?.text == "The Table of Nations")
        #expect(figure.subtitle?.text == "c. 2200 B.C.")
        // A figure inside a figure is never drawn.
        #expect(figure.children.map(\.type) == ["image", "heading", "table"])
        #expect(figure.children[1].id == "part-2")
        // A figure built in code holds what one read does.
        let built = LampBookContentBlock(type: "figure", children: [
            LampBookContentBlock(type: "paragraph", content: LampBookAnnotatedText(text: "Kept")),
            LampBookContentBlock(type: "audio", caption: .plain("Dropped")),
            LampBookContentBlock(type: "figure"),
        ])
        #expect(built.children.map(\.type) == ["paragraph"])
        // Only a figure has children.
        #expect(LampBookContentBlock(type: "paragraph", children: [
            LampBookContentBlock(type: "paragraph", content: LampBookAnnotatedText(text: "Never drawn")),
        ]).children.isEmpty)
        #expect(blocks(#"[{"type": "paragraph", "content": {"text": "p"}, "children": [{"type": "paragraph", "content": {"text": "c"}}]}]"#)
            .first?.children.isEmpty == true)
        let row = try #require(figure.children[2].rows.first)
        #expect(row.label == "good-king")
        #expect(row.cells.first?.alignment == "center")
        #expect(row.cells.first?.label == "reign-start")
        #expect(figure.notes.map(\.text) == ["Dates are approximate."])
        #expect(figure.legend == [LampBookLegendEntry(label: "good-king", title: "Good")])
        // Its own words, as a reader that knows figures draws them …
        #expect(LampBookDrawnText.figureText(of: figure)
            == "The Table of Nations c. 2200 B.C. Peoples descended from Noah. Part two Asa 41 years Dates are approximate. Good")
        // … and its words as the readers draw it today, which know no
        // figures: its `content`, which here it has none of.
        #expect(LampBookDrawnText.text(of: [figure]) == "")
        let projected = try #require(blocks(#"[{"type": "figure", "children": [], "content": {"text": "The words drawn"}}]"#).first)
        #expect(LampBookDrawnText.text(of: [projected]) == "The words drawn")
    }

    /// A new field written wrong is absent, never the loss of the block: an
    /// unknown key never cost one either.
    @Test func amalformedNewFieldCostsNoBlock() throws {
        let read = blocks(#"""
        [{"type": "paragraph", "content": {"text": "Kept"}, "id": 7, "role": [], "title": 3,
          "children": "none", "notes": [{"text": "A note"}, 5], "legend": [{"label": "x"}],
          "rows": [{"label": 1, "cells": [{"column": 0, "align": "diagonal", "label": {}, "content": {"text": "c"}}]}]}]
        """#)
        let block = try #require(read.first)
        #expect(block.content?.text == "Kept")
        #expect(block.id == nil && block.role == nil && block.title == nil && block.children.isEmpty)
        #expect(block.notes.map(\.text) == ["A note"])
        #expect(block.legend.isEmpty)
        #expect(block.rows.first?.label == nil)
        #expect(block.rows.first?.cells.first?.alignment == nil)
        #expect(block.rows.first?.cells.first?.label == nil)
    }

    @Test func smallCapsBoldItalicAndATargetAreResolved() throws {
        let content = LampBookAnnotatedText(text: "the LORD said, see note", annotations: [
            LampBookAnnotation(type: "smallcaps", start: 5, end: 8),
            LampBookAnnotation(type: "bold", start: 0, end: 3),
            LampBookAnnotation(type: "italic", start: 9, end: 13),
            LampBookAnnotation(type: "scripture", start: 15, end: 23, data: LampBookAnnotationData(
                startReference: 1_010_021, endReference: 1_010_032,
                target: LampLinkTarget(startReference: 1_010_021, endReference: 1_010_032)
            )),
        ])
        let resolved = LampBookTextResolver.resolve(content, footnoteNumbers: [:], containingKind: "commentary")
        func runs<T: AttributedStringKey>(_ key: KeyPath<AttributeScopes.LampBookAttributes, T>) -> [String] where T.Value: Equatable {
            resolved.runs.compactMap { run in run.attributes[T.self] == nil ? nil : String(resolved[run.range].characters) }
        }
        #expect(runs(\.bookSmallCaps) == ["ORD"])
        // The note on the passage, in an attribute of its own beside it.
        #expect(runs(\.bookScriptureTarget) == ["see note"])
        #expect(runs(\.bookLinkTarget).isEmpty)
        // The passage is kept for a reader that knows no targets.
        #expect(runs(\.bookScripture) == ["see note"])
        // A target on any other type is not followed: overlapping a scripture
        // link, it would send the reader elsewhere.
        let stray = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "words", annotations: [
            LampBookAnnotation(type: "emphasis", start: 0, end: 5, data: LampBookAnnotationData(
                target: LampLinkTarget(startReference: 1_001_001)
            )),
        ]), footnoteNumbers: [:])
        #expect(stray.runs.allSatisfy { $0.attributes[LampBookTextAttributes.LinkTarget.self] == nil })
        let intents = resolved.runs.compactMap { run in
            run.inlinePresentationIntent.map { (String(resolved[run.range].characters), $0) }
        }
        #expect(intents.contains { $0.0 == "the" && $0.1.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.0 == "said" && $0.1.contains(.emphasized) })
    }
}

/// Each target names exactly one place, read in the module it is in.
struct LampLinkTargetTests {
    private func target(_ json: String) throws -> LampLinkTarget {
        try JSONDecoder().decode(LampLinkTarget.self, from: Data(json.utf8))
    }

    @Test func eachShapeHasOneRoute() throws {
        #expect(try target(#"{"sv": 1001001, "ev": 1011026, "unit": "outline-1001001-1011026", "anchor": "chart-01-02"}"#)
            .destination(in: "commentary")
            == .commentaryPassage(start: 1_001_001, end: 1_011_026, suffix: nil, unit: "outline-1001001-1011026", anchor: "chart-01-02"))
        #expect(try target(#"{"kind": "commentary", "module": "ESVSB", "book": 1, "section": "introduction-to-genesis"}"#)
            .destination(in: "book")
            == .commentaryFrontMatter(book: 1, section: "introduction-to-genesis", anchor: nil))
        #expect(try target(#"{"section": "preface", "anchor": "p2"}"#).destination(in: "book")
            == .bookSection(section: "preface", anchor: "p2"))
    }

    /// A target mixing routes, or one the module it is in cannot hold, names
    /// none.
    @Test func amixedOrMisplacedTargetNamesNone() throws {
        for (json, kind) in [
            (#"{"sv": 1001001, "section": "intro"}"#, "commentary"),
            (#"{"section": "intro"}"#, "commentary"),
            (#"{"kind": "book", "sv": 1001001, "section": "s"}"#, "commentary"),
            (#"{"book": 1, "section": "s", "unit": "u"}"#, "commentary"),
            (#"{"section": "s", "book": 1}"#, "book"),
            (#"{"sv": 1001001}"#, "translation"),
            // Another module's kind is not assumed to be this one's …
            (#"{"module": "another", "section": "intro"}"#, "book"),
            // … and a kind other than this module's names another module,
            // which must be named.
            (#"{"kind": "commentary", "sv": 1001001}"#, "book"),
            // Addresses out of bounds.
            (#"{"kind": "commentary", "module": "C", "book": 67, "section": "s"}"#, "book"),
            (#"{"sv": 0}"#, "commentary"),
            (#"{"sv": 67001001}"#, "commentary"),
            // A range that ends before it begins.
            (#"{"sv": 1002001, "ev": 1001001}"#, "commentary"),
        ] {
            #expect(try target(json).destination(in: kind) == nil, "\(json) in \(kind)")
        }
    }

    /// A module or kind written wrong names nowhere, rather than this module,
    /// and on an annotation is no target at all, so writing it again cannot
    /// turn it into one.
    @Test func amalformedAddressNamesNowhere() throws {
        // Read on its own it is no target, and so cannot be written again
        // as one.
        #expect(throws: DecodingError.self) { try target(#"{"kind": "book", "module": 42, "section": "preface"}"#) }
        #expect(throws: DecodingError.self) { try target(#"{"kind": 3, "section": "preface"}"#) }
        let data = try JSONDecoder().decode(
            LampBookAnnotationData.self,
            from: Data(#"{"sv": 1001001, "target": {"kind": "book", "module": 42, "section": "preface"}}"#.utf8)
        )
        #expect(data.target == nil)
        #expect(data.startReference == 1_001_001)
        // Empty, built in code, is written wrong, and names nowhere — not the
        // note or section it would be without it.
        #expect(LampLinkTarget(kind: "commentary", module: "", startReference: 1_001_001).destination(in: "book") == nil)
        #expect(LampLinkTarget(section: "").destination(in: "book") == nil)
        #expect(LampLinkTarget(startReference: 1_001_001, unit: "").destination(in: "commentary") == nil)
        #expect(LampLinkTarget(section: "preface", anchor: "").destination(in: "book") == nil)
    }

    /// Overlapping links keep each address with its own target.
    @Test func overlappingLinksKeepTheirOwnTargets() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "read here", annotations: [
            LampBookAnnotation(type: "link", start: 0, end: 9, data: LampBookAnnotationData(
                target: LampLinkTarget(section: "preface")
            )),
            LampBookAnnotation(type: "link", start: 5, end: 9, data: LampBookAnnotationData(url: "https://example.com")),
        ]), footnoteNumbers: [:])
        for run in resolved.runs {
            let words = String(resolved[run.range].characters)
            let target = run.attributes[LampBookTextAttributes.LinkTarget.self]
            if words == "here" {
                #expect(run.link?.absoluteString == "https://example.com" && target == nil)
            } else {
                #expect(run.link == nil && target?.section == "preface")
            }
        }
    }

    /// A scripture link's note and a URL link overlapping keep their own
    /// pairs: the URL does not clear the note beside its passage.
    @Test func ascriptureNoteAndAURLKeepTheirOwnPairs() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "see here", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 8, data: LampBookAnnotationData(
                startReference: 1_001_001, target: LampLinkTarget(startReference: 1_001_001)
            )),
            LampBookAnnotation(type: "link", start: 4, end: 8, data: LampBookAnnotationData(url: "https://example.com")),
        ]), footnoteNumbers: [:], containingKind: "commentary")
        #expect(resolved.runs.allSatisfy {
            $0.attributes[LampBookTextAttributes.ScriptureTarget.self]?.startReference == 1_001_001
                && $0.attributes[LampBookTextAttributes.Scripture.self]?.start == 1_001_001
        })
    }

    /// A target judged in the module the text is in: in a book a passage
    /// alone names no place, and replaces no working address.
    @Test func atargetIsJudgedWhereItIs() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "read here", annotations: [
            LampBookAnnotation(type: "link", start: 0, end: 9, data: LampBookAnnotationData(url: "https://example.com")),
            LampBookAnnotation(type: "link", start: 5, end: 9, data: LampBookAnnotationData(
                target: LampLinkTarget(startReference: 1_001_001)
            )),
        ]), footnoteNumbers: [:])
        #expect(resolved.runs.allSatisfy { $0.link?.absoluteString == "https://example.com" })
    }

    /// A scripture annotation's own passage must be one a reader can open,
    /// or its note is not followed either.
    @Test func ascriptureNoteNeedsAPassageToFallBackTo() {
        let annotation = LampBookAnnotation(type: "scripture", start: 0, end: 3, data: LampBookAnnotationData(
            startReference: 43_000_001, target: LampLinkTarget(startReference: 43_003_016)
        ))
        #expect(LampBookTextResolver.usableTarget(for: annotation, containingKind: "commentary") == nil)
    }

    /// A scripture annotation's note is a commentary passage's, never a
    /// section: it would open somewhere the verses do not.
    @Test func ascripturesNoteIsAPassage() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "see", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 3, data: LampBookAnnotationData(
                startReference: 1_001_001, target: LampLinkTarget(section: "preface")
            )),
        ]), footnoteNumbers: [:])
        #expect(resolved.runs.allSatisfy {
            $0.attributes[LampBookTextAttributes.ScriptureTarget.self] == nil
                && $0.attributes[LampBookTextAttributes.Scripture.self]?.start == 1_001_001
        })
    }

    /// A target that names no place replaces no working address.
    @Test func atargetNamingNoPlaceReplacesNothing() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "read here", annotations: [
            LampBookAnnotation(type: "link", start: 0, end: 9, data: LampBookAnnotationData(url: "https://example.com")),
            LampBookAnnotation(type: "link", start: 5, end: 9, data: LampBookAnnotationData(target: LampLinkTarget())),
        ]), footnoteNumbers: [:])
        #expect(resolved.runs.allSatisfy { $0.link?.absoluteString == "https://example.com" })
        #expect(resolved.runs.allSatisfy { $0.attributes[LampBookTextAttributes.LinkTarget.self] == nil })
    }

    /// Overlapping scripture annotations keep each passage with its own
    /// target: a later one without a target clears the earlier one's.
    @Test func overlappingPassagesKeepTheirOwnTargets() {
        let resolved = LampBookTextResolver.resolve(LampBookAnnotatedText(text: "see both", annotations: [
            LampBookAnnotation(type: "scripture", start: 0, end: 8, data: LampBookAnnotationData(
                startReference: 1_001_001, target: LampLinkTarget(startReference: 1_001_001)
            )),
            LampBookAnnotation(type: "scripture", start: 4, end: 8, data: LampBookAnnotationData(startReference: 2_001_001)),
        ]), footnoteNumbers: [:], containingKind: "commentary")
        for run in resolved.runs {
            let words = String(resolved[run.range].characters)
            let target = run.attributes[LampBookTextAttributes.ScriptureTarget.self]
            let passage = run.attributes[LampBookTextAttributes.Scripture.self]
            if words == "both" {
                #expect(passage?.start == 2_001_001 && target == nil, "\(words)")
            } else {
                #expect(passage?.start == 1_001_001 && target?.startReference == 1_001_001, "\(words)")
            }
        }
    }

    /// Any field written wrong makes no target: read as absent, a wrong `ev`
    /// or `unit` picked a different note at the same verse.
    @Test func amistypedFieldMakesNoTarget() throws {
        for json in [
            #"{"sv": 1001001, "ev": "1011026"}"#,
            #"{"sv": 1001001, "unit": 7}"#,
            #"{"section": "preface", "anchor": 4}"#,
            #"{"section": ""}"#,
        ] {
            #expect(throws: DecodingError.self, "\(json)") { try target(json) }
        }
        // But an empty suffix is none, as the compiler stores it — read, and
        // built in code, so a round trip means the same.
        #expect(try target(#"{"sv": 1001001, "suffix": ""}"#).suffix == nil)
        let built = LampLinkTarget(suffix: "", section: "preface")
        let reread = try JSONDecoder().decode(LampLinkTarget.self, from: JSONEncoder().encode(built))
        #expect(built.destination(in: "book") == reread.destination(in: "book"))
    }
}


/// A 2.3 commentary's blocks as the one annotated text an older reader
/// shows (`LampBookDrawnText.projection`), held to the resolver: resolving
/// the projection draws what resolving each of its texts and joining them
/// would.
struct LampBookProjectionTests {
    private func blocks(_ json: String) -> [LampBookContentBlock] {
        LampPortableBookJSON.decodeArray(json, as: LampBookContentBlock.self).items
    }

    /// Every type of block, an annotation of each kind and a footnote marker
    /// in each text; a pointed Hebrew word and an astral letter before an
    /// annotation, so an offset counted in Characters or in UTF-16 is caught;
    /// a span and a marker past their text's end; and pages at both ends.
    private let fixture = #"""
    [
      {"type": "heading", "level": 2, "content": {"text": "Chapter one", "footnote_refs": [{"id": "1", "offset": 7}]}},
      {"type": "paragraph", "content": {"text": "שָׁלוֹם and 𝔊race abounding", "annotations": [
        {"type": "bold", "start": 12, "end": 17},
        {"type": "emphasis", "start": 18, "end": 999, "data": {"style": "italic"}},
        {"type": "page", "start": 0, "end": 0, "data": {"pageNum": 12}},
        {"type": "page", "start": 999, "end": 999, "data": {"pageNum": 13}},
        {"type": "smallcaps", "start": -1, "end": 3}
      ], "footnote_refs": [{"id": "2", "offset": 999}, {"id": "1", "offset": -5}]}},
      {"type": "paragraph", "content": {"text": "See John 3:16 and the note", "annotations": [
        {"type": "scripture", "start": 4, "end": 13, "data": {"sv": 43003016, "target": {"sv": 43003016}}},
        {"type": "link", "start": 18, "end": 26, "data": {"target": {"kind": "commentary", "module": "N", "sv": 43003017}}},
        {"type": "footnote", "start": 22, "end": 26, "data": {"footnoteId": "1"}}
      ]}},
      {"type": "paragraph", "content": {"text": ""}},
      {"type": "paragraph", "content": {"text": "x\u0000y", "annotations": [{"type": "page", "start": 1, "end": 1, "data": {"pageNum": 7}}]}},
      {"type": "thematic-break"},
      {"type": "list", "listType": "bullet", "items": [
        {"content": {"text": "First item", "annotations": [{"type": "italic", "start": 0, "end": 5}]},
         "children": [{"content": {"text": "Nested", "footnote_refs": [{"id": "2", "offset": 6}]}}]},
        {"content": {"text": "Second"}}
      ]},
      {"type": "table", "columnCount": 2, "rows": [
        {"cells": [{"column": 0, "header": true, "content": {"text": "King"}}, {"column": 1, "content": {"text": "Years", "annotations": [{"type": "bold", "start": 0, "end": 5}]}}]},
        {"cells": [{"column": 1, "content": {"text": "41", "footnote_refs": [{"id": "1", "offset": 2}]}}]},
        {"cells": [{"column": 0, "content": {"text": "Asa"}}, {"column": 1, "content": {"text": "911–910\r\n910–870", "annotations": [{"type": "page", "start": 8, "end": 8, "data": {"pageNum": 9}}, {"type": "bold", "start": 9, "end": 16}]}}]}
      ]},
      {"type": "image", "mediaId": "m", "caption": {"text": "A map", "annotations": [{"type": "italic", "start": 2, "end": 5}]}},
      {"type": "figure", "id": "f", "title": "Kings of Judah", "subtitle": {"text": "931–586 BC"},
       "caption": {"text": "From Rehoboam", "annotations": [{"type": "bold", "start": 5, "end": 13}]},
       "children": [
         {"type": "paragraph", "content": {"text": "Intro"}},
         {"type": "table", "columnCount": 1, "rows": [{"cells": [{"column": 0, "content": {"text": "Asa"}}]}]}
       ],
       "notes": [{"text": "See also Israel", "annotations": [{"type": "italic", "start": 9, "end": 15}]}]}
    ]
    """#

    @Test func resolvingTheProjectionDrawsWhatResolvingEachTextDoes() {
        let numbers = ["1": 1, "2": 2]
        let blocks = blocks(fixture)
        #expect(blocks.count == 10)
        for figures in [LampBookDrawnText.Figures.asParts, .asContent] {
            let projection = LampBookDrawnText.projection(of: blocks, figures: figures)
            var expected = AttributedString()
            let empty = LampBookAnnotatedText(text: "")
            let drawn = blocks
                .map { block in
                    LampBookDrawnText.lines(of: block, figures: figures)
                        .map { line in line.filter { $0.text != empty } }
                        .filter { !$0.isEmpty }
                }
                .filter { !$0.isEmpty }
            for (blockIndex, lines) in drawn.enumerated() {
                if blockIndex > 0 { expected += AttributedString(LampBookDrawnText.blockSeparator) }
                for (lineIndex, line) in lines.enumerated() {
                    if lineIndex > 0 { expected += AttributedString(LampBookDrawnText.lineSeparator) }
                    var column = 0
                    for field in line {
                        for _ in 0..<max(field.column - column, 0) {
                            expected += AttributedString(LampBookDrawnText.cellSeparator)
                        }
                        column = field.column
                        let text = field.isCell
                            ? LampBookAnnotatedText(
                                text: LampBookDrawnText.onOneLine(field.text.text),
                                annotations: field.text.annotations, footnoteReferences: field.text.footnoteReferences
                            )
                            : field.text
                        expected += LampBookTextResolver.resolve(text, footnoteNumbers: numbers, containingKind: "commentary")
                    }
                }
            }
            let resolved = LampBookTextResolver.resolve(projection, footnoteNumbers: numbers, containingKind: "commentary")
            #expect(resolved == expected, "\(figures)")
            #expect(String(resolved.characters) == String(expected.characters), "\(figures)")
            // The markers and attributes are there to compare: pages at both
            // ends, footnotes, a link's target, a passage's note.
            let drawnText = String(resolved.characters)
            #expect(drawnText.contains("[p. 12]") && drawnText.contains("[p. 13]"), "\(drawnText)")
            #expect(drawnText.contains("[1]") && drawnText.contains("[2]"))
            #expect(resolved.runs.contains { $0.bookLinkTarget != nil })
            #expect(resolved.runs.contains { $0.bookScriptureTarget != nil })
        }
        // Its words are the words search takes, as today's readers draw them,
        // once a NUL is a space, as search text makes it, and with the
        // columns' visible separators taken out.
        let words = { (text: String) in
            text.replacingOccurrences(of: "\0", with: " ")
                .replacingOccurrences(of: LampBookDrawnText.cellSeparator, with: " ")
                .split(whereSeparator: \.isWhitespace)
        }
        #expect(words(LampBookDrawnText.projection(of: blocks, figures: .asContent).text)
            == words(LampBookDrawnText.text(of: blocks)))
    }

    /// An offset from a file, however far out, is clipped before it is
    /// moved, so none is added to and none traps.
    @Test func noOffsetFromAFileIsAddedToBeforeItIsClipped() {
        let blocks = blocks(#"""
        [{"type": "paragraph", "content": {"text": "before"}},
         {"type": "paragraph", "content": {"text": "words", "annotations": [
           {"type": "bold", "start": 9223372036854775807, "end": 9223372036854775807},
           {"type": "bold", "start": -9223372036854775808, "end": 9223372036854775807},
           {"type": "italic", "start": 0, "end": 9223372036854775807},
           {"type": "page", "start": 9223372036854775807, "end": 0, "data": {"pageNum": 2}}
         ], "footnote_refs": [{"id": "1", "offset": 9223372036854775807}, {"id": "1", "offset": -9223372036854775808}]}}]
        """#)
        let projection = LampBookDrawnText.projection(of: blocks, figures: .asParts)
        #expect(projection.text == "before\n\nwords")
        #expect(projection.annotations.map { "\($0.type) \($0.start)-\($0.end)" } == ["italic 8-13", "page 13-13"])
        // A sparse row keeps its words under their headings; its empty
        // fields after the last are dropped. Found by Codex.
        let table = LampBookDrawnText.projection(of: self.blocks(#"""
        [{"type": "table", "columnCount": 4, "rows": [
          {"cells": [{"column": 0, "content": {"text": "King"}}, {"column": 1, "content": {"text": "Years"}}, {"column": 2, "colSpan": 2, "content": {"text": "Notes"}}]},
          {"cells": [{"column": 1, "content": {"text": "41"}}, {"column": 3, "content": {"text": "x"}}]},
          {"cells": [{"column": 0, "content": {"text": ""}}]},
          {"cells": [{"column": 0, "content": {"text": "Asa"}}]}
        ]}]
        """#), figures: .asParts)
        let bar = LampBookDrawnText.cellSeparator
        #expect(table.text == "King\(bar)Years\(bar)Notes\n\(bar)41\(bar)\(bar)x\nAsa")
        #expect(bar == " \u{200E}│\u{200E} ")
        // A break in a cell keeps the row on one line, offsets unmoved; one
        // in a paragraph is kept.
        let broken = LampBookDrawnText.projection(of: self.blocks(#"""
        [{"type": "table", "rows": [{"cells": [{"column": 0, "content": {"text": "a\nb", "annotations": [{"type": "bold", "start": 2, "end": 3}]}}, {"column": 1, "content": {"text": "Faith | Hope"}}]}]},
         {"type": "paragraph", "content": {"text": "d\ne"}},
         {"type": "list", "items": [{"content": {"text": "f\ng"}}, {"content": {"text": "h"}}]}]
        """#), figures: .asParts)
        #expect(broken.text == "a b\(LampBookDrawnText.cellSeparator)Faith | Hope\n\nd\ne\n\nf g\nh")
        #expect(broken.annotations.map(\.start) == [2])
        // A page covering its printed label keeps the span, clipped, with or
        // without a page number.
        let labelled = LampBookDrawnText.projection(of: self.blocks(#"""
        [{"type": "paragraph", "content": {"text": "x"}},
         {"type": "paragraph", "content": {"text": "[12] words", "annotations": [{"type": "page", "start": 0, "end": 4, "data": {"pageNum": 12}}, {"type": "page", "start": 6, "end": 99}]}}]
        """#), figures: .asParts)
        #expect(labelled.annotations.map { "\($0.start)-\($0.end)" } == ["3-7", "9-13"])
        #expect(projection.footnoteReferences.map(\.offset) == [13, 8])
    }

    /// One object, as an older phone decodes `commentary_json`: an array
    /// showed a blank note. A NUL is kept, for the resolver to space a
    /// marker beside as it does in the text alone.
    @Test func theProjectionIsOneTextAndANulIsASpace() throws {
        let blocks = blocks(#"[{"type": "paragraph", "content": {"text": "a\u0000b", "annotations": [{"type": "bold", "start": 2, "end": 3}]}}, {"type": "paragraph", "content": {"text": "c"}}]"#)
        let projection = LampBookDrawnText.projection(of: blocks, figures: .asParts)
        #expect(projection.text == "a\0b\n\nc")
        #expect(projection.annotations.map(\.start) == [2])
        let json = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        #expect(json.hasPrefix("{"))
        // Only the annotations it is told to keep.
        let plain = LampBookDrawnText.projection(of: blocks, figures: .asParts) { $0.type != "bold" }
        #expect(plain.annotations.isEmpty)

        // A text with nothing left once filtered and clipped adds no break;
        // one left with a marker keeps its place. Found by Codex.
        let around = self.blocks(#"""
        [{"type": "paragraph", "content": {"text": "before"}},
         {"type": "paragraph", "content": {"text": "", "annotations": [{"type": "page", "start": 0, "end": 0, "data": {"pageNum": 4}}]}},
         {"type": "paragraph", "content": {"text": "", "annotations": [{"type": "bold", "start": 0, "end": 1}]}},
         {"type": "paragraph", "content": {"text": "", "annotations": [{"type": "page", "start": 0, "end": 0, "data": {"pageNum": ""}}]}},
         {"type": "paragraph", "content": {"text": "", "annotations": [{"type": "page", "start": 0, "end": 0}]}},
         {"type": "paragraph", "content": {"text": "after"}}]
        """#)
        #expect(LampBookDrawnText.projection(of: around, figures: .asParts) { $0.type != "page" }.text == "before\n\nafter")
        let paged = LampBookDrawnText.projection(of: around, figures: .asParts)
        #expect(paged.text == "before\n\n\n\nafter")
        #expect(paged.annotations.map { "\($0.type) \($0.start)" } == ["page 8"])
    }
}
