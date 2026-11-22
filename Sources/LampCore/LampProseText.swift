import Foundation

/// A run of a writing's prose, as it reads.
///
/// The text carries Foundation's own inline attributes — the same
/// `inlinePresentationIntent`, `link` and `imageURL` that
/// `AttributedString(markdown:)` sets — put there by core's parse rather
/// than by a second one in each app.
///
/// Markdown does not cross this seam, and that is the point. Two earlier
/// designs sent the writer's inline content across as a string: first cut
/// from the source by its parsed range, then written back out from the
/// tree. Review found nineteen ways the words changed — a code span losing
/// its backticks, `&copy;` decoded, `**a**__b__` run together into
/// `**a****b**`, a title's quotes destroying its link — and every one of
/// them was about spelling delimiters for a parser to read again. There are
/// no delimiters here, and nothing reads it again.
///
/// It also ends a smaller thing: Foundation's parser was a fourth Markdown
/// dialect in the system, running inside each app where core's
/// editor-matching work could not reach it.
public struct LampProseText: Equatable, Sendable {
    public let text: AttributedString

    public init(_ text: AttributedString = AttributedString()) {
        self.text = text
    }

    /// The words alone.
    public var plain: String { String(text.characters) }

    /// Whether there is nothing here to draw.
    ///
    /// Only genuinely nothing: a paragraph whose whole content is the code
    /// span `` ` ` `` is a space the writer set in code, and trimming it
    /// away deleted the paragraph.
    public var isEmpty: Bool { text.characters.isEmpty }

    /// The text cut at the breaks the reader should draw.
    ///
    /// A reader that draws a paragraph whole ignores this and draws `text`,
    /// whose newlines are already the right ones. A reader that draws line
    /// by line — as the phone's note reader does, to give each line its own
    /// paragraph style — takes these. The attributes carry across the cut,
    /// so a span broken by a line is still bold on both of them, which a
    /// reader splitting the Markdown itself could not manage.
    public var lines: [LampProseText] {
        var out: [LampProseText] = []
        var current = AttributedString()
        for run in text.runs {
            var piece = AttributedString(text[run.range])
            while let newline = piece.characters.firstIndex(of: "\n") {
                let head = AttributedString(piece[piece.startIndex..<newline])
                current.append(head)
                out.append(LampProseText(current))
                current = AttributedString()
                piece = AttributedString(piece[piece.index(afterCharacter: newline)...])
            }
            current.append(piece)
        }
        out.append(LampProseText(current))
        // A blank line between two breaks is a line the writer left, and a
        // reader drawing `text` draws it. Dropping it here made the two ways
        // of reading the same text disagree.
        if out.count > 1, out.last?.text.characters.isEmpty == true { out.removeLast() }
        return out
    }
}

private extension AttributedString {
    func index(afterCharacter index: AttributedString.Index) -> AttributedString.Index {
        characters.index(after: index)
    }
}

/// A footnote's marker in the prose, `[^1]`.
///
/// The editor draws it as a superscript number rather than as the
/// characters the writer typed, in its resolveFootnotes pass, and no
/// Markdown parser here reads it. Left as text, both apps drew the
/// brackets. Marking it in core means both draw it the same way, and
/// neither has to find it again with a pattern of its own.
///
/// The value is the label between the brackets, which is what a reader
/// numbers by and what the matching `LampProseBlock.footnote` carries.
public enum LampFootnoteReferenceAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "lampFootnoteReference"
}

public extension AttributeScopes {
    struct LampProseAttributes: AttributeScope {
        public let lampFootnoteReference: LampFootnoteReferenceAttribute
    }

    var lampProse: LampProseAttributes.Type { LampProseAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.LampProseAttributes, T>
    ) -> T {
        self[T.self]
    }
}

public extension LampProseText {
    /// The footnote markers in this text, each with its label.
    var footnoteReferences: [(range: Range<AttributedString.Index>, label: String)] {
        text.runs.compactMap { run in
            guard let label = run.lampFootnoteReference else { return nil }
            return (run.range, label)
        }
    }
}
