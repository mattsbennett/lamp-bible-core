import Foundation

/// A form of a layout, carried beside it rather than as a layout of its own.
///
/// A deck names its layout from a closed list, and a layout this app did not
/// know would stop the whole deck opening in an older Lamp. A variant an
/// older Lamp does not know is only left out, so a slide in one degrades to
/// the plain layout beneath it: a statement to a title slide, a comparison
/// to columns without their differences marked.
public enum LampPresentationSlideVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// On a `title` or `closing` slide: its heading set as large as the slide
    /// allows, one phrase to land a point or open a section.
    case statement
    /// On a `title` or `closing` slide: a Hebrew or Greek word set large,
    /// its transliteration (the `subtitle`) and its gloss (a `body` block)
    /// beneath, and any passages under those.
    case word
    /// On a `two-column` slide: the words in which the columns differ are
    /// marked, for translations of one passage, or two accounts of one event.
    case comparison

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Plain"
        case .statement: "Statement"
        case .word: "Word"
        case .comparison: "Comparison"
        }
    }

    /// The layouts this variant belongs to.
    public var layouts: Set<LampPresentationSlideLayout> {
        switch self {
        case .none: Set(LampPresentationSlideLayout.allCases)
        case .statement, .word: [.title, .closing]
        case .comparison: [.twoColumn]
        }
    }

    /// A variant this app does not know draws the plain layout, so a deck
    /// written by a newer app still opens.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

extension LampPresentationSlide {
    /// The variant drawn: the slide's own where its layout takes it, else
    /// the plain layout.
    public var drawnVariant: LampPresentationSlideVariant {
        guard let variant, variant.layouts.contains(layout) else { return .none }
        return variant
    }

    /// This slide with what a comparison marks added to its emphasis: in each
    /// column, the words that are not shared with the others. Every other
    /// slide is returned as it is.
    ///
    /// Added as emphasis entries after the author's own, so they are drawn as
    /// emphasis is (bold, in the accent), an author's entry still wins where
    /// the two overlap, and a slide that lights its emphasis last lights the
    /// differences last.
    public func markingComparison() -> LampPresentationSlide {
        guard drawnVariant == .comparison else { return self }
        let columns = plan.columnGroups
        guard columns.count > 1 else { return self }
        // Each column's passage text, block by block, so marks can be placed
        // back on the blocks they came from.
        let columnBlocks = columns.map { column in
            column.groups.flatMap(\.quotations).filter { $0.kind != .subtitle }
        }
        let columnWords = columnBlocks.map { blocks in
            blocks.flatMap { block in
                LampPresentationComparison.words(in: block.text).map { (block: block.id, word: $0) }
            }
        }
        let keys = columnWords.map { $0.map(\.word.key) }
        // Each column aligned with the first, once: both sides of a pair read
        // their shared words from the one alignment, or where two orderings
        // tie ("Christ Jesus", "Jesus Christ") each side could keep a
        // different word and the shared text would not match.
        let alignments = keys.indices.dropFirst().map { LampPresentationComparison.common(keys[0], keys[$0]) }
        var marked = Set<String>()
        for (index, words) in columnWords.enumerated() {
            // Two columns are set against each other. With three or four the
            // first is the reference, left plain, and each other is marked
            // where it departs from it: set against every other at once, the
            // first was marked wherever any of them reordered a phrase.
            let kept: Set<Int>
            if index > 0 {
                kept = Set(alignments[index - 1].map(\.1))
            } else if columnWords.count == 2 {
                kept = Set(alignments[0].map(\.0))
            } else {
                continue
            }
            for (position, entry) in words.enumerated() where !kept.contains(position) {
                marked.insert("\(entry.block)#\(entry.word.start)")
            }
        }
        guard !marked.isEmpty else { return self }
        var slide = self
        for blockIndex in slide.blocks.indices {
            let block = slide.blocks[blockIndex]
            let words = LampPresentationComparison.words(in: block.text)
            let entries = LampPresentationComparison.entries(
                marking: words.filter { marked.contains("\(block.id)#\($0.start)") },
                of: words,
                in: block
            )
            if !entries.isEmpty {
                slide.blocks[blockIndex].emphasis = (block.emphasis ?? []) + entries
            }
        }
        return slide
    }
}

/// How a comparison finds the words two passages do not share.
enum LampPresentationComparison {
    struct Word: Equatable {
        /// Offsets into the block's characters.
        var start: Int
        var end: Int
        /// What two words are compared by: letters and numbers alone, in
        /// lower case, so "God," and "god" are one word.
        var key: String
    }

    /// The words of `text`: runs of letters and numbers, with an apostrophe
    /// inside a word kept in it ("God's"). Everything else separates words,
    /// so "God—who" and "God — who" are the same two words.
    static func words(in text: String) -> [Word] {
        let characters = Array(text)
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        func joinsWord(at index: Int) -> Bool {
            let c = characters[index]
            guard c == "'" || c == "\u{2019}", index > 0, index + 1 < characters.count else { return false }
            return isWordCharacter(characters[index - 1]) && isWordCharacter(characters[index + 1])
        }
        var words: [Word] = []
        var index = 0
        while index < characters.count {
            guard isWordCharacter(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, isWordCharacter(characters[index]) || joinsWord(at: index) {
                index += 1
            }
            let key = String(characters[start..<index].filter(isWordCharacter)).lowercased()
            words.append(Word(start: start, end: index, key: key))
        }
        return words
    }

    /// The pairs of positions, in `a` and in `b`, that one longest common
    /// subsequence of the two keeps: the words they share, in order.
    static func common(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var kept: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                kept.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return kept
    }

    /// Emphasis entries drawing `marked`, one for each word, each naming the
    /// occurrence it is so a word that appears twice is marked only where it
    /// differs.
    ///
    /// A word apiece rather than a phrase for each run of them: the matcher
    /// cannot place a phrase that repeats inside itself ("very very"), and
    /// an author's own emphasis overlapping a phrase would drop the whole of
    /// it rather than the one word they share.
    static func entries(
        marking marked: [Word],
        of words: [Word],
        in block: LampPresentationBlock
    ) -> [LampPresentationEmphasis] {
        let characters = Array(block.text)
        return marked.compactMap { word in
            let text = String(characters[word.start..<word.end])
            let probe = LampPresentationEmphasis(text: text)
            guard let occurrence = probe.matches(in: characters).firstIndex(where: { $0.lowerBound == word.start })
            else { return nil }
            return LampPresentationEmphasis(text: text, occurrence: occurrence + 1)
        }
    }
}
