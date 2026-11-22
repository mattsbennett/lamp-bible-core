import Foundation

/// Review markers placed so that the Markdown around them still reads as
/// what it is.
///
/// `LampWritingReview.markedMarkdown(in:)` puts a marker at each edge of
/// a marked passage, on the grounds that a private-use character is a
/// letter to every Markdown rule. A letter is the problem. Inside a
/// link's address it is part of the address, so the link goes somewhere
/// else; between the stars of an emphasis run it stops the run being
/// one, so the stars are drawn; before a heading's `#` it stops the line
/// being a heading.
///
/// A renderer shown that Markdown draws the damage. The Mac's editor
/// page instead compares what it parsed against the document it already
/// holds and refuses the marks when they differ — so nothing is drawn
/// wrongly there, and nothing is marked either. Both are failures of the
/// one thing marks are for.
///
/// This moves each marker to the nearest place that leaves the Markdown
/// reading as it did. A marker that cannot stay where it was — inside an
/// address, which is not drawn at all — becomes a point just before,
/// which is something the writer can still reach.
///
/// Ported from the iOS app's `WritingDocumentText`, where codex took it
/// through fifteen rounds; every rule here was a round. Core because
/// both apps need it: only the shapes they draw differ.
public enum LampWritingReviewMarkdown {
    /// Each passage's place is written after its start or point marker,
    /// in private-use digits, so a passage survives Markdown dropping a
    /// marker it read as part of something else and every passage after
    /// it still names its own change.
    public static let placeEnd: Character = "\u{E01A}"
    static let placeFirst: UInt32 = 0xE010
    static let placeLast: UInt32 = 0xE019

    public static func placeDigit(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (placeFirst...placeLast).contains(scalar.value) else { return nil }
        return Int(scalar.value - placeFirst)
    }

    public static func isMarker(_ character: Character) -> Bool {
        character == LampWritingReview.markStart || character == LampWritingReview.markEnd
            || character == LampWritingReview.markPoint
            || placeDigit(character) != nil || character == placeEnd
    }

    public static func unmarked(_ text: String) -> String { text.filter { !isMarker($0) } }
    public static func markers(in text: String) -> String { text.filter(isMarker) }

    /// `marked` with each passage's place written after its marker.
    public static func numbered(_ marked: String) -> String {
        var out = ""
        var next = 0
        for character in marked {
            out.append(character)
            guard character == LampWritingReview.markStart
                || character == LampWritingReview.markPoint else { continue }
            for digit in String(next) {
                out.unicodeScalars.append(
                    Unicode.Scalar(placeFirst + UInt32(digit.wholeNumberValue ?? 0))!
                )
            }
            out.append(placeEnd)
            next += 1
        }
        return out
    }

    /// Where a stretch of marked text leaves the count of passages, and a
    /// passage still open at its end, from where it took them up.
    public static func passing(_ text: String, first: Int, open: Int?) -> (next: Int, open: Int?) {
        var next = first
        var open = open
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch character {
            case LampWritingReview.markStart, LampWritingReview.markPoint:
                let place = Self.place(after: index, in: characters)?.place ?? next
                if character == LampWritingReview.markStart { open = place }
                next = place + 1
            case LampWritingReview.markEnd:
                open = nil
            default:
                break
            }
        }
        return (next, open)
    }

    static func place(after index: Int, in characters: [Character]) -> (place: Int, end: Int)? {
        var at = index + 1
        var value = 0
        var digits = 0
        while at < characters.count, let digit = placeDigit(characters[at]) {
            value = value * 10 + digit
            digits += 1
            at += 1
        }
        guard digits > 0, at < characters.count, characters[at] == placeEnd else { return nil }
        return (value, at)
    }

    /// Markers taken out of text that is not drawn as written, sorted by
    /// where they go: passages begun and ended there as points before it;
    /// an end of one begun before it, at its end; a start of one running
    /// on past it, after it.
    public static func sortingOut(_ markers: String) -> (before: String, ending: String, after: String) {
        var before = ""
        var ending = ""
        var after = ""
        var group: String?
        for character in asPoints(markers) {
            if character == LampWritingReview.markEnd {
                ending.append(character)
            } else if character == LampWritingReview.markStart {
                group = String(character)
            } else if character == LampWritingReview.markPoint {
                group = nil
                before.append(character)
            } else if group != nil {
                group?.append(character)
                if character == placeEnd, let started = group {
                    after += started
                    group = nil
                }
            } else {
                before.append(character)
            }
        }
        if let group { after += group }
        return (before, ending, after)
    }

    /// Markers from text that is not drawn, each passage begun and ended
    /// among them made a point so it has something to reach; a start or
    /// end belonging to a passage outside them kept as it is.
    public static func asPoints(_ markers: String) -> String {
        let characters = Array(markers)
        var open: [Int] = []
        var ended: Set<Int> = []
        var closing: Set<Int> = []
        for (index, character) in characters.enumerated() {
            if character == LampWritingReview.markStart {
                open.append(index)
            } else if character == LampWritingReview.markEnd, let start = open.popLast() {
                ended.insert(start)
                closing.insert(index)
            }
        }
        var out = ""
        for (index, character) in characters.enumerated() {
            if closing.contains(index) { continue }
            out.append(ended.contains(index) ? LampWritingReview.markPoint : character)
        }
        return out
    }

    /// Markers standing between a backslash and the character it escapes
    /// moved after that character, so the escape still reads.
    public static func keepingEscapes(_ line: String) -> String {
        line.replacing(#/\\([\x{E000}-\x{E01A}]+)([!-\/:-@\[-`{-~])/#) { match in
            "\\\(match.output.2)\(match.output.1)"
        }
    }

    /// The line's inline syntax kept as it reads without markers: escapes
    /// whole, and markers stepped outside an emphasis's `*` or `_`, whose
    /// meaning hangs on what stands beside them. Repeated until nothing
    /// moves, so a run of delimiters a marker split comes back together.
    public static func keepingInlineSyntax(_ line: String) -> String {
        guard line.contains(where: isMarker) else { return line }
        var kept = keepingEscapes(line)
        for _ in 0..<8 {
            let before = kept
            kept = kept.replacing(#/([*_`])([\x{E000}-\x{E01A}]+)(\1)/#) {
                "\($0.output.1)\($0.output.3)\($0.output.2)"
            }
            kept = kept.replacing(#/\]([\x{E000}-\x{E01A}]+)\(/#) { "\($0.output.1)](" }
            kept = kept.replacing(#/!([\x{E000}-\x{E01A}]+)\[/#) { "\($0.output.1)![" }
            kept = kept.replacing(#/([^\\_*\x{E000}-\x{E01A}]|^)([\x{E000}-\x{E01A}]+)([_*]+)(?=\S)/#) {
                "\($0.output.1)\($0.output.3)\($0.output.2)"
            }
            kept = kept.replacing(#/([^\s\\_*\x{E000}-\x{E01A}])([_*]+)([\x{E000}-\x{E01A}]+)/#) {
                "\($0.output.1)\($0.output.3)\($0.output.2)"
            }
            // An HTML entity is one token to a renderer: a marker
            // anywhere inside it leaves `&lt;` showing as itself. Every
            // marker in it goes after the semicolon, wherever in it it
            // fell — a change from `&lt;` to `&gt;` marks the name, not
            // the `&` or the `;`, so rules that only looked at those two
            // ends never fired.
            // No bound on the name: `&LeftRightArrow;` is longer than
            // any guess, and the markers in it count too.
            kept = kept.replacing(#/&([A-Za-z0-9#xX\x{E000}-\x{E01A}]+);/#) { match in
                let inside = String(match.output.1)
                let name = unmarked(inside)
                guard inside != name,
                      name.wholeMatch(
                          of: #/[A-Za-z][A-Za-z0-9]*|#[0-9]{1,7}|#[Xx][0-9A-Fa-f]{1,6}/#
                      ) != nil
                else { return String(match.output.0) }
                return "&\(name);\(markers(in: inside))"
            }
            if kept == before { break }
        }
        return kept
    }

    /// Markers inside a link's address moved out before its words, each
    /// passage as a point: in the address they are taken into where the
    /// link goes, and the change they mark has nothing to reach.
    public static func movingMarksOutOfLinks(_ line: String) -> String {
        guard line.contains(where: isMarker) else { return line }
        let escapesKept = keepingInlineSyntax(line)
        return escapesKept.replacing(
            #/(\\?)(!?)\[([^\]]*)\]\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)/#
        ) { match in
            let address = String(match.output.4)
            guard match.output.1.isEmpty, address.contains(where: isMarker) else {
                return String(match.output.0)
            }
            let moved = sortingOut(markers(in: address))
            return "\(match.output.1)\(moved.before)\(match.output.2)"
                + "[\(match.output.3)\(moved.ending)](\(unmarked(address)))\(moved.after)"
        }
        .replacing(#/<([\x{E000}-\x{E01A}]*[A-Za-z][A-Za-z0-9+.\-\x{E000}-\x{E01A}]*:[^\s<>]*)>/#) { match in
            let link = String(match.output.1)
            guard link.contains(where: isMarker) else { return String(match.output.0) }
            let moved = sortingOut(markers(in: link))
            return moved.before + moved.ending + "<\(unmarked(link))>" + moved.after
        }
        // A pipe is not part of a bare URL. The markers go on before
        // any table is split, so a run that crossed one swallowed the
        // next cell and carried its markers out in front of this cell's
        // address — the changed word losing its highlight. A pipe ends
        // the cell in a table row, and a literal one in an address is
        // rare enough to be written as a link. Found by the iOS session.
        .replacing(
            #/(^|[^\w(<\x{E000}-\x{E01A}])([A-Za-z][A-Za-z0-9+.\-\x{E000}-\x{E01A}]*:\/\/[^\s<>()|]+)/#
        ) { match in
            let link = String(match.output.2)
            guard link.contains(where: isMarker) else { return String(match.output.0) }
            let moved = sortingOut(markers(in: link))
            return match.output.1 + moved.before + moved.ending + unmarked(link) + moved.after
        }
    }

    /// A line with any marker standing before its block's own syntax — a
    /// heading's `#`, a list's marker, a quote's `>`, a rule's `---` —
    /// moved after it, so the line still reads as what it is.
    public static func clearingBlockSyntax(_ line: String) -> String {
        let bare = unmarked(line)

        guard let match = bare.prefixMatch(
            of: #/\s*(?:#{1,6}\s+|[-*+]\s+|\d{1,9}[.)]\s+|>\s?)/#
        ) else { return line }
        let syntax = bare[match.range].count
        var head = ""
        var moved = ""
        var rest = Substring(line)
        while head.count < syntax, let character = rest.first {
            rest = rest.dropFirst()
            if isMarker(character) { moved.append(character) } else { head.append(character) }
        }
        return head + asPoints(moved) + rest
    }

    /// Whether a line is a rule — three or more of one mark, and
    /// nothing else. A rule may hold nothing but its own character and
    /// spaces, so it can carry no marker at all: a marker left anywhere
    /// on the line makes it a paragraph of hyphens.
    static func isRule(_ line: String) -> Bool {
        line.wholeMatch(of: #/\s*((?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})/#) != nil
    }

    /// A fence's opening: its character and how many of them. A fence
    /// is closed only by a run of the same character, at least as long,
    /// with nothing but spaces after it — so a `~~~` written inside a
    /// ```` ```` ```` block is content, not a close, and the prose
    /// after the block is not left thinking it is still inside one.
    struct Fence: Equatable {
        let character: Character
        let length: Int
        /// How far the opener was indented, which its closer may differ
        /// from but which tells an indented-code line from a fence.
        let indent: Int
    }

    static func fenceOpening(_ line: String) -> Fence? {
        guard let match = line.wholeMatch(of: #/(\s{0,3})(`{3,}|~{3,})([^`]*)/#) else { return nil }
        let run = String(match.output.2)
        // A backtick fence's info string may hold no backtick.
        if run.first == "`", match.output.3.contains("`") { return nil }
        return Fence(
            character: run.first ?? "`", length: run.count, indent: match.output.1.count
        )
    }

    static func closes(_ fence: Fence, _ line: String) -> Bool {
        guard let match = line.wholeMatch(of: #/\s{0,3}(`{3,}|~{3,})\s*/#) else { return false }
        let run = String(match.output.1)
        return run.first == fence.character && run.count >= fence.length
    }

    /// `line` with its code spans taken out, and what to put back.
    ///
    /// Taken out rather than the line cut into pieces: a link may hold
    /// a code span in its label, and a line cut at the span is a line
    /// where no rule can see that link whole — so a marker in its
    /// address stays there and the whole copy is refused. What stands
    /// in their place is a character no rule looks at and no writing
    /// holds, so the line reads to every rule as it did, less whatever
    /// the code said.
    static let codeStandIn: Character = "\u{E030}"

    static func maskingCodeSpans(_ line: String) -> (masked: String, spans: [String]) {
        guard line.contains("`") else { return (line, []) }
        var masked = ""
        var spans: [String] = []
        var rest = Substring(line)
        while let open = rest.firstMatch(of: #/`+/#) {
            let ticks = String(open.output)
            let before = rest[rest.startIndex..<open.range.lowerBound]
            let after = rest[open.range.upperBound...]
            // A backtick a backslash escapes opens nothing. Left to
            // pair with a real span later in the line, it swallowed
            // everything between — a link whose address holds markers
            // among it, which then stayed in the address. An even run
            // of backslashes is the backslashes themselves escaped.
            if before.last == "\\",
               before.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0 {
                masked += before + ticks
                rest = after
                continue
            }
            // Closed by a run of exactly the same length, as Markdown
            // has it: a longer or shorter run is other code's.
            guard let close = after.firstRange(of: ticks),
                  after[close.upperBound...].first != "`"
            else {
                masked += before + ticks
                rest = after
                continue
            }
            masked += before
            masked.append(codeStandIn)
            spans.append(ticks + after[after.startIndex..<close.lowerBound] + ticks)
            rest = after[close.upperBound...]
        }
        return (masked + rest, spans)
    }

    static func unmasking(_ line: String, _ spans: [String]) -> String {
        guard !spans.isEmpty else { return line }
        var out = ""
        var next = 0
        for character in line {
            if character == codeStandIn, next < spans.count {
                out += spans[next]
                next += 1
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A range a surface gave back, reaching to the start of its line
    /// where only that line's own block syntax stands before it.
    ///
    /// The inverse of `clearingBlockSyntax`'s move. A change to block
    /// syntax alone — `Title` becoming `# Title`, a line becoming a
    /// list item or a quotation — is drawn as a point after the syntax,
    /// since a marker before it would stop the line being what it now
    /// is. The mark itself is still on the `#`. So a surface stepping
    /// to that point and asking to clear or put back sends a range
    /// beginning after the syntax, which touches no mark at all, and
    /// nothing happens — twice over, since the writer tries again.
    ///
    /// Found by the iOS session; both apps' selections meet it.
    public static func takingInSyntax(_ range: NSRange, of text: String) -> NSRange {
        let source = text as NSString
        guard range.location <= source.length else { return range }
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        guard range.location > line.location else { return range }
        let head = source.substring(
            with: NSRange(location: line.location, length: range.location - line.location)
        )
        guard !head.isEmpty, head.wholeMatch(
            of: #/\s*(?:#{1,6}\s+|[-*+]\s+|\d{1,9}[.)]\s+|>\s?)+\s*/#
        ) != nil else { return range }
        return NSRange(
            location: line.location, length: range.length + (range.location - line.location)
        )
    }

    /// Marked Markdown a renderer can be given: every marker moved to a
    /// place that leaves the Markdown reading as it did without them.
    ///
    /// `numbering` writes each passage's place after its marker, which a
    /// surface wants if it draws whatever it parses: a marker the parser
    /// drops anyway would otherwise leave every passage after it naming
    /// the wrong change. A surface that compares what it parsed against
    /// the document it holds, and refuses the marks when they differ,
    /// needs none of that — it is never drawing from a copy a marker was
    /// dropped from — and the extra characters would only be more for it
    /// to strip.
    public static func drawable(_ marked: String, numbering: Bool = true) -> String {
        // The block pass first: moving a marker past a heading's `#` can
        // leave it between a word and the underscore that opened an
        // emphasis, which the inline pass then puts right. The other way
        // round the block pass undoes the inline one's work, and no
        // amount of stripping markers afterwards repairs a parse.
        // A marked rule is left as it is, and the surface makes of it
        // what it can.
        //
        // A rule may hold nothing but its own character and spaces, so
        // there is no place on its line for a marker, and every place
        // off it belongs to another line: appended to the one before,
        // the markers end a fence that was closing, break a rule that
        // was already placed, or stand before a list's dash and make it
        // a paragraph. Each of those breaks a line that was correct to
        // save one that cannot be, and a surface comparing what it
        // parsed then refuses the lot — so a marked rule took every
        // other mark in the writing down with it.
        //
        // Left alone, the rule itself draws as a paragraph of hyphens
        // on a surface that redraws the Markdown, and is refused whole
        // on one that checks. Both are poor; neither spreads.
        // Code is drawn as it is written, so none of these rules apply
        // inside it: a link in a code span is text, not a link, and a
        // marker moved out of its address leaves the changed word with
        // no mark and a point beside the line. Found by the iOS
        // session, marking `new` in `curl https://x.com/new`.
        var fence: Fence?
        return (numbering ? numbered(marked) : marked)
            .components(separatedBy: "\n")
            .map { line -> String in
                let bare = unmarked(line)
                if let open = fence {
                    if closes(open, bare) { fence = nil }
                    return line
                }
                if let opening = fenceOpening(bare) {
                    fence = opening
                    return line
                }
                // The code spans held out of the way, the line put
                // right whole — a link's label may hold one, and a line
                // cut at the span is a line no rule can see that link
                // in.
                let (masked, spans) = maskingCodeSpans(clearingBlockSyntax(line))
                return unmasking(movingMarksOutOfLinks(masked), spans)
            }
            .joined(separator: "\n")
    }
}

extension LampWritingReviewMarkdown {
    /// Markers placed, and the order the passages ended up in.
    ///
    /// Placing can put two passages in the other order — a change to a
    /// link's words and a change to where it points, when the second
    /// one's markers come out of the address and go before the first.
    /// A surface that pairs what it is handed with the passages it finds,
    /// in order, then gives each the other's change.
    ///
    /// `numbered` lets a surface read each passage's own place out of
    /// the text, and that is right for one that draws whatever it
    /// parses. A surface that cannot be taught the places does not have
    /// to be: the order is worked out here, by placing the numbered
    /// copy, reading the places off it, and taking them out again. What
    /// it is handed is the plain placed Markdown it already understands,
    /// and the caller hands its own per-passage things over in `order`.
    ///
    /// `order` holds, for each passage in the placed text, which passage
    /// of the original it is.
    public static func placed(_ marked: String) -> (markdown: String, order: [Int]) {
        let drawn = drawable(marked, numbering: true)
        var order: [Int] = []
        var plain = ""
        let characters = Array(drawn)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == LampWritingReview.markStart || character == LampWritingReview.markPoint,
               let found = place(after: index, in: characters) {
                plain.append(character)
                order.append(found.place)
                index = found.end + 1
                continue
            }
            // A place that is not there to read leaves the passage in
            // the order it stands, which is what an unplaced copy does.
            if character == LampWritingReview.markStart || character == LampWritingReview.markPoint {
                order.append(order.count)
            }
            plain.append(character)
            index += 1
        }
        return (plain, order)
    }

    /// `things`, one to each passage of the original, put in the order
    /// the placed text's passages stand. Short or long lists are left
    /// alone: a caller whose things do not match its passages is one
    /// this cannot help, and guessing would pair them wrongly.
    public static func reordered<T>(_ things: [T], by order: [Int]) -> [T] {
        guard things.count == order.count, Set(order) == Set(0..<things.count) else {
            return things
        }
        return order.map { things[$0] }
    }
}
