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
        String(display(text.map { LampPresentationLetter($0) }).map(\.character))
    }

    /// `displayText` for letters that carry emphasis. Each letter keeps its
    /// own, and the marks and ellipses Lamp adds carry none.
    static func display(_ letters: [LampPresentationLetter]) -> [LampPresentationLetter] {
        // 1. One ellipsis character, however it was typed.
        var value = collapsingTypedEllipses(trimmed(letters))
        guard !value.isEmpty else { return letters }

        // 2. Outer marks the author typed: taken off here and put back in
        // step 6, so every quotation is wrapped the same way.
        value = removingTypedOuterMarks(value)
        guard !value.isEmpty else { return letters }

        // 3 and 4. Ellipses where the quotation begins or ends mid-sentence.
        value = addingLeadingEllipsis(value)
        value = addingTrailingEllipsis(value)

        // 5 and 6. A quotation inside a quotation steps down a level.
        value = demotingInnerMarks(value)
        return [LampPresentationLetter("\u{201C}")] + value + [LampPresentationLetter("\u{201D}")]
    }

    private static func trimmed(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        guard let first = value.firstIndex(where: { !$0.isWhitespaceOrNewline }),
              let last = value.lastIndex(where: { !$0.isWhitespaceOrNewline })
        else { return [] }
        return Array(value[first...last])
    }

    /// Three full stops become one ellipsis, emphasised as the first was.
    private static func collapsingTypedEllipses(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        var result: [LampPresentationLetter] = []
        var index = 0
        while index < value.count {
            if index + 2 < value.count,
               value[index...(index + 2)].allSatisfy({ $0.character == "." }) {
                result.append(LampPresentationLetter("\u{2026}", mark: value[index].mark))
                index += 3
            } else {
                result.append(value[index])
                index += 1
            }
        }
        return result
    }

    /// Removes a pair of outer marks, but only when they are a pair: a
    /// quotation that opens with one speaker and closes with another has marks
    /// that belong to the text.
    private static func removingTypedOuterMarks(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        guard value.count >= 2,
              let first = value.first, doubleMarks.contains(first.character),
              let last = value.last, doubleMarks.contains(last.character)
        else { return value }
        let inner = value[1..<(value.count - 1)]
        guard !inner.contains(where: { doubleMarks.contains($0.character) }) else { return value }
        return trimmed(Array(inner))
    }

    /// An excerpt starting mid-sentence opens with an ellipsis.
    ///
    /// Only a lowercase letter says so. A script without case — Hebrew, Greek —
    /// never triggers this, and a capitalised name at the start is the known
    /// blind spot: an author who wants an ellipsis there types one, and a typed
    /// one is left alone.
    private static func addingLeadingEllipsis(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        guard value.first?.character != "\u{2026}" else { return value }
        guard let letter = value.first(where: { letter in
            !openers.contains(letter.character) && !letter.character.isWhitespace
        }) else { return value }
        guard letter.character.isLowercase else { return value }
        return [LampPresentationLetter("\u{2026}")] + value
    }

    /// An excerpt stopping mid-sentence closes with an ellipsis.
    private static func addingTrailingEllipsis(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        var letters = value
        // Marks and brackets sit outside the sentence's own punctuation.
        var tail: [LampPresentationLetter] = []
        while let last = letters.last, closers.contains(last.character) {
            tail.insert(letters.removeLast(), at: 0)
        }
        guard let last = letters.last else { return value }
        if terminals.contains(last.character) { return value }
        if danglers.contains(last.character) {
            // A comma or dash where the excerpt was cut: the ellipsis replaces it.
            while let trailing = letters.last,
                  danglers.contains(trailing.character) || trailing.character.isWhitespace {
                letters.removeLast()
            }
        }
        return letters + [LampPresentationLetter("\u{2026}")] + tail
    }

    /// Curls the marks inside the quotation.
    ///
    /// Double marks step down to single ones, so the outer pair added in step 6
    /// is the only double pair on the slide. Straight single marks curl where
    /// they stand: an installed translation stores them straight — `Cain's`,
    /// `'Know the LORD,'` — and a verse inserted from Slide Studio would
    /// otherwise carry typewriter punctuation onto a slide set in curled marks.
    private static func demotingInnerMarks(_ value: [LampPresentationLetter]) -> [LampPresentationLetter] {
        var result: [LampPresentationLetter] = []
        var previous: Character?
        for letter in value {
            var demoted = letter
            switch letter.character {
            case "\u{201C}":
                demoted.character = "\u{2018}"
            case "\u{201D}":
                demoted.character = "\u{2019}"
            case "\"", "'":
                // A straight mark says nothing about which end it is, so it is
                // read from what comes before it. After a letter it is an
                // apostrophe, which is the same character as a closing mark.
                demoted.character = opensQuotation(after: previous) ? "\u{2018}" : "\u{2019}"
            default:
                break
            }
            result.append(demoted)
            previous = letter.character
        }
        return result
    }

    /// Whether a straight mark here opens rather than closes.
    private static func opensQuotation(after previous: Character?) -> Bool {
        guard let previous else { return true }
        if previous.isWhitespace { return true }
        // An opening bracket or mark, but not a closing one: `('yes')` opens
        // after the bracket and closes before it.
        return ["(", "[", "{", "\u{2018}", "\u{201C}"].contains(previous)
    }

    /// Whether `block` is drawn as a quotation on `layout`.
    ///
    /// Body, caption and citation blocks are left alone wherever they appear:
    /// there an author types what they mean.
    public static func applies(
        to block: LampPresentationBlock,
        layout: LampPresentationSlideLayout
    ) -> Bool {
        guard block.typography != .verbatim else { return false }
        guard block.kind == .quotation || block.kind == .scripture else { return false }
        switch layout {
        case .quotation, .scripture, .titleAndBody, .twoColumn, .title, .closing: return true
        case .image, .blank: return false
        }
    }
}
