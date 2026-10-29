import Foundation

/// What one translation's Strong's tags say about one key: where it is tagged,
/// the English that renders it, the original forms and grammar behind it where
/// the tags carry them, how it spreads across the canon, and which other keys
/// keep it company.
///
/// Counts are measured against the tagged words of the key's own language in
/// range, so a Greek key is weighed against the New Testament's tags and a
/// Hebrew one against the Old's, whatever the range says.
///
/// A rate alone makes one hit in a short book look like a theme of it. Each
/// book and section is therefore weighed by log-likelihood against the rest of
/// the range, and is said to hold more or fewer than its size predicts only
/// when a difference that large would arise by chance less than once in a
/// thousand. Companions are ranked by the same test over verses, so the keys
/// that keep this one company rise above the ones found everywhere.
public struct LampStrongsAnalysis: Equatable, Sendable {
    /// Keyness at or beyond which a division is said to hold more or fewer:
    /// the 0.1% point of chi-squared with one degree of freedom.
    public static let notableKeyness = 10.83

    public let key: String
    public let translationID: String
    public let translationName: String
    public let translationAbbreviation: String?
    /// Tagged words of the key's language in range.
    public let wordCount: Int
    /// Verses in range with at least one tag of the key's language.
    public let taggedVerseCount: Int
    public let occurrences: [Occurrence]
    /// Each verse with an occurrence, in canonical order.
    public let references: [Int]
    public let renderings: [Rendering]
    public let forms: [Form]
    public let parsings: [Parsing]
    public let grammar: [GrammarCount]
    /// Every book in range with tags of the key's language, those without an
    /// occurrence included: an absence is part of the picture.
    public let books: [Division]
    public let sections: [Division]
    public let companions: [Companion]

    public var occurrenceCount: Int { occurrences.count }
    /// Verses holding the key, not the range's verses: those are
    /// `taggedVerseCount`.
    public var verseCount: Int { references.count }
    /// Occurrences per thousand tagged words of the key's language in range
    /// (`wordCount`): not per thousand verses, nor per thousand English words.
    public var ratePerThousandWords: Double {
        wordCount > 0 ? Double(occurrences.count) * 1_000 / Double(wordCount) : 0
    }

    public init(
        key: String,
        translationID: String,
        translationName: String,
        translationAbbreviation: String?,
        wordCount: Int,
        taggedVerseCount: Int,
        occurrences: [Occurrence],
        references: [Int],
        renderings: [Rendering],
        forms: [Form],
        parsings: [Parsing],
        grammar: [GrammarCount],
        books: [Division],
        sections: [Division],
        companions: [Companion]
    ) {
        self.key = key
        self.translationID = translationID
        self.translationName = translationName
        self.translationAbbreviation = translationAbbreviation
        self.wordCount = wordCount
        self.taggedVerseCount = taggedVerseCount
        self.occurrences = occurrences
        self.references = references
        self.renderings = renderings
        self.forms = forms
        self.parsings = parsings
        self.grammar = grammar
        self.books = books
        self.sections = sections
        self.companions = companions
    }

    /// One tagged rendering of the key. Two tags of the key with only space
    /// between them, and no difference of form or parsing, are one word
    /// rendered in two pieces ("only" and "begotten" for μονογενής) and are
    /// one occurrence here.
    public struct Occurrence: Equatable, Sendable {
        public let reference: Int
        /// Character offsets into the verse's text.
        public let startOffset: Int
        public let endOffset: Int
        public let text: String
        /// The `Rendering` this belongs to.
        public let renderingID: String
        /// The original-language word as tagged, where the tags carry it.
        public let form: String?
        public let morphology: String?

        public init(
            reference: Int,
            startOffset: Int,
            endOffset: Int,
            text: String,
            renderingID: String,
            form: String?,
            morphology: String?
        ) {
            self.reference = reference
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.text = text
            self.renderingID = renderingID
            self.form = form
            self.morphology = morphology
        }
    }

    /// English that renders the key, gathered by the word that carries it:
    /// "of God", "God's" and "to God" are variants of one rendering, "God".
    /// Tags with no English of their own have the empty rendering.
    public struct Rendering: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let count: Int
        public let variants: [Variant]

        public init(id: String, text: String, count: Int, variants: [Variant]) {
            self.id = id
            self.text = text
            self.count = count
            self.variants = variants
        }
    }

    public struct Variant: Equatable, Sendable {
        public let text: String
        public let count: Int

        public init(text: String, count: Int) {
            self.text = text
            self.count = count
        }
    }

    /// An original-language form. Case and a grave accent where an acute
    /// stands at rest are not differences of form.
    public struct Form: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public let count: Int

        public init(id: String, text: String, count: Int) {
            self.id = id
            self.text = text
            self.count = count
        }
    }

    public struct Parsing: Identifiable, Equatable, Sendable {
        public var id: String { code }
        public let code: String
        public let count: Int
        /// The code read out, or nil for a code Lamp cannot read.
        public let description: String?

        public init(code: String, count: Int, description: String?) {
            self.code = code
            self.count = count
            self.description = description
        }
    }

    public struct GrammarCount: Equatable, Sendable {
        public let feature: LampGrammarFeature
        public let value: String
        public let count: Int

        public init(feature: LampGrammarFeature, value: String, count: Int) {
            self.feature = feature
            self.value = value
            self.count = count
        }
    }

    public enum Expectation: String, Codable, Sendable {
        case more
        case fewer
        case asExpected
    }

    /// A book, or a section of the canon such as the Gospels.
    public struct Division: Identifiable, Equatable, Sendable {
        /// The book's number, or a section's first book.
        public let id: Int
        public let name: String
        public let bookRange: ClosedRange<Int>
        public let occurrenceCount: Int
        /// The division's verses holding the key.
        public let verseCount: Int
        /// The division's tagged words of the key's language.
        public let wordCount: Int
        /// The occurrences its share of the words predicts.
        public let expectedCount: Double
        /// Log-likelihood against the rest of the range, negative where it
        /// holds fewer than predicted.
        public let keyness: Double
        /// A book's chapters with tags of the key's language; none for a section.
        public let chapters: [Chapter]

        public init(
            id: Int,
            name: String,
            bookRange: ClosedRange<Int>,
            occurrenceCount: Int,
            verseCount: Int,
            wordCount: Int,
            expectedCount: Double,
            keyness: Double,
            chapters: [Chapter]
        ) {
            self.id = id
            self.name = name
            self.bookRange = bookRange
            self.occurrenceCount = occurrenceCount
            self.verseCount = verseCount
            self.wordCount = wordCount
            self.expectedCount = expectedCount
            self.keyness = keyness
            self.chapters = chapters
        }

        /// Occurrences per thousand of the division's tagged words.
        public var ratePerThousandWords: Double {
            wordCount > 0 ? Double(occurrenceCount) * 1_000 / Double(wordCount) : 0
        }

        public var expectation: Expectation {
            guard abs(keyness) >= LampStrongsAnalysis.notableKeyness else { return .asExpected }
            return keyness > 0 ? .more : .fewer
        }
    }

    public struct Chapter: Identifiable, Equatable, Sendable {
        public var id: Int { number }
        public let number: Int
        public let occurrenceCount: Int
        public let wordCount: Int

        public init(number: Int, occurrenceCount: Int, wordCount: Int) {
            self.number = number
            self.occurrenceCount = occurrenceCount
            self.wordCount = wordCount
        }
    }

    /// Another key found in this one's verses more often than its frequency
    /// in range predicts.
    public struct Companion: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public let key: String
        /// Verses holding both keys.
        public let sharedVerseCount: Int
        /// Verses in range holding the companion.
        public let verseCount: Int
        /// How many times more often the two share a verse than chance predicts.
        public let lift: Double
        public let keyness: Double

        public init(key: String, sharedVerseCount: Int, verseCount: Int, lift: Double, keyness: Double) {
            self.key = key
            self.sharedVerseCount = sharedVerseCount
            self.verseCount = verseCount
            self.lift = lift
            self.keyness = keyness
        }
    }

    /// Divisions of the canon used to group books.
    public static let canonSections: [(name: String, books: ClosedRange<Int>)] = [
        ("Law", 1...5), ("History", 6...17), ("Poetry and Wisdom", 18...22),
        ("Major Prophets", 23...27), ("Minor Prophets", 28...39), ("Gospels", 40...43),
        ("Acts", 44...44), ("Paul’s Letters", 45...57), ("General Letters", 58...65),
        ("Revelation", 66...66),
    ]

    /// Log-likelihood (G²) of a 2×2 table: `hits` of `words` inside, against
    /// `otherHits` of `otherWords` outside. Signed negative where the inside
    /// holds fewer than its share.
    public static func keyness(hits: Int, words: Int, otherHits: Int, otherWords: Int) -> Double {
        let a = Double(hits), c = Double(max(words - hits, 0))
        let b = Double(otherHits), d = Double(max(otherWords - otherHits, 0))
        let total = a + b + c + d
        guard total > 0 else { return 0 }
        func term(_ observed: Double, _ expected: Double) -> Double {
            observed > 0 && expected > 0 ? observed * log(observed / expected) : 0
        }
        let expectedA = (a + c) * (a + b) / total
        let g = 2 * (
            term(a, expectedA)
                + term(c, (a + c) * (c + d) / total)
                + term(b, (b + d) * (a + b) / total)
                + term(d, (b + d) * (c + d) / total)
        )
        return a < expectedA ? -g : g
    }
}

/// Builds a `LampStrongsAnalysis` from verse rows. Hand it every verse in
/// range, in any order, then ask for `analysis()`.
///
/// Every verse's tags are counted, because the counts are measured against all
/// of them; only verses holding the key are read in full. The count reads the
/// annotations' bytes for their `"strongs"` values rather than parsing the
/// JSON, which over a whole Bible is the difference between a pause and a wait.
public struct LampStrongsAnalyzer {
    public let key: String
    private let translationID: String
    private let translationName: String
    private let translationAbbreviation: String?
    private let isEnglish: Bool
    private let keyLanguage: Character?
    private let bareKey: Substring?

    private var normalizedTags: [String: String] = [:]
    private var chapterWords: [Int: [Int: Int]] = [:]
    private var taggedVerseCount = 0
    private var verseFrequency: [String: Int] = [:]
    private var sharedVerses: [String: Int] = [:]
    private var occurrences: [LampStrongsAnalysis.Occurrence] = []
    private var tags: [String] = []

    /// `language` is the translation's; English renderings are gathered by
    /// the word that carries them, and any other language's by their text.
    public init(
        key: String,
        translationID: String,
        translationName: String,
        translationAbbreviation: String? = nil,
        language: String? = nil
    ) {
        let normalized = LampStrongsKey.normalized(key)
        self.key = normalized
        self.translationID = translationID
        self.translationName = translationName
        self.translationAbbreviation = translationAbbreviation
        isEnglish = language.map { $0.lowercased().hasPrefix("en") } ?? true
        let first = normalized.first
        keyLanguage = first == "H" || first == "G" ? first : nil
        bareKey = first?.isNumber == true ? Substring(normalized) : nil
    }

    /// `text` is read only when the verse holds the key.
    public mutating func add(reference: Int, text: @autoclosure () -> String, annotationsJSON: String?) {
        guard let annotationsJSON, !key.isEmpty else { return }
        tags.removeAll(keepingCapacity: true)
        Self.forEachTag(in: annotationsJSON) { raw in
            let tag = normalizedTag(raw)
            if isCounted(tag) { tags.append(tag) }
        }
        guard !tags.isEmpty else { return }
        let (book, chapter, _) = LampBibleReferenceFormatter.components(of: reference)
        chapterWords[book, default: [:]][chapter, default: 0] += tags.count
        taggedVerseCount += 1
        let distinct = Set(tags)
        for tag in distinct { verseFrequency[tag, default: 0] += 1 }
        guard distinct.contains(where: isKey) else { return }

        let (found, joined) = verseOccurrences(reference: reference, text: text(), annotationsJSON: annotationsJSON)
        guard !found.isEmpty else { return }
        // A word tagged in two pieces was counted twice above.
        chapterWords[book, default: [:]][chapter, default: 0] -= joined
        occurrences += found
        for tag in distinct where !isKey(tag) { sharedVerses[tag, default: 0] += 1 }
    }

    public func analysis() -> LampStrongsAnalysis {
        let ordered = occurrences.sorted {
            ($0.reference, $0.startOffset) < ($1.reference, $1.startOffset)
        }
        var references: [Int] = []
        for occurrence in ordered where references.last != occurrence.reference {
            references.append(occurrence.reference)
        }
        let totalWords = chapterWords.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let books = bookDivisions(ordered, totalWords: totalWords)
        return LampStrongsAnalysis(
            key: key,
            translationID: translationID,
            translationName: translationName,
            translationAbbreviation: translationAbbreviation,
            wordCount: totalWords,
            taggedVerseCount: taggedVerseCount,
            occurrences: ordered,
            references: references,
            renderings: renderings(ordered),
            forms: forms(ordered),
            parsings: parsings(ordered),
            grammar: grammar(ordered),
            books: books,
            sections: sections(books, totalHits: ordered.count, totalWords: totalWords),
            companions: companions(hitVerses: references.count)
        )
    }

    // MARK: - Reading a verse

    private mutating func normalizedTag(_ raw: String) -> String {
        if let known = normalizedTags[raw] { return known }
        let tag = LampStrongsKey.normalized(raw)
        normalizedTags[raw] = tag
        return tag
    }

    /// Whether a tag is a word of the key's language. A bare key names no
    /// language, so every Hebrew and Greek tag counts for it; anything else,
    /// such as a TVM code (`TH8799`), is not a word.
    private func isCounted(_ tag: String) -> Bool {
        guard let first = tag.first else { return false }
        if let keyLanguage { return first == keyLanguage }
        return first == "H" || first == "G"
    }

    private func isKey(_ tag: String) -> Bool {
        if tag == key { return true }
        guard let bareKey else { return false }
        return tag.dropFirst() == bareKey
    }

    /// Calls `body` with each value of every `"strongs"` field in the JSON,
    /// split where a field lists several (`"G3588,G2316"`).
    static func forEachTag(in json: String, _ body: (String) -> Void) {
        var json = json
        json.withUTF8 { bytes in
            let field = Array(#""strongs""#.utf8)
            let quote = UInt8(ascii: "\""), colon = UInt8(ascii: ":"), backslash = UInt8(ascii: "\\")
            func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
            func isSeparator(_ byte: UInt8) -> Bool {
                isSpace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: ";") || byte == UInt8(ascii: "|")
            }
            func emit(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                body(String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self))
            }
            let count = bytes.count
            var index = 0
            while index + field.count <= count {
                guard bytes[index] == quote,
                      field.indices.allSatisfy({ bytes[index + $0] == field[$0] }) else {
                    index += 1
                    continue
                }
                var cursor = index + field.count
                while cursor < count, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < count, bytes[cursor] == colon else { index = cursor; continue }
                cursor += 1
                while cursor < count, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < count, bytes[cursor] == quote else { index = cursor; continue }
                cursor += 1
                var start = cursor
                while cursor < count, bytes[cursor] != quote {
                    if bytes[cursor] == backslash {
                        cursor += 2
                        continue
                    }
                    if isSeparator(bytes[cursor]) {
                        emit(start..<cursor)
                        start = cursor + 1
                    }
                    cursor += 1
                }
                emit(start..<min(cursor, count))
                index = cursor + 1
            }
        }
    }

    /// The key's occurrences in one verse, and how many tags were joined into
    /// an occurrence before them.
    private mutating func verseOccurrences(
        reference: Int,
        text: String,
        annotationsJSON: String
    ) -> ([LampStrongsAnalysis.Occurrence], Int) {
        guard let data = annotationsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return ([], 0) }
        let annotations = json as? [[String: Any]]
            ?? (json as? [String: Any])?["annotations"] as? [[String: Any]]
            ?? []
        let characters = Array(text)
        func substring(_ start: Int, _ end: Int) -> String? {
            guard start >= 0, end > start, end <= characters.count else { return nil }
            return String(characters[start..<end])
        }

        var tagged: [LampStrongsAnalysis.Occurrence] = []
        for annotation in annotations {
            let data = annotation["data"] as? [String: Any]
            guard let value = (data?["strongs"] ?? annotation["strongs"]) as? String,
                  let start = annotation["start"] as? Int,
                  let end = annotation["end"] as? Int else { continue }
            let keys = value.split { $0 == "," || $0 == ";" || $0 == "|" || $0.isWhitespace }
                .map { normalizedTag(String($0)) }
            guard let index = keys.firstIndex(where: isKey) else { continue }
            let rendered = annotation["text"] as? String ?? substring(start, end) ?? ""
            tagged.append(occurrence(
                reference: reference, start: start, end: end, text: rendered,
                form: Self.aligned((data?["lemma"] ?? annotation["lemma"]) as? String, index, keys.count),
                morphology: Self.aligned((data?["morphology"] ?? annotation["morphology"]) as? String, index, keys.count)
            ))
        }
        tagged.sort { $0.startOffset < $1.startOffset }

        var found: [LampStrongsAnalysis.Occurrence] = []
        var joined = 0
        for next in tagged {
            guard let last = found.last else {
                found.append(next)
                continue
            }
            if (last.startOffset, last.endOffset) == (next.startOffset, next.endOffset) {
                joined += 1
                continue
            }
            guard last.endOffset >= 0,
                  last.endOffset <= next.startOffset,
                  next.startOffset <= characters.count,
                  characters[last.endOffset..<next.startOffset].allSatisfy(\.isWhitespace),
                  last.form == nil || next.form == nil || last.form == next.form,
                  last.morphology == nil || next.morphology == nil || last.morphology == next.morphology
            else {
                found.append(next)
                continue
            }
            found[found.count - 1] = occurrence(
                reference: reference, start: last.startOffset, end: next.endOffset,
                text: substring(last.startOffset, next.endOffset) ?? last.text + " " + next.text,
                form: last.form ?? next.form, morphology: last.morphology ?? next.morphology
            )
            joined += 1
        }
        return (found, joined)
    }

    private func occurrence(
        reference: Int, start: Int, end: Int, text: String, form: String?, morphology: String?
    ) -> LampStrongsAnalysis.Occurrence {
        LampStrongsAnalysis.Occurrence(
            reference: reference,
            startOffset: start,
            endOffset: end,
            text: text,
            renderingID: Self.renderingHead(of: text, isEnglish: isEnglish).lowercased(),
            form: form,
            morphology: morphology
        )
    }

    /// The part of a field that belongs to the `index`th of `count` keys. A
    /// field listing as many values as there are keys is read in step with
    /// them; a single value under several keys belongs to the first, as the
    /// KJV tags "God" with the article and the noun but gives the article's form.
    static func aligned(_ value: String?, _ index: Int, _ count: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard count > 1 else { return value }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == count { return parts[index].isEmpty ? nil : parts[index] }
        return index == 0 && parts.count == 1 ? value : nil
    }

    // MARK: - Renderings and forms

    private static let edgePunctuation = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters).union(.symbols)

    /// Words that ride along with a rendering without being it: articles,
    /// conjunctions, prepositions, pronouns, auxiliaries and negation, as in
    /// "of God", "his mercy", "He that loveth" or "does not love".
    private static let carriedWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "o", "of", "to", "unto", "in", "into", "on", "upon",
        "at", "by", "for", "from", "with", "because", "that", "which", "who", "whom",
        "i", "me", "my", "thou", "thee", "thy", "thine", "he", "him", "his", "she", "her", "it", "its",
        "we", "us", "our", "you", "ye", "your", "they", "them", "their",
        "be", "been", "being", "is", "are", "was", "were", "am", "art",
        "has", "have", "had", "hath", "hast", "shall", "shalt", "will", "wilt", "would", "should",
        "do", "does", "did", "doth", "may", "might", "must", "can", "could", "let", "not",
    ]

    /// The word that carries an English rendering: the text without its edge
    /// punctuation, the words that ride along with it, or a possessive ending.
    /// Never empty unless the rendering is.
    static func renderingHead(of text: String, isEnglish: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: edgePunctuation)
        guard isEnglish else { return trimmed }
        var words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        func carried(_ word: String) -> Bool {
            carriedWords.contains(word.trimmingCharacters(in: edgePunctuation).lowercased())
        }
        while words.count > 1, carried(words[0]) { words.removeFirst() }
        while words.count > 1, carried(words[words.count - 1]) { words.removeLast() }
        guard var last = words.popLast() else { return "" }
        for ending in ["’s", "'s"] where last.count > ending.count && last.hasSuffix(ending) {
            last.removeLast(ending.count)
        }
        if last.count > 1, last.hasSuffix("’") || last.hasSuffix("'") { last.removeLast() }
        return (words + [last]).joined(separator: " ").trimmingCharacters(in: edgePunctuation)
    }

    private func renderings(_ occurrences: [LampStrongsAnalysis.Occurrence]) -> [LampStrongsAnalysis.Rendering] {
        var heads: [String: [String: Int]] = [:]
        var variants: [String: [String: [String: Int]]] = [:]
        for occurrence in occurrences {
            let head = Self.renderingHead(of: occurrence.text, isEnglish: isEnglish)
            heads[occurrence.renderingID, default: [:]][head, default: 0] += 1
            let variant = occurrence.text.trimmingCharacters(in: Self.edgePunctuation)
            variants[occurrence.renderingID, default: [:]][variant.lowercased(), default: [:]][variant, default: 0] += 1
        }
        return heads.map { id, spellings in
            let groupVariants = (variants[id] ?? [:]).map { _, spellings in
                LampStrongsAnalysis.Variant(text: Self.mostCommon(spellings), count: spellings.values.reduce(0, +))
            }
            return LampStrongsAnalysis.Rendering(
                id: id,
                text: Self.mostCommon(spellings),
                count: spellings.values.reduce(0, +),
                variants: groupVariants.sorted { ($1.count, $0.text) < ($0.count, $1.text) }
            )
        }.sorted { ($1.count, $0.text) < ($0.count, $1.text) }
    }

    /// A form compared without case, and with a grave accent read as the acute
    /// it stands for at rest.
    static func formID(_ form: String) -> String {
        form.trimmingCharacters(in: edgePunctuation)
            .decomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{0300}", with: "\u{0301}")
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    private func forms(_ occurrences: [LampStrongsAnalysis.Occurrence]) -> [LampStrongsAnalysis.Form] {
        var spellings: [String: [String: Int]] = [:]
        for occurrence in occurrences {
            guard let form = occurrence.form?.precomposedStringWithCanonicalMapping else { continue }
            let id = Self.formID(form)
            guard !id.isEmpty else { continue }
            spellings[id, default: [:]][form.trimmingCharacters(in: Self.edgePunctuation), default: 0] += 1
        }
        return spellings.map { id, written in
            LampStrongsAnalysis.Form(id: id, text: Self.mostCommon(written), count: written.values.reduce(0, +))
        }.sorted { ($1.count, $0.text) < ($0.count, $1.text) }
    }

    private func parsings(_ occurrences: [LampStrongsAnalysis.Occurrence]) -> [LampStrongsAnalysis.Parsing] {
        var counts: [String: Int] = [:]
        for occurrence in occurrences {
            if let code = occurrence.morphology { counts[code, default: 0] += 1 }
        }
        return counts.map { code, count in
            LampStrongsAnalysis.Parsing(code: code, count: count, description: describe(code))
        }.sorted { ($1.count, $0.code) < ($0.count, $1.code) }
    }

    private func grammar(_ occurrences: [LampStrongsAnalysis.Occurrence]) -> [LampStrongsAnalysis.GrammarCount] {
        var counts: [LampGrammarValue: Int] = [:]
        for occurrence in occurrences {
            guard let code = occurrence.morphology, key.first == "G" else { continue }
            for value in LampGreekMorphology.features(of: code) { counts[value, default: 0] += 1 }
        }
        let order = Dictionary(uniqueKeysWithValues: LampGrammarFeature.allCases.enumerated().map { ($1, $0) })
        return counts.map { value, count in
            LampStrongsAnalysis.GrammarCount(feature: value.feature, value: value.value, count: count)
        }.sorted {
            let left = order[$0.feature] ?? 0, right = order[$1.feature] ?? 0
            if left != right { return left < right }
            return ($1.count, $0.value) < ($0.count, $1.value)
        }
    }

    /// Robinson's codes are Greek; a Hebrew key's codes are left unread.
    private func describe(_ code: String) -> String? {
        key.first == "G" ? LampGreekMorphology.describe(code) : nil
    }

    private static func mostCommon(_ counts: [String: Int]) -> String {
        counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
    }

    // MARK: - Spread and company

    private func bookDivisions(
        _ occurrences: [LampStrongsAnalysis.Occurrence],
        totalWords: Int
    ) -> [LampStrongsAnalysis.Division] {
        var hits: [Int: [Int: Int]] = [:]
        var verses: [Int: Set<Int>] = [:]
        for occurrence in occurrences {
            let (book, chapter, _) = LampBibleReferenceFormatter.components(of: occurrence.reference)
            hits[book, default: [:]][chapter, default: 0] += 1
            verses[book, default: []].insert(occurrence.reference)
        }
        let totalHits = occurrences.count
        return chapterWords.keys.sorted().map { book in
            let chapters = (chapterWords[book] ?? [:]).keys.sorted().map { chapter in
                LampStrongsAnalysis.Chapter(
                    number: chapter,
                    occurrenceCount: hits[book]?[chapter] ?? 0,
                    wordCount: chapterWords[book]?[chapter] ?? 0
                )
            }
            return division(
                id: book, name: LampBibleReferenceFormatter.bookName(book), books: book...book,
                hits: chapters.reduce(0) { $0 + $1.occurrenceCount },
                verses: verses[book]?.count ?? 0,
                words: chapters.reduce(0) { $0 + $1.wordCount },
                totalHits: totalHits, totalWords: totalWords, chapters: chapters
            )
        }
    }

    private func sections(
        _ books: [LampStrongsAnalysis.Division],
        totalHits: Int,
        totalWords: Int
    ) -> [LampStrongsAnalysis.Division] {
        var sections = LampStrongsAnalysis.canonSections
        let named = sections.map(\.books)
        let others = books.map(\.id).filter { book in !named.contains { $0.contains(book) } }
        if let first = others.min(), let last = others.max() {
            sections.append(("Other Books", first...last))
        }
        return sections.compactMap { section in
            let members = books.filter { section.books.contains($0.id) }
            guard !members.isEmpty else { return nil }
            return division(
                id: section.books.lowerBound, name: section.name, books: section.books,
                hits: members.reduce(0) { $0 + $1.occurrenceCount },
                verses: members.reduce(0) { $0 + $1.verseCount },
                words: members.reduce(0) { $0 + $1.wordCount },
                totalHits: totalHits, totalWords: totalWords, chapters: []
            )
        }
    }

    private func division(
        id: Int, name: String, books: ClosedRange<Int>, hits: Int, verses: Int, words: Int,
        totalHits: Int, totalWords: Int, chapters: [LampStrongsAnalysis.Chapter]
    ) -> LampStrongsAnalysis.Division {
        LampStrongsAnalysis.Division(
            id: id,
            name: name,
            bookRange: books,
            occurrenceCount: hits,
            verseCount: verses,
            wordCount: words,
            expectedCount: totalWords > 0 ? Double(totalHits) * Double(words) / Double(totalWords) : 0,
            keyness: LampStrongsAnalysis.keyness(
                hits: hits, words: words,
                otherHits: totalHits - hits, otherWords: totalWords - words
            ),
            chapters: chapters
        )
    }

    /// Keys that share this key's verses at least twice as often as chance
    /// predicts, and more often than chance at the 1% level, most certain
    /// first. Neither test serves alone. Ranked by certainty, the commonest
    /// words lead, because a word in most verses shares many of them by being
    /// everywhere: the KJV's article would head every list. Ranked by how many
    /// times chance, a name found three times, each beside the key, outranks
    /// every real companion. A pair must also share three verses, or two
    /// where the key has fewer than twenty.
    private func companions(hitVerses: Int, limit: Int = 25) -> [LampStrongsAnalysis.Companion] {
        guard hitVerses > 0, taggedVerseCount > 0 else { return [] }
        let minimumShared = hitVerses < 20 ? 2 : 3
        return sharedVerses.compactMap { tag, shared -> LampStrongsAnalysis.Companion? in
            guard shared >= minimumShared, let verses = verseFrequency[tag] else { return nil }
            let keyness = LampStrongsAnalysis.keyness(
                hits: shared, words: hitVerses,
                otherHits: verses - shared, otherWords: taggedVerseCount - hitVerses
            )
            let lift = Double(shared) * Double(taggedVerseCount) / (Double(hitVerses) * Double(verses))
            guard keyness >= 6.63, lift >= 2 else { return nil }
            return LampStrongsAnalysis.Companion(
                key: tag, sharedVerseCount: shared, verseCount: verses, lift: lift, keyness: keyness
            )
        }
        .sorted { ($1.keyness, $0.key) < ($0.keyness, $1.key) }
        .prefix(limit)
        .map { $0 }
    }
}
