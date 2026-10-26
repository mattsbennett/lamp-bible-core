import Foundation

/// Numbers a devotional's footnotes by the order they are first referred to.
///
/// A devotional keeps its markers in the writing. Its definitions are written
/// beneath the prose, as Markdown has them and as the editor and an agent
/// write them, or in a field of their own; both are read. Markers and
/// definitions were shown exactly as typed. So the labels *were* the
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
        /// The prose as it was written, markers and all, without the
        /// definitions written beneath it. Kept so that each way of showing the
        /// writing can work from the labels rather than from another rendering
        /// of them.
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

    /// Numbers the definitions written in `content` and in `footnotes` by the
    /// order of their first reference in the prose.
    ///
    /// A definition nothing refers to keeps its place after the ones that are
    /// referred to, in the order it was written: it is still the writer's note,
    /// and dropping it would lose work. Those in the writing come before those
    /// in the field, and a label defined twice keeps its first definition.
    public static func numbered(content: String, footnotes: String?) -> Numbered {
        let written = definitionsBeneathProse(in: content)
        let field = definitions(in: footnotes ?? "")
        let definitions = written.definitions + field.definitions
        guard !definitions.isEmpty else {
            return Numbered(
                source: content,
                content: content,
                footnotes: [],
                preamble: field.preamble
            )
        }
        let prose = written.prose

        var byLabel: [String: String] = [:]
        for definition in definitions where byLabel[definition.label] == nil {
            byLabel[definition.label] = definition.content
        }

        // Referred to, in the order of first reference; then the rest, as
        // written. A repeated marker takes the number of its first appearance.
        var seen = Set<String>()
        let ordered = (markerLabels(in: prose) + definitions.map(\.label))
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
            source: prose,
            content: rewritingMarkers(in: prose) { label in
                numbers[label].map { "[^\($0)]" }
            },
            footnotes: numbered,
            preamble: field.preamble
        )
    }

    // MARK: - Shown to a reader

    /// The scheme a footnote marker links to, where a reader can be taken to
    /// the note by clicking it.
    ///
    /// Nothing outside Lamp knows it. Whichever surface shows the writing
    /// answers the link itself, and one with nowhere to go asks for markers
    /// that are not linked at all.
    public static let markerURLScheme = "lamp-footnote"

    /// The link for the marker of the footnote shown as `number`.
    public static func markerURL(number: Int) -> String {
        "\(markerURLScheme):\(number)"
    }

    /// Which footnote a marker's link refers to, or nil for any other link.
    ///
    /// Read from the whole link rather than from its path: the marker's link
    /// has no authority and no slash, and what Foundation calls the path of
    /// such a URL has changed before.
    public static func markerNumber(in url: URL) -> Int? {
        guard url.scheme == markerURLScheme else { return nil }
        return Int(url.absoluteString.dropFirst(markerURLScheme.count + 1))
    }

    /// The prose with each marker set as a superscript number, which is how a
    /// footnote reference reads in a finished document.
    ///
    /// The digits are the Unicode superscript characters rather than styling,
    /// so the number survives being copied out of the reader and needs nothing
    /// of whoever draws the text.
    ///
    /// `linkingMarkers` sets each one as a Markdown link to its note, for a
    /// surface that can take a reader there. A surface that cannot leaves them
    /// plain: a link that does nothing is worse than no link.
    public static func displayContent(
        _ numbered: Numbered,
        linkingMarkers: Bool = false
    ) -> String {
        guard !numbered.footnotes.isEmpty else { return numbered.source }
        let markers = Dictionary(
            uniqueKeysWithValues: numbered.footnotes.map { footnote in
                let shown = superscript(footnote.number)
                guard linkingMarkers else { return (footnote.label, shown) }
                return (footnote.label, "[\(shown)](\(markerURL(number: footnote.number)))")
            }
        )
        // From the writing's own labels, not from the numbered Markdown: a
        // marker left as written because nothing defines it could otherwise be
        // mistaken for the number of a footnote that does exist.
        return rewritingMarkers(in: numbered.source) { markers[$0] }
    }

    /// One footnote as a reader meets it, its own line breaks joined: a
    /// footnote is one note, and the lines of an indented continuation are a
    /// single item in the list it is drawn as.
    public static func displayText(of footnote: Footnote) -> String {
        footnote.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The definitions as a numbered list, in reading order.
    public static func displayFootnotes(_ numbered: Numbered) -> String {
        guard !numbered.footnotes.isEmpty else { return numbered.preamble }
        let list: String = numbered.footnotes.map {
            "\($0.number). \(displayText(of: $0))"
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

    /// The label and the first line of the definition `line` opens, if it
    /// opens one.
    private static func definition(openedBy line: String) -> (label: String, content: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = definitionPattern.firstMatch(in: line, range: range),
              let label = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
              let body = Range(match.range(at: 2), in: line).map({ String(line[$0]) })
        else { return nil }
        return (label, body)
    }

    /// Takes the definitions out of the writing, leaving the prose.
    ///
    /// Read by the editor's own rules, those of readFootnotes in the TipTap
    /// bundle, or the two would disagree about which lines are notes. A definition runs on
    /// through lines indented four spaces or a tab, and through blank lines
    /// only when such a line follows them. Any other line is prose again, so a
    /// paragraph written after a note stays in the writing.
    static func definitionsBeneathProse(
        in content: String
    ) -> (prose: String, definitions: [(label: String, content: String)]) {
        guard content.contains("[^") else { return (content, []) }
        let lines = content.components(separatedBy: "\n")
        var prose: [String] = []
        var definitions: [(label: String, content: String)] = []
        var isOpen = false
        func runsOn(_ line: String) -> Bool {
            isOpen && (line.hasPrefix("    ") || line.hasPrefix("\t"))
        }
        func isBlank(_ line: String) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let definition = definition(openedBy: line) {
                definitions.append(definition)
                isOpen = true
            } else if runsOn(line) {
                definitions[definitions.count - 1].content += "\n" + line
            } else if isBlank(line) {
                var end = index
                while end < lines.count, isBlank(lines[end]), !runsOn(lines[end]) {
                    end += 1
                }
                let blanks = lines[index..<end]
                if end < lines.count, runsOn(lines[end]) {
                    definitions[definitions.count - 1].content += "\n" + blanks.joined(separator: "\n")
                } else {
                    prose.append(contentsOf: blanks)
                }
                index = end
                continue
            } else {
                isOpen = false
                prose.append(line)
            }
            index += 1
        }
        guard !definitions.isEmpty else { return (content, []) }
        return (
            prose.joined(separator: "\n"),
            definitions.map { ($0.label, $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
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
            if let definition = definition(openedBy: line) {
                definitions.append(definition)
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
