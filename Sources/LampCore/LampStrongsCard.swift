import Foundation

/// One figure the Analyse card can print in a slot.
///
/// Nothing here reads the library: every figure comes off an analysis that
/// has already been worked out, so changing a slot costs a redraw and no
/// counting. That is what makes the slots worth choosing at all.
public enum LampStrongsCardFigure: String, Codable, CaseIterable, Identifiable, Sendable {
    case occurrences
    case verses
    case books
    case chapters
    case sections
    case perThousandWords
    case differentWords
    case forms
    case commonest

    public var id: String { rawValue }

    /// Short enough to stand over a large number without wrapping.
    public var title: String {
        switch self {
        case .occurrences: "Occurrences"
        case .verses: "Verses"
        case .books: "Books"
        case .chapters: "Chapters"
        case .sections: "Sections"
        case .perThousandWords: "Per 1,000 Words"
        case .differentWords: "Different Words"
        case .forms: "Forms"
        case .commonest: "Commonest"
        }
    }

    /// What the figure counts, for the chooser and the tile's tooltip. A
    /// number this size is read at a glance and guessed at, so each one says
    /// what its denominator is where it has one.
    public var note: String {
        switch self {
        case .occurrences:
            "How many times the translation tags the word."
        case .verses:
            "Verses holding it at least once."
        case .books:
            "Books holding it, of the books in range that tag its language."
        case .chapters:
            "Chapters holding it, of the chapters in those books."
        case .sections:
            "Divisions of the canon holding it, of those in range."
        case .perThousandWords:
            "How often it occurs for every thousand tagged words — a rate, "
                + "so a long book and a short one can be compared."
        case .differentWords:
            "How many different words the translation uses for it."
        case .forms:
            "How many spellings it takes in the original."
        case .commonest:
            "The share of its occurrences the commonest word takes."
        }
    }

    /// A figure as a tile prints it.
    public struct Reading: Equatable, Sendable {
        /// The large number.
        public var value: String
        /// The small text beside it: a denominator, or the word a share is of.
        public var of: String?
        /// The figure as part of a sentence, for a listener and for a slide's
        /// spoken description: "22 of 27 books".
        public var spoken: String

        public init(value: String, of: String? = nil, spoken: String) {
            self.value = value
            self.of = of
            self.spoken = spoken
        }
    }

    /// The figure for this analysis, or nil where this analysis cannot answer
    /// it — a word with no forms, or a translation whose words were never
    /// counted.
    ///
    /// The card draws only the figures it gets back and never fills a slot
    /// with a substitute: a tile labelled one thing showing another thing's
    /// number is worse than a row one tile short.
    public func reading(of analysis: LampStrongsAnalysis) -> Reading? {
        switch self {
        case .occurrences:
            let count = analysis.occurrenceCount
            return Reading(value: "\(count)", spoken: "\(count) \(count == 1 ? "time" : "times")")
        case .verses:
            let count = analysis.verseCount
            return Reading(value: "\(count)", spoken: "\(count) \(count == 1 ? "verse" : "verses")")
        case .books:
            guard !analysis.books.isEmpty else { return nil }
            return Self.part(
                analysis.booksWithOccurrences, of: analysis.books.count, named: "books"
            )
        case .chapters:
            let chapters = analysis.books.flatMap(\.chapters)
            guard !chapters.isEmpty else { return nil }
            return Self.part(
                chapters.filter { $0.occurrenceCount > 0 }.count,
                of: chapters.count,
                named: "chapters"
            )
        case .sections:
            guard !analysis.sections.isEmpty else { return nil }
            return Self.part(
                analysis.sections.filter { $0.occurrenceCount > 0 }.count,
                of: analysis.sections.count,
                named: "sections of the canon"
            )
        case .perThousandWords:
            // A rate needs words to have been counted. Zero is not a small
            // rate here, it is the absence of a denominator.
            guard analysis.ratePerThousandWords > 0 else { return nil }
            let rate = ((analysis.ratePerThousandWords * 100).rounded() / 100)
                .formatted(.number.precision(.fractionLength(0...2)))
            return Reading(value: rate, spoken: "\(rate) per 1,000 tagged words")
        case .differentWords:
            // Occurrences the translation gives no word of their own are not
            // a word, so they are not one of the words counted here.
            let words = analysis.renderings.filter { !$0.text.isEmpty }.count
            guard words > 0 else { return nil }
            return Reading(
                value: "\(words)",
                spoken: "\(words) different \(words == 1 ? "word" : "words")"
            )
        case .forms:
            guard !analysis.forms.isEmpty else { return nil }
            let count = analysis.forms.count
            return Reading(
                value: "\(count)", spoken: "\(count) \(count == 1 ? "form" : "forms")"
            )
        case .commonest:
            // The commonest *word*, which is why an occurrence with no
            // English of its own cannot hold this slot however many there
            // are of it.
            guard analysis.occurrenceCount > 0,
                  let top = analysis.renderings.first(where: { !$0.text.isEmpty })
            else { return nil }
            let share = LampStrongsSpread.percent(
                Double(top.count) / Double(analysis.occurrenceCount)
            )
            return Reading(value: share, of: "“\(top.text)”", spoken: "\(share) “\(top.text)”")
        }
    }

    private static func part(_ with: Int, of total: Int, named: String) -> Reading {
        Reading(value: "\(with)", of: "of \(total)", spoken: "\(with) of \(total) \(named)")
    }
}

/// Which figures the Analyse card prints, and which chart it draws beneath
/// them.
///
/// Read forgivingly in both halves: a figure or a chart this version does not
/// know is dropped rather than refused, so a card set up in a newer Lamp
/// still opens here, and nothing stored means the three figures the card has
/// always shown. The same reading serves the pane's stored setting and a
/// deck's chart, which is why it is here rather than in either app.
public struct LampStrongsCardChoice: Equatable, Sendable {
    /// How many figures the card prints. Three is what the pane's card is
    /// wide enough for and what the deck's card slide is drawn to; a fourth
    /// would shrink every number to fit.
    public static let slots = 3

    /// What the card has always shown, and what an unset card shows.
    public static let standard = Self(figures: [.occurrences, .verses, .books], chart: .books)

    /// In the order the slots are filled, left to right.
    public var figures: [LampStrongsCardFigure]
    /// The chart under the figures, or nil for none.
    public var chart: LampStrongsGrouping?

    public init(figures: [LampStrongsCardFigure], chart: LampStrongsGrouping?) {
        self.figures = Array(figures.prefix(Self.slots))
        self.chart = chart
    }

    /// The sentinel a stored chart holds when the reader turned the chart
    /// off, so that "off" and "a name this version does not know" stay
    /// different answers.
    public static let noChart = "off"

    /// From what the apps store: a comma-separated list of figure names, and
    /// a chart's name or `off`.
    ///
    /// An empty list is the standard three rather than a card with no
    /// figures, because that is what an unset setting looks like. A name that
    /// is not a figure is dropped, and the same figure twice is kept once:
    /// two slots counting the same thing is a setting no chooser can make and
    /// no reader wants.
    public init(storedFigures: String, storedChart: String) {
        self.figures = Self.figures(named: storedFigures.split(separator: ",").map(String.init))
        let chart = storedChart.trimmingCharacters(in: .whitespaces)
        self.chart = chart == Self.noChart
            ? nil
            // A chart named by a newer Lamp falls back to the card's own
            // strip rather than to no chart: an empty band under the figures
            // reads as a card that failed to draw.
            : (LampStrongsGrouping(rawValue: chart) ?? Self.standard.chart)
    }

    /// The figures these names stand for, dropping any this version does not
    /// know and any repeat, or the standard three where none are left.
    ///
    /// Shared by the pane's stored setting and a deck's chart so that one
    /// forgiving reading serves both: a name from a newer Lamp must not take
    /// a deck down, and must not silently become a different figure either.
    public static func figures(named names: [String]) -> [LampStrongsCardFigure] {
        var seen = Set<LampStrongsCardFigure>()
        let figures = names
            .compactMap { LampStrongsCardFigure(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
        return figures.isEmpty ? standard.figures : Array(figures.prefix(slots))
    }

    public var storedFigures: String { figures.map(\.rawValue).joined(separator: ",") }
    public var storedChart: String { chart?.rawValue ?? Self.noChart }

    /// A figure in a slot, with what that slot prints.
    public struct Printed: Identifiable, Equatable, Sendable {
        public var figure: LampStrongsCardFigure
        public var reading: LampStrongsCardFigure.Reading
        public var id: String { figure.rawValue }

        public init(figure: LampStrongsCardFigure, reading: LampStrongsCardFigure.Reading) {
            self.figure = figure
            self.reading = reading
        }
    }

    /// The figures to print for this analysis, in the chosen order, without
    /// the ones it cannot answer.
    public func readings(of analysis: LampStrongsAnalysis) -> [Printed] {
        figures.compactMap { figure in
            figure.reading(of: analysis).map { Printed(figure: figure, reading: $0) }
        }
    }

    /// The whole row as one sentence. The tiles are read as a row — "116
    /// times in 105 verses" — and a listener given them one by one gets three
    /// numbers instead of a sentence.
    public func spoken(of analysis: LampStrongsAnalysis) -> String {
        readings(of: analysis).map(\.reading.spoken).joined(separator: ", ")
    }

    /// Whether the rate is already one of the printed figures, so the card's
    /// footnote does not print it a second time.
    public var showsRate: Bool { figures.contains(.perThousandWords) }

    /// Which figures are worth offering for this analysis: the ones it can
    /// answer, in a fixed order, so the chooser never offers a slot that
    /// would draw nothing.
    public static func available(for analysis: LampStrongsAnalysis) -> [LampStrongsCardFigure] {
        LampStrongsCardFigure.allCases.filter { $0.reading(of: analysis) != nil }
    }

    /// The chart to draw for this analysis: the chosen one, its stand-in, or
    /// nil where it has nothing to draw.
    public func chart(for analysis: LampStrongsAnalysis) -> LampStrongsGrouping? {
        guard let chart else { return nil }
        if chart.canDraw(analysis) { return chart }
        return standIn(for: analysis)
    }

    /// The chart drawn in place of the chosen one, where the chosen one has
    /// nothing to draw and another says the same: nil otherwise.
    ///
    /// In a text in the word's own language (TAGNT, TAHOT), what it
    /// "translates as" is its own spellings, so a card set to Translated As
    /// draws the forms: the same words, with their Latin letters and what
    /// each does. The choice itself is kept, so an English translation draws
    /// Translated As again. The apps name the stand-in in their choosers.
    public func standIn(for analysis: LampStrongsAnalysis) -> LampStrongsGrouping? {
        guard chart == .renderings,
              analysis.isInKeysOwnLanguage,
              LampStrongsGrouping.forms.canDraw(analysis) else { return nil }
        return .forms
    }
}

extension LampStrongsGrouping {
    /// Whether this analysis has a chart's worth of values for it.
    ///
    /// One division is not a chart: a strip of a single column, or a ring
    /// that is one whole circle, draws a shape that says nothing the figures
    /// above it did not. Renderings and forms can be empty outright — a
    /// translation's own words have no forms to count.
    public func canDraw(_ analysis: LampStrongsAnalysis) -> Bool {
        switch self {
        case .books: analysis.books.count > 1
        case .sections: analysis.sections.count > 1
        // Not for a text in the key's own language: what it "translates
        // as" is its own spellings, the forms chart again.
        case .renderings: analysis.renderings.count > 1 && !analysis.isInKeysOwnLanguage
        case .forms: analysis.forms.count > 1
        }
    }
}
