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
        !ranges(in: text, wordStartsOnly: false).isEmpty
    }

    /// Where this term falls in `text`, as Character offsets. A quoted term
    /// must stand as a whole word or phrase. A typed word, which the full-text
    /// index matches at the start of a word, is found there when
    /// `wordStartsOnly` is set.
    func ranges(in text: String, wordStartsOnly: Bool) -> [Range<Int>] {
        let haystack = Array(LampSearchQuery.foldingApostrophes(text))
        let needle = LampSearchQuery.foldingApostrophes(self.text)
        guard !needle.isEmpty, !haystack.isEmpty else { return [] }
        let folded = String(haystack)
        var found: [Range<Int>] = []
        var searchStart = folded.startIndex
        while searchStart < folded.endIndex,
              let match = folded.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<folded.endIndex
              ) {
            let lower = folded.distance(from: folded.startIndex, to: match.lowerBound)
            let upper = folded.distance(from: folded.startIndex, to: match.upperBound)
            func isWordCharacter(_ offset: Int) -> Bool {
                haystack.indices.contains(offset) && (haystack[offset].isLetter || haystack[offset].isNumber)
            }
            let startsWord = !isWordCharacter(lower - 1)
            let endsWord = !isWordCharacter(upper)
            if isExact ? startsWord && endsWord : (!wordStartsOnly || startsWord) {
                found.append(lower..<upper)
            }
            searchStart = folded.index(after: match.lowerBound)
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

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ text: String) -> Bool {
        terms.allSatisfy { $0.matches(text) }
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
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let characters = Array(collapsed)
        var marks: [Range<Int>] = []
        for term in terms {
            let starts = term.ranges(in: collapsed, wordStartsOnly: true)
            marks += starts.isEmpty ? term.ranges(in: collapsed, wordStartsOnly: false) : starts
        }
        marks.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for mark in marks {
            if let last = merged.last, mark.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, mark.upperBound)
            } else {
                merged.append(mark)
            }
        }

        var window = 0..<characters.count
        if characters.count > limit {
            var start = max((merged.first?.lowerBound ?? 0) - limit / 3, 0)
            while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
            var end = min(start + limit, characters.count)
            if end < characters.count {
                var cut = end
                while cut > start, !characters[cut - 1].isWhitespace { cut -= 1 }
                if cut > start + limit / 2 { end = cut - 1 }
            }
            window = start..<end
        }

        var result = window.lowerBound > 0 ? "…" : ""
        var cursor = window.lowerBound
        for mark in merged where mark.lowerBound < window.upperBound && mark.upperBound > window.lowerBound {
            let lower = max(mark.lowerBound, window.lowerBound)
            let upper = min(mark.upperBound, window.upperBound)
            result += String(characters[cursor..<lower]) + "<mark>" + String(characters[lower..<upper]) + "</mark>"
            cursor = upper
        }
        result += String(characters[cursor..<window.upperBound])
        return result.trimmingCharacters(in: .whitespaces) + (window.upperBound < characters.count ? "…" : "")
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
