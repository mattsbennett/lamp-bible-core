import Foundation
import LampModuleKit

/// The working-out behind the Septuagint section, for both apps.
///
/// What is here is every decision the section makes: which of a Hebrew word's
/// verses the Septuagint renders with this Greek word, where to mark the Greek
/// in them, what doubt a row has to own up to, whether the words' places
/// settle that doubt, and which text a row's English should come from.
///
/// What is **not** here is reading. Each app fetches chapters, analyses and
/// versifications its own way, and holds its own paging and caches; the only
/// I/O this file knows about is a closure it is handed. Keeping the judgement
/// on this side is the point: a blind review of the Mac's first cut found four
/// faults, all of them in the orchestration around these rules and none in the
/// rules, which is exactly the code the phone would otherwise write again.
extension LampSeptuagintSection {
    /// A word's place in the verse it stands in, as the tags give it: offsets
    /// in **code points**, not in Swift's Characters. A pointed Hebrew word is
    /// twelve of the one and about six of the other.
    public struct Span: Equatable, Sendable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }

        /// Where the word sits in its verse, 0 to 1, by its middle.
        public func middle(of length: Int) -> Double? {
            guard length > 0 else { return nil }
            return (Double(start) + Double(end)) / 2 / Double(length)
        }
    }

    /// What a doubt was made of, kept so that settling can rewrite it rather
    /// than drop it: position says which occurrence answers to this word and
    /// nothing at all about a different Hebrew word standing beside it.
    public struct Competing: Equatable, Sendable {
        public let greek: String
        public let words: [String]

        public init(greek: String, words: [String]) {
            self.greek = greek
            self.words = words
        }
    }

    /// One Hebrew word as the crossing needs it.
    public struct CrossingWord: Equatable, Sendable {
        public let id: String
        /// The word as it is printed in a note about it.
        public let printed: String
        public let references: [Int]
        /// How often it stands in each of those verses.
        public let occurrences: [Int: Int]

        public init(id: String, printed: String, references: [Int], occurrences: [Int: Int]) {
            self.id = id
            self.printed = printed
            self.references = references
            self.occurrences = occurrences
        }
    }

    /// Everything the crossing works out, in one value so neither app can
    /// keep half of it.
    public struct Crossing: Equatable, Sendable {
        /// Each word's verses that the Septuagint renders with this Greek word.
        public let rendered: [String: [Int]]
        /// Where the Greek word stands, by the Hebrew verse the row is for.
        public let marks: [Int: [Span]]
        public let doubts: [String: [Int: String]]
        public let competing: [String: [Int: Competing]]

        public init(
            rendered: [String: [Int]],
            marks: [Int: [Span]],
            doubts: [String: [Int: String]],
            competing: [String: [Int: Competing]]
        ) {
            self.rendered = rendered
            self.marks = marks
            self.doubts = doubts
            self.competing = competing
        }
    }

    /// Cross each Hebrew word's verses with the Septuagint's own.
    ///
    /// Two texts read, not an alignment guessed: the Hebrew word's verses come
    /// from the Hebrew text's tags and the Greek word's from the Septuagint's,
    /// and only the numbering between them is converted.
    ///
    /// `greekOccurrences` is where the Greek word stands in each Septuagint
    /// verse. `septuagintReferences` is every verse it stands in at all — the
    /// two differ, because a Septuagint analysis may carry references without
    /// the occurrences behind them.
    public static func cross(
        words: [CrossingWord],
        greekForm: String?,
        septuagintReferences: Set<Int>,
        greekOccurrences: [Int: [Span]],
        hebrewNumbering: LampVersification,
        septuagintNumbering: LampVersification
    ) -> Crossing {
        var rendered: [String: [Int]] = [:]
        var marks: [Int: [Span]] = [:]
        var doubts: [String: [Int: String]] = [:]
        var competing: [String: [Int: Competing]] = [:]
        for word in words {
            guard !word.references.isEmpty else { continue }
            let hits = versesRenderedByGreek(
                hebrew: word.references,
                hebrewNumbering: hebrewNumbering,
                septuagintNumbering: septuagintNumbering,
                septuagintReferences: septuagintReferences
            )
            rendered[word.id] = word.references.filter(hits.contains)
            for reference in hits {
                let counterparts = hebrewNumbering
                    .counterparts(of: reference, in: septuagintNumbering)
                // The marks are offsets into the Greek verse they were found
                // in, and the line drawn for a psalm title is its two halves
                // joined, so only the first half's offsets land where the text
                // does. A word standing in a title's second half is listed —
                // the crossing above uses every counterpart — but left
                // unmarked, rather than marked in the wrong place.
                if let first = counterparts.first, let spans = greekOccurrences[first] {
                    marks[reference] = spans
                }
                // The doubt counts every counterpart, which the mark cannot.
                // A psalm title answering to two Greek verses, with the word
                // standing only in the second, has no mark and still has an
                // ambiguity — and skipping the count with the mark dropped a
                // doubt that was known.
                let standing = counterparts.reduce(0) { $0 + (greekOccurrences[$1]?.count ?? 0) }
                guard standing > 0 else { continue }
                // The other Hebrew words this same Greek word renders, where
                // one of them stands in this verse too: the doubt a reader is
                // least able to see for themselves.
                let others = words
                    .filter { $0.id != word.id && $0.references.contains(reference) }
                    .map(\.printed)
                guard let doubt = pairingDoubt(
                    greek: greekForm,
                    hebrew: word.printed,
                    hebrewOccurrences: word.occurrences[reference] ?? 1,
                    greekOccurrences: standing,
                    alsoRendered: others
                ) else { continue }
                doubts[word.id, default: [:]][reference] = doubt
                competing[word.id, default: [:]][reference] =
                    Competing(greek: greekForm ?? "", words: others)
            }
        }
        return Crossing(rendered: rendered, marks: marks, doubts: doubts, competing: competing)
    }

    /// A translation of the Greek Old Testament in another language, among
    /// those installed, for this key.
    ///
    /// Asked of **this** key, and the answer kept for it alone: a key standing
    /// only in the New Testament says nothing about the next one. Candidates
    /// are only texts that tag Strong's and are not themselves in an original
    /// language, so the question is put to two or three modules at most.
    /// Throws rather than swallowing a failed read, so a text that could not
    /// be analysed this time is never mistaken for one that is not a
    /// Septuagint in English — a caller that cached that answer would hide
    /// the control until the app was restarted.
    public static func septuagintInEnglish(
        among candidates: [(id: String, tagsStrongs: Bool, isOriginalLanguage: Bool)],
        key: String,
        analyse: (String) async throws -> LampStrongsAnalysis?
    ) async throws -> String? {
        guard key.uppercased().hasPrefix("G") else { return nil }
        for candidate in candidates where candidate.tagsStrongs && !candidate.isOriginalLanguage {
            guard let analysis = try await analyse(candidate.id) else { continue }
            if rendersTheGreekOldTestament(analysis, isOriginalLanguage: false) {
                return candidate.id
            }
        }
        return nil
    }

    /// Which of the rows on a page need their Hebrew read to settle them.
    ///
    /// Only rows that carry a doubt, and only those answering to one Septuagint
    /// verse — a psalm title's line is two verses joined, and an offset into
    /// one of them does not land in the join. Everything else is left out
    /// **before** the read, so the usual page, where four rows in five have
    /// nothing to settle, costs nothing at all.
    public static func versesNeedingHebrew(
        among shown: [Int],
        doubted: Set<Int>,
        hebrewNumbering: LampVersification,
        septuagintNumbering: LampVersification
    ) -> [Int] {
        shown.filter {
            doubted.contains($0)
                && hebrewNumbering.counterparts(of: $0, in: septuagintNumbering).count == 1
        }
    }

    /// The doubts a page is left with once the words' places have been read.
    ///
    /// Returns only the rows whose note changes, each to its new note or to
    /// nil where there is nothing left to say. A settled row keeps any doubt
    /// about a *different* Hebrew word standing in the same verse, because
    /// position settles which occurrence answers to this word and says nothing
    /// whatever about that.
    public static func settle(
        verses: [Int],
        hebrewWord printed: String,
        hebrewSpans: [Int: [Span]],
        hebrewLengths: [Int: Int],
        greekSpans: [Int: [Span]],
        greekLengths: [Int: Int],
        competing: [Int: Competing]
    ) -> [Int: String?] {
        var changed: [Int: String?] = [:]
        for reference in verses {
            guard let hebrewHere = hebrewSpans[reference],
                  let greekHere = greekSpans[reference],
                  let hebrewLength = hebrewLengths[reference],
                  let greekLength = greekLengths[reference]
            else { continue }
            let hebrewAt = hebrewHere.compactMap { $0.middle(of: hebrewLength) }
            let greekAt = greekHere.compactMap { $0.middle(of: greekLength) }
            guard hebrewAt.count == hebrewHere.count, greekAt.count == greekHere.count,
                  pairingIsSettled(hebrewAt: hebrewAt, greekAt: greekAt)
            else { continue }
            let kept = competing[reference]
            changed[reference] = pairingDoubt(
                greek: kept?.greek,
                hebrew: printed,
                hebrewOccurrences: 1,
                greekOccurrences: 1,
                alsoRendered: kept?.words ?? []
            )
        }
        return changed
    }
}
