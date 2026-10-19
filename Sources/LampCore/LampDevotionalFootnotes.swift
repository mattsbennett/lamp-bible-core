import Foundation

/// Numbers a devotional's footnotes by the order they are first referred to.
///
/// A devotional keeps its markers in the writing and its definitions in a field
/// of their own, and both were shown exactly as typed. So the labels *were* the
/// numbering: adding a footnote early in a talk with thirty-five of them meant
/// renumbering every later one by hand, in the prose and in the definitions,
/// and a mistake either side left a marker pointing at the wrong note.
///
/// The labels in the source can now be any run of characters with no space in
/// it and no closing bracket — `[^lewis]`, `[^2a]`, `[^pinker-48]`, or numbers
/// in any order — and a reader is shown 1, 2, 3 in reading order. The
/// numbering happens where the writing is shown or exported, never on save:
/// rewriting `draft.md` would change it under an agent that is editing it.
public enum LampDevotionalFootnotes {
    /// One footnote as it will be shown: the number a reader sees, the label
    /// the writing used for it, and what it says.
    public struct Footnote: Equatable, Sendable {
        public var number: Int
        public var label: String
        public var content: String

        public init(number: Int, label: String, content: String) {
            self.number = number
            self.label = label
            self.content = content
        }
    }

    /// A devotional's prose and footnotes, renumbered together.
    public struct Numbered: Equatable, Sendable {
        /// The prose exactly as it was written, markers and all. Kept so that
        /// each way of showing the writing can work from the labels rather than
        /// from another rendering of them.
        public var source: String
        /// The prose with every marker that has a definition rewritten to its
        /// number, as Markdown. A marker with no definition is left exactly as
        /// written — silently dropping it would hide the mistake.
        public var content: String
        /// The definitions, in reading order.
        public var footnotes: [Footnote]
        /// Anything written above the first definition, kept as it was.
        public var preamble: String

        public init(
            source: String,
            content: String,
            footnotes: [Footnote],
            preamble: String = ""
        ) {
            self.source = source
            self.content = content
            self.footnotes = footnotes
            self.preamble = preamble
        }

        public var isEmpty: Bool { footnotes.isEmpty }
    }

    // MARK: - Numbering

    /// Numbers `footnotes` by the order of their first reference in `content`.
    ///
    /// A definition nothing refers to keeps its place after the ones that are
    /// referred to, in the order it was written: it is still the writer's note,
    /// and dropping it would lose work.
    public static func numbered(content: String, footnotes: String?) -> Numbered {
        let parsed = definitions(in: footnotes ?? "")
        guard !parsed.definitions.isEmpty else {
            return Numbered(
                source: content,
                content: content,
                footnotes: [],
                preamble: parsed.preamble
            )
        }

        var byLabel: [String: String] = [:]
        for definition in parsed.definitions where byLabel[definition.label] == nil {
            byLabel[definition.label] = definition.content
        }

        // Referred to, in the order of first reference; then the rest, as
        // written. A repeated marker takes the number of its first appearance.
        var seen = Set<String>()
        let ordered = (markerLabels(in: content) + parsed.definitions.map(\.label))
            .filter { byLabel[$0] != nil && seen.insert($0).inserted }

        var numbers: [String: Int] = [:]
        var numbered: [Footnote] = []
        for label in ordered {
            guard let body = byLabel[label] else { continue }
            let number = numbered.count + 1
            numbers[label] = number
            numbered.append(Footnote(number: number, label: label, content: body))
        }

        return Numbered(
            source: content,
            content: rewritingMarkers(in: content) { label in
                numbers[label].map { "[^\($0)]" }
            },
            footnotes: numbered,
            preamble: parsed.preamble
        )
    }

    // MARK: - Shown to a reader

    /// The prose with each marker set as a superscript number, which is how a
    /// footnote reference reads in a finished document.
    ///
    /// The digits are the Unicode superscript characters rather than styling,
    /// so the number survives being copied out of the reader and needs nothing
    /// of whoever draws the text.
    public static func displayContent(_ numbered: Numbered) -> String {
        guard !numbered.footnotes.isEmpty else { return numbered.source }
        let superscripts = Dictionary(
            uniqueKeysWithValues: numbered.footnotes.map {
                ($0.label, superscript($0.number))
            }
        )
        // From the writing's own labels, not from the numbered Markdown: a
        // marker left as written because nothing defines it could otherwise be
        // mistaken for the number of a footnote that does exist.
        return rewritingMarkers(in: numbered.source) { superscripts[$0] }
    }

    /// The definitions as a numbered list, in reading order.
    ///
    /// A definition's own line breaks are joined: a footnote is one note, and
    /// the lines of an indented continuation are a single item in the list it
    /// is drawn as.
    public static func displayFootnotes(_ numbered: Numbered) -> String {
        guard !numbered.footnotes.isEmpty else { return numbered.preamble }
        let list: String = numbered.footnotes.map { footnote -> String in
            let body = footnote.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "\(footnote.number). \(body)"
        }.joined(separator: "\n")
        guard !numbered.preamble.isEmpty else { return list }
        return "\(numbered.preamble)\n\n\(list)"
    }

    /// `12` as `¹²`.
    public static func superscript(_ number: Int) -> String {
        let digits = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        let value = abs(number)
        guard value > 0 else { return digits[0] }
        var result = ""
        var remaining = value
        while remaining > 0 {
            result = digits[remaining % 10] + result
            remaining /= 10
        }
        return result
    }

    // MARK: - Exported

    /// The definitions as Markdown footnote definitions, in reading order.
    ///
    /// An exported document carries real footnotes — `[^1]` in the prose
    /// against `[^1]:` beneath it, which `Numbered.content` already holds — so
    /// that whatever reads it afterwards numbers them as the reader saw them.
    public static func exportedFootnotes(_ numbered: Numbered) -> String {
        guard !numbered.footnotes.isEmpty else { return numbered.preamble }
        let definitions = LampPersonalMarkdownWriter.footnoteDefinitions(
            numbered.footnotes.map { (id: String($0.number), content: $0.content) }
        )
        guard !numbered.preamble.isEmpty else { return definitions }
        return "\(numbered.preamble)\n\n\(definitions)"
    }

    // MARK: - Reading the source

    private static let markerPattern = try! NSRegularExpression(
        pattern: #"\[\^([^\]\s]+)\]"#
    )
    private static let definitionPattern = try! NSRegularExpression(
        pattern: #"^\s{0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#
    )

    /// Every footnote label referred to in the prose, in the order they appear.
    static func markerLabels(in content: String) -> [String] {
        // The common document has no footnotes at all, and this runs wherever a
        // devotional is shown. A scan for the two characters that open a marker
        // is far cheaper than a regular expression over the whole document.
        guard content.contains("[^") else { return [] }
        return markerPattern.matches(
            in: content,
            range: NSRange(content.startIndex..., in: content)
        ).compactMap { match in
            Range(match.range(at: 1), in: content).map { String(content[$0]) }
        }
    }

    /// Rewrites each marker whose label `replacement` has something for,
    /// leaving the rest exactly as written. The replacement stands for the
    /// whole marker, brackets included.
    ///
    /// Right to left, so that rewriting one marker cannot move the next.
    private static func rewritingMarkers(
        in content: String,
        replacement: (String) -> String?
    ) -> String {
        guard content.contains("[^") else { return content }
        let matches = markerPattern.matches(
            in: content,
            range: NSRange(content.startIndex..., in: content)
        )
        guard !matches.isEmpty else { return content }
        let rewritten = NSMutableString(string: content)
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: content),
                  let text = replacement(String(content[range]))
            else { continue }
            rewritten.replaceCharacters(in: match.range, with: text)
        }
        return rewritten as String
    }

    /// Splits a definitions field into what was written above the first
    /// definition and the definitions themselves.
    ///
    /// A line that does not open a definition continues the one above it, which
    /// is how a footnote running to several lines keeps them.
    static func definitions(
        in footnotes: String
    ) -> (preamble: String, definitions: [(label: String, content: String)]) {
        var preamble: [String] = []
        var definitions: [(label: String, content: String)] = []
        for line in footnotes.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = definitionPattern.firstMatch(in: line, range: range),
               let label = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
               let body = Range(match.range(at: 2), in: line).map({ String(line[$0]) }) {
                definitions.append((label, body))
            } else if definitions.isEmpty {
                preamble.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                definitions[definitions.count - 1].content += "\n" + line
            }
        }
        return (
            preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            definitions.map { ($0.label, $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }
}
