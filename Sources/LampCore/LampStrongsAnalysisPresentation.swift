import Foundation
import LampModuleKit

// What the apps draw from a Strong's analysis: narrowing it to a figure's
// occurrences, the charts' bars, shares and grids, the verse around a word,
// and the Septuagint section's wording. Pure, so the Mac and the phone draw
// the same figures and say the same things about them.

/// Whether a key's analyses amount to a finding at all.
///
/// A translation answers for every key asked of it, because most of what a
/// card draws belongs to the module rather than to the key: the tagged words
/// a rate is measured against, the books in range an absence is marked in.
/// So a key that is no key - "H0" - came back from every tagged translation
/// as an analysis reading nought occurrences, nought verses and nought of 39
/// books, and drew as a finding about Hebrew rather than as a key that does
/// not exist.
///
/// Judged here rather than in the library, because the same zero is worth
/// drawing elsewhere: a comparison across translations shows a bar at nought
/// for a translation that does not use the key, and that bar is a true thing
/// to say about that translation. What differs between the two is the
/// question being asked, not the data, so the library goes on answering and
/// the apps decide what the answer means.
public enum LampStrongsPresence {
    /// True when not one of the analyses holds a single occurrence - the case
    /// of no analyses at all included.
    ///
    /// Ask it only once every translation has answered. Part-way through, the
    /// first to answer may be one that does not tag the key while another
    /// does, and "not here" would be wrong a tenth of a second before it was
    /// right.
    public static func absent(from analyses: [LampStrongsAnalysis]) -> Bool {
        analyses.allSatisfy(\.occurrences.isEmpty)
    }

    /// What to call the absence. The key is named, because the pane that
    /// shows this is usually reached by typing and a typo is the likeliest
    /// reason to be here.
    public static func title(key: String) -> String {
        "No Tags for \(key)"
    }

    /// Why nothing was found, which is a different thing in a narrowed
    /// search: a key may be tagged all through the Bible and still reach none
    /// of the books being searched, and saying there that no translation tags
    /// it would be false.
    public static func reason(narrowed: Bool) -> String {
        narrowed
            ? "No installed translation tags this key in the chosen books."
            : "No installed translation tags this key. Check the number, or "
                + "install a translation that carries tags."
    }
}

/// Narrowing a Strong's analysis to the occurrences behind one of its figures.
///
/// Every case is answerable from an occurrence on its own. That is the point:
/// the analysis already carries every occurrence in range, so choosing a
/// rendering or a chapter filters the list in place rather than asking the
/// library a second question. A search would not do — it stops at a page of
/// hits, and a common key has far more occurrences than a page holds.
public enum LampStrongsFilter: Hashable, Sendable {
    /// Carries the rendering's text as well as its id, because the chip has to
    /// name what was chosen and an id is not a thing to show anyone.
    case rendering(id: String, text: String)
    case form(String)
    case grammar(feature: LampGrammarFeature, value: String)
    case book(number: Int)
    case chapter(book: Int, number: Int)

    /// What the removable chip says.
    public var label: String {
        switch self {
        case .rendering(_, let text):
            "“\(text)”"
        case .form(let text):
            text
        case .grammar(let feature, let value):
            "\(feature.title): \(value)"
        case .book(let number):
            LampBibleReferenceFormatter.bookName(number)
        case .chapter(let book, let number):
            "\(LampBibleReferenceFormatter.bookName(book)) \(number)"
        }
    }

    /// Whether `occurrence` of `key` is one this filter keeps. A grammar
    /// value needs the key: a Hebrew code is read for the morpheme its
    /// Strong's number names, and the code alone cannot say whether it is
    /// Hebrew or Greek.
    public func matches(_ occurrence: LampStrongsAnalysis.Occurrence, key: String) -> Bool {
        switch self {
        case .rendering(let id, _):
            occurrence.renderingID == id
        case .form(let text):
            // Compared as the Forms figure groups them: its count takes in
            // every spelling of a form, so the list it opens must too.
            occurrence.form.map(LampStrongsAnalyzer.formID) == LampStrongsAnalyzer.formID(text)
        case .grammar(let feature, let value):
            // Read through core's own parser for the key's language rather
            // than taking the code apart here. The grammar counts this filter
            // narrows were built by that parser, so anything else would answer
            // a different question from the number the reader clicked.
            occurrence.morphology.map {
                LampMorphology.features(of: $0, strongsKey: LampStrongsKey.normalized(key))
                    .contains { $0.feature == feature && $0.value == value }
            } ?? false
        case .book(let number):
            LampBibleReferenceFormatter.components(of: occurrence.reference).book == number
        case .chapter(let book, let number):
            {
                let parts = LampBibleReferenceFormatter.components(of: occurrence.reference)
                return parts.book == book && parts.chapter == number
            }()
        }
    }
}

/// Which slice of a ring or pie a point falls in.
///
/// SwiftUI hit-testing could not be relied on for this. A filled `Shape` is a
/// view the size of its whole frame rather than of its path, and
/// `.contentShape(theShape)` — which should narrow it — did not change what
/// `.onHover` reported: every slice still answered for the whole square, so
/// the last one drawn, which is always "Other", lit up wherever the pointer
/// was. Working the angle out directly is both correct and testable.
public enum LampStrongsShareHit {
    /// The index into `fractions`, or nil for the hole, outside the circle,
    /// or a gap.
    ///
    /// The angles match how the wedges are drawn: zero at twelve o'clock,
    /// growing clockwise. `thickness` is the ring's share of the radius, 1
    /// for a solid pie.
    public static func index(
        at point: CGPoint,
        in size: CGSize,
        fractions: [Double],
        thickness: Double
    ) -> Int? {
        guard !fractions.isEmpty else { return nil }
        let outer = Double(min(size.width, size.height)) / 2
        guard outer > 0 else { return nil }

        let dx = Double(point.x) - Double(size.width) / 2
        let dy = Double(point.y) - Double(size.height) / 2
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius <= outer else { return nil }

        let inner = outer * (1 - thickness)
        // A pie is filled to the middle; a ring's hole is not part of it.
        if inner > 0.5, radius < inner { return nil }

        // atan2 is zero at three o'clock, so a quarter turn puts zero at
        // twelve, where the first wedge starts.
        var turn = (atan2(dy, dx) / (2 * .pi)) + 0.25
        turn -= turn.rounded(.down)

        var start = 0.0
        for (index, fraction) in fractions.enumerated() {
            if turn >= start, turn < start + fraction { return index }
            start += fraction
        }
        // Rounding can leave a point a hair past the last wedge's end rather
        // than inside it, which would flicker the highlight off at one angle.
        return abs(turn - start) < 1e-6 ? fractions.count - 1 : nil
    }
}

extension LampStrongsFilter {
    /// The filter as the tail of a sentence about the occurrence list:
    /// "rendered “beloved”", "in John 3". The list's own heading carries it,
    /// so what a click did is said where its effect is, not in the pane that
    /// was clicked.
    public var narrowing: String {
        switch self {
        case .rendering(_, let text): "translated “\(text)”"
        case .form(let text): "as \(text)"
        case .grammar: label
        case .book, .chapter: "in \(label)"
        }
    }

    /// The occurrence list's heading: every occurrence, or how many of them
    /// the filter leaves.
    public static func heading(shown: Int, total: Int, narrowed: Bool) -> String {
        let noun = total == 1 ? "occurrence" : "occurrences"
        if !narrowed { return total == 1 ? "1 occurrence" : "All \(total) \(noun)" }
        return "\(shown) of \(total) \(noun)"
    }

    /// What is left when this filter is chosen a second time.
    ///
    /// Choosing the same thing again widens by one step rather than clearing
    /// everything. A chapter falls back to its own book, because the book's
    /// chapter strip is still open underneath it: dropping straight to no
    /// filter left the reader looking at one book's chapters while the list
    /// beside them showed every occurrence in the Bible. Everything else has
    /// nothing wider to fall back to.
    public var widened: LampStrongsFilter? {
        if case .chapter(let book, _) = self { return .book(number: book) }
        return nil
    }
}

extension LampStrongsAnalysis {
    /// The occurrences one filter leaves, or all of them when nothing is
    /// chosen.
    public func occurrences(matching filter: LampStrongsFilter?) -> [Occurrence] {
        guard let filter else { return occurrences }
        return occurrences.filter { filter.matches($0, key: key) }
    }
}

/// Which translation's analysis the pane shows first.
public enum LampStrongsAnalysisOrder {
    /// The analyses with the translation being read at the front.
    ///
    /// The pane shows the active translation before the others have been
    /// worked out, so the order it finally settles into has to start with that
    /// same one. Otherwise the row a reader was looking at slides down the
    /// list as the rest arrive.
    public static func ordered(
        _ analyses: [LampStrongsAnalysis],
        activeTranslationID: String?
    ) -> [LampStrongsAnalysis] {
        guard
            let activeTranslationID,
            let index = analyses.firstIndex(where: { $0.translationID == activeTranslationID })
        else { return analyses }
        var ordered = analyses
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}

public enum LampStrongsSpreadMeasure: String, CaseIterable, Identifiable, Sendable {
    case occurrences
    case perThousandWords

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .occurrences: "Occurrences"
        case .perThousandWords: "Per 1,000 Words"
        }
    }
}

/// What the spread divides a word's occurrences by: the one question it
/// answers is where the word occurs.
///
/// Renderings and forms are not here. Overview lists them already, with
/// their own ring, and a second chart of them was the same figures again.
/// Books and sections are drawn as bars and chapters as a grid, so how a
/// chart is drawn follows from this and is never a choice of its own.
public enum LampStrongsSpreadGrouping: String, CaseIterable, Identifiable, Sendable {
    case books
    case sections
    case chapters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .books: "Books"
        case .sections: "Sections"
        case .chapters: "Chapters"
        }
    }

    /// The grouping a bar chart draws, or nil for the chapter grid.
    public var bars: LampStrongsGrouping? {
        switch self {
        case .books: .books
        case .sections: .sections
        case .chapters: nil
        }
    }

    /// Whether "per 1,000 words" means anything. The grid shades chapters
    /// by how often the word occurs in them, and has no rate to offer.
    public var usesMeasure: Bool { self != .chapters }
}

/// One bar of the spread chart.
public struct LampStrongsSpreadBar: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let value: Double
    /// How long to draw the bar, as a fraction of the longest one.
    public let share: Double
    /// This division's part of every occurrence charted, 0...1: the "16%"
    /// beside a count, which is what a ring of the same figures would say.
    public let fractionOfOccurrences: Double
    public let expectation: LampStrongsAnalysis.Expectation
    public let occurrenceCount: Int
    public let wordCount: Int

    public init(
        id: Int,
        name: String,
        value: Double,
        share: Double,
        fractionOfOccurrences: Double = 0,
        expectation: LampStrongsAnalysis.Expectation,
        occurrenceCount: Int,
        wordCount: Int
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.share = share
        self.fractionOfOccurrences = fractionOfOccurrences
        self.expectation = expectation
        self.occurrenceCount = occurrenceCount
        self.wordCount = wordCount
    }
}

public enum LampStrongsSpread {
    /// Bars for a run of divisions, scaled against the longest of them.
    ///
    /// Scaled here rather than in the view because the zero case has to be
    /// decided once: a key that occurs nowhere in range gives every division a
    /// value of nothing, and dividing by the largest of those is a crash in
    /// one place and a chart of full-width bars in another.
    public static func bars(
        _ divisions: [LampStrongsAnalysis.Division],
        measure: LampStrongsSpreadMeasure
    ) -> [LampStrongsSpreadBar] {
        let values = divisions.map { division in
            switch measure {
            case .occurrences: Double(division.occurrenceCount)
            case .perThousandWords: division.ratePerThousandWords
            }
        }
        let longest = values.max() ?? 0
        let total = divisions.reduce(0) { $0 + $1.occurrenceCount }
        return zip(divisions, values).map { division, value in
            LampStrongsSpreadBar(
                id: division.id,
                name: division.name,
                value: value,
                share: longest > 0 ? value / longest : 0,
                fractionOfOccurrences: total > 0
                    ? Double(division.occurrenceCount) / Double(total)
                    : 0,
                expectation: division.expectation,
                occurrenceCount: division.occurrenceCount,
                wordCount: division.wordCount
            )
        }
    }

    /// A part of the whole as a percentage: "16%", "<1%" for a part too
    /// small to round to one, so a book holding the word never reads "0%".
    public static func percent(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        let whole = Int((fraction * 100).rounded())
        return whole < 1 ? "<1%" : "\(whole)%"
    }
}

/// A verse around the word that carries the key.
///
/// Only the translation being read is asked for its verses — the others cost
/// about a megabyte each for a common key and nothing reads them — so a
/// snippet is drawn from `LampStrongsAnalysis.verseTexts`, which is empty
/// unless it was asked for.
public enum LampStrongsContext {
    public struct Snippet: Equatable, Sendable {
        public var before: String
        /// The words the tag covers, which the row draws emphasised.
        public var word: String
        public var after: String
        /// Text was dropped from that end to keep the row short.
        public var isTrimmedAtStart: Bool
        public var isTrimmedAtEnd: Bool

        public init(
            before: String,
            word: String,
            after: String,
            isTrimmedAtStart: Bool = false,
            isTrimmedAtEnd: Bool = false
        ) {
            self.before = before
            self.word = word
            self.after = after
            self.isTrimmedAtStart = isTrimmedAtStart
            self.isTrimmedAtEnd = isTrimmedAtEnd
        }
    }

    /// The verse split around `startOffset..<endOffset`, trimmed to `window`
    /// characters either side.
    ///
    /// Offsets count **code points**, as every annotation offset in Lamp
    /// does. Slicing the scalars rather than `Array(verse)` is the whole
    /// point: a verse with a decomposed accent earlier in it has more scalars
    /// than Characters, and cutting by Character moves the highlight off the
    /// word — which is what this comment used to recommend, and what it did.
    /// Measured over the bundled texts, in verses where the two units differ,
    /// every tag lands by code point and none by grapheme.
    ///
    /// `window` is counted the same way, so a long verse is trimmed by the
    /// unit it is sliced by.
    ///
    /// Out-of-range offsets are clamped rather than trusted. They have been
    /// wrong before — the book readers indexed characters while the converters
    /// counted scalars — and a verse is the one place where being wrong by a
    /// little means slicing a sentence mid-word instead of crashing, which is
    /// harder to notice.
    public static func snippet(
        of verse: String,
        from startOffset: Int,
        to endOffset: Int,
        window: Int = 72
    ) -> Snippet {
        let scalars = Array(verse.unicodeScalars)
        let start = min(max(0, startOffset), scalars.count)
        let end = min(max(start, endOffset), scalars.count)
        func text(_ slice: ArraySlice<Unicode.Scalar>) -> String {
            String(String.UnicodeScalarView(slice))
        }

        var before = text(scalars[..<start])
        var after = text(scalars[end...])
        let word = text(scalars[start..<end])

        var trimmedStart = false
        if before.unicodeScalars.count > window {
            before = text(Array(before.unicodeScalars).suffix(window)[...])
            // Not mid-word: start at the next space, so a row never opens on
            // half of a word.
            if let space = before.firstIndex(of: " ") {
                before = String(before[before.index(after: space)...])
            }
            trimmedStart = true
        }
        var trimmedEnd = false
        if after.unicodeScalars.count > window {
            after = text(Array(after.unicodeScalars).prefix(window)[...])
            if let space = after.lastIndex(of: " ") {
                after = String(after[..<space])
            }
            trimmedEnd = true
        }

        return Snippet(
            before: before,
            word: word,
            after: after,
            isTrimmedAtStart: trimmedStart,
            isTrimmedAtEnd: trimmedEnd
        )
    }
}

/// Each division's proportion of the whole.
public enum LampStrongsShare {
    public struct Slice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let value: Int
        /// 0...1 of the total.
        public let fraction: Double
        /// True for the slice that gathers everything past the limit.
        public let isOther: Bool

        public init(id: String, name: String, value: Int, fraction: Double, isOther: Bool = false) {
            self.id = id
            self.name = name
            self.value = value
            self.fraction = fraction
            self.isOther = isOther
        }
    }

    /// The largest divisions by count, with the rest gathered into "Other".
    ///
    /// Gathered rather than drawn, because a ring of twenty-seven slivers
    /// answers no question anyone has. Divisions holding nothing are left out
    /// entirely: a slice of zero is invisible but still takes a label.
    public static func slices(
        from divisions: [LampStrongsAnalysis.Division],
        limit: Int = 6
    ) -> [Slice] {
        let total = divisions.reduce(0) { $0 + $1.occurrenceCount }
        guard total > 0 else { return [] }
        let ranked = divisions
            .filter { $0.occurrenceCount > 0 }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
        let kept = ranked.prefix(limit)
        var slices = kept.map {
            Slice(
                id: String($0.id),
                name: $0.name,
                value: $0.occurrenceCount,
                fraction: Double($0.occurrenceCount) / Double(total)
            )
        }
        let rest = ranked.dropFirst(kept.count).reduce(0) { $0 + $1.occurrenceCount }
        if rest > 0 {
            slices.append(
                Slice(
                    id: "other",
                    name: "Other",
                    value: rest,
                    fraction: Double(rest) / Double(total),
                    isOther: true
                )
            )
        }
        return slices
    }
}

extension LampStrongsShare {
    /// At or above this share, one slice is nearly the whole ring.
    public static let dominantFraction = 0.9

    /// Whether one count is nearly all of them, so a ring of them says
    /// only that, and a list says it as well with the rest legible.
    ///
    /// Both apps open such a figure as a list. A blind panel marked down the
    /// ring in every round when one slice held 97%: four 1% slivers that no
    /// reader can tell apart.
    public static func isDominated(_ counts: [Int]) -> Bool {
        let total = counts.reduce(0, +)
        guard total > 0, let largest = counts.max() else { return false }
        return Double(largest) / Double(total) >= dominantFraction
    }
}

/// How strongly a companion goes with the key, for showing beside it.
///
/// Companions are listed by their keyness (log-likelihood), the strength of
/// the association, which is not the multiplier beside them: a high multiple
/// over few verses says less than a smaller one over many. Shown as a share
/// of the strongest, so the order reads as sorted.
public enum LampStrongsCompanionStrength {
    /// 0...1: this companion's keyness against the strongest listed.
    public static func fraction(
        of companion: LampStrongsAnalysis.Companion,
        among companions: [LampStrongsAnalysis.Companion]
    ) -> Double {
        let strongest = companions.map(\.keyness).max() ?? 0
        guard strongest > 0 else { return 0 }
        return min(max(companion.keyness / strongest, 0), 1)
    }
}

/// Every chapter of every book, shaded by how often the key occurs.
public enum LampStrongsGrid {
    public struct Cell: Identifiable, Equatable, Sendable {
        public var id: Int { number }
        public let number: Int
        public let occurrenceCount: Int
        /// 0...1 against the busiest chapter anywhere in the grid.
        public let intensity: Double

        public init(number: Int, occurrenceCount: Int, intensity: Double) {
            self.number = number
            self.occurrenceCount = occurrenceCount
            self.intensity = intensity
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let cells: [Cell]
        public let occurrenceCount: Int

        public init(id: Int, name: String, cells: [Cell], occurrenceCount: Int) {
            self.id = id
            self.name = name
            self.cells = cells
            self.occurrenceCount = occurrenceCount
        }
    }

    /// Rows for the books that hold the key.
    ///
    /// Shaded against the busiest chapter in the whole grid rather than the
    /// busiest in each row: per-row shading would paint a book with one
    /// occurrence as darkly as 1 John 4, which is the opposite of what the
    /// picture is for.
    public static func rows(
        from books: [LampStrongsAnalysis.Division],
        includingEmptyBooks: Bool = false
    ) -> [Row] {
        let busiest = books.flatMap(\.chapters).map(\.occurrenceCount).max() ?? 0
        return books.compactMap { book in
            guard includingEmptyBooks || book.occurrenceCount > 0 else { return nil }
            guard !book.chapters.isEmpty else { return nil }
            return Row(
                id: book.id,
                name: book.name,
                cells: book.chapters.map { chapter in
                    Cell(
                        number: chapter.number,
                        occurrenceCount: chapter.occurrenceCount,
                        intensity: busiest > 0
                            ? Double(chapter.occurrenceCount) / Double(busiest)
                            : 0
                    )
                },
                occurrenceCount: book.occurrenceCount
            )
        }
    }
}

/// A division to chart, with the filter choosing it should apply.
///
/// Carried together because they come apart: a bar in a chart of renderings
/// looks like a bar in a chart of books, but choosing it means "only this
/// rendering", not "only this book".
public struct LampStrongsChartDivision: Identifiable, Equatable, Sendable {
    public let division: LampStrongsAnalysis.Division
    public let filter: LampStrongsFilter?

    public var id: Int { division.id }

    public init(division: LampStrongsAnalysis.Division, filter: LampStrongsFilter?) {
        self.division = division
        self.filter = filter
    }
}

/// What a chart's bars stand for.
public enum LampStrongsGrouping: String, CaseIterable, Identifiable, Sendable {
    case books
    case sections
    case renderings
    case forms

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .books: "Books"
        case .sections: "Sections"
        case .renderings: "Translated As"
        case .forms: "Forms"
        }
    }

    /// Whether "per 1,000 words" means anything.
    ///
    /// A book has a word count to measure against. A rendering is a count of
    /// itself: there is no population of "words that could have been
    /// rendered this way", so a rate would be a number with no question
    /// behind it.
    public var usesMeasure: Bool { self == .books || self == .sections }

    /// Only books carry chapters, so only books can be shaded as a grid.
    public var hasChapters: Bool { self == .books }

    /// The divisions to chart, each with the filter it stands for.
    ///
    /// Renderings and forms are turned into divisions so one set of charts
    /// can draw all four groupings. They carry no keyness — a rendering is
    /// not more or less frequent than chance predicts, it is simply a choice
    /// translators made — so nothing is ever marked "more" or "fewer" here.
    public func divisions(of analysis: LampStrongsAnalysis) -> [LampStrongsChartDivision] {
        switch self {
        case .books:
            analysis.books.map { .init(division: $0, filter: .book(number: $0.id)) }
        case .sections:
            // A section spans several books, and no single filter says
            // "these books", so choosing one narrows nothing.
            analysis.sections.map { .init(division: $0, filter: nil) }
        case .renderings:
            analysis.renderings.enumerated().map { index, rendering in
                .init(
                    division: Self.standIn(
                        id: index, name: rendering.text.isEmpty
                            ? "(no English of its own)"
                            : rendering.text,
                        count: rendering.count
                    ),
                    filter: .rendering(id: rendering.id, text: rendering.text)
                )
            }
        case .forms:
            analysis.forms.enumerated().map { index, form in
                .init(
                    division: Self.standIn(id: index, name: form.text, count: form.count),
                    filter: .form(form.text)
                )
            }
        }
    }

    /// A division that only carries a name and a count.
    ///
    /// `wordCount` is zero, which makes `ratePerThousandWords` zero — correct
    /// rather than merely safe, since there is no population to be a rate of,
    /// and the measure picker is hidden for these groupings anyway.
    private static func standIn(
        id: Int,
        name: String,
        count: Int
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id,
            name: name,
            bookRange: 0...0,
            occurrenceCount: count,
            verseCount: count,
            wordCount: 0,
            expectedCount: 0,
            keyness: 0,
            chapters: []
        )
    }
}

/// Which dictionary's entry the Strong's pane's Definition shows.
public enum LampStrongsDefinitionChoice {
    /// The dictionary chosen from the menu, then the default for the key's
    /// language, then the first that has an entry — and only ever one of
    /// `withEntries`, so the pane never opens on a dictionary with nothing to
    /// say about the word while another has an entry.
    public static func shown(
        among withEntries: [String],
        chosen: String?,
        preferred: String?
    ) -> String? {
        if let chosen, withEntries.contains(chosen) { return chosen }
        if let preferred, withEntries.contains(preferred) { return preferred }
        return withEntries.first
    }
}

/// The Septuagint section of the Analyse pane: the Hebrew a Greek word renders
/// in the Septuagint, and what that Hebrew does in the Old Testament.
///
/// The counts and verses here belong to the *Hebrew* word, not to the Greek
/// one — the Septuagint does not always use this Greek word where that Hebrew
/// stands. Every heading says so, because a bare number beside a Greek word
/// reads as the Greek word's own, and would be wrong.
public enum LampSeptuagintSection {
    /// The Hebrew words a Greek entry's senses name, in the order the lexicon
    /// prints them, without the same word twice.
    ///
    /// A word repeated across senses is one word to a reader. Identity is the
    /// printed word with its number, so two different words that happen to
    /// share a number — or one word with and without a stem — are not folded
    /// together.
    public static func words(in senses: [LampDictionarySense]) -> [LampSeptuagintHebrew] {
        var seen = Set<String>()
        return senses.flatMap(\.septuagintHebrew).filter {
            seen.insert("\($0.text)|\($0.strongs ?? "")").inserted
        }
    }

    /// The printed word with the stem the note gives it: "רנן pi.".
    public static func word(_ hebrew: LampSeptuagintHebrew) -> String {
        guard let stem = hebrew.stem else { return hebrew.text }
        return "\(hebrew.text) \(stem)"
    }

    /// What to say where the Greek text has no such verse, naming the text.
    ///
    /// The absence belongs to the edition, not to the Septuagint: Brenton
    /// prints Codex Vaticanus, whose shorter David and Goliath leaves out
    /// 1 Samuel 17:12–31 and 18:1–5 among others, which other witnesses have.
    /// Saying "the Septuagint doesn't have this verse" would be a claim about
    /// the whole tradition that the installed text cannot support.
    public static func missingVerse(in septuagint: String?) -> String {
        guard let septuagint, !septuagint.isEmpty else {
            return "This verse isn’t in the Greek text installed."
        }
        return "This verse isn’t in \(septuagint)."
    }

    /// What stands in place of the verses when no Septuagint is installed.
    ///
    /// Said once, because it is one fact about the library rather than
    /// twenty-five facts about the text. `missingVerse(in:)` would be wrong
    /// here in both halves: it names a text that isn't there, and it says the
    /// verse is absent from it, which nothing has checked.
    public static let withoutSeptuagint =
        "No Septuagint is installed, so there’s no Greek to put beside these verses."

    /// What to say when the Greek text is installed but could not be read.
    ///
    /// Kept apart from `missingVerse(in:)` deliberately. That one is a claim
    /// about the text — this verse is not in it — and this one is a claim
    /// about the attempt, which is all a failed read supports.
    public static func unreadable(_ septuagint: String?) -> String {
        guard let septuagint, !septuagint.isEmpty else {
            return "The Greek text couldn’t be read."
        }
        return "\(septuagint) couldn’t be read."
    }

    /// The Septuagint's Greek for each of `references`, given in the Hebrew
    /// text's numbering, read a chapter at a time.
    ///
    /// Each reference is converted from the Hebrew text's numbering to the
    /// Septuagint's — Psalm 51:5 is the Septuagint's 50:7 — which is why the
    /// Septuagint is found by declaring that numbering rather than by name. A
    /// verse the conversion has no counterpart for, or the chapter does not
    /// hold, is left out; `missingVerse(in:)` says so for it. Each chapter is
    /// read once however many references fall in it, and a chapter that
    /// cannot be read leaves its verses out rather than ending the rest.
    ///
    /// Cancelled, it throws rather than return what it has: a verse it never
    /// reached would be absent too, and absence here is read as the text not
    /// having the verse, which for an unread verse is false.
    public static func greek(
        for references: [Int],
        hebrewNumbering: LampVersification,
        septuagintNumbering: LampVersification,
        readChapter: (_ book: Int, _ chapter: Int) async throws -> [Int: String]
    ) async throws -> [Int: String] {
        try await verses(
            for: references,
            numbering: hebrewNumbering,
            textNumbering: septuagintNumbering,
            readChapter: readChapter
        )
    }

    /// One text's verses for references given in another text's numbering,
    /// read a chapter at a time.
    ///
    /// The same walk `greek(for:…)` is named for, which the Septuagint's own
    /// verses need in the other direction: their English companion is read
    /// for references the Greek text numbers. Each chapter is read once
    /// however many references fall in it, a reference the conversion has no
    /// counterpart for is left out, and a chapter that cannot be read costs
    /// only its own verses.
    ///
    /// Cancelled, it throws rather than return what it has: a verse it never
    /// reached would be absent too, and absence is read as the text not
    /// having the verse, which for an unread verse is false.
    public static func verses(
        for references: [Int],
        numbering: LampVersification,
        textNumbering: LampVersification,
        readChapter: (_ book: Int, _ chapter: Int) async throws -> [Int: String]
    ) async throws -> [Int: String] {
        var chapters: [Int: [Int: String]] = [:]
        var read: [Int: String] = [:]
        for reference in references {
            try Task.checkCancellation()
            // Every verse the text numbers for this one, not the first of
            // them: a psalm's title is one verse here and two in the
            // Septuagint, and half a title is not the verse.
            var halves: [String] = []
            for mapped in numbering.counterparts(of: reference, in: textNumbering) {
                let parts = LampBibleReferenceFormatter.components(of: mapped)
                let chapterKey = parts.book * 1_000 + parts.chapter
                if chapters[chapterKey] == nil {
                    do {
                        chapters[chapterKey] = try await readChapter(parts.book, parts.chapter)
                    } catch {
                        // A read cut short by cancellation is not a chapter
                        // that could not be read.
                        try Task.checkCancellation()
                        chapters[chapterKey] = [:]
                    }
                }
                if let text = chapters[chapterKey]?[parts.verse] { halves.append(text) }
            }
            if !halves.isEmpty {
                read[reference] = halves.joined(separator: " ")
            }
        }
        return read
    }

    /// The whole section's title, with the Greek word's own use in the
    /// Septuagint above and the Hebrew words it translates below.
    ///
    /// `title` stays the heading of the lower half, which is what it has
    /// always named, so nothing that draws it has to change.
    public static let ownUseTitle = "In the Septuagint"

    /// Why the Greek word's own Septuagint verses are worth a reader's time,
    /// said for someone who does not read Greek and will not be reading them
    /// in Greek.
    /// The one heading over everything said about how the section's figures
    /// were arrived at: what the Septuagint is, what the tags are, and what
    /// a crossed verse list cannot promise.
    ///
    /// One disclosure rather than five open paragraphs. A blind design panel
    /// read the section with the method written out around the charts and
    /// called it documentation rather than analysis — "five separate
    /// paragraphs at caption size stack between the charts, so the figures
    /// get buried" — while asking for the same sentences to be kept and
    /// grouped. They are all still here, one press away.
    public static let methodologyTitle = "How this is counted"

    /// The disclosure above the Hebrew words' lists that says, collapsed by
    /// default, how far they are narrowed (`renderedHeading`): kept one
    /// press away rather than as a paragraph, which read as hedging (owner,
    /// Nov 2026).
    public static let narrowingTitle = "Which verses are listed"

    public static let ownUseAbout =
        "The Septuagint is the Greek Old Testament the New Testament’s first "
        + "readers knew, so the same Greek word here shows what it was already "
        + "used to say."

    /// What to say under figures a text's own machine-made tags produced.
    ///
    /// Shown where the text declares that its Strong's numbers were matched
    /// rather than printed, and only there: a published tagged text says
    /// nothing of the sort. The order of the sentence is the order of the
    /// certainty — which word it is, then its dictionary form, then the
    /// parse, which is where a tagger's mistakes gather, and which is what
    /// the case, number and gender figures above it are made of. The full
    /// statement, with its source, is in the tagging's own disclosure
    /// beside the forms.
    public static let ownUseCaution =
        "These figures are read from that text’s own tags, which Lamp made by "
        + "machine rather than finding them printed. Which word each one is, "
        + "and its dictionary form, are surer than its case, number and gender."

    /// What the Greek word's own use in the Septuagint comes to, in one line.
    ///
    /// Verses rather than words, because a verse is what a reader goes and
    /// reads, and because the two Testaments' counts are then in the same
    /// unit as everything else the pane says. The New Testament's count is
    /// given beside it only when that text is installed and analysed: a
    /// missing half would otherwise read as a count of nothing.
    ///
    /// The counts stand side by side and are never added, nor divided into
    /// one another. The Septuagint is the longer text by far, so a bare
    /// multiple would flatter it, and "as often for its length" is a claim
    /// about rates this line does not make — the spread below carries that.
    public static func ownUseHeadline(
        greek lemma: String?,
        septuagint: LampStrongsAnalysis,
        newTestament: LampStrongsAnalysis?
    ) -> String {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "This word"
        let greek = septuagint.references.count
        func verses(_ count: Int) -> String {
            "\(count) \(count == 1 ? "verse" : "verses")"
        }
        let opening = "\(lemma) stands in \(verses(greek)) of the Greek Old Testament"
        guard let newTestament, !newTestament.references.isEmpty else { return opening + "." }
        return opening + ", and in \(verses(newTestament.references.count)) "
            + "of the New Testament."
    }

    /// One Greek word's use in the two Testaments, side by side.
    ///
    /// For a reader with no Greek this is what a tagged Septuagint is for:
    /// whether the word they are reading in the New Testament was already a
    /// word of the Greek Old Testament, and how much of one.
    ///
    /// The counts stand apart and are never added — they are two texts, not
    /// two halves of one — and each bar is drawn against the larger side
    /// rather than against their sum, so neither can be read as a share of a
    /// whole. The rate per thousand tagged words is given beside them,
    /// because 1,238 against 330 is in good part the Septuagint being the
    /// longer book, and a reader who is told only the counts will conclude
    /// something the counts do not say.
    public struct Contrast: Equatable, Sendable {
        public struct Side: Equatable, Sendable {
            /// What a reader knows the text as.
            public var label: String
            /// The module the count was read from, for saying where it came
            /// from and whose tagging stands behind it.
            public var source: String
            /// Verses holding the word — what a reader goes and reads.
            public var verseCount: Int
            public var occurrenceCount: Int
            /// The text's tagged words of the key's language: the rate's own
            /// denominator, not a count of the text's words.
            public var wordCount: Int

            public init(
                label: String, source: String, verseCount: Int,
                occurrenceCount: Int, wordCount: Int
            ) {
                self.label = label
                self.source = source
                self.verseCount = verseCount
                self.occurrenceCount = occurrenceCount
                self.wordCount = wordCount
            }

            /// Occurrences per thousand tagged words. Zero where nothing is
            /// tagged, which is no rate at all rather than a rate of none.
            public var perThousandWords: Double {
                wordCount > 0 ? Double(occurrenceCount) * 1_000 / Double(wordCount) : 0
            }
        }

        public var newTestament: Side
        public var septuagint: Side

        public init(newTestament: Side, septuagint: Side) {
            self.newTestament = newTestament
            self.septuagint = septuagint
        }

        /// Each side's bar as a fraction of the larger side's verses, so the
        /// longer bar is full and the shorter is read against it.
        public func share(of side: Side) -> Double {
            let largest = max(newTestament.verseCount, septuagint.verseCount)
            guard largest > 0 else { return 0 }
            return Double(side.verseCount) / Double(largest)
        }
    }

    /// The two Testaments side by side, when both have something to show.
    ///
    /// Nil unless both sides hold the word: one side alone is not a contrast,
    /// and `ownUseHeadline(greek:septuagint:newTestament:)` says what there is
    /// to say in that case. The Septuagint is named as installed, since which
    /// Greek Old Testament it is matters to every count under it.
    public static func contrast(
        newTestament: LampStrongsAnalysis?,
        septuagint: LampStrongsAnalysis?
    ) -> Contrast? {
        guard let newTestament, let septuagint,
              !newTestament.references.isEmpty, !septuagint.references.isEmpty
        else { return nil }
        return Contrast(
            newTestament: Contrast.Side(
                label: "New Testament",
                source: newTestament.translationName,
                verseCount: newTestament.references.count,
                occurrenceCount: newTestament.occurrenceCount,
                wordCount: newTestament.wordCount
            ),
            septuagint: Contrast.Side(
                label: "Septuagint",
                source: septuagint.translationName,
                verseCount: septuagint.references.count,
                occurrenceCount: septuagint.occurrenceCount,
                wordCount: septuagint.wordCount
            )
        )
    }

    /// The one thing the two bars cannot show, said under them: how often
    /// the word stands for the length of each text, since a word can stand
    /// in four times as many Septuagint verses and still be the rarer word
    /// there. Empty where either side has no tagged words to count against;
    /// the bars say the rest themselves (owner, Nov 2026: the prose about
    /// how they are drawn was dropped).
    public static func contrastCaption(_ contrast: Contrast) -> String {
        func rate(_ side: Contrast.Side) -> String {
            let value = side.perThousandWords
            // A word standing 14 times in the Septuagint's 476,000 tagged
            // words is 0.03 per thousand, which one decimal place prints as
            // "0.0" — a figure that reads as "none at all" beside a count of
            // 14 right above it. Two places where one would round a real
            // rate away; never for a rate that is truly zero.
            if value > 0, value < 0.1 { return String(format: "%.2f", value) }
            return String(format: "%.1f", value)
        }
        let sides = [contrast.newTestament, contrast.septuagint]
        guard sides.allSatisfy({ $0.wordCount > 0 }) else { return "" }
        return "Per 1,000 tagged words: \(rate(contrast.newTestament)) in the New Testament, "
            + "\(rate(contrast.septuagint)) in the Septuagint."
    }

    /// The number a reader looks one of those verses up by: their own
    /// translation's, where it has the verse, and the Septuagint's own where
    /// it does not.
    ///
    /// The Septuagint numbers Psalm 51:5 as 50:7, and a reader sent to 50:7
    /// finds another psalm in the Bible they own. Where the conversion has no
    /// counterpart the Septuagint's own number is all there is — the verse
    /// exists only there — and `isTheSeptuagintsOwn` says so, rather than
    /// leaving the row to imply a verse the reader's Bible has.
    public struct Numbering: Equatable, Sendable {
        public var reference: Int
        public var isTheSeptuagintsOwn: Bool

        public init(reference: Int, isTheSeptuagintsOwn: Bool) {
            self.reference = reference
            self.isTheSeptuagintsOwn = isTheSeptuagintsOwn
        }
    }

    /// Each Septuagint reference as the reader looks it up, keyed by the
    /// reference the Greek text numbers it.
    public static func readerNumbering(
        of references: [Int],
        septuagintNumbering: LampVersification,
        readerNumbering: LampVersification
    ) -> [Int: Numbering] {
        var numbered: [Int: Numbering] = [:]
        for reference in references {
            // One destination, because that is all opening a verse can be.
            if let mapped = septuagintNumbering.opens(reference, in: readerNumbering) {
                numbered[reference] = Numbering(reference: mapped, isTheSeptuagintsOwn: false)
            } else {
                numbered[reference] = Numbering(reference: reference, isTheSeptuagintsOwn: true)
            }
        }
        return numbered
    }

    /// Which of a Hebrew word's verses the Septuagint renders with this
    /// Greek word, by reading its own tags.
    ///
    /// Until the Septuagint was tagged, a Hebrew word's verses were all that
    /// could be listed, and the Greek under any one of them might use quite
    /// another word: for דָבָר it uses λόγος in 575 of 1,289 verses, so
    /// more than half the list was beside the point for a reader studying
    /// λόγος. With both texts tagged the two lists can be crossed, and
    /// what is left is the verses where the Hebrew word stands and the
    /// Septuagint reached for this Greek word.
    ///
    /// References come in and go out in the Hebrew text's numbering, since
    /// that is what the rows are keyed by; the Septuagint's own numbering is
    /// used only to look each one up (its Psalm 50:7 is the Hebrew's 51:5).
    ///
    /// What this says, exactly: the Greek verse holds the word. It does not
    /// say the Greek word stands for *this* Hebrew word there rather than
    /// for another word of the same verse, which no tag in either text can
    /// settle. Narrow a list by it, and say what the narrowing means.
    public static func versesRenderedByGreek(
        hebrew references: [Int],
        hebrewNumbering: LampVersification,
        septuagintNumbering: LampVersification,
        septuagintReferences: Set<Int>
    ) -> Set<Int> {
        guard !septuagintReferences.isEmpty else { return [] }
        var found = Set<Int>()
        for reference in references {
            // Any counterpart carrying the Greek word makes this verse one of
            // the word's. A Hebrew psalm title answers to two Septuagint
            // verses, and the word may stand in either.
            let mapped = hebrewNumbering.counterparts(of: reference, in: septuagintNumbering)
            if mapped.contains(where: septuagintReferences.contains) { found.insert(reference) }
        }
        return found
    }

    /// What the narrowed list is, said where a reader can act on it.
    ///
    /// Named rather than counted alone, because "575 of 1,289" invites the
    /// reading that the other 714 are missing something; they are verses the
    /// Septuagint translated another way, which is a fact about the Greek
    /// and not a gap.
    public static func renderedHeading(
        greek lemma: String?,
        shown: Int,
        of total: Int
    ) -> String {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "this word"
        guard total > 0 else { return "" }
        guard shown < total else {
            return "The Septuagint uses \(lemma) in all \(total) of them."
        }
        return "Narrowed to the \(shown) of \(total) where the Septuagint uses "
            + "\(lemma); in the rest it translates the Hebrew another way."
    }

    /// What a narrowed list does not promise, said with it.
    ///
    /// The crossing is of verses, not of words. A verse is kept because the
    /// Hebrew word stands in it and the Greek word stands in the
    /// Septuagint's verse at the same place; in a long verse the Greek word
    /// may be rendering some other word of it, and no tag in either text can
    /// settle which. Narrowing a list makes a reader trust it more, so what
    /// it still cannot show has to be said beside it rather than left to be
    /// assumed.
    public static func renderedCaveat(greek lemma: String?) -> String {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "the Greek word"
        return "A verse is here because both stand in it: the Hebrew word, and "
            + "\(lemma) in the Greek. In a long verse \(lemma) may be translating "
            + "another word of it."
    }

    /// What stands in the way of reading one crossed verse as a pairing.
    ///
    /// The crossing is of verses: this Hebrew word stands in the verse, and
    /// the Greek word stands in the Septuagint's. Three things can make that
    /// less than a pairing, and each is worth saying because each is a
    /// different doubt:
    ///
    /// - the Hebrew word stands more than once, so at most one of them is
    ///   the one the Greek word renders;
    /// - the Greek word stands more than once, the same the other way round;
    /// - another Hebrew word that this same Greek word renders stands in the
    ///   verse too, which is the case most likely to mislead, since the
    ///   Greek word may belong to that one instead.
    ///
    /// Nil where none of them holds: one of each, and nothing competing for
    /// it. That is as strong as a verse-level crossing can be, and a row
    /// with nothing said against it should read that way.
    /// Whether where the words stand settles which Greek occurrence answers
    /// to which Hebrew one, clearly enough to stop warning about it.
    ///
    /// Positions are each word's midpoint as a fraction of its own verse,
    /// 0 to 1. A Septuagint verse and its Hebrew do not run to the same
    /// length, but a word's place within its verse carries across: measured
    /// over 5,762 pairings that are forced — one occurrence on each side, so
    /// the answer is not in doubt — the Greek word sits a median 0.028 from
    /// where the Hebrew word sits, and 90% of them within 0.092.
    ///
    /// So the nearest candidate wins, but only when it is genuinely near
    /// (within that 0.092, rounded to `near`) and the next is genuinely far
    /// (`far`). Gated that way it answered 517 two-candidate problems whose
    /// answer was known from 99.6% correct, against 95.8% for nearest alone,
    /// and it settles about 70% of the verses that carry a doubt. Ungated it
    /// would be wrong about one verse in twenty-four.
    ///
    /// This is inference from position, not a reading from any source, so it
    /// is only ever used to decide **whether to warn** — never to print which
    /// Hebrew word a Greek word renders. Where it does not settle, the doubt
    /// stands as written.
    ///
    /// Measured on the books where the two numbering systems agree. Psalms,
    /// Jeremiah, Esther and Daniel were left out, and they are also where the
    /// Greek word order is freest, so 99.6% is the better case rather than
    /// the average one.
    public static func pairingIsSettled(
        hebrewAt: [Double],
        greekAt: [Double],
        near: Double = 0.09,
        far: Double = 0.20
    ) -> Bool {
        guard !hebrewAt.isEmpty, !greekAt.isEmpty else { return false }
        // One each is settled by arithmetic, not by position.
        guard hebrewAt.count > 1 || greekAt.count > 1 else { return true }
        // More Hebrew occurrences than Greek ones means at least one Hebrew
        // word the Greek cannot be answering to; nothing to settle.
        guard hebrewAt.count <= greekAt.count else { return false }
        var taken: [Int] = []
        for position in hebrewAt {
            let ranked = greekAt.enumerated()
                .map { (index: $0.offset, distance: abs($0.element - position)) }
                .sorted { $0.distance < $1.distance }
            guard let best = ranked.first, best.distance <= near else { return false }
            if ranked.count > 1, ranked[1].distance < far { return false }
            // Two Hebrew words cannot both answer to the same Greek one.
            if taken.contains(best.index) { return false }
            taken.append(best.index)
        }
        return true
    }

    public static func pairingDoubt(
        greek lemma: String?,
        hebrew word: String,
        hebrewOccurrences: Int,
        greekOccurrences: Int,
        alsoRendered: [String]
    ) -> String? {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "the Greek word"
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var doubts: [String] = []
        if hebrewOccurrences > 1 {
            doubts.append("\(word.isEmpty ? "the Hebrew word" : Self.isolated(word)) stands "
                + "\(Self.times(hebrewOccurrences)) in this verse")
        }
        if greekOccurrences > 1 {
            doubts.append("\(lemma) stands \(Self.times(greekOccurrences)) in the Greek")
        }
        let competing = alsoRendered
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !competing.isEmpty {
            doubts.append("\(lemma) also renders \(Self.joined(competing.map(Self.isolated))), "
                + "which stands here too")
        }
        guard !doubts.isEmpty else { return nil }
        // Read as an English sentence, whatever it opens with. A sentence
        // beginning with a Hebrew word takes that word's direction for the
        // whole paragraph, which threw the full stop to the front and left
        // the Hebrew stranded at the end — a design panel read the result as
        // a rendering fault, in four separate reports.
        return "\u{200E}" + doubts.joined(separator: "; ") + "."
    }

    /// A word of another script set inside an English sentence, isolated so
    /// neither the sentence's punctuation nor the word's own order moves.
    ///
    /// First-strong isolate rather than a left-to-right mark: the mark fixes
    /// the direction around the word, the isolate keeps the word itself from
    /// joining what is beside it.
    private static func isolated(_ text: String) -> String {
        "\u{2068}\(text)\u{2069}"
    }

    /// "a", "a and b", "a, b and c". Callers isolate each item that is not
    /// English before handing it in, so the list reads left to right
    /// whichever way an item's own script runs.
    private static func joined(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func times(_ count: Int) -> String {
        switch count {
        case 2: "twice"
        case 3: "three times"
        default: "\(count) times"
        }
    }

    /// A Hebrew word's heading, naming whose verses they are.
    ///
    /// With its transliteration and the English it is most often rendered
    /// by, it reads to someone with no Hebrew: "ʼahăbâh “love” (H160) · in
    /// 40 Hebrew verses". Without them it is the Hebrew as printed: "Hebrew
    /// אַהֲבָה (H160) · 40 verses".
    /// `usingGreek` names the Greek word when the count beside a Hebrew word
    /// is the narrowed one. Without it "in 735 Hebrew verses" reads as all
    /// the verses that Hebrew word stands in, which is the number the list
    /// was narrowed *from*. `of` is that number, where it is known: "130 of
    /// 158 verses using ὀργή" keeps in the heading the fact that the list
    /// is narrowed, and from how many, which a sentence above the lists
    /// once said.
    public static func heading(
        _ hebrew: LampSeptuagintHebrew,
        transliteration: String? = nil,
        rendering: String? = nil,
        verses: Int,
        of total: Int? = nil,
        usingGreek: String? = nil
    ) -> String {
        let transliteration = transliteration.flatMap { $0.isEmpty ? nil : $0 }
        let rendering = rendering.flatMap { $0.isEmpty ? nil : $0 }
        let greek = usingGreek.flatMap { $0.isEmpty ? nil : $0 }
        // A total only beside a narrowed count, and only where it narrows.
        let ofTotal = greek != nil ? total.flatMap { $0 > verses ? " of \($0)" : nil } ?? "" : ""
        let verseWord = (ofTotal.isEmpty ? verses : total ?? verses) == 1 ? "verse" : "verses"
        let counted = greek.map { "\(verses)\(ofTotal) \(verseWord) using \($0)" }
            ?? "in \(verses) Hebrew \(verseWord)"
        guard transliteration != nil || rendering != nil else {
            let name = hebrew.strongs.map { "\(word(hebrew)) (\($0))" } ?? word(hebrew)
            return greek.map { "Hebrew \(name) · \(verses)\(ofTotal) \(verseWord) using \($0)" }
                ?? "Hebrew \(name) · \(verses) \(verseWord)"
        }
        var name = [transliteration ?? word(hebrew), rendering.map { "“\($0)”" }]
            .compactMap { $0 }
            .joined(separator: " ")
        if let strongs = hebrew.strongs { name += " (\(strongs))" }
        return "\(name) · \(counted)"
    }

    /// The section's title. It is the Hebrew a Greek word translates, which
    /// the title says, because "Septuagint" alone promised the Greek word's
    /// own verses through the Old Testament.
    public static let title = "Hebrew It Translates"

    /// What the installed Septuagint can say about the Greek word itself, as
    /// far as that has been looked up.
    ///
    /// Four cases rather than an optional name, on the rule the verses
    /// themselves keep: "not looked up yet", "none installed" and "installed,
    /// and prints no tags" are three different things to say, and an optional
    /// name said all three in the same words. Unknown, the note says nothing
    /// about tagging at all, rather than say one of the others and be wrong.
    public enum Tagging: Equatable, Sendable {
        /// Not looked up yet.
        case unknown
        /// No Septuagint installed. The verses say so themselves
        /// (`withoutSeptuagint`), so the note does not say it twice. Not
        /// spelt `none`, which would read as `Optional.none` wherever a
        /// `Tagging?` is written.
        case notInstalled
        /// A Septuagint that prints no Strong's numbers, named as installed.
        case untagged(String)
        /// A Septuagint that tags its own words, named as installed.
        case tagged(String)
    }

    /// What the section is, said once at its top: the lexicon's link from the
    /// Greek word to these Hebrew words, and why the verses are the Hebrew
    /// word's rather than the Greek word's.
    ///
    /// The verses are the Hebrew word's whichever way `septuagint` falls:
    /// they come from the lexicon's link between the words, not from the
    /// Greek text's tags. What changes is what can be said about the Greek
    /// word itself. Untagged, nothing in that text can count it, which the
    /// note says of that text by name rather than of the Septuagint at
    /// large. Tagged, saying it would be false — the text is analysed like
    /// any other translation, with this word's own verses and counts — so
    /// the note sends the reader to it instead.
    public static func note(greek lemma: String?, septuagint: Tagging = .unknown) -> String {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "this word"
        let whose = "The Septuagint, the Greek Old Testament, uses \(lemma) mostly "
            + "for these Hebrew words. The verses are each Hebrew word’s, not "
            + "\(lemma)’s"
        func named(_ name: String, or fallback: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        switch septuagint {
        case .unknown, .notInstalled:
            return whose + "."
        case .untagged(let name):
            return whose + ": \(named(name, or: "the Septuagint installed")) "
                + "isn’t tagged word by word, so its Greek, under each verse, "
                + "may use another word."
        case .tagged:
            // Nothing: the words below and their headings ("130 of 158
            // verses using ὀργή") say it, and the sentence that said it
            // again was read as hedging (owner, Nov 2026).
            return ""
        }
    }

    /// What a Hebrew word is most often rendered by in an English
    /// translation's analysis of it: a gloss a reader with no Hebrew can
    /// read, and a fact about that translation rather than a definition.
    public static func rendering(in analysis: LampStrongsAnalysis) -> String? {
        analysis.renderings.first { !$0.text.isEmpty }?.text
    }

    /// One verse of a Hebrew word's list in English: its number there, and
    /// the verse with the English the word is rendered by marked.
    public struct English: Equatable, Sendable {
        /// In the English translation's own numbering, which is the number a
        /// reader of it looks the verse up by — kept whether or not the verse
        /// is marked, so one list never mixes two numberings.
        public let reference: Int
        /// The verse as that translation prints it, whole. Nil where the
        /// translation has the verse but does not tag the word in it: shown
        /// unmarked it would be a guess at which English is the word's.
        public let text: String?
        /// Every place the translation tags the word, in code points, in the
        /// order they stand. Empty exactly when `text` is nil.
        ///
        /// Every place, not the first: the Greek line beside this one marks
        /// each occurrence, and a row that marked one of two in the English
        /// said the two texts disagreed when they agreed. ABP Genesis 1:3,
        /// "Let there be light! And there was light.", is the case the owner
        /// found — one "light" marked against φῶς marked twice.
        public let marks: [Span]

        public init(reference: Int, text: String?, marks: [Span]) {
            self.reference = reference
            self.text = text
            self.marks = marks
        }
    }

    /// The English for each of `references`, given in the Hebrew text's
    /// numbering, from an English translation's analysis of the Hebrew word
    /// read with its verse text.
    ///
    /// The number needs only the two numberings; the mark needs the
    /// analysis. With no analysis — a Hebrew word with no Strong's number to
    /// analyse, or one the translation tags nowhere — every verse still has
    /// its English number, and none is marked.
    ///
    /// The marks are the translation's own tags, at the offsets it records,
    /// and nothing is guessed: a verse the translation does not tag with
    /// this word has its English number and no text. Only a verse its
    /// numbering has no counterpart for is left out, which is a different
    /// fact — the translation has no such verse, not that it doesn't use the
    /// word there.
    ///
    /// The verse comes back whole rather than cut around one occurrence. A
    /// word rendered twice is marked twice, as it is in the Greek line the
    /// row shows beside this one, and the two lines are then saying the same
    /// thing about the same verse.
    /// Where a verse row's English comes from, and which word is marked in it.
    ///
    /// Two quite different readings. The reader's own Bible translates the
    /// **Hebrew**, so the word marked in it is the Hebrew word's rendering,
    /// and the Greek beside it has to be taken on trust. A translation of
    /// the Greek Old Testament translates the **Greek**, so the word marked
    /// is that Greek word's own English — which is what someone who does
    /// not read Greek came to the section for.
    public enum EnglishSource: Equatable, Sendable {
        /// The translation being read, marked where it renders the Hebrew.
        case readersBible(moduleID: String, key: String)
        /// A translation of the Greek Old Testament, marked where it renders
        /// the Greek word itself.
        case septuagintInEnglish(moduleID: String, key: String)
    }

    /// Whether a text carries the Greek Old Testament in another language: a
    /// translation, not an original-language text, holding a Greek key in
    /// Old Testament books.
    ///
    /// Recognised by what it tags rather than by what it is called. An
    /// English Bible translated from the Hebrew tags the Old Testament with
    /// Hebrew keys; a Greek text is an original-language text; only a
    /// translation **of the Greek** tags Greek keys in those books. The
    /// Apostolic Bible Polyglot is one, and declares neither "septuagint"
    /// versification nor anything else that would say so.
    public static func rendersTheGreekOldTestament(
        _ analysis: LampStrongsAnalysis,
        isOriginalLanguage: Bool
    ) -> Bool {
        guard !isOriginalLanguage, analysis.key.uppercased().hasPrefix("G") else { return false }
        return analysis.books.contains { $0.id <= 39 && $0.occurrenceCount > 0 }
    }

    /// What the two English readings are called where a reader picks between
    /// them.
    ///
    /// Each is named by the text it is, because "Septuagint in English" and
    /// "Your Bible" told a reader nothing they could check: the owner, seeing
    /// them, could not tell which module either stood for. A module's own
    /// abbreviation is the name it wears everywhere else in the app.
    public enum EnglishChoice {
        public static let title = "English from"
        /// Used only where a module has no name to give, which no installed
        /// module should be.
        public static let direct = "Septuagint in English"
        public static let indirect = "Your Bible"

        /// Whether there are two readings to choose between.
        ///
        /// A reader whose own Bible *is* the Septuagint in English — someone
        /// reading the ABP — has one text, and the control offered it twice
        /// under one name. The indirect reading would ask that same module
        /// for the Hebrew word, which it does not tag, so the rows would go
        /// blank. One reading, and the note under it already says which.
        public static func isOffered(
            septuagintInEnglish: String?,
            readersTranslationID: String?
        ) -> Bool {
            guard let septuagintInEnglish, !septuagintInEnglish.isEmpty else { return false }
            return septuagintInEnglish != readersTranslationID
        }

        /// The two labels, each named for its text.
        public static func titles(
            septuagintInEnglish: String?,
            readersBible: String?
        ) -> (direct: String, indirect: String) {
            func named(_ name: String?, or fallback: String) -> String {
                guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { return fallback }
                return name
            }
            return (
                direct: named(septuagintInEnglish, or: direct),
                indirect: named(readersBible, or: indirect)
            )
        }

        /// What the reading chosen marks, for the disclosure under the choice,
        /// naming both texts as the picker does.
        ///
        /// Each by its name, never "your Bible" and "your translators": with
        /// both installed both are the reader's Bibles, and the picker above
        /// names them (owner, Nov 2026). Short, and only what tells the two
        /// apart: which word each marks, and the one cost of each.
        public static func note(
            readsSeptuagintInEnglish direct: Bool,
            septuagintInEnglish: String?,
            readersBible: String?,
            greek lemma: String?
        ) -> String {
            let names = titles(septuagintInEnglish: septuagintInEnglish, readersBible: readersBible)
            let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "this Greek word"
            if direct {
                return "\(names.direct) translates the Septuagint itself, so the marked word "
                    + "is the English for \(lemma). It numbers some verses differently "
                    + "from \(names.indirect)."
            }
            return "\(names.indirect) translates the Hebrew, so the marked word is its English "
                + "for the Hebrew word. Each verse listed is one where the Septuagint uses "
                + "\(lemma), so it\u{2019}s close to that word\u{2019}s sense, but the wording is "
                + "\(names.indirect)\u{2019}s, not the Greek\u{2019}s."
        }
    }

    /// The Septuagint's own Greek under each verse of the section's lists.
    ///
    /// Hidden to begin with. It is the evidence for the row — the Greek word
    /// marked where the tagging says it stands — but it doubles the height of
    /// every row, and a reader who does not read Greek never wants it. So it
    /// is offered rather than given, and the control says what it would add.
    public enum OriginalLanguage {
        /// Says what the switch does, so the sentence below is a hint rather
        /// than a line of prose standing in front of the figures. "Greek"
        /// alone left a reader to guess whether it meant the Greek text, a
        /// Greek font, or Greek word order.
        public static let title = "Greek under each verse"
        public static let note =
            "The Septuagint's own words under each verse, marked where this Greek word stands."
    }

    /// An English text split into its ordinary words and the word-order
    /// markers an interlinear prints among them.
    ///
    /// The Apostolic Bible Polyglot writes the Greek word order as numbers
    /// against the English words — "[2detested 3her 1Amnon]" — which its
    /// readers expect, but as superscripts, not as digits run into the words.
    /// In plain text they read as damage.
    ///
    /// A marker is a run of digits with a letter immediately after it and no
    /// space between. A real number is never written that way: over 4,000
    /// verses of ABP there are 11,263 markers and 7 free-standing numbers,
    /// and the rule separates them exactly.
    ///
    /// `next` is what follows `text` where a caller has the line in pieces —
    /// a verse snippet is cut into before/word/after, and the cut falls
    /// exactly between a marker and the word it belongs to, since the tag
    /// marks the word and not the number. Without it the last run of digits
    /// has nothing after it to be glued to and is drawn as a number the verse
    /// means, which is how "3of love" comes out as a stray 3. A caller
    /// holding the whole line passes nothing.
    public static func interlinearRuns(
        in text: String, followedBy next: String? = nil
    ) -> [(text: String, isMarker: Bool)] {
        var runs: [(text: String, isMarker: Bool)] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isNumber else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            var digits = ""
            var cursor = index
            while cursor < text.endIndex, text[cursor].isNumber {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            // Glued to a word, so a marker; otherwise it is a number the
            // verse means. At the end of the text the word may be in the
            // next piece of a line the caller holds in pieces.
            let glued = cursor < text.endIndex
                ? text[cursor].isLetter
                : (next?.first?.isLetter ?? false)
            if glued {
                if !plain.isEmpty { runs.append((plain, false)); plain = "" }
                runs.append((digits, true))
            } else {
                plain += digits
            }
            index = cursor
        }
        if !plain.isEmpty { runs.append((plain, false)) }
        return runs
    }

    /// What each reading gives and what it costs, said where the choice is
    /// made.
    ///
    /// Neither is a lesser version of the other, and the warning is not that
    /// one is wrong. The direct reading is exact about the word and strange
    /// about everything else: it is another translation's wording, numbering
    /// its verses its own way. The indirect reading is the reader's own
    /// Bible, and it is not a guess either — the verse is already narrowed to
    /// one where the Septuagint uses this Greek word, and where the words'
    /// places settle which occurrence answers to which the row stops warning.
    /// What it cannot do is show the Greek word's own English, because the
    /// reader's translators were rendering the Hebrew.
    public static let indirectEnglishWarning =
        "Your own Bible, marked where it renders the Hebrew word. The verse "
        + "is already one where the Septuagint uses this Greek word, so this "
        + "is the Greek word's sense reached through the Hebrew, in wording "
        + "you know — an approximation, and a close one. What it cannot show "
        + "is the Greek word's own English: your translators were rendering "
        + "the Hebrew, and the Septuagint's translators made their own choice "
        + "centuries earlier."

    /// What the direct reading is, for the same disclosure.
    public static let directEnglishNote =
        "A translation of the Greek Old Testament itself, so the marked word "
        + "is the Greek word's own English, with nothing inferred. It is not "
        + "the translation you read, and it numbers some verses its own way."

    /// The English to show in a verse row, given what is installed.
    ///
    /// Without a Septuagint in English this is the reader's own Bible on the
    /// Hebrew word, which is all there has ever been. With one it is that
    /// text on the Greek word. A Hebrew word with no Strong's number of its
    /// own leaves only the reader's Bible, since there is nothing to mark.
    public static func englishSource(
        hebrewKey: String?,
        greekKey: String,
        readersTranslationID: String,
        septuagintInEnglish: String?
    ) -> EnglishSource? {
        if let septuagintInEnglish, !septuagintInEnglish.isEmpty, !greekKey.isEmpty {
            return .septuagintInEnglish(moduleID: septuagintInEnglish, key: greekKey)
        }
        guard let hebrewKey, !hebrewKey.isEmpty else { return nil }
        return .readersBible(moduleID: readersTranslationID, key: hebrewKey)
    }

    public static func english(
        for references: [Int],
        hebrewNumbering: LampVersification,
        englishNumbering: LampVersification,
        analysis: LampStrongsAnalysis?
    ) -> [Int: English] {
        var tagged: [Int: [Span]] = [:]
        for occurrence in analysis?.occurrences ?? [] {
            tagged[occurrence.reference, default: []].append(
                Span(start: occurrence.startOffset, end: occurrence.endOffset)
            )
        }
        var english: [Int: English] = [:]
        for reference in references {
            // One verse to show in the row, as opening one would give.
            guard let mapped = hebrewNumbering.opens(reference, in: englishNumbering)
            else { continue }
            // A verse the translation does not tag keeps its number and
            // shows no text: which English is the word's would be a guess,
            // and the row says so by having nothing to show.
            guard let marks = tagged[mapped], !marks.isEmpty,
                  let text = analysis?.verseTexts[mapped]
            else {
                english[reference] = English(reference: mapped, text: nil, marks: [])
                continue
            }
            english[reference] = English(
                reference: mapped,
                text: text,
                marks: marks.sorted { $0.start < $1.start }
            )
        }
        return english
    }
}

/// What a Strong's key is called: its lemma, transliteration and a short
/// gloss, as the analysis heads it and lists its companions.
///
/// One rule for every reader of an analysis — the Mac's pane, the phone's,
/// and the agent tool — so the pane and an outside agent looking at the same
/// key do not disagree about what the word is.
///
/// The lemma and transliteration come from the first entry that has them,
/// Strong's own entries first (`preferredDictionaryIDs`), then the order
/// given. Strong's prints the bare word; Dodson prints it with its endings
/// ("ἀγάπη, ης, ἡ"), which is right in a lexicon and wrong as a heading.
///
/// The gloss is a sense's own `gloss` from any entry before a short
/// definition from any: Strong's short definition is the King James
/// renderings ("(feast of) charity(-ably), dear, love"), which is no gloss,
/// and a short definition elsewhere can run to a sentence.
public struct LampStrongsHeadword: Equatable, Sendable {
    public var lemma: String?
    public var transliteration: String?
    /// A sense's own gloss and never a short definition: "love, goodwill",
    /// short enough to sit beside the word in a heading. Nil where no entry
    /// has one, and a heading then shows none rather than a definition cut
    /// off part way.
    public var shortGloss: String?
    /// The first short definition, for where no entry has a gloss.
    public var shortDefinition: String?

    /// The gloss where there is one, else the first short definition.
    public var gloss: String? { shortGloss ?? shortDefinition }

    public init(
        lemma: String? = nil,
        transliteration: String? = nil,
        shortGloss: String? = nil,
        shortDefinition: String? = nil
    ) {
        self.lemma = lemma
        self.transliteration = transliteration
        self.shortGloss = shortGloss
        self.shortDefinition = shortDefinition
    }

    /// The dictionaries a headword is read from first: Strong's Greek and
    /// Hebrew, whose headings are the bare word, then TBESG.
    public static let preferredDictionaryIDs = ["strongs_greek", "strongs_hebrew", "tbesg"]

    /// `known` with `results` read into it, by normalized key. A field already
    /// set is kept, so entries read later — another translation's companions,
    /// a lexicon further down the order — fill gaps and never overwrite; a
    /// gloss found later still takes the place of a short definition.
    public static func merging(
        _ results: [LampDictionaryResult],
        into known: [String: LampStrongsHeadword] = [:]
    ) -> [String: LampStrongsHeadword] {
        var headwords = known
        let ordered = LampModuleSelection.ordered(
            results, preferredIDs: preferredDictionaryIDs, id: \.moduleID
        )
        for result in ordered {
            let key = LampStrongsKey.normalized(result.key)
            let current = headwords[key]
            headwords[key] = LampStrongsHeadword(
                lemma: current?.lemma ?? result.lemma,
                transliteration: current?.transliteration ?? result.transliteration,
                shortGloss: current?.shortGloss
                    ?? result.senses.lazy.compactMap { $0.gloss.flatMap(headGloss) }.first,
                shortDefinition: current?.shortDefinition
                    ?? result.senses.lazy.compactMap(\.shortDefinition).first
            )
        }
        return headwords
    }

    /// A gloss written as senses under one head, "to see: see; to see:
    /// appear" or "faith; faith: faithfulness" as TBESG writes them, read as
    /// that head: "to see", "faith". Parts with different heads name
    /// different things ("John; Jonah", "seed: offspring; seed(s)"), as does
    /// a single sense ("hell: Hades"), and the gloss is kept, tidied for a
    /// heading: blank parts dropped and parts joined with "; ", so it need
    /// not match the lexicon's stored text character for character. Nil for a gloss with nothing in it, so a
    /// blank field falls through to the next sense or the short definition.
    public static func headGloss(_ gloss: String) -> String? {
        let parts = gloss.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let heads = parts.map { part in
            (part.range(of: ":").map { String(part[..<$0.lowerBound]) } ?? part)
                .trimmingCharacters(in: .whitespaces)
        }
        guard let head = heads.first else { return nil }
        // One part is one sense, "hell: Hades", and its head alone would
        // make Hades, Gehenna and Tartarus all "hell".
        guard heads.count > 1, !head.isEmpty, heads.allSatisfy({ $0 == head }) else {
            return parts.joined(separator: "; ")
        }
        return head
    }
}

extension LampStrongsAnalysis {
    /// How many of `books` the key occurs in. `books` is every book in range
    /// that tags the key's language, zeros included, so "22 of 27 books"
    /// counts a Greek word against the New Testament rather than the canon.
    public var booksWithOccurrences: Int {
        books.filter { $0.occurrenceCount > 0 }.count
    }
}

extension LampStrongsAnalysis {
    /// Whether this text is written in the key's own language — TAGNT for a
    /// Greek key, TAHOT for a Hebrew one — so that what it "translates as"
    /// is the key's own spellings, which Forms already lists with their
    /// Latin letters and what each does.
    ///
    /// Both apps then show no Translated As here, and point to Compare,
    /// where every translation's English for the word is listed. Decided by
    /// the script of what the text tags, most of it by count, not by the
    /// module's name.
    public var isInKeysOwnLanguage: Bool {
        let first = LampStrongsKey.normalized(key).first
        let inScript: (Unicode.Scalar) -> Bool
        switch first {
        case "G":
            inScript = { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }
        case "H":
            inScript = { (0x0590...0x05FF).contains($0.value) || (0xFB1D...0xFB4F).contains($0.value) }
        default:
            return false
        }
        let total = renderings.reduce(0) { $0 + $1.count }
        guard total > 0 else { return false }
        let written = renderings
            .filter { $0.text.unicodeScalars.contains(where: inScript) }
            .reduce(0) { $0 + $1.count }
        return written * 2 > total
    }
}

/// A translation's commonest renderings in one line, as Compare lists them:
/// "love (112), It (1), beloved (1)". A Greek text's own Greek is said in
/// Latin letters too, "ἀγάπη agapē (36)", as its forms are. One wording for
/// both apps and the deck slide, so the three cannot drift apart.
public enum LampStrongsRenderingSummary {
    public static func line(of analysis: LampStrongsAnalysis, limit: Int = 3) -> String {
        analysis.renderings.prefix(limit)
            .map { rendering in
                var text = rendering.text.isEmpty ? "—" : rendering.text
                // Hebrew in its own isolate, so a line that starts with it
                // still reads left to right, word, count, comma.
                if text.unicodeScalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) {
                    text = "\u{2068}\(text)\u{2069}"
                }
                let said = LampGreekTransliteration.latinIfGreek(rendering.text).map { " \($0)" } ?? ""
                return "\(text)\(said) (\(rendering.count))"
            }
            .joined(separator: ", ")
    }
}

/// Greek in Latin letters, as a reader without Greek would say it:
/// ἀγάπην "agapēn", εὐαγγέλιον "euangelion", ῥῆμα "rhēma", υἱός "huios".
///
/// The SBL scheme without its accents: η and ω are ē and ō, a rough
/// breathing is an h before the word, γ before γ, κ, ξ or χ is n, and υ is u
/// in a diphthong and y elsewhere. An iota written beneath its vowel is an i
/// after it, ἀγάπῃ "agapēi", so it is not read as ἀγάπη, another form.
public enum LampGreekTransliteration {
    /// Latin letters for words written in Greek, and nil for anything else:
    /// the English a translation gave, or Hebrew, which a letter-for-letter
    /// scheme reads wrongly more often than not (as `LampStrongsFormReading`
    /// leaves it). For what a Greek text "translates as", which is its own
    /// Greek, so a reader without the language can say it as the forms are.
    public static func latinIfGreek(_ text: String) -> String? {
        let isGreek = text.unicodeScalars.contains {
            (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value)
        }
        guard isGreek else { return nil }
        let latin = latin(text).trimmingCharacters(in: .whitespaces)
        return latin.isEmpty ? nil : latin
    }

    public static func latin(_ greek: String) -> String {
        greek.split(separator: " ", omittingEmptySubsequences: false)
            .map { word(String($0)) }
            .joined(separator: " ")
    }

    private static let letters: [Character: String] = [
        "α": "a", "β": "b", "γ": "g", "δ": "d", "ε": "e", "ζ": "z", "η": "ē", "θ": "th",
        "ι": "i", "κ": "k", "λ": "l", "μ": "m", "ν": "n", "ξ": "x", "ο": "o", "π": "p",
        "ρ": "r", "σ": "s", "ς": "s", "τ": "t", "υ": "y", "φ": "ph", "χ": "ch", "ψ": "ps",
        "ω": "ō",
    ]
    private static let roughBreathing: Unicode.Scalar = "\u{0314}"
    private static let iotaSubscript: Unicode.Scalar = "\u{0345}"

    private static func word(_ word: String) -> String {
        // Each letter with its marks, so a breathing is read with its letter.
        let decomposed = Array(word.decomposedStringWithCanonicalMapping)
        var bases: [Character] = []
        var subscripts: Set<Int> = []
        var rough = false
        var isCapital = false
        for (index, character) in decomposed.enumerated() {
            let scalars = character.unicodeScalars
            guard let base = scalars.first else { continue }
            if index < 2, scalars.contains(roughBreathing) { rough = true }
            let letter = Character(String(base).lowercased())
            if index == 0, String(base) != String(base).lowercased() { isCapital = true }
            if scalars.contains(iotaSubscript) { subscripts.insert(bases.count) }
            bases.append(letter)
        }
        var out = ""
        for (index, letter) in bases.enumerated() {
            let next = index + 1 < bases.count ? bases[index + 1] : nil
            let previous = index > 0 ? bases[index - 1] : nil
            switch letter {
            case "γ" where next.map { "γκξχ".contains($0) } == true:
                out += "n"
            case "υ" where previous.map { "αεηο".contains($0) } == true || next == "ι":
                out += "u"
            case "ρ" where index == 0 && rough:
                out += "rh"
            default:
                out += letters[letter] ?? String(letter)
            }
            if subscripts.contains(index) { out += "i" }
        }
        if rough, bases.first != "ρ" { out = "h" + out }
        return isCapital ? out.prefix(1).uppercased() + out.dropFirst() : out
    }
}

/// A form of a word as a reader without Greek or Hebrew can read it: how to
/// say it, what its spelling does in a sentence, and the English it became.
///
/// A bare list of ἀγάπη, ἀγάπην, ἀγάπῃ and ἀγάπης tells such a reader only
/// that the word has four spellings. What separates them is their job — the
/// one doing, the one done to, "of", "to" — which English does with word
/// order and small words; so each is said in those terms, beside the English
/// this translation actually gave it.
public struct LampStrongsFormReading: Equatable, Sendable {
    public let form: LampStrongsAnalysis.Form
    /// Latin letters for a Greek form; nil for Hebrew, whose vowels a
    /// letter-for-letter scheme gets wrong more often than right.
    public let transliteration: String?
    /// What the spelling does, in plain words: "the subject", "“of …”",
    /// "he, she or it · did it, as a whole". A spelling that does more than
    /// one job names every one, commonest first: "either the subject or the
    /// object, one spelling for both". Nil where the tags carry no parsing.
    public let role: String?
    /// The parsing in grammar's own terms, every one the spelling carries.
    public let parsing: String?
    /// The English this form most often became in this translation,
    /// commonest first. Empty for a Greek or Hebrew text, which has none.
    public let renderedAs: [String]

    public init(
        form: LampStrongsAnalysis.Form,
        transliteration: String?,
        role: String?,
        parsing: String?,
        renderedAs: [String]
    ) {
        self.form = form
        self.transliteration = transliteration
        self.role = role
        self.parsing = parsing
        self.renderedAs = renderedAs
    }

    /// A reading for each of the analysis's forms, in its order, from this
    /// translation's own tags and nothing else.
    ///
    /// Nothing is borrowed from another text, by owner decision (2026-11-09):
    /// a parsing or an English that Lamp inferred is not the source's claim,
    /// and a reader cannot tell the two apart. A translation whose tags give
    /// spellings without parsings has readings without roles, and `gaps`
    /// says so.
    ///
    /// A spelling is not always one parsing: πνεῦμα is a subject in some
    /// verses and an object in others, ἡμέρας "of a day" or "days". So every
    /// parsing a spelling carries is kept, and a role is stated alone only
    /// when they all agree on it. Stating the commonest alone was wrong for
    /// some 1 in 20 of the New Testament's nouns, to the reader least able to
    /// tell.
    public static func readings(of analysis: LampStrongsAnalysis) -> [LampStrongsFormReading] {
        let key = LampStrongsKey.normalized(analysis.key)
        let isGreek = key.first == "G"
        let script = key.first ?? "G"
        var codes: [String: [String: Int]] = [:]
        // By form, then by the English folded to lower case, each spelling
        // counted: "Love" at the start of a sentence is the same English as
        // "love", and is shown as it is most often written. A tag whose text
        // is the Greek or Hebrew word itself is no English at all.
        var english: [String: [String: [String: Int]]] = [:]
        for occurrence in analysis.occurrences {
            guard let form = occurrence.form else { continue }
            let id = LampStrongsAnalyzer.formID(form)
            if let code = occurrence.morphology { codes[id, default: [:]][code, default: 0] += 1 }
            let text = englishOfForm(occurrence.text)
            guard !text.isEmpty, !LampStrongsAnalyzer.isOriginalScript(text, language: script) else { continue }
            english[id, default: [:]][text.lowercased(), default: [:]][text, default: 0] += 1
        }
        return analysis.forms.map { form in
            let carried = codes[form.id] ?? [:]
            var roles: [String: Int] = [:]
            var parsings: [String: Int] = [:]
            var partsOfSpeech: Set<String> = []
            for (code, count) in carried {
                let features = LampMorphology.features(of: code, strongsKey: key)
                // A parsing with no job to say, an adverb's, is still a choice
                // of its own: dropped, the role beside it would speak for it,
                // as "the subject" did for πλησίον, an adverb sixteen times
                // in seventeen.
                let job = script == "H"
                    ? hebrewRole(code: code, form: form.text, features: features)
                    : role(of: features)
                let said = job ?? partOfSpeech(features)
                if job == nil, let said { partsOfSpeech.insert(said) }
                if let said { roles[said, default: 0] += count }
                if !features.isEmpty {
                    parsings[features.map(\.value).joined(separator: " · "), default: 0] += count
                }
            }
            let rendered = (english[form.id] ?? [:]).values
                .map { spellings in
                    (
                        text: spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "",
                        count: spellings.values.reduce(0, +)
                    )
                }
                .sorted { ($1.count, $0.text) < ($0.count, $1.text) }
            // A second English only when it is a real alternative, not one
            // tag's stray span.
            let shown = rendered.prefix(2).enumerated()
                .filter { $0.offset == 0 || $0.element.count * 4 >= rendered[0].count }
                .map(\.element.text)
            return LampStrongsFormReading(
                form: form,
                transliteration: isGreek ? LampGreekTransliteration.latin(form.text) : nil,
                // A part of speech alone says nothing a reader can use about
                // the spelling ("a noun"); it is said only beside a job.
                role: roles.count == 1 && partsOfSpeech.contains(roles.keys.first ?? "") ? nil : either(roles),
                parsing: parsings.isEmpty ? nil : ranked(parsings).joined(separator: ", or "),
                renderedAs: shown
            )
        }
    }

    /// A parsing named by its part of speech: "an adverb", "a noun".
    private static func partOfSpeech(_ features: [LampGrammarValue]) -> String? {
        guard let part = features.first(where: { $0.feature == .partOfSpeech })?.value.lowercased() else {
            return nil
        }
        return ("aeiou".contains(part.first ?? "x") ? "an " : "a ") + part
    }

    /// A Hebrew form's job, with the small words its spelling carries.
    ///
    /// A Hebrew word takes "and", "in", "to", "the" on its front and "his",
    /// "her", "their" on its end, each a morpheme of its code (`HR/Ncfsc/Sp3ms`
    /// is in + love + his). The number names the noun, so `features` reads
    /// only that; the rest are read here from the code and, for which
    /// preposition it is, from the letter that spells it. A noun bound to a
    /// suffix is bound to it, not to the word after: בְּאַהֲבָתוֹ is "in his …".
    static func hebrewRole(code: String, form: String, features: [LampGrammarValue]) -> String? {
        var segments = code.split(separator: "/").map(String.init)
        if let first = segments.first, first.first == "H" || first.first == "A" {
            segments[0] = String(first.dropFirst())
        }
        guard let content = segments.firstIndex(where: { segment in
            guard let letter = segment.first else { return false }
            return "NAVP".contains(letter)
        }) else { return role(of: features) }
        let letters = form.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.map(Character.init)
        var front: [String] = []
        var letterIndex = 0
        for segment in segments[..<content] {
            switch segment.first {
            case "C":
                front.append("and")
                letterIndex += 1
            case "R":
                let letter = letterIndex < letters.count ? letters[letterIndex] : nil
                if let word = prepositions[letter ?? " "] { front.append(word) }
                letterIndex += 1
                if segment.dropFirst().first == "d" { front.append("the") }
            case "T" where segment.dropFirst().first == "d":
                front.append("the")
                letterIndex += 1
            default:
                letterIndex += 1
            }
        }
        let isVerb = segments[content].first == "V"
        var suffix: String?
        for segment in segments[(content + 1)...] {
            if segment.hasPrefix("Sp") {
                suffix = pronoun(Array(segment.dropFirst(2)), possessive: !isVerb)
            } else if segment.hasPrefix("Sd") {
                front.append("toward")
            }
        }
        // Bound to its suffix, a noun says so through the suffix alone.
        let content_ = suffix != nil && !isVerb
            ? features.filter { !($0.feature == .state && $0.value == "Construct") }
            : features
        var frame: String?
        if isVerb {
            if !front.isEmpty || suffix != nil {
                frame = "“" + (front + ["…"] + [suffix].compactMap { $0 }).joined(separator: " ") + "”"
            }
        } else if !front.isEmpty || suffix != nil {
            frame = "“" + (front + [suffix].compactMap { $0 } + ["…"]).joined(separator: " ") + "”"
        }
        let parts = [frame, role(of: content_)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let prepositions: [Character: String] = [
        "ב": "in", "ל": "to", "כ": "like", "מ": "from",
    ]

    /// A pronoun suffix's person, gender and number (`3ms`) as English: "his"
    /// on a noun, "him" on a verb.
    private static func pronoun(_ fields: [Character], possessive: Bool) -> String? {
        guard fields.count >= 3 else { return nil }
        let (person, gender, number) = (fields[0], fields[1], fields[2])
        let plural = number == "p"
        switch (person, plural) {
        case ("1", false): return possessive ? "my" : "me"
        case ("1", true): return possessive ? "our" : "us"
        case ("2", _): return possessive ? "your" : "you"
        case ("3", true): return possessive ? "their" : "them"
        case ("3", false):
            switch gender {
            case "f": return possessive ? "her" : "her"
            case "m": return possessive ? "his" : "him"
            default: return possessive ? "its" : "it"
            }
        default: return nil
        }
    }

    private static func ranked(_ counts: [String: Int]) -> [String] {
        counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }

    /// One role, or every role a spelling does, said as a choice. What the
    /// roles share is said once, outside it: "either the object or the
    /// subject, one spelling for both · more than one".
    static func either(_ roles: [String: Int]) -> String? {
        let all = ranked(roles)
        guard all.count > 1 else { return all.first }
        let parts = all.map { $0.components(separatedBy: " · ") }
        var head: [String] = []
        while let first = parts[0].dropFirst(head.count).first,
              parts.allSatisfy({ $0.count > head.count + 1 && $0[head.count] == first }) {
            head.append(first)
        }
        var tail: [String] = []
        while let last = parts[0].dropLast(tail.count).last,
              parts.allSatisfy({ $0.count > head.count + tail.count + 1 && $0[$0.count - 1 - tail.count] == last }) {
            tail.insert(last, at: 0)
        }
        let choices = parts.map { $0[head.count..<($0.count - tail.count)].joined(separator: " · ") }
        let shown = choices.prefix(3)
        let rest = choices.count > shown.count ? " or more" : ""
        let jobs = choices.count == 2 ? "both" : "each"
        let choice = "either " + shown.joined(separator: " or ") + rest + ", one spelling for \(jobs)"
        return (head + [choice] + tail).joined(separator: " · ")
    }

    /// Words a tag can take in from its neighbours that the form itself does
    /// not carry: a καί before it, a sentence's "But".
    private static let joiningWords: Set<String> = ["and", "but", "or", "so", "yet", "then", "now"]

    /// The English a tag covers, as a form's rendering: without edge
    /// punctuation or a joining word in front. Its case is left alone, since
    /// "God" is not "god"; a capital that only starts a sentence is folded
    /// in with the rest where the renderings are counted.
    static func englishOfForm(_ text: String) -> String {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, joiningWords.contains(words[0].lowercased()) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// What the Forms heading says to a reader new to the language, and
    /// what each spelling below is shown with, which depends on what this
    /// translation's tags carry.
    public static func note(for analysis: LampStrongsAnalysis, readings: [LampStrongsFormReading]) -> String {
        let isHebrew = LampStrongsKey.normalized(analysis.key).first == "H"
        let why = isHebrew
            ? "Hebrew joins words like “and”, “the” and “in” to the front of a word, "
                + "and changes its ending for “of”, for more than one, and for who acts."
            : "Greek changes a word’s ending for its job in the sentence, where English "
                + "uses word order and words like “of” and “to”."
        var shown: [String] = []
        if readings.contains(where: { $0.transliteration != nil }) { shown.append("how to say it") }
        if readings.contains(where: { $0.role != nil }) { shown.append("what it does") }
        if readings.contains(where: { !$0.renderedAs.isEmpty }) { shown.append("the English it became here") }
        guard !shown.isEmpty else { return why }
        let list = shown.count == 1
            ? shown[0]
            : shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        return why + " Each spelling is shown with \(list)."
    }

    /// What this translation's tags do not say about the word's forms, each
    /// a sentence the Forms section prints, so a figure that cannot be given
    /// is said to be missing rather than looking miscounted.
    public static func gaps(of analysis: LampStrongsAnalysis, readings: [LampStrongsFormReading]) -> [String] {
        let name = analysis.translationAbbreviation ?? analysis.translationName
        let language = LampStrongsKey.normalized(analysis.key).first == "H" ? "Hebrew" : "Greek"
        guard !analysis.forms.isEmpty else {
            return ["\(name) tags the word by its number but not by its \(language) spelling, "
                + "so its forms cannot be counted here."]
        }
        var gaps: [String] = []
        if !readings.contains(where: { $0.parsing != nil }) {
            gaps.append("\(name) tags each \(language) spelling but not its grammar, "
                + "so what each one does is not said here.")
        }
        let spelled = analysis.forms.reduce(0) { $0 + $1.count }
        let total = analysis.occurrenceCount
        if spelled < total {
            let missing = total - spelled
            gaps.append("\(missing) of \(total) "
                + (total == 1 ? "occurrence is" : (missing == 1 ? "occurrences is" : "occurrences are"))
                + " tagged in \(name) without a \(language) spelling.")
        }
        return gaps
    }

    /// The parsing's job in a sentence, in plain words.
    static func role(of features: [LampGrammarValue]) -> String? {
        var values: [LampGrammarFeature: String] = [:]
        for feature in features where values[feature.feature] == nil {
            values[feature.feature] = feature.value
        }
        let plural = values[.number].map { $0 == "Plural" || $0 == "Dual" } ?? false
        var parts: [String] = []

        if let mood = values[.mood] ?? values[.form].flatMap(hebrewVerbForm) {
            switch mood {
            case "Infinitive":
                parts.append("“to …”")
            case "Participle", "Imperative participle":
                parts.append("“…ing”, “the one who …”")
            case "Participle passive":
                parts.append("“…ed”, “the one who is …ed”")
            case "Imperative":
                parts.append(plural ? "a command to more than one" : "a command")
            case "Subjunctive":
                parts.append("“may …”, “might …”")
            case "Optative":
                parts.append("a wish, “may it …”")
            default:
                if let who = person(values[.person], plural: plural, gender: values[.gender]) {
                    parts.append(who)
                }
                let when = values[.tense].flatMap(greekTime) ?? values[.form].flatMap(hebrewTime)
                if let when { parts.append(when) }
            }
            if values[.voice] == "Passive" { parts.append("done to, not doing") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        switch values[.grammaticalCase] {
        case "Nominative": parts.append("the subject")
        case "Genitive": parts.append("“of …”")
        case "Dative": parts.append("“to …”, “for …”, “in …”")
        case "Accusative": parts.append("the object")
        case "Vocative": parts.append("someone spoken to, “O …”")
        default: break
        }
        switch values[.state] {
        case "Construct": parts.append("“… of”, bound to the word after it")
        case "Definite": parts.append("“the …”")
        default: break
        }
        if plural { parts.append(values[.number] == "Dual" ? "two of them" : "more than one") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A Hebrew verb's form as the mood it stands in for here.
    private static func hebrewVerbForm(_ form: String) -> String? {
        switch form {
        case "Infinitive": "Infinitive"
        case "Participle": "Participle"
        case "Participle passive": "Participle passive"
        case "Imperative": "Imperative"
        case "Perfect", "Consecutive Perfect", "Imperfect", "Consecutive Imperfect",
             "Conjunction+Imperfect": "Finite"
        default: nil
        }
    }

    private static func person(_ person: String?, plural: Bool, gender: String?) -> String? {
        switch person {
        case "1st person", "First": plural ? "we" : "I"
        case "2nd person", "Second": plural ? "you, more than one" : "you"
        case "3rd person", "Third":
            plural ? "they" : gender == "Masculine" ? "he" : gender == "Feminine" ? "she" : "he, she or it"
        default: nil
        }
    }

    private static func greekTime(_ tense: String) -> String? {
        switch tense {
        case "Present": "now, or as a habit"
        case "Imperfect": "“was …ing”, “used to …”"
        case "Future": "“will …”"
        case "Aorist": "did it, as a whole"
        case "Perfect": "“has …”, done and still so"
        case "Pluperfect": "“had …”"
        default: nil
        }
    }

    /// A Hebrew verb's form says less about time than about whether the act
    /// is whole or under way, so these are its usual English.
    private static func hebrewTime(_ form: String) -> String? {
        switch form {
        case "Perfect": "“did”, “has done”"
        case "Imperfect": "“does”, “will do”"
        case "Consecutive Imperfect": "“and … did”, the next thing that happened"
        case "Consecutive Perfect": "“and … will”"
        case "Conjunction+Imperfect": "“and … does” or “will”"
        default: nil
        }
    }
}

/// Where the standout book's name goes on the canon strip.
///
/// The name is drawn over its own column, but it is usually wider than one
/// column, so a tall neighbour can end up with the name running through it.
/// The owner saw it as ἔθνος G1484 in the ESV: Romans is the standout with
/// 29 occurrences, Acts beside it has 43 and is the tallest column on the
/// chart, and "Romans" — centred over Romans — crossed Acts' bar.
///
/// Both apps draw this strip, so the placement is decided here rather than
/// twice. Found and first solved on the phone by ios-56 (iOS c0929c7); this
/// is that rule, in the one place the two can share.
public enum LampStrongsCanonStripLabel {
    /// Where to centre the name, and the height of the tallest column it
    /// would then stand over.
    ///
    /// Three positions are tried — centred over the book's column, starting
    /// at its left edge, and ending at its right edge — each kept inside the
    /// chart. Whichever stands over the lowest column wins, so the name
    /// steps aside when a tall neighbour sits on one side only; a tie keeps
    /// it centred, which is where it belongs when nothing is in the way.
    ///
    /// `heights` is every column's drawn height, in the order they are laid
    /// out, measured the same way the bars are: a label cleared of a height
    /// the bar does not actually have is a label in the wrong place.
    public static func place(
        labelWidth: Double,
        over index: Int,
        heights: [Double],
        column: Double,
        spacing: Double,
        in width: Double
    ) -> (x: Double, clearing: Double) {
        let half = labelWidth / 2
        let left = (column + spacing) * Double(index)
        // A couple of points of slack, so a column the name merely grazes
        // still counts as under it.
        let slack = 2.0
        func clearing(at x: Double) -> Double {
            heights.indices
                .filter { index in
                    let start = (column + spacing) * Double(index)
                    return start < x + half + slack && start + column > x - half - slack
                }
                .map { heights[$0] }
                .max() ?? 0
        }
        return [left + column / 2, left + half, left + column - half]
            .map { min(max($0, half), width - half) }
            .map { (x: $0, clearing: clearing(at: $0)) }
            // `min(by:)` keeps the first of equals, and centred is first.
            .min { $0.clearing < $1.clearing }!
    }
}
