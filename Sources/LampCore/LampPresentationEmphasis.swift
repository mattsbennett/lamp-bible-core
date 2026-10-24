import Foundation

/// Words in a block drawn bold and in colour: a key detail in the accent, or
/// one of the theme's named highlights where a deck sets ideas apart.
///
/// The words are named rather than counted by position, so an agent writes
/// what it means, and the stored text stays exactly as its source has it. The
/// cost is that rewording a block can leave an entry naming words it no longer
/// has; the validator reports that, and nothing is drawn for it.
public struct LampPresentationEmphasis: Codable, Equatable, Sendable {
    /// The words, exactly as the block's text has them: case, punctuation and
    /// line breaks included. They match whole words only, so `law` does not
    /// emphasise part of `lawless`.
    public var text: String
    /// The name of one of the theme's `highlights`. Absent means the accent.
    public var highlight: String?
    /// Which appearance of the words, counting from 1. Absent means every one.
    public var occurrence: Int?

    public init(text: String, highlight: String? = nil, occurrence: Int? = nil) {
        self.text = text
        self.highlight = highlight
        self.occurrence = occurrence
    }

    /// Where the words appear in `characters`, as offsets, left to right and
    /// never overlapping.
    func matches(in characters: [Character]) -> [Range<Int>] {
        let phrase = Array(text)
        guard let first = phrase.first, let last = phrase.last else { return [] }
        var found: [Range<Int>] = []
        var start = 0
        while start + phrase.count <= characters.count {
            let end = start + phrase.count
            if characters[start..<end].elementsEqual(phrase),
               !(start > 0 && Self.isWordCharacter(characters[start - 1]) && Self.isWordCharacter(first)),
               !(end < characters.count && Self.isWordCharacter(characters[end]) && Self.isWordCharacter(last)) {
                found.append(start..<end)
                start = end
            } else {
                start += 1
            }
        }
        return found
    }

    /// The matches drawn: every one, or the one `occurrence` names, which is
    /// none when it names one the text does not have.
    func drawnMatches(in characters: [Character]) -> [Range<Int>] {
        let all = matches(in: characters)
        guard let occurrence else { return all }
        return all.indices.contains(occurrence - 1) ? [all[occurrence - 1]] : []
    }

    var mark: LampPresentationTextRun.Mark {
        highlight.map(LampPresentationTextRun.Mark.highlight) ?? .accent
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

/// A stretch of a block's words as they are drawn, emphasised or not.
public struct LampPresentationTextRun: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        /// The theme's accent colour.
        case accent
        /// The theme highlight of this name, or the accent if it has none.
        case highlight(String)
    }

    public var text: String
    public var mark: Mark?

    public init(text: String, mark: Mark? = nil) {
        self.text = text
        self.mark = mark
    }

    /// `letters` joined into runs, a new run wherever the mark changes.
    static func runs(of letters: [LampPresentationLetter]) -> [Self] {
        var runs: [Self] = []
        for letter in letters {
            if let last = runs.last, last.mark == letter.mark {
                runs[runs.count - 1].text.append(letter.character)
            } else {
                runs.append(.init(text: String(letter.character), mark: letter.mark))
            }
        }
        return runs
    }
}

/// One character as it is drawn, with the emphasis it is drawn in.
struct LampPresentationLetter: Equatable {
    var character: Character
    var mark: LampPresentationTextRun.Mark?

    init(_ character: Character, mark: LampPresentationTextRun.Mark? = nil) {
        self.character = character
        self.mark = mark
    }

    var isWhitespaceOrNewline: Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }
}

extension LampPresentationBlock {
    /// Each character of `text` with the emphasis it is drawn in. A match
    /// that overlaps words an earlier entry already emphasised is not drawn.
    var emphasisedLetters: [LampPresentationLetter] {
        let characters = Array(text)
        var letters = characters.map { LampPresentationLetter($0) }
        var taken = [Bool](repeating: false, count: characters.count)
        for entry in emphasis ?? [] {
            for match in entry.drawnMatches(in: characters) where !taken[match].contains(true) {
                for offset in match {
                    letters[offset].mark = entry.mark
                    taken[offset] = true
                }
            }
        }
        return letters
    }

    /// What this block draws on `layout`, in runs of emphasis: its text, set
    /// as a quotation where it is one.
    public func drawnRuns(on layout: LampPresentationSlideLayout) -> [LampPresentationTextRun] {
        let letters = emphasisedLetters
        guard LampPresentationQuoteTypography.applies(to: self, layout: layout) else {
            return LampPresentationTextRun.runs(of: letters)
        }
        return LampPresentationTextRun.runs(of: LampPresentationQuoteTypography.display(letters))
    }

    /// A body block's list items, one for each line that has words, in runs
    /// of emphasis.
    public var listItemRuns: [[LampPresentationTextRun]] {
        var items: [[LampPresentationLetter]] = [[]]
        for letter in emphasisedLetters {
            if letter.character.isNewline {
                items.append([])
            } else {
                items[items.count - 1].append(letter)
            }
        }
        return items.compactMap { item in
            guard let first = item.firstIndex(where: { !$0.isWhitespaceOrNewline }),
                  let last = item.lastIndex(where: { !$0.isWhitespaceOrNewline })
            else { return nil }
            return LampPresentationTextRun.runs(of: Array(item[first...last]))
        }
    }
}
