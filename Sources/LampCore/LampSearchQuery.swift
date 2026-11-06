import Foundation

public struct LampSearchTerm: Equatable, Sendable {
    public let text: String
    public let isExact: Bool

    public init(text: String, isExact: Bool) {
        self.text = text
        self.isExact = isExact
    }

    /// Whether `text` holds this term: anywhere for a typed word, as a whole
    /// word or phrase when quoted. Case, accents and the form of an
    /// apostrophe make no difference, so "Lord's" finds "Lord’s" and "λογος"
    /// finds "λόγος".
    public func matches(_ text: String) -> Bool {
        !ranges(in: text, wordStartsOnly: false, maximumMatches: 1).isEmpty
    }

    /// Where this term falls in `text`, as Character offsets. A quoted term
    /// must stand as a whole word or phrase. A typed word, which the full-text
    /// index matches at the start of a word, is found there when
    /// `wordStartsOnly` is set.
    func ranges(in text: String, wordStartsOnly: Bool, maximumMatches: Int? = nil) -> [Range<Int>] {
        let needle = LampSearchQuery.foldingApostrophes(self.text)
        // No text-wide normalization is needed for the usual word query.
        // Only a needle containing an apostrophe needs its equivalent forms.
        let folded = needle.contains("'") ? LampSearchQuery.foldingApostrophes(text) : text
        guard !needle.isEmpty, !folded.isEmpty else { return [] }
        var found: [Range<Int>] = []
        var searchStart = folded.startIndex
        var searchOffset = 0
        while searchStart < folded.endIndex,
              let match = folded.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<folded.endIndex
              ) {
            // Count from the previous match, not from the beginning each time.
            // Repeated common words in a long chapter otherwise become quadratic.
            let lower = searchOffset + folded.distance(from: searchStart, to: match.lowerBound)
            let upper = lower + folded.distance(from: match.lowerBound, to: match.upperBound)
            func isWordCharacter(_ index: String.Index) -> Bool {
                index < folded.endIndex && (folded[index].isLetter || folded[index].isNumber)
            }
            let startsWord = match.lowerBound == folded.startIndex
                || !isWordCharacter(folded.index(before: match.lowerBound))
            let endsWord = !isWordCharacter(match.upperBound)
            if isExact ? startsWord && endsWord : (!wordStartsOnly || startsWord) {
                found.append(lower..<upper)
                if let maximumMatches, found.count >= maximumMatches { break }
            }
            searchStart = folded.index(after: match.lowerBound)
            searchOffset = lower + 1
        }
        return found
    }
}

/// A passage a search names, for going straight to it rather than searching.
public struct LampSearchReference: Equatable, Sendable {
    /// Packed references. A chapter named without verses runs from verse 1
    /// to 999, as a range does everywhere else.
    public let startReference: Int
    public let endReference: Int

    public init(startReference: Int, endReference: Int) {
        self.startReference = startReference
        self.endReference = endReference
    }

    /// "John 3:16", "1 Corinthians 13".
    public var description: String {
        LampBibleReferenceFormatter.describeRange(from: startReference, to: endReference)
    }
}

/// iOS's quoted-phrase and prefix-search grammar, shared with Mac search.
public struct LampSearchQuery: Equatable, Sendable {
    public let source: String
    public let terms: [LampSearchTerm]

    public init(_ source: String) {
        self.source = source
        self.terms = Self.parse(source)
    }

    private init(source: String, terms: [LampSearchTerm]) {
        self.source = source
        self.terms = terms
    }

    /// The query's words in the order typed, as one phrase, when it has more
    /// than one: a text holding "kingdom of God" together answers it better
    /// than one with "kingdom" in one place and "God" pages on. It starts a
    /// word, and ends one only where the last term was quoted.
    var phrase: LampSearchTerm? {
        guard terms.count > 1, let last = terms.last else { return nil }
        return LampSearchTerm(text: plainText, isExact: last.isExact)
    }

    /// Whether `text` holds the query's words together, in order, however
    /// its lines break. A query of one term has no phrase to hold.
    public func holdsPhrase(_ text: String) -> Bool {
        guard let phrase else { return false }
        return !phrase.ranges(in: Self.singleSpaced(text), wordStartsOnly: true, maximumMatches: 1).isEmpty
    }

    /// FTS5 MATCH argument for the phrase, as `fts5Query` writes a quoted
    /// one, prefix-matching its last word unless that was quoted.
    public var phraseFTS5Query: String? {
        guard let phrase else { return nil }
        let query = LampSearchQuery(source: phrase.text, terms: [phrase]).fts5Query
        return query.isEmpty ? nil : query
    }

    /// Runs of whitespace as one space, so that a phrase is found across a
    /// line break; text without such a run is returned as it is.
    static func singleSpaced(_ text: String) -> String {
        guard text.contains("  ") || text.contains(where: { $0.isWhitespace && $0 != " " }) else { return text }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ text: String) -> Bool {
        terms.allSatisfy { $0.matches(text) }
    }

    /// Refines a legacy LIKE prefilter to the same word-start boundary used
    /// by indexed book/commentary searches. A quoted term also ends a word.
    func matchesWordPrefixes(_ text: String) -> Bool {
        terms.allSatisfy {
            !$0.ranges(in: text, wordStartsOnly: true, maximumMatches: 1).isEmpty
        }
    }

    public var plainText: String {
        terms.map(\.text).joined(separator: " ")
    }

    /// The passage the whole query names, "John 3:16", "1 Cor 13" or "Ps
    /// 23:1-4", when the book has that chapter. A chapter is required, so a
    /// book's name alone ("Job", "Acts", "Mark") stays a word to search for.
    public var reference: LampSearchReference? {
        guard let range = try? LampReferenceParser.parse(source),
              let startChapters = LampReferenceParser.chapterCount(ofBook: range.start.book),
              let endChapters = LampReferenceParser.chapterCount(ofBook: range.end.book),
              range.start.chapter <= startChapters, range.end.chapter <= endChapters else { return nil }
        return LampSearchReference(
            startReference: range.start.book * 1_000_000 + range.start.chapter * 1_000 + (range.start.verse ?? 1),
            endReference: range.end.book * 1_000_000 + range.end.chapter * 1_000 + (range.end.verse ?? 999)
        )
    }

    /// FTS5 MATCH argument. Exact quoted terms stay phrases; unquoted terms
    /// use iOS's prefix match rule. Every term is escaped before interpolation.
    ///
    /// A hyphen or an apostrophe separates rather than disappears. FTS5
    /// tokenizes "self-control" as `self` and `control`, and "Lord’s" as
    /// `lord` and `s`, so deleting either character asked for a single token,
    /// "selfcontrol" or "lords", that no verse contains, and the search found
    /// nothing at all. Keeping it as a space asks for the tokens together,
    /// which is what was typed.
    public var fts5Query: String {
        terms.compactMap { term -> String? in
            var escaped = Self.foldingApostrophes(term.text)
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "'", with: " ")
                .replacingOccurrences(of: "^", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !escaped.isEmpty else { return nil }
            escaped = escaped
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\u{201C}", with: "")
                .replacingOccurrences(of: "\u{201D}", with: "")
            return "\"\(escaped)\"" + (term.isExact ? "" : "*")
        }.joined(separator: " ")
    }

    /// Broad Realm prefilter used by the iOS bundled dictionary adapter.
    public var realmPrefilter: String {
        source
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The keys of a module's JSON whose string values are its words. Every
    /// other string in it is structure: a type, an id, a style.
    public static let jsonTextKeys = [
        "text", "content", "title", "gloss", "shortDefinition", "definition",
        "usage", "derivation", "word", "label",
    ]

    /// Prepared LIKE predicate for module tables without FTS indexes. Terms
    /// must all match, and each term may appear in any listed column.
    ///
    /// A JSON column is searched in the words it holds, never in its keys.
    /// Matched as text, every commentary unit holds "text" and "start", and
    /// every lexicon entry "definition", so those words, and any search for
    /// "the end", matched everything. The raw LIKE still runs first, so the
    /// JSON is only walked where the term appears somewhere in it.
    ///
    /// `%` and `_` in a term are matched as themselves, and an apostrophe
    /// matches either form, since translations print "Lord’s" and keyboards
    /// type "Lord's".
    public func sqlLikePredicate(
        columns: [String],
        jsonColumns: [String] = []
    ) -> (condition: String, arguments: [String]) {
        guard !terms.isEmpty, !columns.isEmpty || !jsonColumns.isEmpty else { return ("0", []) }
        let keys = Self.jsonTextKeys.map { "'\($0)'" }.joined(separator: ", ")
        var arguments: [String] = []
        let condition = terms.map { term -> String in
            var alternatives: [String] = []
            for variant in Self.apostropheVariants(of: term.text) {
                let pattern = "%" + Self.escapedForLike(variant) + "%"
                for column in columns {
                    alternatives.append("COALESCE(\(column), '') LIKE ? ESCAPE '\\'")
                    arguments.append(pattern)
                }
                for column in jsonColumns {
                    alternatives.append("""
                        (COALESCE(\(column), '') LIKE ? ESCAPE '\\' AND EXISTS (
                        SELECT 1 FROM json_tree(CASE WHEN json_valid(\(column)) THEN \(column) ELSE '{}' END) AS j
                        WHERE j.type = 'text' AND (j.key IN (\(keys)) OR j.parent IS NULL)
                        AND j.value LIKE ? ESCAPE '\\'))
                        """)
                    arguments += [pattern, pattern]
                }
            }
            return "(" + alternatives.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
        return (condition, arguments)
    }

    public func textRank(in texts: [String]) -> Double {
        let query = realmPrefilter.lowercased()
        guard !query.isEmpty else { return 0 }
        return texts.reduce(0) { score, text in
            let lower = text.lowercased()
            if lower == query { return score + 10 }
            if lower.hasPrefix(query) { return score + 5 }
            if lower.contains(query) { return score + 1 }
            return score
        }
    }

    /// `text` cut to about `limit` characters around its first match, with
    /// every match wrapped in `<mark>`: the words the search found, marked as
    /// it matched them. A typed word is marked where a word starts with it, as
    /// the full-text index finds it, or anywhere when it starts no word, as a
    /// substring search finds it. Text without a match is cut from its start.
    public func markedSnippet(_ text: String, limit: Int = 280) -> String {
        guard limit > 0, !text.isEmpty else { return "" }
        // A phrase may cross a paragraph break. Normalize that exceptional
        // case before locating it; ordinary word snippets need no full copy.
        if phrase != nil || terms.contains(where: { $0.text.contains(where: \.isWhitespace) }) {
            let spaced = Self.singleSpaced(text)
            if spaced != text { return markedSnippet(spaced, limit: limit) }
        }
        // Locate only the first useful occurrence of each term. Once a window
        // is chosen, find/highlight matches only inside that bounded window.
        let matches = terms.map { term -> (term: LampSearchTerm, startsWord: Bool, first: Int?) in
            if let first = term.ranges(in: text, wordStartsOnly: true, maximumMatches: 1).first {
                return (term, true, first.lowerBound)
            }
            return (term, false, term.ranges(in: text, wordStartsOnly: false, maximumMatches: 1).first?.lowerBound)
        }
        // Where the words stand together, if they do, rather than wherever
        // the first of them turns up: "of" is everywhere.
        let together = phrase?.ranges(in: text, wordStartsOnly: true, maximumMatches: 1).first?.lowerBound
        let first = together ?? matches.compactMap(\.first).min() ?? 0
        var start = text.index(text.startIndex, offsetBy: max(0, first - limit / 3))
        var rewind = 0
        while start > text.startIndex, rewind < limit {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
            rewind += 1
        }

        // Collapse just enough text to display the snippet, not a whole book
        // chapter. Keep one extra character to detect a clipped final word.
        var characters: [Character] = []
        characters.reserveCapacity(min(limit, 4096))
        var cursor = start
        var spacePending = false
        while cursor < text.endIndex, characters.count <= limit {
            let character = text[cursor]
            cursor = text.index(after: cursor)
            if character.isWhitespace {
                if !characters.isEmpty { spacePending = true }
            } else {
                if spacePending { characters.append(" ") }
                characters.append(character)
                spacePending = false
            }
        }
        var end = min(limit, characters.count)
        let hasMore = cursor < text.endIndex || characters.count > end
        if characters.count > end {
            var cut = end
            while cut > 0, !characters[cut - 1].isWhitespace { cut -= 1 }
            if cut > end / 2 { end = cut - 1 }
        }
        characters = Array(characters.prefix(end))
        let window = String(characters)
        let marks = matches.flatMap {
            $0.term.ranges(in: window, wordStartsOnly: $0.startsWord)
        }.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var merged: [Range<Int>] = []
        for mark in marks {
            if let last = merged.last, mark.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, mark.upperBound)
            } else {
                merged.append(mark)
            }
        }
        var result = start > text.startIndex ? "…" : ""
        var offset = 0
        for mark in merged {
            result += String(characters[offset..<mark.lowerBound])
                + "<mark>" + String(characters[mark]) + "</mark>"
            offset = mark.upperBound
        }
        result += String(characters[offset...])
        return result.trimmingCharacters(in: .whitespaces) + (hasMore ? "…" : "")
    }

    /// Curly and modifier apostrophes as the straight one, Character for
    /// Character, so offsets into the result are offsets into the text.
    static func foldingApostrophes(_ text: String) -> String {
        guard text.contains(where: { apostrophes.contains($0) }) else { return text }
        return String(text.map { apostrophes.contains($0) ? "'" : $0 })
    }

    private static let apostrophes: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    /// The term as typed, and with its apostrophes in the other form.
    private static func apostropheVariants(of text: String) -> [String] {
        let straight = foldingApostrophes(text)
        guard straight.contains("'") else { return [text] }
        return [straight, straight.replacingOccurrences(of: "'", with: "\u{2019}")]
    }

    private static func escapedForLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Splits on whitespace, keeping quoted phrases whole. A quote opens only
    /// at the start of a word, and a single quote closes only where no letter
    /// follows it, so the apostrophe in "God's" or 'God's love' is part of
    /// the word rather than a quote opening or closing in it.
    private static func parse(_ raw: String) -> [LampSearchTerm] {
        let input = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !input.isEmpty else { return [] }
        let openingDouble: Set<Character> = ["\"", "\u{201C}"]
        let closingDouble: Set<Character> = ["\"", "\u{201D}"]
        let openingSingle: Set<Character> = ["'", "\u{2018}"]
        let closingSingle: Set<Character> = ["'", "\u{2019}"]

        var terms: [LampSearchTerm] = []
        var current = ""
        var quote: Character?
        func flush(exact: Bool) {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { terms.append(LampSearchTerm(text: text, isExact: exact)) }
            current = ""
        }
        for (index, character) in input.enumerated() {
            let next = index + 1 < input.count ? input[index + 1] : nil
            let letterFollows = next.map { $0.isLetter || $0.isNumber } ?? false
            if let activeQuote = quote {
                let closes = activeQuote == "\""
                    ? closingDouble.contains(character)
                    : closingSingle.contains(character) && !letterFollows
                if closes {
                    flush(exact: true)
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if current.isEmpty,
                      openingDouble.contains(character) || openingSingle.contains(character) {
                quote = openingDouble.contains(character) ? "\"" : "'"
            } else if openingDouble.contains(character) {
                flush(exact: false)
                quote = "\""
            } else if character.isWhitespace {
                flush(exact: false)
            } else {
                current.append(character)
            }
        }
        flush(exact: quote != nil)
        return terms
    }
}
