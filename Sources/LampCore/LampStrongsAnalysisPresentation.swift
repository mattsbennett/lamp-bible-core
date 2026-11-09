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
            occurrence.form == text
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
        case .rendering(_, let text): "rendered “\(text)”"
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
        case .renderings: "Renderings"
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
