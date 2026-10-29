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
            annotation("page", 0, 0, LampBookAnnotationData(pageNumber: "41")),
        ])

        let value = LampBookTextResolver.resolve(content, footnoteNumbers: [:])

        #expect(runs(of: LampBookTextAttributes.Scripture.self, in: value).map { $0.0 } == ["beginning"])
        // Page numbers are the PDF's, not the printed page's: no marker.
        #expect(String(value.characters) == "In the beginning")
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
            "Item", "John again", "Cell",
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
