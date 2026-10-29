import Foundation
import LampModuleKit

/// A chart on a slide, drawn from what the library says rather than from
/// numbers someone typed.
///
/// A deck names what to chart: a Strong's key in a translation over a run of
/// books, grouped by book, section, rendering or form, counted as occurrences
/// or per thousand words, and drawn as bars, columns, a grid or a share. Lamp
/// works out `values` when the deck is built and stores them, so an agent can
/// put a chart on a slide without inventing its figures, a device without
/// that translation still draws it, and a check against the library reports
/// one that has gone stale.
public struct LampPresentationChart: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        /// A Strong's key, such as G26.
        public var strongs: String
        public var translationID: String
        /// A run of whole books — "NT", "Romans", "Matthew-John" — or the whole
        /// translation when absent.
        public var range: String?

        public init(strongs: String, translationID: String, range: String? = nil) {
            self.strongs = strongs
            self.translationID = translationID
            self.range = range
        }
    }

    public enum Grouping: String, Codable, CaseIterable, Identifiable, Sendable {
        case book
        case section
        case rendering
        case form

        public var id: String { rawValue }
    }

    public enum Measure: String, Codable, CaseIterable, Identifiable, Sendable {
        case occurrences
        case perThousandWords

        public var id: String { rawValue }
    }

    /// How the values are drawn.
    ///
    /// `columns` stand in canonical order, every book in range among them, so
    /// where a word gathers shows as a shape. `grid` shades each book's
    /// chapters. `share` is a ring of the whole, largest first.
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case bars
        case columns
        case grid
        case share

        public var id: String { rawValue }

        /// A style this app does not know reads as bars, so a deck written by
        /// a newer app still opens rather than failing as a whole.
        public init(from decoder: Decoder) throws {
            self = Style(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bars
        }
    }

    public struct Value: Codable, Equatable, Sendable {
        public var label: String
        public var value: Double
        /// `more` or `fewer` for a book or section holding a count chance does
        /// not explain; absent otherwise.
        public var standing: LampStrongsAnalysis.Expectation?
        /// A grid row's chapters, from chapter 1, measured as the chart is.
        public var chapters: [Double]?

        public init(
            label: String,
            value: Double,
            standing: LampStrongsAnalysis.Expectation? = nil,
            chapters: [Double]? = nil
        ) {
            self.label = label
            self.value = value
            self.standing = standing
            self.chapters = chapters
        }
    }

    /// Renderings and forms are ranked, and a chart shows the commonest.
    public static let rankedLimit = 8
    /// Past this many bars a chart is hard to read from the back of a room.
    public static let readableBars = 24
    /// Past this many books a grid's rows are too thin to read.
    public static let readableGridRows = 40
    /// A share shows this many slices at most, the smallest gathered into one.
    public static let shareSlices = 8

    public var source: Source
    public var by: Grouping
    public var measure: Measure
    /// Absent, the chart is bars.
    public var style: Style?
    /// Written by Lamp, never by hand.
    public var values: [Value]?

    public init(
        source: Source,
        by: Grouping,
        measure: Measure = .occurrences,
        style: Style? = nil,
        values: [Value]? = nil
    ) {
        self.source = source
        self.by = by
        self.measure = measure
        self.style = style
        self.values = values
    }

    public var drawnStyle: Style { style ?? .bars }

    /// Whether values print as whole counts. A share is always of occurrences:
    /// rates per thousand words do not add up to a whole.
    public var countsOccurrences: Bool { measure == .occurrences || drawnStyle == .share }

    /// The values an analysis gives this chart.
    ///
    /// As bars, a book appears when the key occurs there, or when its absence
    /// is itself notable: ἀγαπάω never in Acts is part of the picture. As
    /// columns or a grid every book in range appears, because the gaps are the
    /// shape. Sections appear whole, empty ones included, because there are
    /// few of them. A share is of occurrences, largest first, with everything
    /// past its last slice gathered as "Others" so the ring is the whole.
    public func values(from analysis: LampStrongsAnalysis) -> [Value] {
        func measured(_ count: Int, of words: Int) -> Double {
            guard measure == .perThousandWords else { return Double(count) }
            guard words > 0 else { return 0 }
            return (Double(count) * 100_000 / Double(words)).rounded() / 100
        }
        func standing(_ division: LampStrongsAnalysis.Division) -> LampStrongsAnalysis.Expectation? {
            division.expectation == .asExpected ? nil : division.expectation
        }
        if drawnStyle == .share { return shareValues(from: analysis) }
        switch by {
        case .book where drawnStyle == .grid:
            return analysis.books.map { book in
                let chapters = Dictionary(uniqueKeysWithValues: book.chapters.map { ($0.number, $0) })
                let last = chapters.keys.max() ?? 0
                return .init(
                    label: book.name,
                    value: measured(book.occurrenceCount, of: book.wordCount),
                    standing: standing(book),
                    chapters: last > 0
                        ? (1...last).map { chapters[$0].map { measured($0.occurrenceCount, of: $0.wordCount) } ?? 0 }
                        : []
                )
            }
        case .book:
            return analysis.books
                .filter { drawnStyle == .columns || $0.occurrenceCount > 0 || $0.expectation != .asExpected }
                .map { .init(label: $0.name, value: measured($0.occurrenceCount, of: $0.wordCount), standing: standing($0)) }
        case .section:
            return analysis.sections.map {
                .init(label: $0.name, value: measured($0.occurrenceCount, of: $0.wordCount), standing: standing($0))
            }
        case .rendering:
            return analysis.renderings.prefix(Self.rankedLimit).map {
                .init(label: $0.text.isEmpty ? "(no English)" : $0.text, value: measured($0.count, of: analysis.wordCount))
            }
        case .form:
            return analysis.forms.prefix(Self.rankedLimit).map {
                .init(label: $0.text, value: measured($0.count, of: analysis.wordCount))
            }
        }
    }

    private func shareValues(from analysis: LampStrongsAnalysis) -> [Value] {
        let counts: [(label: String, count: Int)] = switch by {
        case .book: analysis.books.map { ($0.name, $0.occurrenceCount) }
        case .section: analysis.sections.map { ($0.name, $0.occurrenceCount) }
        case .rendering: analysis.renderings.map { ($0.text.isEmpty ? "(no English)" : $0.text, $0.count) }
        case .form: analysis.forms.map { ($0.text, $0.count) }
        }
        let ranked = counts.filter { $0.count > 0 }.sorted { ($1.count, $0.label) < ($0.count, $1.label) }
        guard ranked.count > Self.shareSlices else {
            return ranked.map { .init(label: $0.label, value: Double($0.count)) }
        }
        let others = ranked.dropFirst(Self.shareSlices - 1).reduce(0) { $0 + $1.count }
        return ranked.prefix(Self.shareSlices - 1).map { .init(label: $0.label, value: Double($0.count)) }
            + [.init(label: "Others", value: Double(others))]
    }

    /// A value as the chart prints it.
    public func formatted(_ value: Double) -> String {
        countsOccurrences
            ? String(Int(value.rounded()))
            : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// A book's name short enough to stand under a narrow column: its OSIS
    /// abbreviation, or the label as it is when it names no book.
    public static func abbreviated(_ label: String) -> String {
        LampCanonicalBooks.book(named: label)?.osisID ?? label
    }

    /// What a listener hears in place of the bars.
    public var spokenDescription: String {
        let what = "\(source.strongs) in \(source.translationID)"
            + (source.range.map { ", \($0)" } ?? "")
            + (measure == .perThousandWords ? ", per thousand words" : "")
        guard let values, !values.isEmpty else { return "Chart of \(what)" }
        let total = values.reduce(0) { $0 + $1.value }
        let bars = values.map { value in
            let note = switch value.standing {
            case .more: ", more than expected"
            case .fewer: ", fewer than expected"
            default: ""
            }
            let share = drawnStyle == .share && total > 0
                ? ", \(Int((value.value * 100 / total).rounded())) percent" : ""
            return "\(value.label) \(formatted(value.value))\(share)\(note)"
        }
        return "Chart of \(what): " + bars.joined(separator: "; ")
    }
}

/// Every chart in a deck with its values worked out, and what could not be.
public struct LampPresentationChartReport: Equatable, Sendable {
    /// The deck with each chart that could be worked out carrying its values.
    public var deck: LampPresentationDeck
    public var issues: [LampPresentationDeckIssue]
    /// Whether any chart's values changed.
    public var changed: Bool

    public init(deck: LampPresentationDeck, issues: [LampPresentationDeckIssue], changed: Bool) {
        self.deck = deck
        self.issues = issues
        self.changed = changed
    }
}

public extension LampLibrary {
    /// `chart`'s values from this library, or nil when its translation is not
    /// installed or does not tag the key's language in range.
    func chartValues(_ chart: LampPresentationChart) throws -> [LampPresentationChart.Value]? {
        let books = try chart.source.range.map(LampReferenceParser.books)
        return try strongsAnalyses(
            key: chart.source.strongs,
            moduleIDs: [chart.source.translationID],
            bookRange: books
        ).first.map(chart.values(from:))
    }

    /// Works out every chart in `deck` again. A deck being built takes the
    /// report's `deck`; a deck only being checked reads its issues, which name
    /// a chart whose stored values no longer match the library. A chart this
    /// library cannot work out keeps the values it carries.
    func workingOutCharts(in deck: LampPresentationDeck) -> LampPresentationChartReport {
        var result = deck
        var issues: [LampPresentationDeckIssue] = []
        var changed = false
        for (slideIndex, slide) in deck.slides.enumerated() {
            for (blockIndex, block) in slide.blocks.enumerated() {
                guard block.kind == .chart, let chart = block.chart else { continue }
                let path = "slides[\(slideIndex)].blocks[\(blockIndex)].chart"
                let named = "\(chart.source.strongs) in \(chart.source.translationID)"
                // An unreadable range is the validator's to report.
                guard let worked = try? chartValues(chart) else {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).source",
                        message: chart.values == nil
                            ? "This library has no tagged \(chart.source.translationID) to work out "
                                + "\(named) from, so the chart draws empty."
                            : "This library has no tagged \(chart.source.translationID) to check "
                                + "\(named) against; the chart draws the values it carries."
                    ))
                    continue
                }
                if worked.isEmpty {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).source",
                        message: "\(named) has nothing to chart in this range."
                    ))
                }
                guard worked != chart.values else { continue }
                if chart.values != nil {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).values",
                        message: "The values no longer match \(chart.source.translationID) "
                            + "in this library. Building the deck updates them."
                    ))
                }
                result.slides[slideIndex].blocks[blockIndex].chart?.values = worked
                changed = true
            }
        }
        return LampPresentationChartReport(deck: result, issues: issues, changed: changed)
    }
}
