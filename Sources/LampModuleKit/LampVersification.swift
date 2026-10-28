import Foundation

/// A scheme for numbering the Bible's verses, and how it differs from the
/// numbering of the original-language texts, which every scheme is mapped
/// through.
///
/// The schemes are Paratext's standard ones, as SIL publishes them: English,
/// the original languages, the Septuagint, the Vulgate, and the Russian
/// canonical and Orthodox numberings. Lamp's own references, which its
/// commentaries, notes and cross-references are keyed to, are in the English
/// scheme.
///
/// References are Lamp's BBCCCVVV integers. A psalm's title, which some
/// schemes number as a verse and others don't, is verse 0.
public struct LampVersification: Sendable {
    public enum Scheme: String, CaseIterable, Sendable {
        case english = "eng"
        case original = "org"
        case septuagint = "lxx"
        case vulgate = "vul"
        case russianCanonical = "rsc"
        case russianOrthodox = "rso"

        /// The scheme a module's `versification` field names, in Paratext's
        /// codes or the names module sources use. An empty field, "standard"
        /// and "kjv" are the English scheme, which is what Lamp has always
        /// read every translation as.
        public init?(moduleValue: String?) {
            let value = (moduleValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch value {
            case "", "standard", "kjv", "english", "eng", "rsv", "nrsv":
                self = .english
            case "org", "original", "hebrew", "bhs", "masoretic", "greek":
                self = .original
            case "lxx", "septuagint":
                self = .septuagint
            case "vul", "vulg", "vulgate", "catholic":
                self = .vulgate
            case "rsc", "russian", "synodal", "russiancanonical":
                self = .russianCanonical
            case "rso", "russianorthodox", "orthodox":
                self = .russianOrthodox
            default:
                return nil
            }
        }
    }

    public let scheme: Scheme
    /// The highest verse of each chapter, by book number and then chapter.
    public let verseCounts: [Int: [Int: Int]]
    /// Every mapping, in the order that decides between two for one verse:
    /// a translation's own departures first, then the scheme's lines as the
    /// file lists them.
    private let pairs: [(verse: Int, original: Int)]
    /// A verse in this scheme, by the original-language verse it is. Verses
    /// not listed are numbered as the original numbers them.
    private let toOriginal: [Int: Int]
    /// The verse in this scheme an original-language verse is, where this
    /// scheme numbers it differently. Built from every line rather than from
    /// `toOriginal`: a scheme can map one verse to two originals, as the
    /// Vulgate's Psalm 9:22 is both the original 10:0 and 10:1, and each of
    /// them still has to find its way back.
    private let fromOriginal: [Int: Int]

    /// One of the standard schemes.
    public static func standard(_ scheme: Scheme) -> LampVersification {
        standards[scheme]!
    }

    private static let standards: [Scheme: LampVersification] = Dictionary(
        uniqueKeysWithValues: Scheme.allCases.map { scheme in
            (scheme, parse(LampVersificationData.schemes[scheme.rawValue] ?? "", as: scheme))
        }
    )

    /// This scheme with a translation's own departures from it, written as
    /// the scheme's mapping lines are, from this numbering to the original's:
    /// `ROM 14:24-26 = ROM 16:25-27` for a translation that ends Romans 14
    /// with the doxology the English scheme numbers 16:25–27.
    public func departing(by lines: [String]) -> LampVersification {
        LampVersification(
            scheme: scheme,
            verseCounts: verseCounts,
            pairs: Self.mappings(in: lines.joined(separator: "\n"), books: Self.bookNumbers(in: scheme)) + pairs
        )
    }

    /// The original-language verse `reference` in this scheme is.
    public func original(of reference: Int) -> Int {
        toOriginal[reference] ?? reference
    }

    /// The verse in this scheme that an original-language verse is, or nil
    /// where this scheme has no verse for it: its number here means another.
    public func reference(forOriginal original: Int) -> Int? {
        if let mapped = fromOriginal[original] { return mapped }
        return toOriginal[original] == nil ? original : nil
    }

    /// The verse in `target`'s numbering that `reference` in this one is, or
    /// nil where the target numbers no such verse.
    public func convert(_ reference: Int, to target: LampVersification) -> Int? {
        target.reference(forOriginal: original(of: reference))
    }

    /// The standard scheme whose chapter lengths best match a translation's,
    /// for a translation that doesn't say which it follows. English wins a tie:
    /// it is what Lamp has always assumed.
    public static func likeliestScheme(forVerseCounts counts: [Int: [Int: Int]]) -> Scheme {
        var best = Scheme.english
        var bestScore = -1
        for scheme in Scheme.allCases {
            let reference = standard(scheme).verseCounts
            var score = 0
            for (book, chapters) in counts {
                for (chapter, last) in chapters where reference[book]?[chapter] == last {
                    score += 1
                }
            }
            if score > bestScore {
                best = scheme
                bestScore = score
            }
        }
        return best
    }

    // MARK: - Reading the schemes

    private init(scheme: Scheme, verseCounts: [Int: [Int: Int]], pairs: [(verse: Int, original: Int)]) {
        self.scheme = scheme
        self.verseCounts = verseCounts
        self.pairs = pairs
        var toOriginal: [Int: Int] = [:]
        var fromOriginal: [Int: Int] = [:]
        for (verse, original) in pairs {
            if toOriginal[verse] == nil { toOriginal[verse] = original }
            if fromOriginal[original] == nil { fromOriginal[original] = verse }
        }
        self.toOriginal = toOriginal
        self.fromOriginal = fromOriginal
    }

    private static func parse(_ text: String, as scheme: Scheme) -> LampVersification {
        let books = bookNumbers(in: scheme)
        var counts: [Int: [Int: Int]] = [:]
        for line in contentLines(of: text) where !line.contains("=") {
            let parts = line.split(separator: " ")
            guard let code = parts.first, let book = books[String(code)] else { continue }
            for entry in parts.dropFirst() {
                let pair = entry.split(separator: ":")
                guard pair.count == 2, let chapter = Int(pair[0]), let last = Int(pair[1]) else { continue }
                counts[book, default: [:]][chapter] = last
            }
        }
        return LampVersification(scheme: scheme, verseCounts: counts, pairs: mappings(in: text, books: books))
    }

    /// The text's lines with comments taken off, and blank ones left out.
    private static func contentLines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? nil : line
        }
    }

    /// Every verse a text's mapping lines move, paired with where it goes.
    ///
    /// A range maps verse by verse. Where its two sides differ in length, as
    /// where one scheme joins two psalms the other keeps apart, they pair as
    /// far as both go and the longer side's rest goes to the other's last
    /// verse. Parts of a verse (`3a`, `3b`) map as the whole verse: Lamp's
    /// references have no parts. Books Lamp doesn't number are passed over.
    private static func mappings(
        in text: String,
        books: [String: Int]
    ) -> [(verse: Int, original: Int)] {
        var result: [(verse: Int, original: Int)] = []
        // The original's side is always in the original's codes.
        let originalBooks = bookNumbers(in: .original)
        for line in contentLines(of: text) where line.contains("=") {
            let sides = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2,
                  let from = verses(in: sides[0], books: books),
                  let to = verses(in: sides[1], books: originalBooks),
                  !from.isEmpty, !to.isEmpty else { continue }
            for (index, verse) in from.enumerated() {
                result.append((verse, to[min(index, to.count - 1)]))
            }
        }
        return result
    }

    /// The verses one side of a mapping line names: `PSA 3:0-8`, `JOL 3:1`.
    private static func verses(in side: String, books: [String: Int]) -> [Int]? {
        let parts = side.split(separator: " ")
        guard parts.count == 2, let book = books[String(parts[0])] else { return nil }
        let place = parts[1].split(separator: ":")
        guard place.count == 2, let chapter = Int(place[0]) else { return nil }
        let range = place[1].split(separator: "-").map { Int($0.filter(\.isNumber)) }
        guard let first = range.first ?? nil else { return nil }
        let last = range.count > 1 ? (range[1] ?? first) : first
        guard last >= first else { return nil }
        return (first...last).map { book * 1_000_000 + chapter * 1_000 + $0 }
    }

    /// The book each of a scheme's codes is in Lamp's numbering.
    ///
    /// The Septuagint has no Esther or Daniel of its own codes: it numbers
    /// the Greek books, which a Lamp translation still keys as Esther and
    /// Daniel. Elsewhere those codes are separate deuterocanonical books,
    /// which Lamp doesn't number, so the reading is the Septuagint's alone.
    private static func bookNumbers(in scheme: Scheme) -> [String: Int] {
        var books = canonicalBookNumbers
        if scheme == .septuagint {
            books["ESG"] = books["EST"]
            books["DAG"] = books["DAN"]
        }
        return books
    }

    private static let canonicalBookNumbers: [String: Int] = Dictionary(
        uniqueKeysWithValues: LampCanonicalBooks.all.map { ($0.usfmCode, $0.number) }
    )
}
