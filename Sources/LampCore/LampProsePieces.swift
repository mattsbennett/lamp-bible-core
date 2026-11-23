import Foundation

public extension LampProse {
    /// A text cut where one block ends and the next begins, so that each
    /// piece read on its own reads exactly as it reads in the whole.
    ///
    /// For a surface showing something as it arrives. A reply from an agent
    /// grows a few characters at a time and is redrawn each time, and
    /// reading all of it again on every token costs more as it gets longer,
    /// precisely when there is most of it. Cut this way, a surface reads
    /// only the piece that changed: a 4.4 KB reply read in 22 pieces reads
    /// 1.8 KB in all, rather than 4.4 KB twenty-two times.
    ///
    /// The cut is refused wherever a blank line may not end what it is in:
    ///
    /// - inside a fence, whose opener and closer count only within three
    ///   spaces of the margin, since four spaces in is indented code;
    /// - before an indented line, which may carry on a list item above;
    /// - before a list item, which may carry on the list above it, and take
    ///   its numbering from it;
    /// - anywhere in a text holding `]:`, `<pre` or `<!--`, because a link's
    ///   target, a preformatted block and a comment all reach past a blank
    ///   line.
    ///
    /// **The pieces are only safe while each is read with the same options
    /// as the whole**, by a parse that does not look across a block. That is
    /// what these rules are written against; a reading that reaches further
    /// than a block would need them checked again.
    ///
    /// Written by the iOS session for the phone's reply panel, held by its
    /// tests through two rounds of review, and lifted here so the Mac reads
    /// a growing reply the same way rather than by a second set of rules.
    static func pieces(of text: String) -> [String] {
        // Read whole where a blank line may not end what it's in: a link's
        // target written as a definition (anywhere, quoted or wrapped), or a
        // `<pre>` block or HTML comment.
        let lowered = text.lowercased()
        if text.contains("]:") || lowered.contains("<pre") || lowered.contains("<!--") {
            return [text]
        }
        var blocks: [String] = []
        var current: [Substring] = []
        var fence: (character: Character, length: Int)?
        var blank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            // A fence opens or closes within three spaces of the margin;
            // further in, it's indented code.
            let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.dropFirst(indent.count)
            if let open = fence {
                let run = trimmed.prefix { $0 == open.character }
                if width <= 3, run.count >= open.length,
                   trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                current.append(line)
                continue
            }
            if trimmed.isEmpty {
                blank = true
                current.append(line)
                continue
            }
            // Not before an indented line, which may carry on a list item,
            // nor a list item, which may go on the list above (its numbering
            // counts on from it).
            if blank, indent.isEmpty, !current.isEmpty, !opensListItem(line) {
                blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .newlines))
                current = []
            }
            blank = false
            if width <= 3, let character = trimmed.first, character == "`" || character == "~" {
                let run = trimmed.prefix { $0 == character }
                if run.count >= 3 { fence = (character, run.count) }
            }
            current.append(line)
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .newlines))
        }
        return blocks.filter { !$0.isEmpty }
    }

    /// Whether a line opens a list item: `-`, `*` or `+`, or a number and `.`
    /// or `)`, then a space or the line's end. Read by hand: it's asked at
    /// every block of a reply on every piece it grows by.
    private static func opensListItem(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        var rest = line.dropFirst()
        if first == "-" || first == "*" || first == "+" {
            return rest.first.map { $0 == " " || $0 == "\t" } ?? true
        }
        guard first.isASCII, first.isNumber else { return false }
        var digits = 1
        while let next = rest.first, next.isASCII, next.isNumber, digits < 9 {
            rest = rest.dropFirst()
            digits += 1
        }
        guard let mark = rest.first, mark == "." || mark == ")" else { return false }
        rest = rest.dropFirst()
        return rest.first.map { $0 == " " || $0 == "\t" } ?? true
    }
}
