import Foundation

/// Where a review marker can stand without changing what the text around it
/// reads as.
///
/// A marker is a private-use character, and to a Markdown parser it is a
/// letter. So one standing on a fence line stops the fence closing, one
/// outside a table row's pipes becomes a cell of its own, and one before an
/// indented block's indent takes the line out of the code. The reader then
/// draws something the writer never wrote.
///
/// Two things answer that, and only the second has to be right. A surface
/// reads its file **twice**, with its markers and without, and keeps the
/// markers of a piece only where that piece reads exactly as it does
/// without them; elsewhere it draws the piece as written, and the changes
/// stay reachable in its menu. That is what makes it correct, and it is the
/// caller's to do, because only the caller knows what "reads the same"
/// means for what it draws.
///
/// What is here is the second thing: moving markers off what is only syntax
/// before the parse, so the common cases survive that comparison and stay
/// visible. Nothing here has to be complete. Whatever it misses costs a
/// passage its highlight, never its record.
///
/// Written by the iOS session, over five rounds of review, and lifted here
/// when the Mac needed the same work, so there is one copy rather than two.
public enum LampWritingReviewPlacement {
    // MARK: Ends that know their start

    /// Each end marker given the place of the start it closes.
    ///
    /// A passage is then known by both its edges. Should a parse lose one
    /// edge of each of two passages, the two that are left are not taken for
    /// one passage running between them.
    public static func placingEnds(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var open: String?
        var at = 0
        while at < characters.count {
            let character = characters[at]
            out.append(character)
            if character == LampWritingReview.markStart || character == LampWritingReview.markPoint {
                var place = ""
                var next = at + 1
                while next < characters.count,
                      LampWritingReviewMarkdown.placeDigit(characters[next]) != nil {
                    place.append(characters[next])
                    next += 1
                }
                if !place.isEmpty, next < characters.count,
                   characters[next] == LampWritingReviewMarkdown.placeEnd {
                    out += place + String(LampWritingReviewMarkdown.placeEnd)
                    if character == LampWritingReview.markStart { open = place }
                    at = next
                }
            } else if character == LampWritingReview.markEnd {
                if let place = open { out += place + String(LampWritingReviewMarkdown.placeEnd) }
                open = nil
            }
            at += 1
        }
        return out
    }

    // MARK: Markers off what is only syntax

    /// The marked text with markers taken off what is only syntax, where
    /// they would stop it reading as it does.
    ///
    /// A fence's own lines (the opening one's markers into its code, the
    /// closing one's onto the code's end), a table's alignment row (onto the
    /// row after), a row's outer pipes (moved inside them), a change of only
    /// the pipe between two cells (made a point, which neither cell draws),
    /// a footnote's label, a blank line (onto the next line with words), and
    /// a whole-line picture or recording (into its caption).
    ///
    /// Core's own placement leaves code exactly as written, fences included,
    /// because a surface that checks its parse refuses such a marker; a
    /// surface that draws them wants this.
    public static func settlingSyntaxLines(_ marked: String) -> String {
        var lines = marked.components(separatedBy: "\n")
        let bareLines = lines.map(unmarked)
        guard lines.count > 1 || marked.contains(where: isMarker) else { return marked }
        let model = LampMarkdownModel(parsing: bareLines.joined(separator: "\n"))
        var starts: [Int] = []
        var offset = 0
        for line in bareLines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        func line(of location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= location { low = middle } else { high = middle - 1 }
            }
            return low
        }
        func taking(_ index: Int) -> String {
            let found = markers(in: lines[index])
            if !found.isEmpty { lines[index] = unmarked(lines[index]) }
            return found
        }
        /// Markers put on a line where its words begin: after its quote
        /// marks and indent, then past any block syntax there.
        func putting(_ moved: String, onto index: Int, code: Bool) {
            guard !moved.isEmpty else { return }
            let prefix = containerPrefix(lines[index])
            let placed = String(prefix) + moved + lines[index].dropFirst(prefix.count)
            lines[index] = code ? placed : LampWritingReviewMarkdown.clearingBlockSyntax(placed)
        }
        // Lines a code block or a table holds, which a blank line's markers
        // are not moved onto, and a blank line in code keeps its own.
        var held = Set<Int>()
        var tableRows: [Int: Int] = [:]
        // For each line of a code block, the last line of its code.
        var codeEnds: [Int: Int] = [:]
        for block in model.blocks.sorted(by: { $0.range.location < $1.range.location }) {
            let first = line(of: block.range.location)
            let last = line(of: max(block.range.location, NSMaxRange(block.range) - 1))
            if block.kind == .codeBlock || block.kind == .table { held.formUnion(first...last) }
            if block.kind == .table {
                // A row that is not the alignment row, to take markers in.
                for index in first...last { tableRows[index] = index == first + 1 ? first : index }
            }
            switch block.kind {
            case .codeBlock:
                // A fence opens within three spaces of its container, or is
                // closed by its own mark; four in, it is indented code.
                let opener = fence(opening: bareLines[first])
                let indent = bareLines[first].prefix { $0 == " " || $0 == ">" }
                    .filter { $0 == " " }.count
                let fenced = opener.map { indent < 4 || (last > first && closes(bareLines[last], $0)) } ?? false
                guard fenced, let fence = opener else {
                    // Indented code: a marker before the indent moved past
                    // it, or the line is not code.
                    for index in first...last {
                        let head = lines[index].prefix {
                            isMarker($0) || $0 == " " || $0 == "\t" || $0 == ">"
                        }
                        guard head.contains(where: isMarker) else { continue }
                        lines[index] = String(head.filter { !isMarker($0) })
                            + markers(in: String(head))
                            + lines[index].dropFirst(head.count)
                    }
                    for index in first...last { codeEnds[index] = last }
                    continue
                }
                let opening = taking(first)
                // A fence never closed runs to the end of its container.
                let closed = last > first && closes(bareLines[last], fence)
                let closing = closed ? taking(last) : ""
                let inner = (first + 1)..<(closed ? last : last + 1)
                for index in first...last { codeEnds[index] = inner.isEmpty ? first : inner.upperBound - 1 }
                if inner.isEmpty {
                    // Nothing in the block: onto the line after it, the line
                    // before, or, alone in the file, left where it was.
                    let moved = LampWritingReviewMarkdown.asPoints(opening + closing)
                    if last + 1 < lines.count {
                        putting(moved, onto: last + 1, code: false)
                    } else if first > 0 {
                        lines[first - 1] += moved
                    } else {
                        lines[first] += moved
                    }
                } else {
                    putting(
                        LampWritingReviewMarkdown.asPoints(opening),
                        onto: inner.lowerBound, code: true
                    )
                    lines[inner.upperBound - 1] += LampWritingReviewMarkdown.asPoints(closing)
                }
            case .table where last > first:
                let alignment = taking(first + 1)
                if !alignment.isEmpty {
                    let moved = LampWritingReviewMarkdown.asPoints(alignment)
                    if first + 2 <= last {
                        lines[first + 2] = insideRow(moved, lines[first + 2])
                    } else {
                        lines[first] += moved
                    }
                }
                for index in first...last where index != first + 1 {
                    lines[index] = keepingMarkersInsidePipes(lines[index])
                }
            default:
                break
            }
        }
        for index in lines.indices where !held.contains(index) {
            // A footnote's label read as its label.
            let bare = unmarked(lines[index])
            if lines[index] != bare,
               let label = bare.prefixMatch(of: #/ {0,3}\[\^[^\]\s]+\]:[ \t]?/#) {
                var moved = ""
                var kept = ""
                var rest = Substring(lines[index])
                while kept.count < bare[label.range].count, let character = rest.first {
                    rest = rest.dropFirst()
                    if isMarker(character) { moved.append(character) } else { kept.append(character) }
                }
                lines[index] = kept + moved + rest
            }
        }
        // A blank line kept blank: its markers onto the next line with words
        // that is prose, else the one before, else left where they were.
        let isBlank: (Int) -> Bool = { unmarked(lines[$0]).allSatisfy { $0 == " " || $0 == "\t" } }
        for index in lines.indices
        where !held.contains(index) && isBlank(index) && lines[index].contains(where: isMarker) {
            let moved = LampWritingReviewMarkdown.asPoints(markers(in: lines[index]))
            if let next = lines.indices[(index + 1)...].first(where: { !isBlank($0) }),
               !held.contains(next) {
                lines[index] = unmarked(lines[index])
                putting(moved, onto: next, code: false)
            } else if let before = lines.indices[..<index].last(where: { !isBlank($0) }),
                      !held.contains(before) {
                lines[index] = unmarked(lines[index])
                lines[before] += moved
            } else if let before = lines.indices[..<index].last(where: { !isBlank($0) }) {
                // Only a table or code to go to: into its last cell, or onto
                // the end of its code.
                lines[index] = unmarked(lines[index])
                if let row = tableRows[before] {
                    lines[row] = keepingMarkersInsidePipes(lines[row] + moved)
                } else {
                    lines[codeEnds[before] ?? before] += moved
                }
            }
        }
        for index in lines.indices
        where !held.contains(index) && lines[index].contains(where: isMarker) {
            lines[index] = markersIntoCaption(lines[index])
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Passages the parse kept one edge of

    /// The places whose other edge is missing from what a parse gave back.
    public struct Unpaired: Equatable, Sendable {
        /// Places with a start and no end.
        public let lostEnd: Set<Int>
        /// Places with an end and no start.
        public let lostStart: Set<Int>

        public var isEmpty: Bool { lostEnd.isEmpty && lostStart.isEmpty }
    }

    /// One change to a drawn text, as a range in its UTF-16 and what stands
    /// there instead.
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
    }

    /// Which places lost an edge, across every piece a surface drew.
    ///
    /// Every piece has to be looked at together: a passage's start may be in
    /// one and its end in another.
    public static func unpaired(across texts: [String]) -> Unpaired {
        var starts = Set<Int>()
        var ends = Set<Int>()
        for text in texts {
            for found in placedMarkers(in: text as NSString) {
                if found.marker == 0xE000 { starts.insert(found.place) }
                if found.marker == 0xE001 { ends.insert(found.place) }
            }
        }
        return Unpaired(lostEnd: starts.subtracting(ends), lostStart: ends.subtracting(starts))
    }

    /// The changes that draw a half-kept passage safely, latest first so
    /// that earlier ranges still hold when they are applied in order.
    ///
    /// A start whose end was lost becomes a point, rather than highlighting
    /// on to the end of the file. An end whose start was lost is taken out.
    /// The caller applies them to whatever it drew, because only it knows
    /// how to keep the attributes around them.
    public static func pointingEdits(in text: String, unpaired: Unpaired) -> [Edit] {
        guard !unpaired.isEmpty else { return [] }
        return placedMarkers(in: text as NSString).compactMap { found -> Edit? in
            if found.marker == 0xE000, unpaired.lostEnd.contains(found.place) {
                return Edit(
                    range: NSRange(location: found.at, length: 1),
                    replacement: String(LampWritingReview.markPoint)
                )
            }
            if found.marker == 0xE001, unpaired.lostStart.contains(found.place) {
                return Edit(range: NSRange(location: found.at, length: found.length), replacement: "")
            }
            return nil
        }.reversed()
    }

    /// Each start, end and point marker with the place written after it:
    /// where it stands and how long it is with its place, in UTF-16, where
    /// every marker and digit is one unit. One with no place is left out.
    static func placedMarkers(in text: NSString) -> [(at: Int, length: Int, marker: unichar, place: Int)] {
        var out: [(at: Int, length: Int, marker: unichar, place: Int)] = []
        var at = 0
        while at < text.length {
            let unit = text.character(at: at)
            guard (0xE000...0xE002).contains(unit) else {
                at += 1
                continue
            }
            var next = at + 1
            var place = 0
            while next < text.length, (0xE010...0xE019).contains(text.character(at: next)) {
                place = place * 10 + Int(text.character(at: next) - 0xE010)
                next += 1
            }
            if next > at + 1, next < text.length, text.character(at: next) == 0xE01A {
                out.append((at, next + 1 - at, unit, place))
                at = next + 1
            } else {
                at += 1
            }
        }
        return out
    }

    // MARK: Lines

    /// A picture or recording on a line of its own with the markers around
    /// it moved into its caption, where they leave it on a line of its own.
    private static func markersIntoCaption(_ line: String) -> String {
        let bare = unmarked(line)
        guard bare.wholeMatch(of: #/\s*!?\[[^\]]*\]\((?:media/|lamp-media:\/\/)[^)\s]+\)\s*/#) != nil,
              let open = line.firstIndex(of: "["), let close = line.range(of: "](")
        else { return line }
        let head = line[..<open]
        guard let end = line[close.upperBound...].firstIndex(of: ")") else { return line }
        let tail = line[line.index(after: end)...]
        let before = markers(in: String(head.filter { $0 != "!" }))
        let after = markers(in: String(tail))
        guard !before.isEmpty || !after.isEmpty else { return line }
        let bang = head.contains("!") ? "!" : ""
        let indent = head.filter { $0 == " " || $0 == "\t" }
        return indent + bang + "[" + before + line[line.index(after: open)..<close.lowerBound]
            + after + line[close.lowerBound...end]
    }

    /// A line's quote marks and indent, which hold it in its container.
    private static func containerPrefix(_ line: String) -> Substring {
        line.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
    }

    /// The fence a line opens, its quote marks and indent aside.
    private static func fence(opening line: String) -> (character: Character, length: Int)? {
        let rest = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix { $0 == character }.count
        return length >= 3 ? (character, length) : nil
    }

    /// Whether a line closes a fence: the same character, at least as long,
    /// and nothing after it but spaces.
    private static func closes(_ line: String, _ fence: (character: Character, length: Int)) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        let run = rest.prefix { $0 == fence.character }
        return run.count >= fence.length && rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `markers` put at the start of a table row's first cell's words.
    private static func insideRow(_ markers: String, _ row: String) -> String {
        let prefix = containerPrefix(row)
        let rest = row.dropFirst(prefix.count)
        guard rest.first == "|" else { return prefix + markers + rest }
        let cell = rest.dropFirst()
        let space = cell.prefix { $0 == " " || $0 == "\t" }
        return prefix + "|" + space + markers + cell.dropFirst(space.count)
    }

    /// A table row with markers standing outside its outer pipes moved in
    /// past them, where they would be cells of their own, and a change of
    /// only the pipe between two cells made a point, which neither draws.
    private static func keepingMarkersInsidePipes(_ row: String) -> String {
        var row = row
        let isMarkerOrSpace: (Character) -> Bool = {
            isMarker($0) || $0 == " " || $0 == "\t" || $0 == ">"
        }
        // Before the first pipe, the quote marks holding the row kept.
        let head = row.prefix(while: isMarkerOrSpace)
        if head.contains(where: isMarker), row.dropFirst(head.count).first == "|" {
            let prefix = String(head.filter { !isMarker($0) })
            row = insideRow(markers(in: String(head)), prefix + row.dropFirst(head.count))
        }
        // After the last.
        let tail = String(row.reversed().prefix { isMarker($0) || $0 == " " || $0 == "\t" }.reversed())
        let body = row.dropLast(tail.count)
        if tail.contains(where: isMarker), body.last == "|", !body.dropLast().hasSuffix("\\") {
            // At the end of the last cell's words, before its spaces.
            let cell = body.dropLast()
            let space = String(cell.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            row = cell.dropLast(space.count) + markers(in: tail) + space + "|"
        }
        return row.replacing(
            #/\x{E000}([\x{E010}-\x{E01A}]*)([ \t]*)\|([ \t]*)\x{E001}[\x{E010}-\x{E01A}]*/#
        ) { match in
            "\u{E002}\(match.output.1)\(match.output.2)|\(match.output.3)"
        }
    }

    // MARK: Markers

    private static func isMarker(_ character: Character) -> Bool {
        LampWritingReviewMarkdown.isMarker(character)
    }

    private static func unmarked(_ text: String) -> String {
        LampWritingReviewMarkdown.unmarked(text)
    }

    private static func markers(in text: String) -> String {
        LampWritingReviewMarkdown.markers(in: text)
    }
}
