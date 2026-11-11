import Foundation
import LampModuleKit

// What the apps draw from a Strong's analysis: narrowing it to a figure's
// occurrences, the charts' bars, shares and grids, the verse around a word,
// and the Septuagint section's wording. Pure, so the Mac and the phone draw
// the same figures and say the same things about them.

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
    /// Offsets count `Character`s, as every annotation offset in Lamp does.
    /// Slicing `Array(verse)` rather than the scalars is the whole point: a
    /// verse with a decomposed accent earlier in it has more scalars than
    /// characters, and cutting by scalars moves the highlight off the word.
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
        let characters = Array(verse)
        let start = min(max(0, startOffset), characters.count)
        let end = min(max(start, endOffset), characters.count)

        var before = String(characters[..<start])
        var after = String(characters[end...])
        let word = String(characters[start..<end])

        var trimmedStart = false
        if before.count > window {
            before = String(before.suffix(window))
            // Not mid-word: start at the next space, so a row never opens on
            // half of a word.
            if let space = before.firstIndex(of: " ") {
                before = String(before[before.index(after: space)...])
            }
            trimmedStart = true
        }
        var trimmedEnd = false
        if after.count > window {
            after = String(after.prefix(window))
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
        var chapters: [Int: [Int: String]] = [:]
        var greek: [Int: String] = [:]
        for reference in references {
            try Task.checkCancellation()
            guard let mapped = hebrewNumbering.convert(reference, to: septuagintNumbering)
            else { continue }
            let parts = LampBibleReferenceFormatter.components(of: mapped)
            let chapterKey = parts.book * 1_000 + parts.chapter
            if chapters[chapterKey] == nil {
                do {
                    chapters[chapterKey] = try await readChapter(parts.book, parts.chapter)
                } catch {
                    // A read cut short by cancellation is not a chapter that
                    // could not be read.
                    try Task.checkCancellation()
                    chapters[chapterKey] = [:]
                }
            }
            if let text = chapters[chapterKey]?[parts.verse] {
                greek[reference] = text
            }
        }
        return greek
    }

    /// A Hebrew word's heading, naming whose verses they are.
    ///
    /// With its transliteration and the English it is most often rendered
    /// by, it reads to someone with no Hebrew: "ʼahăbâh “love” (H160) · in
    /// 40 Hebrew verses". Without them it is the Hebrew as printed: "Hebrew
    /// אַהֲבָה (H160) · 40 verses".
    public static func heading(
        _ hebrew: LampSeptuagintHebrew,
        transliteration: String? = nil,
        rendering: String? = nil,
        verses: Int
    ) -> String {
        let transliteration = transliteration.flatMap { $0.isEmpty ? nil : $0 }
        let rendering = rendering.flatMap { $0.isEmpty ? nil : $0 }
        guard transliteration != nil || rendering != nil else {
            let name = hebrew.strongs.map { "\(word(hebrew)) (\($0))" } ?? word(hebrew)
            return "Hebrew \(name) · \(verses) \(verses == 1 ? "verse" : "verses")"
        }
        var name = [transliteration ?? word(hebrew), rendering.map { "“\($0)”" }]
            .compactMap { $0 }
            .joined(separator: " ")
        if let strongs = hebrew.strongs { name += " (\(strongs))" }
        return "\(name) · in \(verses) Hebrew \(verses == 1 ? "verse" : "verses")"
    }

    /// The section's title. It is the Hebrew a Greek word translates, which
    /// the title says, because "Septuagint" alone promised the Greek word's
    /// own verses through the Old Testament.
    public static let title = "Hebrew It Translates"

    /// What the section is, said once at its top: the lexicon's link from the
    /// Greek word to these Hebrew words, and why the verses are the Hebrew
    /// word's rather than the Greek word's.
    public static func note(greek lemma: String?) -> String {
        let lemma = lemma.flatMap { $0.isEmpty ? nil : $0 } ?? "this word"
        return "The Septuagint, the Greek Old Testament, uses \(lemma) mostly "
            + "for these Hebrew words. The verses are each Hebrew word’s, not "
            + "\(lemma)’s: the Septuagint installed isn’t tagged word by word, "
            + "so its Greek, under each verse, may use another word."
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
        /// Nil where the translation has the verse but does not tag the word
        /// in it: shown unmarked would be a guess at which English it is.
        public let snippet: LampStrongsContext.Snippet?

        public init(reference: Int, snippet: LampStrongsContext.Snippet?) {
            self.reference = reference
            self.snippet = snippet
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
    /// The mark is the translation's own tag, at the offsets it records,
    /// and nothing is guessed: a verse the translation does not tag with
    /// this word has its English number and no snippet. Only a verse its
    /// numbering has no counterpart for is left out, which is a different
    /// fact — the translation has no such verse, not that it doesn't use the
    /// word there.
    public static func english(
        for references: [Int],
        hebrewNumbering: LampVersification,
        englishNumbering: LampVersification,
        analysis: LampStrongsAnalysis?,
        window: Int = 90
    ) -> [Int: English] {
        var first: [Int: LampStrongsAnalysis.Occurrence] = [:]
        for occurrence in analysis?.occurrences ?? [] where first[occurrence.reference] == nil {
            first[occurrence.reference] = occurrence
        }
        var english: [Int: English] = [:]
        for reference in references {
            guard let mapped = hebrewNumbering.convert(reference, to: englishNumbering)
            else { continue }
            var snippet: LampStrongsContext.Snippet?
            if let occurrence = first[mapped], let text = analysis?.verseTexts[mapped] {
                snippet = LampStrongsContext.snippet(
                    of: text,
                    from: occurrence.startOffset,
                    to: occurrence.endOffset,
                    window: window
                )
            }
            english[reference] = English(reference: mapped, snippet: snippet)
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
