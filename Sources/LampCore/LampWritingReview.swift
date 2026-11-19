import Foundation

/// What of a writing the assistant changed that its writer has not yet read
/// through and cleared.
///
/// A writer going over a draft with the assistant reads each passage and
/// clears it, and a later turn that changes a passage already cleared marks
/// it again. This is that record: the marks still to be read, and the ones
/// cleared or replaced, for one writing.
///
/// **A mark is anchored by its words, not by a position.** It keeps the
/// text it covers and a little on either side, and is found again in
/// whatever text the writing has now. So typing elsewhere in the writing
/// moves no mark and changes nothing here. The record changes only when the
/// assistant marks something, the writer clears something, or an edit runs
/// into a mark's own words. That matters because the record syncs to every
/// device: it travels on its own, apart from the writing's collection, and
/// should not be resent for every keystroke.
///
/// **It merges as a set.** Two devices can clear different passages, or one
/// can clear while the Mac marks a turn, and neither loses the other's: the
/// merge is every mark either has, less every mark either has retired. A
/// retired mark is never brought back under its id. A passage the assistant
/// changes again after it was cleared gets a new mark with a fresh id,
/// which no retirement can hide.
///
/// Positions handed out and taken in are UTF-16 offsets, which are what both
/// text views and the web editor count in.
public struct LampWritingReview: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    /// How much of the text on either side of a mark it keeps to be found
    /// by, at most: it stops at a line break.
    public static let contextLength = 24

    public var formatVersion: Int
    public var writingID: String
    /// The marks still to be read, in no order that means anything.
    public var marks: [Mark]
    /// Every mark cleared, or replaced by a mark covering its words anew.
    public var retired: [Retirement]

    public init(writingID: String, marks: [Mark] = [], retired: [Retirement] = []) {
        self.formatVersion = Self.formatVersion
        self.writingID = writingID
        self.marks = marks
        self.retired = retired
    }

    /// One passage the assistant changed. `text` empty is a place where it
    /// took words out and put nothing in.
    public struct Mark: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let text: String
        public let before: String
        public let after: String
        public let markedAt: Date
        /// The chat turn that made the change, where one did.
        public let turnID: UUID?

        public init(id: UUID = UUID(), text: String, before: String, after: String, markedAt: Date, turnID: UUID?) {
            self.id = id
            self.text = text
            self.before = before
            self.after = after
            self.markedAt = markedAt
            self.turnID = turnID
        }

        var anchor: Anchor { Anchor(text: text, before: before, after: after) }
    }

    public struct Retirement: Codable, Equatable, Hashable, Sendable {
        public let id: UUID
        public let retiredAt: Date

        public init(id: UUID, retiredAt: Date) {
            self.id = id
            self.retiredAt = retiredAt
        }
    }

    /// A mark found in a text, by the editors that draw it.
    public struct Located: Equatable, Sendable {
        public let id: UUID
        /// Empty for a place words were taken out.
        public let range: NSRange
    }

    public var isEmpty: Bool { marks.isEmpty }

    // MARK: Finding marks

    /// Where each mark is in `text`, in the order they stand. A mark whose
    /// words are no longer there is left out: somebody rewrote them, which
    /// is reading them.
    public func located(in text: String) -> [Located] {
        let source = text as NSString
        return marks
            .compactMap { mark in
                Self.find(mark.anchor, in: source).map { Located(id: mark.id, range: $0) }
            }
            .sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
    }

    /// The ranges to draw: located marks, with any that overlap or touch
    /// drawn as one.
    public func highlightedRanges(in text: String) -> [NSRange] {
        Self.coalesced(located(in: text).map(\.range), joiningAcross: nil)
    }

    // MARK: Changing the record

    /// The record after the assistant changed the writing from `old` to
    /// `new`: everything it put in is marked, a place it only took words
    /// out is marked as a point, and every mark already standing is carried
    /// across. A mark the change ran into is joined to the change.
    public func markingAssistantChange(
        from old: String, to new: String, turnID: UUID? = nil, at date: Date = Date()
    ) -> LampWritingReview {
        guard old != new else { return self }
        let alignment = LampTextAlignment(from: old, to: new)
        var ranges: [NSRange] = []
        for range in located(in: old).map(\.range) {
            ranges += alignment.carried(range, takingChanges: true)
        }
        for segment in alignment.segments where !segment.isEqual {
            ranges.append(segment.new)
        }
        let target = new as NSString
        let joined = Self.coalesced(ranges, joiningAcross: target)
        return reanchored(to: joined, in: target, turnID: turnID, at: date)
    }

    /// The record after the writer changed the writing from `old` to `new`.
    /// What they typed is theirs and is not marked; marked words they took
    /// out go with the mark; the rest of a mark they typed into stays.
    ///
    /// Returns the record unchanged, equal to `self`, when no mark's words
    /// or the text beside them were touched, which is the usual case: the
    /// caller can then skip writing it.
    public func carryingWriterEdit(from old: String, to new: String, at date: Date = Date()) -> LampWritingReview {
        guard old != new, !marks.isEmpty else { return self }
        let source = old as NSString
        let target = new as NSString
        // Most edits are nowhere near a mark: each still finds its words in
        // the new text exactly as before, and nothing need be written.
        let unmoved = marks.allSatisfy { mark in
            guard let before = Self.find(mark.anchor, in: source),
                  let after = Self.find(mark.anchor, in: target) else { return false }
            return Self.occurrenceIndex(of: mark.anchor, at: before, in: source)
                == Self.occurrenceIndex(of: mark.anchor, at: after, in: target)
        }
        if unmoved { return self }
        let alignment = LampTextAlignment(from: old, to: new)
        var ranges: [NSRange] = []
        for range in located(in: old).map(\.range) {
            ranges += alignment.carried(range, takingChanges: false)
        }
        return reanchored(to: Self.coalesced(ranges, joiningAcross: nil), in: target, turnID: nil, at: date)
    }

    /// The record with everything in `range` of `text` cleared. A mark only
    /// partly inside keeps its part outside, as a new mark; a point inside
    /// or at either end is cleared.
    public func clearing(_ range: NSRange, in text: String, at date: Date = Date()) -> LampWritingReview {
        let source = text as NSString
        var result = self
        var kept: [Mark] = []
        var added: [Mark] = []
        let located = Dictionary(self.located(in: text).map { ($0.id, $0.range) }, uniquingKeysWith: { first, _ in first })
        for mark in marks {
            guard let found = located[mark.id], Self.touches(found, range) else {
                kept.append(mark)
                continue
            }
            result.retired.append(Retirement(id: mark.id, retiredAt: date))
            for piece in Self.subtracting(range, from: found).map({ Self.trimmed($0, in: source) }) where piece.length > 0 {
                added.append(Self.mark(piece, in: source, turnID: mark.turnID, at: mark.markedAt))
            }
        }
        result.marks = kept + added
        return result
    }

    /// The record with every mark cleared.
    public func clearingAll(at date: Date = Date()) -> LampWritingReview {
        var result = self
        result.retired += marks.map { Retirement(id: $0.id, retiredAt: date) }
        result.marks = []
        return result
    }

    /// The record with what another copy of it knows: every mark either has,
    /// less every mark either has retired. The same whichever side merges.
    public func merged(with other: LampWritingReview) -> LampWritingReview {
        var retiredByID: [UUID: Date] = [:]
        for retirement in retired + other.retired {
            retiredByID[retirement.id] = min(retiredByID[retirement.id] ?? retirement.retiredAt, retirement.retiredAt)
        }
        var marksByID: [UUID: Mark] = [:]
        for mark in marks + other.marks where retiredByID[mark.id] == nil {
            if let existing = marksByID[mark.id] {
                // An id is made once and never reused, so two copies of one
                // mark agree. Should they not, both sides keep the same one.
                marksByID[mark.id] = Self.encodedOrder(existing, mark) ? existing : mark
            } else {
                marksByID[mark.id] = mark
            }
        }
        var result = LampWritingReview(writingID: writingID)
        result.formatVersion = max(formatVersion, other.formatVersion)
        result.marks = marksByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.retired = retiredByID
            .map { Retirement(id: $0.key, retiredAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    /// The record without retirements made before `date`.
    ///
    /// A retirement is kept so that a copy which still has the mark cannot
    /// bring it back in a merge. Once every device has merged since, it
    /// guards nothing, so the caller drops old ones rather than letting the
    /// record only grow. A device away for longer than that could show a
    /// cleared passage marked again, which is the whole of the risk.
    public func pruningRetirements(before date: Date) -> LampWritingReview {
        var result = self
        result.retired.removeAll { $0.retiredAt < date }
        return result
    }

    // MARK: Encoding

    /// The file's bytes: the same for the same record on every device.
    public func encoded() throws -> Data {
        var sorted = self
        sorted.marks.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.retired.sort { $0.id.uuidString < $1.id.uuidString }
        return try Self.encoder.encode(sorted)
    }

    public static func decoded(from data: Data) throws -> LampWritingReview {
        try decoder.decode(LampWritingReview.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    // MARK: Internals

    struct Anchor: Equatable, Hashable {
        let text: String
        let before: String
        let after: String
    }

    /// Marks for `ranges` of `text`, keeping the id of any standing mark
    /// that already covers exactly those words, and retiring the rest.
    private func reanchored(
        to ranges: [NSRange], in text: NSString, turnID: UUID?, at date: Date
    ) -> LampWritingReview {
        var standing: [Anchor: Mark] = [:]
        for mark in marks { standing[mark.anchor] = standing[mark.anchor] ?? mark }
        var result = self
        var next: [Mark] = []
        var kept = Set<UUID>()
        for range in Self.coalesced(ranges.map { Self.trimmed($0, in: text) }, joiningAcross: nil) {
            let fresh = Self.mark(range, in: text, turnID: turnID, at: date)
            if let existing = standing[fresh.anchor], !kept.contains(existing.id) {
                next.append(existing)
                kept.insert(existing.id)
            } else {
                next.append(fresh)
            }
        }
        for mark in marks where !kept.contains(mark.id) {
            result.retired.append(Retirement(id: mark.id, retiredAt: date))
        }
        result.marks = next
        return result
    }

    /// `range` without the spaces and line breaks at either end, which no
    /// reader takes for a change; one that was nothing else is a point.
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        var start = range.location
        var end = NSMaxRange(range)
        let blank = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(text.character(at: start)), blank.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)), blank.contains(scalar) { end -= 1 }
        return start == end ? NSRange(location: range.location, length: 0) : NSRange(location: start, length: end - start)
    }

    static func mark(_ range: NSRange, in text: NSString, turnID: UUID?, at date: Date) -> Mark {
        let beforeStart = start(ofCharacters: contextLength, endingAt: range.location, in: text)
        let afterEnd = end(ofCharacters: contextLength, startingAt: NSMaxRange(range), in: text)
        return Mark(
            text: text.substring(with: range),
            before: text.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
            after: text.substring(with: NSRange(location: NSMaxRange(range), length: afterEnd - NSMaxRange(range))),
            markedAt: date,
            turnID: turnID
        )
    }

    /// Where `anchor` is in `text`: its words with both sides of context,
    /// then with one, then its words alone if they stand only once. A point
    /// is found by its context alone.
    static func find(_ anchor: Anchor, in text: NSString) -> NSRange? {
        let length = (anchor.text as NSString).length
        if let found = first(anchor.before + anchor.text + anchor.after, in: text) {
            return NSRange(location: found.location + (anchor.before as NSString).length, length: length)
        }
        if !anchor.before.isEmpty, let found = only(anchor.before + anchor.text, in: text) {
            return NSRange(location: found.location + (anchor.before as NSString).length, length: length)
        }
        if !anchor.after.isEmpty, let found = only(anchor.text + anchor.after, in: text) {
            return NSRange(location: found.location, length: length)
        }
        if length > 0, let found = only(anchor.text, in: text) {
            return found
        }
        return nil
    }

    /// Which occurrence of the anchor's whole needle `range` is, so a mark
    /// found again can be told apart from one that moved onto a twin.
    private static func occurrenceIndex(of anchor: Anchor, at range: NSRange, in text: NSString) -> Int? {
        let needle = anchor.before + anchor.text + anchor.after
        let offset = (anchor.before as NSString).length
        var index = 0
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { return nil }
            if found.location + offset == range.location { return index }
            index += 1
            let next = found.location + 1
            guard next <= text.length else { return nil }
            search = NSRange(location: next, length: text.length - next)
        }
    }

    private static func first(_ needle: String, in text: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let found = text.range(of: needle, options: .literal)
        return found.location == NSNotFound ? nil : found
    }

    private static func only(_ needle: String, in text: NSString) -> NSRange? {
        guard let found = first(needle, in: text) else { return nil }
        let rest = found.location + 1
        let again = text.range(of: needle, options: .literal, range: NSRange(location: rest, length: text.length - rest))
        return again.location == NSNotFound ? found : nil
    }

    private static func start(ofCharacters count: Int, endingAt end: Int, in text: NSString) -> Int {
        var location = end
        var taken = 0
        while location > 0, taken < count {
            let previous = text.rangeOfComposedCharacterSequence(at: location - 1)
            if isLineBreak(previous, in: text) { break }
            location = previous.location
            taken += 1
        }
        return location
    }

    private static func end(ofCharacters count: Int, startingAt start: Int, in text: NSString) -> Int {
        var location = start
        var taken = 0
        while location < text.length, taken < count {
            let next = text.rangeOfComposedCharacterSequence(at: location)
            if isLineBreak(next, in: text) { break }
            location = NSMaxRange(next)
            taken += 1
        }
        return location
    }

    /// A mark's context stops at the end of its line, so a turn that
    /// changes another paragraph leaves the mark, and its id, as it was. A
    /// mark re-anchored under a new id is not hidden by a clear of the old
    /// one, so context reaching into the next paragraph made a clear on one
    /// device come undone when the Mac marked a turn further down.
    private static func isLineBreak(_ range: NSRange, in text: NSString) -> Bool {
        let character = text.substring(with: range)
        return character == "\n" || character == "\r" || character == "\r\n"
    }

    static func touches(_ mark: NSRange, _ range: NSRange) -> Bool {
        if mark.length == 0 {
            return mark.location >= range.location && mark.location <= NSMaxRange(range)
        }
        return mark.location < NSMaxRange(range) && range.location < NSMaxRange(mark)
            || (range.length == 0 && range.location >= mark.location && range.location <= NSMaxRange(mark))
    }

    static func subtracting(_ range: NSRange, from mark: NSRange) -> [NSRange] {
        guard mark.length > 0 else { return [] }
        var pieces: [NSRange] = []
        if range.location > mark.location {
            pieces.append(NSRange(location: mark.location, length: min(range.location, NSMaxRange(mark)) - mark.location))
        }
        if NSMaxRange(range) < NSMaxRange(mark) {
            let start = max(NSMaxRange(range), mark.location)
            pieces.append(NSRange(location: start, length: NSMaxRange(mark) - start))
        }
        // A caret with nothing selected clears the mark it stands in whole.
        return range.length == 0 ? [] : pieces
    }

    /// `ranges` sorted, with any that overlap or touch made one. Given a
    /// text, two ranges with only spaces between them on the same line are
    /// joined too, so "slow red" marks as one passage, not two words.
    /// A point inside or at the edge of a range is taken into it.
    static func coalesced(_ ranges: [NSRange], joiningAcross text: NSString?) -> [NSRange] {
        let sorted = ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            let gap = NSRange(location: NSMaxRange(last), length: max(0, range.location - NSMaxRange(last)))
            let joins = range.location <= NSMaxRange(last)
                || (text.map { isSpaces(gap, in: $0) } ?? false && last.length > 0 && range.length > 0)
            if joins {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func isSpaces(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, range.length <= 2 else { return false }
        return text.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func encodedOrder(_ lhs: Mark, _ rhs: Mark) -> Bool {
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) || left == right
    }
}

/// How one text became another, word by word: runs that stayed the same,
/// and runs that changed, each with its place in both texts in UTF-16.
struct LampTextAlignment {
    struct Segment: Equatable {
        let old: NSRange
        let new: NSRange
        let isEqual: Bool
    }

    let segments: [Segment]

    init(from old: String, to new: String) {
        let oldTokens = Self.tokens(of: old)
        let newTokens = Self.tokens(of: new)
        // Most turns change a passage or two of a long draft: what both
        // texts begin and end with is the same, and is left out of the
        // difference, whose cost grows with the length it is given times
        // the size of the change.
        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count,
              oldTokens[prefix].text == newTokens[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].text == newTokens[newTokens.count - 1 - suffix].text { suffix += 1 }
        let oldMiddle = oldTokens[prefix..<(oldTokens.count - suffix)].map(\.text)
        let newMiddle = newTokens[prefix..<(newTokens.count - suffix)].map(\.text)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed.insert(prefix + offset)
            case .insert(let offset, _, _): inserted.insert(prefix + offset)
            }
        }
        var segments: [Segment] = []
        var oldIndex = 0
        var newIndex = 0
        var oldOffset = 0
        var newOffset = 0
        func append(old oldLength: Int, new newLength: Int, isEqual: Bool) {
            guard oldLength > 0 || newLength > 0 else { return }
            let segment = Segment(
                old: NSRange(location: oldOffset, length: oldLength),
                new: NSRange(location: newOffset, length: newLength),
                isEqual: isEqual
            )
            if let last = segments.last, last.isEqual == isEqual {
                segments[segments.count - 1] = Segment(
                    old: NSRange(location: last.old.location, length: last.old.length + oldLength),
                    new: NSRange(location: last.new.location, length: last.new.length + newLength),
                    isEqual: isEqual
                )
            } else {
                segments.append(segment)
            }
            oldOffset += oldLength
            newOffset += newLength
        }
        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            var oldLength = 0
            var newLength = 0
            while oldIndex < oldTokens.count, removed.contains(oldIndex) {
                oldLength += oldTokens[oldIndex].length
                oldIndex += 1
            }
            while newIndex < newTokens.count, inserted.contains(newIndex) {
                newLength += newTokens[newIndex].length
                newIndex += 1
            }
            append(old: oldLength, new: newLength, isEqual: false)
            if oldIndex < oldTokens.count, newIndex < newTokens.count,
               !removed.contains(oldIndex), !inserted.contains(newIndex) {
                append(old: oldTokens[oldIndex].length, new: newTokens[newIndex].length, isEqual: true)
                oldIndex += 1
                newIndex += 1
            } else if oldLength == 0, newLength == 0 {
                // Cannot happen for a difference of the two token lists:
                // what neither removed nor inserted pairs in order. Should
                // it, the rest is one change rather than a loop for ever.
                let restOld = oldTokens[oldIndex...].reduce(0) { $0 + $1.length }
                let restNew = newTokens[newIndex...].reduce(0) { $0 + $1.length }
                append(old: restOld, new: restNew, isEqual: false)
                break
            }
        }
        self.segments = segments
    }

    /// Where the part of `range` of the old text is in the new text, as the
    /// pieces that survived. With `takingChanges`, a change the range runs
    /// into comes along whole, as the assistant's work; without, what was
    /// typed in its place is left out, as the writer's own. A point keeps
    /// its place unless the writer edited where it stood.
    func carried(_ range: NSRange, takingChanges: Bool) -> [NSRange] {
        var pieces: [NSRange] = []
        for segment in segments {
            if range.length == 0 {
                let inside = range.location >= segment.old.location && range.location <= NSMaxRange(segment.old)
                guard inside else { continue }
                if segment.isEqual {
                    pieces.append(NSRange(location: segment.new.location + range.location - segment.old.location, length: 0))
                    return pieces
                }
                if takingChanges {
                    pieces.append(segment.new)
                    return pieces
                }
                // Strictly inside text the writer replaced: gone with it.
                if range.location > segment.old.location, range.location < NSMaxRange(segment.old) { return [] }
                continue
            }
            let overlap = NSIntersectionRange(range, segment.old)
            let runsInto = overlap.length > 0
                || (segment.old.length == 0 && segment.old.location > range.location && segment.old.location < NSMaxRange(range))
            guard runsInto else { continue }
            if segment.isEqual {
                pieces.append(NSRange(location: segment.new.location + overlap.location - segment.old.location, length: overlap.length))
            } else if takingChanges, segment.new.length > 0 {
                pieces.append(segment.new)
            }
        }
        return pieces
    }

    struct Token {
        let text: String
        let length: Int
    }

    /// Words, runs of spaces, and every other character on its own.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentKind = 0
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(Token(text: current, length: current.utf16.count))
            current = ""
        }
        for character in text {
            let kind: Int
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                kind = 1
            } else if character == " " || character == "\t" {
                kind = 2
            } else {
                kind = 3
            }
            if kind != currentKind || kind == 3 { flush() }
            current.append(character)
            currentKind = kind
        }
        flush()
        return tokens
    }
}
