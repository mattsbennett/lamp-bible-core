import Foundation

public struct LampSearchTerm: Equatable, Sendable {
    public let text: String
    public let isExact: Bool
    /// Typed with a `*` before it, as `*faith`: found anywhere in a word, as
    /// "unfaithful" holds it, rather than only where a word starts.
    public let isWithinWord: Bool

    public init(text: String, isExact: Bool, isWithinWord: Bool = false) {
        self.text = text
        self.isExact = isExact
        self.isWithinWord = isWithinWord && !isExact
    }

    /// Whether `text` holds this term: where a word starts with it for a
    /// typed word, as the full-text index finds it, so that "faith" finds
    /// "faithful" and not "unfaithful"; anywhere in a word for one typed
    /// `*faith`; as a whole word or phrase when quoted. Case, accents and the
    /// form of an apostrophe make no difference, so "Lord's" finds "Lord’s"
    /// and "λογος" finds "λόγος".
    public func matches(_ text: String) -> Bool {
        !ranges(in: text, wordStartsOnly: true, maximumMatches: 1).isEmpty
    }

    /// Where this term falls in `text`, as Character offsets. A quoted term
    /// must stand as a whole word or phrase, and one typed `*word` may fall
    /// anywhere. A typed word, which the full-text index matches at the start
    /// of a word, is found there when `wordStartsOnly` is set.
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
            if isExact ? startsWord && endsWord : (isWithinWord || !wordStartsOnly || startsWord) {
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

/// The search grammar every search of either app reads a query by: a typed
/// word is found where a word starts with it (`faith`, or `faith*`, finds
/// "faithful"); one typed `*faith` anywhere in a word ("unfaithful"); a
/// quoted word or phrase whole (`"faith"`, `"kingdom of God"`). Every term
/// must be found.
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
    /// word, and ends one only where the last term was quoted. A query with a
    /// term found within words has none.
    var phrase: LampSearchTerm? {
        guard terms.count > 1, !hasWithinWordTerms, let last = terms.last else { return nil }
        return LampSearchTerm(text: plainText, isExact: last.isExact)
    }

    /// Whether `text` holds the query's words together, in order, however
    /// its lines break. A query of one term has no phrase to hold.
    public func holdsPhrase(_ text: String) -> Bool {
        phraseOffset(in: text) != nil
    }

    /// Where the query's words first stand together in `text`, as a
    /// Character offset: the first starting a word, each after the one
    /// before with only whitespace between, however much, and the last a
    /// word's start unless it was quoted. Found in one pass over the text as
    /// it is: rebuilding a long chapter to single-space it, for every result
    /// kept, made a search of several words seconds long.
    func phraseOffset(in text: String) -> Int? {
        guard phrase != nil, let last = terms.last else { return nil }
        let words = terms.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
            .map { Self.foldingApostrophes(String($0)) }
        guard let head = words.first, !head.isEmpty else { return nil }
        // Folding keeps every Character in place, so offsets into it are
        // offsets into the text.
        let folded = words.contains { $0.contains("'") } ? Self.foldingApostrophes(text) : text
        func isWordCharacter(_ index: String.Index) -> Bool {
            index < folded.endIndex && (folded[index].isLetter || folded[index].isNumber)
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchStart = folded.startIndex
        while searchStart < folded.endIndex,
              let match = folded.range(of: head, options: options, range: searchStart..<folded.endIndex) {
            searchStart = folded.index(after: match.lowerBound)
            if match.lowerBound > folded.startIndex, isWordCharacter(folded.index(before: match.lowerBound)) {
                continue
            }
            var cursor = match.upperBound
            var together = true
            for word in words.dropFirst() {
                var next = cursor
                while next < folded.endIndex, folded[next].isWhitespace { next = folded.index(after: next) }
                guard next > cursor,
                      let following = folded.range(
                        of: word, options: options.union(.anchored), range: next..<folded.endIndex
                      ) else {
                    together = false
                    break
                }
                cursor = following.upperBound
            }
            if together, !last.isExact || !isWordCharacter(cursor) {
                return folded.distance(from: folded.startIndex, to: match.lowerBound)
            }
        }
        return nil
    }

    /// FTS5 MATCH argument for the phrase, as `fts5Query` writes a quoted
    /// one, prefix-matching its last word unless that was quoted.
    public var phraseFTS5Query: String? {
        guard let phrase else { return nil }
        let query = LampSearchQuery(source: phrase.text, terms: [phrase]).fts5Query
        return query.isEmpty ? nil : query
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Whether a term is found within words, which a full-text index, finding
    /// the words a term starts, can't answer by itself.
    public var hasWithinWordTerms: Bool { terms.contains(where: \.isWithinWord) }

    /// The query of `term` alone, read as it was.
    func only(_ term: LampSearchTerm) -> LampSearchQuery {
        LampSearchQuery(source: term.text, terms: [term])
    }

    public func matches(_ text: String) -> Bool {
        terms.allSatisfy { $0.matches(text) }
    }

    /// Refines a LIKE prefilter, which finds a term anywhere, to the query's
    /// own rule for each term, as `matches`: a typed word where a word
    /// starts, as the indexed searches find it, a quoted one whole.
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
    /// Empty, as for a query of nothing searchable, where a term is found
    /// within words: an index has no way to ask for that by itself, so the
    /// text is read instead, or the words holding it are asked for by
    /// `fts5Query(wordsHolding:)`.
    ///
    /// A hyphen or an apostrophe separates rather than disappears. FTS5
    /// tokenizes "self-control" as `self` and `control`, and "Lord’s" as
    /// `lord` and `s`, so deleting either character asked for a single token,
    /// "selfcontrol" or "lords", that no verse contains, and the search found
    /// nothing at all. Keeping it as a space asks for the tokens together,
    /// which is what was typed.
    public var fts5Query: String {
        hasWithinWordTerms ? "" : fts5Query { _ in [] }
    }

    /// FTS5 MATCH argument with each term found within words asked as the
    /// words of the index holding it, from `words`, any one of them. Each
    /// such term must have one. FTS5 takes words side by side as all of
    /// them, but not a group of either, so a query with one says AND.
    func fts5Query(wordsHolding words: (LampSearchTerm) throws -> [String]) rethrows -> String {
        try terms.compactMap { term -> String? in
            if term.isWithinWord {
                let alternatives = try words(term).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return alternatives.count == 1 ? alternatives[0] : "(" + alternatives.joined(separator: " OR ") + ")"
            }
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
        }.joined(separator: hasWithinWordTerms ? " AND " : " ")
    }

    /// Broad Realm prefilter used by the iOS bundled dictionary adapter.
    public var realmPrefilter: String {
        source
            .replacingOccurrences(of: "*", with: "")
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
    ///
    /// Where the query's words stand together the window is cut there, unless
    /// `findingPhrase` is false: a caller that already knows they don't need
    /// not have the text read for them again.
    public func markedSnippet(_ text: String, limit: Int = 280, findingPhrase: Bool = true) -> String {
        guard limit > 0, !text.isEmpty else { return "" }
        // A phrase may cross a paragraph break. Normalize that exceptional
        // case before locating it; ordinary word snippets need no full copy.
        if terms.contains(where: { $0.text.contains(where: \.isWhitespace) }),
           text.contains("  ") || text.contains(where: { $0.isWhitespace && $0 != " " }) {
            return markedSnippet(
                text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                limit: limit, findingPhrase: findingPhrase
            )
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
        let together = findingPhrase ? phraseOffset(in: text) : nil
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
            var text = current.trimmingCharacters(in: .whitespaces)
            // `*faith` is found within words. A `*` anywhere else, as in
            // `faith*`, asks what a typed word already does, and is dropped.
            let withinWord = !exact && text.hasPrefix("*")
            text = text.replacingOccurrences(of: "*", with: "")
            if !text.isEmpty { terms.append(LampSearchTerm(text: text, isExact: exact, isWithinWord: withinWord)) }
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
