import Foundation

public struct LampSearchTerm: Equatable, Sendable {
    public let text: String
    public let isExact: Bool

    public init(text: String, isExact: Bool) {
        self.text = text
        self.isExact = isExact
    }

    public func matches(_ text: String) -> Bool {
        guard isExact else { return text.localizedCaseInsensitiveContains(self.text) }
        let escaped = NSRegularExpression.escapedPattern(for: self.text)
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\b", options: .caseInsensitive
        ) else { return text.localizedCaseInsensitiveContains(self.text) }
        return expression.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) != nil
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

    /// FTS5 MATCH argument. Exact quoted terms stay phrases; unquoted terms
    /// use iOS's prefix match rule. Every term is escaped before interpolation.
    public var fts5Query: String {
        terms.compactMap { term -> String? in
            var escaped = term.text
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "-", with: "")
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
                .replacingOccurrences(of: "\u{2018}", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
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

    /// Prepared LIKE predicate for module tables without FTS indexes. Terms
    /// must all match, and each term may appear in any listed column.
    public func sqlLikePredicate(columns: [String]) -> (condition: String, arguments: [String]) {
        guard !terms.isEmpty, !columns.isEmpty else { return ("0", []) }
        let condition = terms.map { _ in
            "(" + columns.map { "COALESCE(\($0), '') LIKE ? COLLATE NOCASE" }
                .joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
        let arguments = terms.flatMap { term in
            Array(repeating: "%\(term.text)%", count: columns.count)
        }
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

    private static func parse(_ raw: String) -> [LampSearchTerm] {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for character in input {
            if let activeQuote = quote {
                if (activeQuote == "\"" ? closingDouble : closingSingle).contains(character) {
                    flush(exact: true)
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if openingDouble.contains(character) || openingSingle.contains(character) {
                flush(exact: false)
                quote = openingDouble.contains(character) ? "\"" : "'"
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
