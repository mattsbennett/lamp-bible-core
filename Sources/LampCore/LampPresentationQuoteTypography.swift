import Foundation

/// Sets a quotation the way a quotation is set: in marks, with ellipses where
/// it starts or ends mid-sentence.
///
/// These are presentation, not content. They follow from the block's role, so
/// an author types the words and Lamp draws them — which also keeps scripture
/// stored exactly as the translation has it, and lets Slide Studio insert a
/// verse with no agent involved.
///
/// The stored text never changes. Checks that compare a deck with its sources
/// keep working, because they read what is stored.
public enum LampPresentationQuoteTypography {
    /// Marks that may wrap a quotation.
    private static let doubleMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
    /// Characters that may sit outside the first or last letter.
    private static let openers: Set<Character> = [
        "(", "[", "{", "\u{2018}", "\u{201C}", "'", "\"",
    ]
    private static let closers: Set<Character> = [
        ")", "]", "}", "\u{2019}", "\u{201D}", "'", "\"",
    ]
    /// Punctuation that ends a sentence, so the quotation is complete.
    private static let terminals: Set<Character> = [".", "!", "?", "\u{2026}"]
    /// Punctuation that shows the sentence was cut short.
    private static let danglers: Set<Character> = [",", ";", ":", "-", "\u{2013}", "\u{2014}"]

    /// How `text` should be drawn. Returns it unchanged when it is empty.
    public static func displayText(_ text: String) -> String {
        // 1. One ellipsis character, however it was typed.
        var value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "...", with: "\u{2026}")
        guard !value.isEmpty else { return text }

        // 2. Outer marks the author typed: taken off here and put back in
        // step 6, so every quotation is wrapped the same way.
        value = removingTypedOuterMarks(value)
        guard !value.isEmpty else { return text }

        // 3 and 4. Ellipses where the quotation begins or ends mid-sentence.
        value = addingLeadingEllipsis(value)
        value = addingTrailingEllipsis(value)

        // 5 and 6. A quotation inside a quotation steps down a level.
        value = demotingInnerMarks(value)
        return "\u{201C}" + value + "\u{201D}"
    }

    /// Removes a pair of outer marks, but only when they are a pair: a
    /// quotation that opens with one speaker and closes with another has marks
    /// that belong to the text.
    private static func removingTypedOuterMarks(_ value: String) -> String {
        var characters = Array(value)
        guard characters.count >= 2,
              let first = characters.first, doubleMarks.contains(first),
              let last = characters.last, doubleMarks.contains(last)
        else { return value }
        let inner = characters[1..<(characters.count - 1)]
        guard !inner.contains(where: { doubleMarks.contains($0) }) else { return value }
        characters.removeFirst()
        characters.removeLast()
        return String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An excerpt starting mid-sentence opens with an ellipsis.
    ///
    /// Only a lowercase letter says so. A script without case — Hebrew, Greek —
    /// never triggers this, and a capitalised name at the start is the known
    /// blind spot: an author who wants an ellipsis there types one, and a typed
    /// one is left alone.
    private static func addingLeadingEllipsis(_ value: String) -> String {
        let characters = Array(value)
        guard characters.first != "\u{2026}" else { return value }
        guard let letter = characters.first(where: { character in
            !openers.contains(character) && !character.isWhitespace
        }) else { return value }
        guard letter.isLowercase else { return value }
        return "\u{2026}" + value
    }

    /// An excerpt stopping mid-sentence closes with an ellipsis.
    private static func addingTrailingEllipsis(_ value: String) -> String {
        var characters = Array(value)
        // Marks and brackets sit outside the sentence's own punctuation.
        var tail: [Character] = []
        while let last = characters.last, closers.contains(last) {
            tail.insert(characters.removeLast(), at: 0)
        }
        guard let last = characters.last else { return value }
        if terminals.contains(last) { return value }
        if danglers.contains(last) {
            // A comma or dash where the excerpt was cut: the ellipsis replaces it.
            while let trailing = characters.last,
                  danglers.contains(trailing) || trailing.isWhitespace {
                characters.removeLast()
            }
        }
        return String(characters) + "\u{2026}" + String(tail)
    }

    /// Double marks inside the quotation become single ones, so the outer pair
    /// added in step 6 is the only double pair on the slide.
    private static func demotingInnerMarks(_ value: String) -> String {
        var result: [Character] = []
        var previous: Character?
        for character in value {
            switch character {
            case "\u{201C}":
                result.append("\u{2018}")
            case "\u{201D}":
                result.append("\u{2019}")
            case "\"":
                // A straight mark says nothing about which end it is, so it is
                // read from what comes before it.
                let opens = previous == nil
                    || previous?.isWhitespace == true
                    || (previous.map { openers.contains($0) } ?? false)
                result.append(opens ? "\u{2018}" : "\u{2019}")
            default:
                result.append(character)
            }
            previous = character
        }
        return String(result)
    }

    /// Whether `block` is drawn as a quotation on `layout`.
    ///
    /// Body, caption and citation blocks are left alone wherever they appear,
    /// and so are two-column bodies: there an author types what they mean.
    public static func applies(
        to block: LampPresentationBlock,
        layout: LampPresentationSlideLayout
    ) -> Bool {
        guard block.typography != .verbatim else { return false }
        guard block.kind == .quotation || block.kind == .scripture else { return false }
        switch layout {
        case .quotation, .scripture, .titleAndBody: return true
        case .title, .closing, .twoColumn, .image, .blank: return false
        }
    }
}
