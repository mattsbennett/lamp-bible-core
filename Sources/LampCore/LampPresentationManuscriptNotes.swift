import Foundation

/// Derives a deck's speaker notes from the writing it accompanies.
///
/// A talk has two artifacts — the manuscript and the deck — and a speaker wants
/// the whole manuscript in the presenter notes, split slide by slide, still
/// right after the prose is edited. Copying it in by hand goes stale the moment
/// a sentence changes, and nothing notices.
///
/// Each slide names the phrase where its passage begins; its notes run from
/// there to the next slide's phrase. Phrases live in the deck rather than as
/// markers in the manuscript, so the writing stays free of presentation data.
///
/// This sits beside `LampPresentationSlidePlan` for the same reason that type
/// exists: the app, the helper CLI, and the tests must not drift.
public enum LampPresentationManuscriptNotes {
    public struct Resolution: Equatable, Sendable {
        /// Resolved notes, by slide ID. A slide with no anchor is absent.
        public var notesBySlideID: [String: String]
        public var problems: [Problem]
        /// How much of the manuscript the notes account for, in characters.
        public var coveredCharacters: Int
        public var manuscriptCharacters: Int

        public init(
            notesBySlideID: [String: String] = [:],
            problems: [Problem] = [],
            coveredCharacters: Int = 0,
            manuscriptCharacters: Int = 0
        ) {
            self.notesBySlideID = notesBySlideID
            self.problems = problems
            self.coveredCharacters = coveredCharacters
            self.manuscriptCharacters = manuscriptCharacters
        }

        public var isComplete: Bool { problems.isEmpty }
    }

    public enum Problem: Equatable, Sendable {
        case anchorNotFound(slideID: String, anchor: String)
        case anchorAmbiguous(slideID: String, anchor: String, occurrences: Int)
        case textBeforeFirstAnchor(preview: String)
        case noAnchors

        /// Said the way the render report says everything else.
        public var message: String {
            switch self {
            case .anchorNotFound(_, let anchor):
                return "The notes anchor \(quoted(anchor)) is no longer in the manuscript. "
                    + "This slide keeps its last notes; its passage reads on under the "
                    + "slide before it."
            case .anchorAmbiguous(_, let anchor, let occurrences):
                return "The notes anchor \(quoted(anchor)) appears \(occurrences) times "
                    + "from here on. The first was taken; a longer phrase would be certain."
            case .textBeforeFirstAnchor(let preview):
                return "The manuscript opens with text no slide claims: \(quoted(preview))"
            case .noAnchors:
                return "This deck follows the manuscript but no slide names where its "
                    + "notes begin."
            }
        }

        /// The slide this concerns, when it concerns one.
        public var slideID: String? {
            switch self {
            case .anchorNotFound(let slideID, _): return slideID
            case .anchorAmbiguous(let slideID, _, _): return slideID
            case .textBeforeFirstAnchor, .noAnchors: return nil
            }
        }

        private func quoted(_ value: String) -> String {
            let shortened = value.count > 60 ? String(value.prefix(60)) + "…" : value
            return "“\(shortened)”"
        }
    }

    // MARK: - Plain text

    /// The spoken body of a Markdown manuscript, with nothing that is not said
    /// aloud: no headings, rules, footnotes, or emphasis marks.
    public static func plainText(fromMarkdown markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)

        // The body starts after the title, if the manuscript has one.
        if let heading = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines = Array(lines[lines.index(after: heading)...])
        }
        // ...and ends where the footnotes begin.
        if let footnotes = lines.firstIndex(where: { isFootnoteDefinition($0) }) {
            lines = Array(lines[..<footnotes])
        }

        var paragraphs: [String] = []
        var paragraph: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isHeading(trimmed) || isHorizontalRule(trimmed) {
                // A heading or rule ends the paragraph it follows without
                // contributing a word to it.
                if !paragraph.isEmpty {
                    paragraphs.append(paragraph.joined(separator: "\n"))
                    paragraph = []
                }
                continue
            }
            let spoken = inlineText(stripMarkers(from: trimmed))
            if !spoken.isEmpty { paragraph.append(spoken) }
        }
        if !paragraph.isEmpty { paragraphs.append(paragraph.joined(separator: "\n")) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isFootnoteDefinition(_ line: String) -> Bool {
        line.range(of: #"^\s*\[\^[^\]]+\]:"#, options: .regularExpression) != nil
    }

    /// Removes the marks that start a line without being spoken: blockquote
    /// arrows, bullet markers, and ordered-list numbers.
    private static func stripMarkers(from line: String) -> String {
        var value = line
        while value.hasPrefix(">") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let marker = value.range(
            of: #"^([-*+]|\d+[.)])\s+"#,
            options: .regularExpression
        ) {
            value = String(value[marker.upperBound...])
        }
        // A table row reads as its cell text.
        if value.hasPrefix("|") {
            let cells = value.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // The dashes under a table header say nothing.
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) {
                return ""
            }
            value = cells.joined(separator: " ")
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Removes inline Markdown that is written but not spoken.
    private static func inlineText(_ value: String) -> String {
        var result = value
        for (pattern, replacement) in [
            // Images contribute nothing; links contribute their text.
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            // Footnote markers.
            (#"\[\^[^\]]+\]"#, ""),
            // Emphasis, strongest first so `***` does not leave a stray `*`.
            (#"\*\*\*([^*]+)\*\*\*"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"\*([^*]+)\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Resolving

    /// Splits `manuscript` across `deck`'s slides at their anchors.
    public static func resolve(
        deck: LampPresentationDeck,
        manuscript: String
    ) -> Resolution {
        let body = plainText(fromMarkdown: manuscript)
        let haystack = Normalized(body)
        var problems: [Problem] = []

        // Anchors in slide order: the reading order of the talk.
        let anchored = deck.slides.compactMap { slide -> (slide: LampPresentationSlide, anchor: String)? in
            guard let anchor = slide.notesAnchor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !anchor.isEmpty
            else { return nil }
            return (slide, anchor)
        }
        guard !anchored.isEmpty else {
            return Resolution(
                problems: [.noAnchors],
                manuscriptCharacters: body.count
            )
        }

        var starts: [(slideID: String, start: Int)] = []
        var cursor = 0
        for (slide, anchor) in anchored {
            let needle = Normalized(anchor)
            guard let found = haystack.firstRange(of: needle, from: cursor) else {
                problems.append(.anchorNotFound(slideID: slide.id, anchor: anchor))
                continue
            }
            let occurrences = haystack.occurrences(of: needle, from: cursor)
            if occurrences > 1 {
                problems.append(.anchorAmbiguous(
                    slideID: slide.id,
                    anchor: anchor,
                    occurrences: occurrences
                ))
            }
            starts.append((slide.id, found.lowerBound))
            cursor = found.upperBound
        }

        guard let first = starts.first else {
            return Resolution(problems: problems, manuscriptCharacters: body.count)
        }
        let opening = haystack.originalText(from: 0, to: first.start)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !opening.isEmpty {
            problems.append(.textBeforeFirstAnchor(preview: String(opening.prefix(80))))
        }

        var notes: [String: String] = [:]
        var covered = 0
        for (index, entry) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].start : haystack.count
            let passage = haystack.originalText(from: entry.start, to: end)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            notes[entry.slideID] = passage
            covered += passage.count
        }

        return Resolution(
            notesBySlideID: notes,
            problems: problems,
            coveredCharacters: covered,
            manuscriptCharacters: body.count
        )
    }

    /// Applies a resolution to a deck, leaving a slide's existing notes in
    /// place when its anchor could not be found.
    public static func applying(
        _ resolution: Resolution,
        to deck: LampPresentationDeck
    ) -> LampPresentationDeck {
        var deck = deck
        for index in deck.slides.indices {
            let slide = deck.slides[index]
            guard let anchor = slide.notesAnchor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !anchor.isEmpty
            else {
                // A slide with no anchor is deliberately silent.
                deck.slides[index].speakerNotes = ""
                continue
            }
            // Never blank notes because an anchor broke: a stale passage is far
            // more use to a speaker than nothing.
            if let resolved = resolution.notesBySlideID[slide.id] {
                deck.slides[index].speakerNotes = resolved
            }
        }
        return deck
    }

    // MARK: - Quotation check

    /// A slide quotation whose words are no longer in the manuscript.
    public struct StaleQuotation: Equatable, Sendable {
        public var slideID: String
        public var blockID: String
        /// The part that could not be found, which is what to go looking for.
        public var fragment: String

        public var message: String {
            "This quotation no longer appears in the manuscript: "
                + "“\(fragment.count > 60 ? String(fragment.prefix(60)) + "…" : fragment)”"
        }
    }

    /// Finds slide quotations the manuscript no longer supports.
    ///
    /// Reworded prose is the common case, and a deck quietly keeps showing the
    /// old wording. Only `quotation` blocks and `scripture` blocks with no
    /// reference are checked: a scripture block that names its reference is
    /// already compared against the installed translation, which is a stronger
    /// test than comparing it with the prose.
    ///
    /// Text is split on ellipses first, because a quotation that elides a
    /// middle will never appear in the manuscript whole. Fragments shorter than
    /// 15 characters are left alone; they match too easily to mean anything.
    public static func staleQuotations(
        in deck: LampPresentationDeck,
        manuscript: String
    ) -> [StaleQuotation] {
        let haystack = Normalized(plainText(fromMarkdown: manuscript))
        var stale: [StaleQuotation] = []
        for slide in deck.slides {
            for block in slide.blocks {
                guard block.manuscriptCheck != .skip else { continue }
                let checkable = block.kind == .quotation
                    || (block.kind == .scripture && block.scriptureReference == nil)
                guard checkable else { continue }
                for fragment in block.text.components(separatedBy: CharacterSet(charactersIn: "…"))
                    .flatMap({ $0.components(separatedBy: "...") }) {
                    let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 15 else { continue }
                    guard !haystack.contains(Normalized(trimmed)) else { continue }
                    stale.append(StaleQuotation(
                        slideID: slide.id,
                        blockID: block.id,
                        fragment: trimmed
                    ))
                }
            }
        }
        return stale
    }

    // MARK: - Comparable text

    /// Text prepared for comparison, keeping a map back to the original.
    ///
    /// Whitespace runs collapse to one space and quotation marks lose their
    /// curl, so a phrase typed in a deck matches the same words set differently
    /// in the manuscript. Offsets into the normalised form map back, so the
    /// passage handed to a speaker is the prose as written.
    struct Normalized {
        private let characters: [Character]
        /// For each normalised character, where it came from.
        private let origins: [Int]
        private let original: [Character]

        var count: Int { characters.count }

        init(_ value: String) {
            original = Array(value)
            var characters: [Character] = []
            var origins: [Int] = []
            var lastWasSpace = false
            for (index, character) in original.enumerated() {
                if character.isWhitespace {
                    if lastWasSpace || characters.isEmpty { continue }
                    characters.append(" ")
                    origins.append(index)
                    lastWasSpace = true
                    continue
                }
                lastWasSpace = false
                characters.append(Self.folded(character))
                origins.append(index)
            }
            while characters.last == " " {
                characters.removeLast()
                origins.removeLast()
            }
            self.characters = characters
            self.origins = origins
        }

        private static func folded(_ character: Character) -> Character {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}": return "'"
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": return "\""
            case "\u{2013}", "\u{2014}": return "-"
            default: return character
            }
        }

        func firstRange(of needle: Normalized, from start: Int) -> Range<Int>? {
            guard !needle.characters.isEmpty, start <= characters.count else { return nil }
            let limit = characters.count - needle.characters.count
            guard limit >= start else { return nil }
            for offset in start...limit {
                var matched = true
                for inner in needle.characters.indices
                where characters[offset + inner] != needle.characters[inner] {
                    matched = false
                    break
                }
                if matched { return offset..<(offset + needle.characters.count) }
            }
            return nil
        }

        func occurrences(of needle: Normalized, from start: Int) -> Int {
            var count = 0
            var cursor = start
            while let found = firstRange(of: needle, from: cursor) {
                count += 1
                cursor = found.lowerBound + 1
            }
            return count
        }

        func contains(_ needle: Normalized) -> Bool {
            firstRange(of: needle, from: 0) != nil
        }

        /// The original text behind a normalised range.
        func originalText(from start: Int, to end: Int) -> String {
            guard start < end, start < origins.count else { return "" }
            let lower = origins[start]
            let upper = end < origins.count ? origins[end] : original.count
            guard lower < upper else { return "" }
            return String(original[lower..<upper])
        }
    }
}
