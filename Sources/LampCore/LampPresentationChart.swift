import Foundation
import LampModuleKit

/// A chart on a slide, drawn from what the library says rather than from
/// numbers someone typed.
///
/// A deck names what to chart: a Strong's key in a translation over a run of
/// books, perhaps narrowed to one rendering, form or grammatical value; what
/// to group it by; how to measure it; and how to draw it. These are the
/// figures of the Strong's analysis — where the word falls, how it is
/// rendered, its forms and grammar, the words that keep it company, how each
/// translation tags it, and the headword card — so anything the analysis
/// shows can be put on a slide. Lamp works out `values` (and a card's
/// `headword`) when the deck is built and stores them, so an agent can put a
/// chart on a slide without inventing its figures, a device without that
/// translation still draws it, and a check against the library reports one
/// that has gone stale.
public struct LampPresentationChart: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        /// A Strong's key, such as G26.
        public var strongs: String
        /// The translation whose tags are counted. A chart by translation
        /// compares `translations` instead and does not read this.
        public var translationID: String
        /// A run of whole books — "NT", "Romans", "Matthew-John" — or the whole
        /// translation when absent.
        public var range: String?
        /// Only the occurrences this leaves are counted, or every one when
        /// absent.
        public var filter: Filter?
        /// The translations a chart by translation compares, or every tagged
        /// one in the library when absent.
        public var translations: [String]?

        public init(
            strongs: String,
            translationID: String,
            range: String? = nil,
            filter: Filter? = nil,
            translations: [String]? = nil
        ) {
            self.strongs = strongs
            self.translationID = translationID
            self.range = range
            self.filter = filter
            self.translations = translations
        }
    }

    /// Narrows a chart to the occurrences that match every field given: "where
    /// ἀγάπη is rendered love", "only its genitives".
    ///
    /// A filter answers from each occurrence on its own, as the analysis
    /// pane's does, and the chart is then of those occurrences alone — each
    /// book still weighed against all of its tagged words, since those are
    /// the words the kept occurrences stand among.
    public struct Filter: Codable, Equatable, Sendable {
        public struct Grammar: Codable, Equatable, Sendable {
            public var feature: LampGrammarFeature
            /// As the analysis names it: "Genitive", "Aorist".
            public var value: String

            public init(feature: LampGrammarFeature, value: String) {
                self.feature = feature
                self.value = value
            }
        }

        /// An English rendering, as the analysis's Rendered As lists it.
        public var rendering: String?
        /// An original-language form, compared without case or accent at rest.
        public var form: String?
        public var grammar: Grammar?

        public init(rendering: String? = nil, form: String? = nil, grammar: Grammar? = nil) {
            self.rendering = rendering
            self.form = form
            self.grammar = grammar
        }

        private static func given(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }

        /// Whether it narrows nothing, and is the same as no filter.
        public var isEmpty: Bool {
            Self.given(rendering) == nil && Self.given(form) == nil
                && Self.given(grammar?.value) == nil
        }

        /// The filter as the tail of a sentence about the chart: "rendered
        /// “love”, as ἀγάπης, Case: Genitive".
        public var narrowing: String {
            var parts: [String] = []
            if let rendering = Self.given(rendering) { parts.append("translated “\(rendering)”") }
            if let form = Self.given(form) { parts.append("as \(form)") }
            if let grammar, let value = Self.given(grammar.value) {
                parts.append("\(grammar.feature.title): \(value)")
            }
            return parts.joined(separator: ", ")
        }

        /// Whether `occurrence` of `key` is one this filter keeps.
        ///
        /// A rendering is matched by the word that carries it, as the
        /// analysis gathers them, so "love" keeps "of love" and "love's". The
        /// grammar is read by core's own parser for the key's language, the
        /// one the analysis's grammar counts were built by.
        public func matches(_ occurrence: LampStrongsAnalysis.Occurrence, key: String) -> Bool {
            if let rendering = Self.given(rendering),
               occurrence.renderingID != LampStrongsAnalyzer.renderingHead(of: rendering, isEnglish: true).lowercased() {
                return false
            }
            if let form = Self.given(form),
               occurrence.form.map(LampStrongsAnalyzer.formID) != LampStrongsAnalyzer.formID(form) {
                return false
            }
            if let grammar, let value = Self.given(grammar.value) {
                let features = occurrence.morphology.map {
                    LampMorphology.features(of: $0, strongsKey: LampStrongsKey.normalized(key))
                } ?? []
                guard features.contains(where: {
                    $0.feature == grammar.feature && $0.value.caseInsensitiveCompare(value) == .orderedSame
                }) else { return false }
            }
            return true
        }

        /// What the analyzer keeps, or nil when the filter narrows nothing.
        public func keeping(key: String) -> (@Sendable (LampStrongsAnalysis.Occurrence) -> Bool)? {
            guard !isEmpty else { return nil }
            let filter = self
            return { filter.matches($0, key: key) }
        }
    }

    public enum Grouping: String, Codable, CaseIterable, Identifiable, Sendable {
        case book
        case section
        case rendering
        case form
        /// The values of one grammatical feature, named by `feature`.
        case grammar
        /// The key in each translation, side by side.
        case translation
        /// The keys that share its verses more often than chance predicts.
        case companion

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .book: "Book"
            case .section: "Section"
            case .rendering: "Translated As"
            case .form: "Form"
            case .grammar: "Grammar"
            case .translation: "Translation"
            case .companion: "Companion"
            }
        }

        /// Whether its values are parts of one whole, so that a share or a
        /// percentage means something. Translations each count the whole
        /// again, and companions are not counts at all.
        public var isPartOfWhole: Bool { self != .translation && self != .companion }

        /// Whether "per 1,000 words" means anything. A companion is measured
        /// by how many times chance it keeps the key company.
        public var usesMeasure: Bool { self != .companion }
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
    /// chapters. `share` is a ring of the whole, largest first. `card` is the
    /// analysis's headword card: the word, its gloss and counts, over a
    /// column for each book.
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case bars
        case columns
        case grid
        case share
        case card

        public var id: String { rawValue }

        /// A style this app does not know reads as bars, so a deck written by
        /// a newer app still opens rather than failing as a whole.
        public init(from decoder: Decoder) throws {
            self = Style(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bars
        }

        /// Whether it draws a column or row per book, so charts by book only.
        public var isOfBooks: Bool { self == .grid || self == .card }
    }

    public struct Value: Codable, Equatable, Sendable {
        public var label: String
        public var value: Double
        /// `more` or `fewer` for a book or section holding a count chance does
        /// not explain; absent otherwise.
        public var standing: LampStrongsAnalysis.Expectation?
        /// A grid row's chapters, from chapter 1, measured as the chart is.
        public var chapters: [Double]?
        /// A second, smaller line under the label: a companion's key and
        /// gloss, a translation's commonest renderings.
        public var detail: String?
        /// The part of every occurrence charted that this value holds, 0...1,
        /// printed beside a bar as a percentage. Only for bars of a whole.
        public var share: Double?

        public init(
            label: String,
            value: Double,
            standing: LampStrongsAnalysis.Expectation? = nil,
            chapters: [Double]? = nil,
            detail: String? = nil,
            share: Double? = nil
        ) {
            self.label = label
            self.value = value
            self.standing = standing
            self.chapters = chapters
            self.detail = detail
            self.share = share
        }
    }

    /// The figures a card prints above its columns. Written by Lamp.
    public struct Headword: Codable, Equatable, Sendable {
        public var lemma: String?
        public var transliteration: String?
        /// A lexicon's own gloss, never a definition cut to fit.
        public var gloss: String?
        public var occurrences: Int
        public var verses: Int
        /// Books holding the key.
        public var books: Int
        /// Books in range that tag the key's language, so "22 of 27".
        public var bookCount: Int
        public var perThousandWords: Double
        /// The translation counted, as a reader knows it.
        public var translation: String
        /// The figures the card printed, in its slots' order, where they are
        /// not the three the fields above name.
        ///
        /// Those fields are always written, so a card in a deck opened by a
        /// Lamp that predates choosable slots draws the card it always drew
        /// rather than an empty row.
        public var figures: [Figure]?

        /// A figure as a card's tile prints it. Written by Lamp.
        public struct Figure: Codable, Equatable, Sendable {
            public var label: String
            public var value: String
            /// The smaller text beside the value: "of 27", or the word a
            /// share is of.
            public var of: String?

            public init(label: String, value: String, of: String? = nil) {
                self.label = label
                self.value = value
                self.of = of
            }
        }

        public init(
            lemma: String? = nil,
            transliteration: String? = nil,
            gloss: String? = nil,
            occurrences: Int,
            verses: Int,
            books: Int,
            bookCount: Int,
            perThousandWords: Double,
            translation: String,
            figures: [Figure]? = nil
        ) {
            self.lemma = lemma
            self.transliteration = transliteration
            self.gloss = gloss
            self.occurrences = occurrences
            self.verses = verses
            self.books = books
            self.bookCount = bookCount
            self.perThousandWords = perThousandWords
            self.translation = translation
            self.figures = figures
        }
    }

    /// Renderings, forms, grammar and companions are ranked, and a chart shows
    /// the commonest.
    public static let rankedLimit = 8
    /// Past this many bars a chart is hard to read from the back of a room.
    public static let readableBars = 24
    /// Past this many books a grid's rows are too thin to read.
    public static let readableGridRows = 40
    /// A share shows this many slices at most: the six largest and "Other",
    /// as the analysis's ring has it (`LampStrongsShare`).
    public static let shareSlices = 7

    public var source: Source
    public var by: Grouping
    /// The grammatical feature a chart by grammar shows: case, tense.
    public var feature: LampGrammarFeature?
    public var measure: Measure
    /// Absent, the chart is bars.
    public var style: Style?
    /// Which figures a card prints, named as `LampStrongsCardFigure` names
    /// them, when they are not the card's standard three. A name this version
    /// does not know is left out rather than refused, so a deck written by a
    /// newer Lamp still opens here.
    public var figures: [String]?
    /// Written by Lamp, never by hand.
    public var values: [Value]?
    /// A card's word and counts. Written by Lamp, never by hand.
    public var headword: Headword?
    /// What was matched to the counted translation when its module was built
    /// and the chart rests on, each said as a sentence the slide prints
    /// under the chart (`LampTranslationSource`). Written by Lamp.
    public var sources: [String]?

    public init(
        source: Source,
        by: Grouping,
        feature: LampGrammarFeature? = nil,
        measure: Measure = .occurrences,
        style: Style? = nil,
        figures: [String]? = nil,
        values: [Value]? = nil,
        headword: Headword? = nil,
        sources: [String]? = nil
    ) {
        self.source = source
        self.by = by
        self.feature = feature
        self.measure = measure
        self.style = style
        self.figures = figures
        self.values = values
        self.headword = headword
        self.sources = sources
    }

    /// A measure left out counts occurrences, as the skill's validator has
    /// always allowed; refusing it here refused the whole deck it was in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(Source.self, forKey: .source)
        by = try container.decode(Grouping.self, forKey: .by)
        feature = try container.decodeIfPresent(LampGrammarFeature.self, forKey: .feature)
        measure = try container.decodeIfPresent(Measure.self, forKey: .measure) ?? .occurrences
        style = try container.decodeIfPresent(Style.self, forKey: .style)
        // Names, not cases: an unknown figure is dropped when they are read,
        // where an unknown case would throw and take the whole deck with it.
        figures = try container.decodeIfPresent([String].self, forKey: .figures)
        values = try container.decodeIfPresent([Value].self, forKey: .values)
        headword = try container.decodeIfPresent(Headword.self, forKey: .headword)
        sources = try container.decodeIfPresent([String].self, forKey: .sources)
    }

    /// The parts of a translation's tagging this chart rests on: its Strong's
    /// numbers always, and its spellings too for a chart of forms.
    public var restsOn: Set<LampTranslationSource.Part> {
        by == .form ? [.strongs, .forms] : [.strongs]
    }

    public var drawnStyle: Style { style ?? .bars }

    /// The figures this card prints, the standard three where none are named.
    public var cardFigures: [LampStrongsCardFigure] {
        LampStrongsCardChoice.figures(named: figures ?? [])
    }

    /// Whether values print as whole counts. A share is always of occurrences:
    /// rates per thousand words do not add up to a whole.
    public var countsOccurrences: Bool {
        by != .companion && (measure == .occurrences || drawnStyle == .share)
    }

    /// The values a set of analyses gives this chart: one per translation for
    /// a chart by translation, else the first analysis's. `headwords` names
    /// a companion by its word rather than its number.
    public func values(
        from analyses: [LampStrongsAnalysis],
        headwords: [String: LampStrongsHeadword] = [:]
    ) -> [Value] {
        guard by == .translation else {
            return analyses.first.map { values(from: $0, headwords: headwords) } ?? []
        }
        return analyses.map { analysis in
            Value(
                label: analysis.translationAbbreviation ?? analysis.translationName,
                value: measured(analysis.occurrenceCount, of: analysis.wordCount),
                detail: analysis.renderings.prefix(3)
                    .map { "\($0.text.isEmpty ? "—" : $0.text) (\($0.count))" }
                    .joined(separator: ", ")
            )
        }
        .sorted { ($1.value, $0.label) < ($0.value, $1.label) }
    }

    /// The values an analysis gives this chart.
    ///
    /// As bars, a book appears when the key occurs there, or when its absence
    /// is itself notable: ἀγαπάω never in Acts is part of the picture. As
    /// columns, a grid or a card every book in range appears, because the
    /// gaps are the shape. Sections appear whole, empty ones included,
    /// because there are few of them. A share is of occurrences, largest
    /// first, with everything past its sixth slice gathered as "Other" so the
    /// ring is the whole.
    public func values(
        from analysis: LampStrongsAnalysis,
        headwords: [String: LampStrongsHeadword] = [:]
    ) -> [Value] {
        func standing(_ division: LampStrongsAnalysis.Division) -> LampStrongsAnalysis.Expectation? {
            division.expectation == .asExpected ? nil : division.expectation
        }
        if drawnStyle == .share, by.isPartOfWhole { return shareValues(from: analysis) }
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
            let everyBook = drawnStyle == .columns || drawnStyle == .card
            return analysis.books
                .filter { everyBook || $0.occurrenceCount > 0 || $0.expectation != .asExpected }
                .map {
                    .init(
                        label: $0.name,
                        value: measured($0.occurrenceCount, of: $0.wordCount),
                        standing: standing($0),
                        share: share($0.occurrenceCount, of: analysis.occurrenceCount)
                    )
                }
        case .section:
            return analysis.sections.map {
                .init(
                    label: $0.name,
                    value: measured($0.occurrenceCount, of: $0.wordCount),
                    standing: standing($0),
                    share: share($0.occurrenceCount, of: analysis.occurrenceCount)
                )
            }
        case .rendering:
            return analysis.renderings.prefix(Self.rankedLimit).map {
                .init(
                    label: $0.text.isEmpty ? "(no English)" : $0.text,
                    value: measured($0.count, of: analysis.wordCount),
                    share: share($0.count, of: analysis.occurrenceCount)
                )
            }
        case .form:
            let total = analysis.forms.reduce(0) { $0 + $1.count }
            let readings = Self.formDetails(of: analysis)
            return analysis.forms.prefix(Self.rankedLimit).map {
                .init(
                    label: $0.text,
                    value: measured($0.count, of: analysis.wordCount),
                    detail: readings[$0.id],
                    share: share($0.count, of: total)
                )
            }
        case .grammar:
            let counts = grammarCounts(in: analysis)
            let total = counts.reduce(0) { $0 + $1.count }
            return counts.prefix(Self.rankedLimit).map {
                .init(
                    label: $0.value,
                    value: measured($0.count, of: analysis.wordCount),
                    share: share($0.count, of: total)
                )
            }
        case .translation:
            return values(from: [analysis], headwords: headwords)
        case .companion:
            return analysis.companions.prefix(Self.rankedLimit).map { companion in
                let headword = headwords[companion.key]
                let lemma = headword?.lemma.flatMap { $0.isEmpty ? nil : $0 }
                let shared = companion.sharedVerseCount == 1
                    ? "1 shared verse" : "\(companion.sharedVerseCount) shared verses"
                return .init(
                    label: lemma ?? companion.key,
                    value: (companion.lift * 10).rounded() / 10,
                    detail: ([lemma == nil ? nil : companion.key, headword?.gloss, shared] as [String?])
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
            }
        }
    }

    /// The card's figures, from the analysis and the key's headword.
    public func headword(
        from analysis: LampStrongsAnalysis,
        headword: LampStrongsHeadword?
    ) -> Headword {
        func given(_ text: String?) -> String? {
            text.flatMap { $0.isEmpty ? nil : $0 }
        }
        let chosen = cardFigures
        // What the card printed, which is not always what was chosen: a word
        // with no forms prints no Forms tile, and the slide should show the
        // card that was added rather than a fuller one.
        let printed = chosen.compactMap { figure in
            figure.reading(of: analysis).map {
                Headword.Figure(label: figure.title, value: $0.value, of: $0.of)
            }
        }
        return Headword(
            lemma: given(headword?.lemma),
            transliteration: given(headword?.transliteration),
            gloss: given(headword?.shortGloss),
            occurrences: analysis.occurrenceCount,
            verses: analysis.verseCount,
            books: analysis.booksWithOccurrences,
            bookCount: analysis.books.count,
            perThousandWords: (analysis.ratePerThousandWords * 100).rounded() / 100,
            translation: analysis.translationAbbreviation ?? analysis.translationName,
            // Left out where the card prints its standard three, which the
            // fields above already carry: a deck of ordinary cards is then
            // written exactly as it was before slots could be chosen. Left
            // out too where nothing printable is left, since the three are
            // then the only figures there are to draw.
            figures: chosen == LampStrongsCardChoice.standard.figures || printed.isEmpty
                ? nil
                : printed
        )
    }

    /// Whether this chart takes the key's own headword as well as its values.
    public var showsHeadword: Bool { drawnStyle == .card }

    /// The keys whose headwords this chart names: the key itself on a card,
    /// its companions in a chart of them.
    public func headwordKeys(in analyses: [LampStrongsAnalysis]) -> [String] {
        var keys: [String] = []
        if showsHeadword { keys.append(LampStrongsKey.normalized(source.strongs)) }
        if by == .companion, let analysis = analyses.first {
            keys += analysis.companions.prefix(Self.rankedLimit).map(\.key)
        }
        return keys
    }

    private func measured(_ count: Int, of words: Int) -> Double {
        guard measure == .perThousandWords, by.usesMeasure else { return Double(count) }
        guard words > 0 else { return 0 }
        return (Double(count) * 100_000 / Double(words)).rounded() / 100
    }

    /// A bar's part of the whole, for bars of occurrences only: a rate per
    /// thousand words is not a part of anything.
    private func share(_ count: Int, of total: Int) -> Double? {
        guard drawnStyle == .bars, measure == .occurrences, by.isPartOfWhole, total > 0 else {
            return nil
        }
        return (Double(count) * 10_000 / Double(total)).rounded() / 10_000
    }

    private func grammarCounts(in analysis: LampStrongsAnalysis) -> [LampStrongsAnalysis.GrammarCount] {
        guard let feature else { return [] }
        return analysis.grammar.filter { $0.feature == feature }
    }

    private func shareValues(from analysis: LampStrongsAnalysis) -> [Value] {
        let formDetails = by == .form ? Self.formDetails(of: analysis) : [:]
        let counts: [(label: String, count: Int, detail: String?)] = switch by {
        case .book: analysis.books.map { ($0.name, $0.occurrenceCount, nil) }
        case .section: analysis.sections.map { ($0.name, $0.occurrenceCount, nil) }
        case .rendering: analysis.renderings.map { ($0.text.isEmpty ? "(no English)" : $0.text, $0.count, nil) }
        case .form: analysis.forms.map { ($0.text, $0.count, formDetails[$0.id]) }
        case .grammar: grammarCounts(in: analysis).map { ($0.value, $0.count, nil) }
        case .translation, .companion: []
        }
        let ranked = counts.filter { $0.count > 0 }.sorted { ($1.count, $0.label) < ($0.count, $1.label) }
        guard ranked.count > Self.shareSlices else {
            return ranked.map { .init(label: $0.label, value: Double($0.count), detail: $0.detail) }
        }
        let others = ranked.dropFirst(Self.shareSlices - 1).reduce(0) { $0 + $1.count }
        return ranked.prefix(Self.shareSlices - 1).map {
            .init(label: $0.label, value: Double($0.count), detail: $0.detail)
        } + [.init(label: "Other", value: Double(others))]
    }

    /// Each form's line under its spelling, by form ID: its Latin letters and
    /// what it does, "agapēs · “of …”", for a room that reads no Greek.
    private static func formDetails(of analysis: LampStrongsAnalysis) -> [String: String] {
        var details: [String: String] = [:]
        for reading in LampStrongsFormReading.readings(of: analysis) {
            let line = [reading.transliteration, reading.role].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { details[reading.form.id] = line }
        }
        return details
    }

    /// A value as the chart prints it.
    public func formatted(_ value: Double) -> String {
        if by == .companion {
            return value.formatted(.number.precision(.fractionLength(1))) + "×"
        }
        return countsOccurrences
            ? String(Int(value.rounded()))
            : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// A value with its share, as a bar prints it: "12 · 16%". A bar of
    /// nothing prints its count alone, as the analysis's Spread does.
    public func printed(_ value: Value) -> String {
        guard let share = value.share, share > 0 else { return formatted(value.value) }
        return "\(formatted(value.value)) · \(LampStrongsSpread.percent(share))"
    }

    /// A book's name short enough to stand under a narrow column: its OSIS
    /// abbreviation, or the label as it is when it names no book.
    public static func abbreviated(_ label: String) -> String {
        LampCanonicalBooks.book(named: label)?.osisID ?? label
    }

    /// What the chart counts, in words: "G26 in ESV, rendered “love”, NT".
    public var subject: String {
        var what = by == .translation
            ? "\(source.strongs) across translations"
            : "\(source.strongs) in \(source.translationID)"
        if let filter = source.filter, !filter.isEmpty { what += ", \(filter.narrowing)" }
        if let range = source.range { what += ", \(range)" }
        if by == .grammar, let feature { what += ", by \(feature.title.lowercased())" }
        if measure == .perThousandWords, by.usesMeasure, drawnStyle != .share {
            what += ", per thousand words"
        }
        return what
    }

    /// What a listener hears in place of the bars.
    public var spokenDescription: String {
        let what = subject
        var heard: [String] = []
        if showsHeadword, let headword {
            let word = [headword.lemma, headword.gloss].compactMap { $0 }.joined(separator: ", ")
            // The figures the card actually printed, not the three the
            // struct carries for an older Lamp's benefit: a listener given
            // the wrong three hears a card that is not on the screen.
            let counts = headword.figures.map { figures in
                figures
                    .map { "\($0.label) \($0.value)" + ($0.of.map { " \($0)" } ?? "") }
                    .joined(separator: ", ")
            } ?? "\(headword.occurrences) times in \(headword.verses) verses, "
                + "in \(headword.books) of \(headword.bookCount) books"
            heard.append((word.isEmpty ? "" : "\(word): ") + counts)
        }
        let footnote = (sources ?? []).map { " " + $0 }.joined()
        guard let values, !values.isEmpty else {
            return (heard.isEmpty ? "Chart of \(what)" : "Chart of \(what): " + heard.joined()) + footnote
        }
        let total = values.reduce(0) { $0 + $1.value }
        heard += values.map { value in
            let note = switch value.standing {
            case .more: ", more than expected"
            case .fewer: ", fewer than expected"
            default: ""
            }
            let share: String
            if let part = value.share, part > 0 {
                share = ", \(Int((part * 100).rounded())) percent"
            } else if drawnStyle == .share && total > 0 {
                share = ", \(Int((value.value * 100 / total).rounded())) percent"
            } else {
                share = ""
            }
            let figure = by == .companion
                ? "\(formatted(value.value)) chance" : formatted(value.value)
            return "\(value.label) \(figure)\(share)\(note)"
        }
        return "Chart of \(what): " + heard.joined(separator: "; ") + (footnote.isEmpty ? "" : "." + footnote)
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
    /// `chart` with its values (and a card's headword) worked out from this
    /// library, or nil when it has nothing to work them out from: the
    /// translation is not installed, or does not tag the key's language in
    /// range; for a chart by translation, none it compares does.
    ///
    /// `translationIDs` limits the translations a chart by translation may
    /// compare, and `dictionaryIDs` the lexicons a headword is read from;
    /// nil for every installed one. An agent passes what its policy permits.
    func workedOut(
        _ chart: LampPresentationChart,
        translationIDs: Set<String>? = nil,
        dictionaryIDs: Set<String>? = nil
    ) throws -> LampPresentationChart? {
        let books = try chart.source.range.map(LampReferenceParser.books)
        let keeping = chart.source.filter?.keeping(key: chart.source.strongs)
        let analyses: [LampStrongsAnalysis]
        if chart.by == .translation {
            var compared = chart.source.translations.map(Set.init)
            if let translationIDs { compared = compared?.intersection(translationIDs) ?? translationIDs }
            analyses = try strongsAnalyses(
                key: chart.source.strongs, moduleIDs: compared, bookRange: books, keeping: keeping
            )
        } else {
            analyses = try strongsAnalyses(
                key: chart.source.strongs,
                moduleIDs: [chart.source.translationID],
                bookRange: books,
                keeping: keeping
            )
        }
        guard !analyses.isEmpty else { return nil }

        let keys = chart.headwordKeys(in: analyses)
        var headwords: [String: LampStrongsHeadword] = [:]
        if !keys.isEmpty, dictionaryIDs?.isEmpty != true {
            headwords = LampStrongsHeadword.merging(
                (try? dictionaryEntries(keys: keys, moduleIDs: dictionaryIDs)) ?? []
            )
        }
        var worked = chart
        worked.values = chart.values(from: analyses, headwords: headwords)
        // Said on the slide, as the analysis says it, so what was matched to
        // a translation when it was built is never shown as its own print.
        let said = try analyses.flatMap { analysis in
            try translationSources(moduleID: analysis.translationID)
                .filter { chart.restsOn.contains($0.part) }
                .map {
                    $0.disclosure(
                        translationName: analysis.translationAbbreviation ?? analysis.translationName,
                        strongsKey: chart.source.strongs
                    )
                }
        }
        worked.sources = said.isEmpty ? nil : said
        worked.headword = chart.showsHeadword
            ? chart.headword(from: analyses[0], headword: headwords[LampStrongsKey.normalized(chart.source.strongs)])
            : nil
        return worked
    }

    /// `chart`'s values from this library, or nil when it cannot work them out.
    func chartValues(_ chart: LampPresentationChart) throws -> [LampPresentationChart.Value]? {
        try workedOut(chart)?.values
    }

    /// Works out every chart in `deck` again. A deck being built takes the
    /// report's `deck`; a deck only being checked reads its issues, which name
    /// a chart whose stored values no longer match the library. A chart this
    /// library cannot work out keeps the values it carries.
    func workingOutCharts(
        in deck: LampPresentationDeck,
        translationIDs: Set<String>? = nil,
        dictionaryIDs: Set<String>? = nil
    ) -> LampPresentationChartReport {
        var result = deck
        var issues: [LampPresentationDeckIssue] = []
        var changed = false
        for (slideIndex, slide) in deck.slides.enumerated() {
            for (blockIndex, block) in slide.blocks.enumerated() {
                guard block.kind == .chart, let chart = block.chart else { continue }
                let path = "slides[\(slideIndex)].blocks[\(blockIndex)].chart"
                let named = chart.subject
                let counted = chart.by == .translation
                    ? "translation it compares"
                    : chart.source.translationID
                // An unreadable range is the validator's to report.
                guard let worked = try? workedOut(
                    chart, translationIDs: translationIDs, dictionaryIDs: dictionaryIDs
                ) else {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).source",
                        message: chart.values == nil
                            ? "This library has no tagged \(counted) to work out "
                                + "\(named) from, so the chart draws empty."
                            : "This library has no tagged \(counted) to check "
                                + "\(named) against; the chart draws the values it carries."
                    ))
                    continue
                }
                if worked.values?.isEmpty != false {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).source",
                        message: "\(named) has nothing to chart in this range."
                    ))
                }
                guard worked.values != chart.values || worked.headword != chart.headword
                        || worked.sources != chart.sources else { continue }
                if chart.values != nil {
                    issues.append(.init(
                        severity: .warning,
                        path: "\(path).values",
                        message: "The values no longer match "
                            + (chart.by == .translation ? "the translations" : chart.source.translationID)
                            + " in this library. Building the deck updates them."
                    ))
                }
                result.slides[slideIndex].blocks[blockIndex].chart = worked
                changed = true
            }
        }
        return LampPresentationChartReport(deck: result, issues: issues, changed: changed)
    }
}
