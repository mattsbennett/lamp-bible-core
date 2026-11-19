import Foundation

/// What of a writing the assistant changed that its writer has not yet read
/// through and cleared.
///
/// A writer going over a draft with the assistant reads each passage and
/// clears it, and a later turn that changes a passage already cleared marks
/// it again. This is that record, for one writing.
///
/// **A mark is anchored by its words, not by a position.** Each piece of it
/// keeps the text it covers and a little on either side, and is found again
/// in whatever text the writing has now; where the same words stand twice,
/// the copy nearest where the piece last was is taken. So typing elsewhere
/// moves no mark and changes nothing here. The record changes only when the
/// assistant marks something, the writer clears something, or an edit runs
/// into a mark or the words beside it. That matters because the record syncs
/// to every device on its own, apart from the writing's collection, and
/// should not be resent for every keystroke.
///
/// **It merges, and a clear made anywhere holds.**
/// - A mark keeps its id for as long as it lasts. Carried through an edit,
///   it gets a higher version; two copies of one mark merge to the higher.
/// - Clearing a whole mark retires its id, and a retired id never returns.
/// - Clearing part of one records what was cleared, which is taken out of
///   the mark wherever it is drawn, whichever copy of the mark won. So two
///   devices clearing different parts of one passage leave only the part
///   neither cleared.
/// - A passage the assistant changes after it was cleared is new work, and
///   gets a new mark with a fresh id.
///
/// Positions handed out and taken in are UTF-16 offsets, which are what both
/// text views and the web editor count in.
public struct LampWritingReview: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    /// How much of the text on either side of a piece it keeps to be found
    /// by.
    public static let contextLength = 24

    public var formatVersion: Int
    public var writingID: String
    /// The marks still to be read, in no order that means anything.
    public var marks: [Mark]
    /// Marks cleared whole.
    public var retired: [Retirement]
    /// Parts of marks cleared.
    public var clearances: [Clearance]

    public init(
        writingID: String, marks: [Mark] = [], retired: [Retirement] = [], clearances: [Clearance] = []
    ) {
        self.formatVersion = Self.formatVersion
        self.writingID = writingID
        self.marks = marks
        self.retired = retired
        self.clearances = clearances
    }

    /// Some words of a mark, or a place where words were taken out and none
    /// put in (`text` empty), with what stood either side.
    public struct Piece: Codable, Hashable, Sendable {
        public let text: String
        public let before: String
        public let after: String
        /// Where the piece was when it was last anchored. Only a tiebreak,
        /// between two copies of the same words.
        public let hint: Int

        public init(text: String, before: String, after: String, hint: Int) {
            self.text = text
            self.before = before
            self.after = after
            self.hint = hint
        }

        /// The piece as found again, without where it was.
        func sameWords(as other: Piece) -> Bool {
            text == other.text && before == other.before && after == other.after
        }
    }

    /// One passage the assistant changed.
    public struct Mark: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let pieces: [Piece]
        /// Raised each time the mark is carried to new words, so two copies
        /// of it merge to the later.
        public let version: Int
        public let markedAt: Date
        /// The chat turn that made the change, where one did.
        public let turnID: UUID?

        public init(id: UUID = UUID(), pieces: [Piece], version: Int = 1, markedAt: Date, turnID: UUID?) {
            self.id = id
            self.pieces = pieces
            self.version = version
            self.markedAt = LampWritingReview.toTheMillisecond(markedAt)
            self.turnID = turnID
        }
    }

    public struct Retirement: Codable, Equatable, Hashable, Sendable {
        public let id: UUID
        public let retiredAt: Date

        public init(id: UUID, retiredAt: Date) {
            self.id = id
            self.retiredAt = LampWritingReview.toTheMillisecond(retiredAt)
        }
    }

    /// Part of a mark the writer cleared. Carried through edits as a mark
    /// is, under its own id and a rising version, so it keeps covering the
    /// words it cleared; kept for as long as its mark is.
    public struct Clearance: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let markID: UUID
        public let pieces: [Piece]
        public let version: Int
        public let clearedAt: Date

        public init(id: UUID = UUID(), markID: UUID, pieces: [Piece], version: Int = 1, clearedAt: Date) {
            self.id = id
            self.markID = markID
            self.pieces = pieces
            self.version = version
            self.clearedAt = LampWritingReview.toTheMillisecond(clearedAt)
        }
    }

    /// A mark found in a text, by the editors that draw it.
    public struct Located: Equatable, Sendable {
        public let id: UUID
        /// What of the mark is still to be read, in order. An empty range is
        /// a place words were taken out.
        public let ranges: [NSRange]
    }

    public var isEmpty: Bool { marks.isEmpty }

    /// Times as the file holds them, so a record read back equals the one
    /// written: one that differed only below a millisecond would look
    /// changed, and be sent again, for nothing.
    static func toTheMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    // MARK: Finding marks

    /// Where each mark is in `text`, less what of it was cleared. A mark
    /// none of whose words are there any more is left out: somebody rewrote
    /// them, which is reading them.
    public func located(in text: String) -> [Located] {
        located(in: text, strictly: false)
    }

    /// With `strictly`, a piece is found only with its context on both
    /// sides. Carrying marks across an edit asks that: the text before the
    /// edit is the one they were last anchored in, so a piece not found
    /// whole there is stale, and the looser readings could take the same
    /// word from somewhere else and move the mark onto it.
    ///
    /// With `anchoredOnly` as well, a piece whose words and context stand
    /// more than once is found only at the place it holds. A carry from
    /// one text to another applies only to marks anchored in the first, and
    /// one anchored there stands exactly where it says wherever its words
    /// repeat, since a carry keeps the place of a repeated piece current.
    /// A mark anchored in some other text — made by a turn while this carry
    /// waited behind another — would otherwise be taken from a copy of its
    /// words and moved onto the wrong one.
    func located(in text: String, strictly: Bool, anchoredOnly: Bool = false) -> [Located] {
        let source = text as NSString
        var cleared: [UUID: [NSRange]] = [:]
        for clearance in clearances {
            for piece in clearance.pieces {
                if let range = Self.find(piece, in: source, strictly: strictly, anchoredOnly: anchoredOnly) {
                    cleared[clearance.markID, default: []].append(range)
                }
            }
        }
        return marks.compactMap { mark -> Located? in
            var ranges = mark.pieces.compactMap { Self.find($0, in: source, strictly: strictly, anchoredOnly: anchoredOnly) }
            for range in cleared[mark.id] ?? [] {
                ranges = ranges.flatMap { Self.subtracting(range, from: $0) }.compactMap { Self.remainder($0, in: source) }
            }
            ranges = Self.coalesced(ranges, joiningAcross: nil)
            return ranges.isEmpty ? nil : Located(id: mark.id, ranges: ranges)
        }
        .sorted { ($0.ranges[0].location, $0.ranges[0].length) < ($1.ranges[0].location, $1.ranges[0].length) }
    }

    /// The ranges to draw: every mark's, with any that overlap or touch
    /// drawn as one.
    public func highlightedRanges(in text: String) -> [NSRange] {
        Self.coalesced(located(in: text).flatMap(\.ranges), joiningAcross: nil)
    }

    // MARK: Crossing into a web editor

    /// The markers a web editor finds marks by: private-use characters, which
    /// no writing holds and no Markdown rule reads as anything but a letter.
    /// The editor's `review-marks.js` uses the same three.
    public static let markStart: Character = "\u{E000}"
    public static let markEnd: Character = "\u{E001}"
    public static let markPoint: Character = "\u{E002}"

    /// `text` with a marker at each edge of what is still marked, for a web
    /// editor to place the marks in the document it shows from the Markdown
    /// it was given. Nil where nothing is marked.
    public func markedMarkdown(in text: String) -> String? {
        let ranges = highlightedRanges(in: text)
        guard !ranges.isEmpty else { return nil }
        let source = text as NSString
        var result = ""
        var at = 0
        for range in ranges {
            result += source.substring(with: NSRange(location: at, length: range.location - at))
            if range.length == 0 {
                result.append(Self.markPoint)
            } else {
                result.append(Self.markStart)
                result += source.substring(with: range)
                result.append(Self.markEnd)
            }
            at = NSMaxRange(range)
        }
        result += source.substring(from: at)
        return result
    }

    /// The range a web editor marked in Markdown it sent back — a start and
    /// an end marker, or a point — and the Markdown without them. Nil unless
    /// there is exactly one such range, or where the Markdown without its
    /// markers is not `text`: the editor was showing something else, and
    /// clearing by its range would clear the wrong words.
    public static func markedRange(in marked: String, of text: String) -> NSRange? {
        var plain = ""
        var start: Int?
        var end: Int?
        for character in marked {
            switch character {
            case markStart where start == nil:
                start = (plain as NSString).length
            case markEnd where end == nil:
                end = (plain as NSString).length
            case markPoint where start == nil:
                start = (plain as NSString).length
                end = start
            case markStart, markEnd, markPoint:
                return nil
            default:
                plain.append(character)
            }
        }
        // Unit for unit: the offsets are UTF-16 ones, and a string equal to
        // `text` only by Unicode's rules, `é` spelled as `e` and an accent,
        // puts them on other characters.
        guard let start, let end, end >= start else { return nil }
        if plain.utf16.elementsEqual(text.utf16) { return NSRange(location: start, length: end - start) }
        return mapped(NSRange(location: start, length: end - start), from: plain, to: text)
    }

    /// `range` of an editor's Markdown, placed in the Markdown held, where the
    /// two differ only in how the editor writes the same document back — a
    /// list's `*` returned as `-`, an emphasis's `_` as `*`. Placed word by
    /// word, and refused unless the words it covers are the same words in
    /// both: an editor showing a different text clears nothing.
    private static func mapped(_ range: NSRange, from editor: String, to text: String) -> NSRange? {
        let alignment = LampTextAlignment(from: editor, to: text)
        let changed = alignment.segments.filter { !$0.isEqual }.reduce(0) { $0 + max($1.old.length, $1.new.length) }
        // Spelling, not substance: a few characters of the whole, or of a
        // short document a handful.
        guard changed <= max((editor as NSString).length / 20, 16) else { return nil }
        func place(_ offset: Int, atEnd: Bool) -> Int? {
            for segment in alignment.segments where offset >= segment.old.location && offset <= NSMaxRange(segment.old) {
                if segment.isEqual { return segment.new.location + offset - segment.old.location }
                if offset == segment.old.location { return segment.new.location }
                if offset == NSMaxRange(segment.old) { return NSMaxRange(segment.new) }
                return atEnd ? NSMaxRange(segment.new) : segment.new.location
            }
            return nil
        }
        guard let start = place(range.location, atEnd: false),
              let end = place(NSMaxRange(range), atEnd: true), end >= start else { return nil }
        let placed = NSRange(location: start, length: end - start)
        func words(_ string: String) -> [Substring] {
            string.split { !($0.isLetter || $0.isNumber) }
        }
        guard words((editor as NSString).substring(with: range)) == words((text as NSString).substring(with: placed)) else {
            return nil
        }
        return placed
    }

    // MARK: Changing the record

    /// The record after the assistant changed the writing from `old` to
    /// `new`. What it put in is marked, a passage at a time, under fresh
    /// ids; a place it only took words out is marked as a point. Every mark
    /// already standing is carried across as the writer's edits carry it.
    public func markingAssistantChange(
        from old: String, to new: String, turnID: UUID? = nil, at date: Date = Date()
    ) -> LampWritingReview {
        guard old != new else { return self }
        let alignment = LampTextAlignment(from: old, to: new)
        var result = carried(through: alignment, from: old, to: new, at: date)
        let target = new as NSString
        let changed = alignment.segments.filter { !$0.isEqual }.map { Self.trimmed($0.new, in: target) }
        for range in Self.coalesced(changed, joiningAcross: target) {
            result.marks.append(Mark(
                pieces: [Self.piece(range, in: target)], markedAt: date, turnID: turnID
            ))
        }
        return result
    }

    /// The record after the writer changed the writing from `old` to `new`.
    /// What they typed is theirs and is not marked; marked words they took
    /// out go with the mark; the rest of a mark they typed into stays; a
    /// place words were taken out goes once they write there.
    ///
    /// Returns the record unchanged, equal to `self`, when no mark's words
    /// or the text beside them were touched, which is the usual case: the
    /// caller can then skip writing it.
    public func carryingWriterEdit(from old: String, to new: String, at date: Date = Date()) -> LampWritingReview {
        guard old != new, !marks.isEmpty else { return self }
        return carried(through: LampTextAlignment(from: old, to: new), from: old, to: new, at: date)
    }

    /// The record with everything in `range` of `text` cleared. A mark only
    /// partly inside keeps its part outside; a point inside or at either end
    /// is cleared.
    public func clearing(_ range: NSRange, in text: String, at date: Date = Date()) -> LampWritingReview {
        let source = text as NSString
        var result = self
        let located = Dictionary(self.located(in: text).map { ($0.id, $0.ranges) }, uniquingKeysWith: { first, _ in first })
        result.marks = []
        for mark in marks {
            guard let ranges = located[mark.id], ranges.contains(where: { Self.touches($0, range) }) else {
                result.marks.append(mark)
                continue
            }
            let kept = ranges.flatMap { Self.subtracting(range, from: $0) }.compactMap { Self.remainder($0, in: source) }
            if kept.isEmpty {
                result.retired.append(Retirement(id: mark.id, retiredAt: date))
                continue
            }
            for cleared in ranges where Self.touches(cleared, range) {
                let part = cleared.length == 0 ? cleared : NSIntersectionRange(cleared, range)
                result.clearances.append(Clearance(
                    markID: mark.id, pieces: Self.wordPieces(of: part, in: source), clearedAt: date
                ))
            }
            result.marks.append(Mark(
                id: mark.id, pieces: kept.map { Self.piece($0, in: source) },
                version: mark.version + 1, markedAt: mark.markedAt, turnID: mark.turnID
            ))
        }
        return result.tidied()
    }

    /// The record with every mark cleared.
    public func clearingAll(at date: Date = Date()) -> LampWritingReview {
        var result = self
        result.retired += marks.map { Retirement(id: $0.id, retiredAt: date) }
        result.marks = []
        return result.tidied()
    }

    /// The record after turns were undone and the writing put back from
    /// `current` to `restored`: the marks those turns made are retired, and
    /// the rest are carried across the text the undo put back, which is
    /// nobody's new work.
    public func undoingTurns(
        _ turns: Set<UUID>, from current: String, to restored: String, at date: Date = Date()
    ) -> LampWritingReview {
        var result = self
        for mark in marks where mark.turnID.map(turns.contains) == true {
            result.retired.append(Retirement(id: mark.id, retiredAt: date))
        }
        result.marks.removeAll { $0.turnID.map(turns.contains) == true }
        return result.tidied().carryingWriterEdit(from: current, to: restored, at: date)
    }

    /// The record with what another copy of it knows. Each mark either has,
    /// at the higher version of the two; less every mark either retired;
    /// with every part either cleared. The same whichever side merges.
    public func merged(with other: LampWritingReview) -> LampWritingReview {
        var retiredByID: [UUID: Date] = [:]
        for retirement in retired + other.retired {
            retiredByID[retirement.id] = min(retiredByID[retirement.id] ?? retirement.retiredAt, retirement.retiredAt)
        }
        var marksByID: [UUID: Mark] = [:]
        for mark in marks + other.marks where retiredByID[mark.id] == nil {
            guard let existing = marksByID[mark.id] else {
                marksByID[mark.id] = mark
                continue
            }
            marksByID[mark.id] = Self.later(existing, mark)
        }
        var clearancesByID: [UUID: Clearance] = [:]
        for clearance in clearances + other.clearances where retiredByID[clearance.markID] == nil {
            clearancesByID[clearance.id] = clearancesByID[clearance.id].map { Self.later($0, clearance) } ?? clearance
        }
        var result = LampWritingReview(writingID: writingID)
        result.formatVersion = max(formatVersion, other.formatVersion)
        result.marks = marksByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.retired = retiredByID
            .map { Retirement(id: $0.key, retiredAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.clearances = clearancesByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    /// The record without retirements made before `date`.
    ///
    /// A retirement is kept so that a copy which still has the mark cannot
    /// bring it back in a merge. Once every device has merged since, it
    /// guards nothing, so the caller drops old ones rather than letting the
    /// record only grow. A device away for longer than that could show a
    /// cleared passage marked again, which is the whole of the risk.
    ///
    /// Clearances are not pruned by age: what they cleared may still stand
    /// in the winning copy of their mark, which would show it again. They go
    /// with their mark.
    public func pruning(before date: Date) -> LampWritingReview {
        var result = self
        result.retired.removeAll { $0.retiredAt < date }
        return result
    }

    /// Without the clearances of marks no longer held.
    private func tidied() -> LampWritingReview {
        let held = Set(marks.map(\.id))
        var result = self
        result.clearances.removeAll { !held.contains($0.markID) }
        return result
    }

    // MARK: Encoding

    /// The file's bytes: the same for the same record on every device.
    public func encoded() throws -> Data {
        var sorted = self
        sorted.marks.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.retired.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.clearances.sort { $0.id.uuidString < $1.id.uuidString }
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

    /// Every mark carried from `old` to `new`, under its own id: the words
    /// of it that survive, a raised version where they moved or changed, and
    /// retired where none survive.
    private func carried(
        through alignment: LampTextAlignment, from old: String, to new: String, at date: Date
    ) -> LampWritingReview {
        let target = new as NSString
        let found = Dictionary(located(in: old, strictly: true, anchoredOnly: true).map { ($0.id, $0.ranges) }, uniquingKeysWith: { first, _ in first })
        var result = self
        result.marks = []
        for mark in marks {
            // Already in the new text, whole, where it was anchored: made
            // for this very change. An assistant's draft is marked as it is
            // taken in and then saved like any edit, and carrying the new
            // mark across that same change again could take it from a copy
            // of its words in the old text and move it there.
            if mark.pieces.allSatisfy({ Self.find($0, in: target, strictly: true)?.location == $0.hint }) {
                result.marks.append(mark)
                continue
            }
            guard let ranges = found[mark.id] else {
                // Not in the old text either: nothing to carry, and nothing
                // to say it was read. Kept as it was, for the copy that can
                // still find it.
                result.marks.append(mark)
                continue
            }
            let survived = Self.coalesced(
                ranges.flatMap { alignment.carried($0) }.map { Self.trimmed($0, in: target) },
                joiningAcross: nil
            )
            guard !survived.isEmpty else {
                result.retired.append(Retirement(id: mark.id, retiredAt: date))
                continue
            }
            let pieces = survived.map { Self.piece($0, in: target) }
            result.marks.append(Self.unmoved(mark.pieces, pieces, in: target) ? mark : Mark(
                id: mark.id, pieces: pieces, version: mark.version + 1,
                markedAt: mark.markedAt, turnID: mark.turnID
            ))
        }
        // Clearances follow the words they cleared, as marks do, so a mark's
        // later copy cannot show again what was cleared of an earlier one.
        let source = old as NSString
        result.clearances = clearances.map { clearance in
            let ranges = clearance.pieces.compactMap { Self.find($0, in: source, strictly: true, anchoredOnly: true) }
            guard !ranges.isEmpty else { return clearance }
            let survived = Self.coalesced(
                ranges.flatMap { alignment.carried($0) }.compactMap { Self.remainder($0, in: target) },
                joiningAcross: nil
            )
            let pieces = survived.map { Self.piece($0, in: target) }
            return Self.unmoved(clearance.pieces, pieces, in: target) ? clearance : Clearance(
                id: clearance.id, markID: clearance.markID, pieces: pieces,
                version: clearance.version + 1, clearedAt: clearance.clearedAt
            )
        }
        result = result.tidied()
        return result.marks == marks && result.retired == retired && result.clearances == clearances ? self : result
    }

    /// Whether pieces carried to a new text are the ones held: the same
    /// words beside the same words, and, where those stand more than once,
    /// at the same place. Otherwise the place held would be stale, and the
    /// nearest copy to it could be another one.
    private static func unmoved(_ held: [Piece], _ carried: [Piece], in text: NSString) -> Bool {
        guard held.count == carried.count else { return false }
        return zip(held, carried).allSatisfy { old, new in
            old.sameWords(as: new) && (old.hint == new.hint || !standsTwice(new, in: text))
        }
    }

    private static func standsTwice(_ piece: Piece, in text: NSString) -> Bool {
        only(piece.before + piece.text + piece.after, in: text) == nil
    }

    private static func later(_ lhs: Clearance, _ rhs: Clearance) -> Clearance {
        if lhs.version != rhs.version { return lhs.version > rhs.version ? lhs : rhs }
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }

    private static func later(_ lhs: Mark, _ rhs: Mark) -> Mark {
        if lhs.version != rhs.version { return lhs.version > rhs.version ? lhs : rhs }
        // The same version from two devices: either will do, so long as
        // both sides keep the same one.
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }

    /// What was cleared, a word to a piece, so each is found again on its
    /// own. One piece for the whole phrase was lost as soon as any word of it
    /// changed — on another device, by a writer who never saw the clear —
    /// and the rest of what was cleared showed as marked again. A word with
    /// one side of its context intact is still found. A point is one piece.
    static func wordPieces(of range: NSRange, in text: NSString) -> [Piece] {
        guard range.length > 0 else { return [piece(range, in: text)] }
        var pieces: [Piece] = []
        var location = range.location
        let end = NSMaxRange(range)
        let blank = CharacterSet.whitespacesAndNewlines
        func isBlank(_ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map(blank.contains) ?? false
        }
        while location < end {
            while location < end, isBlank(location) { location += 1 }
            let start = location
            while location < end, !isBlank(location) { location += 1 }
            if location > start {
                pieces.append(piece(NSRange(location: start, length: location - start), in: text))
            }
        }
        return pieces.isEmpty ? [piece(range, in: text)] : pieces
    }

    static func piece(_ range: NSRange, in text: NSString) -> Piece {
        let beforeStart = start(ofCharacters: contextLength, endingAt: range.location, in: text)
        let afterEnd = end(ofCharacters: contextLength, startingAt: NSMaxRange(range), in: text)
        return Piece(
            text: text.substring(with: range),
            before: text.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
            after: text.substring(with: NSRange(location: NSMaxRange(range), length: afterEnd - NSMaxRange(range))),
            hint: range.location
        )
    }

    /// Where `piece` is in `text`: its words with both sides of context,
    /// the copy nearest its hint where there are several; then with one
    /// side, then its words alone, if those stand only once. A point is
    /// found by its context.
    static func find(_ piece: Piece, in text: NSString, strictly: Bool = false, anchoredOnly: Bool = false) -> NSRange? {
        let length = (piece.text as NSString).length
        let offset = (piece.before as NSString).length
        if let found = nearest(piece.before + piece.text + piece.after, to: piece.hint - offset, in: text) {
            let location = found.location + offset
            if anchoredOnly, location != piece.hint, standsTwice(piece, in: text) { return nil }
            return NSRange(location: location, length: length)
        }
        if strictly { return nil }
        if !piece.before.isEmpty, let found = only(piece.before + piece.text, in: text) {
            return NSRange(location: found.location + offset, length: length)
        }
        if !piece.after.isEmpty, let found = only(piece.text + piece.after, in: text) {
            return NSRange(location: found.location, length: length)
        }
        if length > 0, let found = only(piece.text, in: text) {
            return found
        }
        return nil
    }

    private static func nearest(_ needle: String, to hint: Int, in text: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var best: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while search.length >= 0 {
            let found = text.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            if best.map({ abs($0.location - hint) > abs(found.location - hint) }) ?? true { best = found }
            let next = found.location + 1
            guard next <= text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        return best
    }

    private static func only(_ needle: String, in text: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let found = text.range(of: needle, options: .literal)
        guard found.location != NSNotFound else { return nil }
        let rest = found.location + 1
        let again = text.range(of: needle, options: .literal, range: NSRange(location: rest, length: text.length - rest))
        return again.location == NSNotFound ? found : nil
    }

    private static func start(ofCharacters count: Int, endingAt end: Int, in text: NSString) -> Int {
        var location = end
        var taken = 0
        while location > 0, taken < count {
            location = text.rangeOfComposedCharacterSequence(at: location - 1).location
            taken += 1
        }
        return location
    }

    private static func end(ofCharacters count: Int, startingAt start: Int, in text: NSString) -> Int {
        var location = start
        var taken = 0
        while location < text.length, taken < count {
            location = NSMaxRange(text.rangeOfComposedCharacterSequence(at: location))
            taken += 1
        }
        return location
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

    /// What is left of a piece once part of it is cleared, without the
    /// spaces at its new ends; nothing, where only spaces were left, which
    /// is not a place words were taken out.
    static func remainder(_ range: NSRange, in text: NSString) -> NSRange? {
        guard range.length > 0 else { return range }
        let trimmed = trimmed(range, in: text)
        return trimmed.length > 0 ? trimmed : nil
    }

    static func touches(_ mark: NSRange, _ range: NSRange) -> Bool {
        if mark.length == 0 {
            return mark.location >= range.location && mark.location <= NSMaxRange(range)
        }
        if range.length == 0 {
            return range.location >= mark.location && range.location <= NSMaxRange(mark)
        }
        return mark.location < NSMaxRange(range) && range.location < NSMaxRange(mark)
    }

    /// What of `mark` is left once `range` is taken out of it. A point in or
    /// at the edge of `range` goes; a caret with nothing selected takes the
    /// whole of the mark it stands in.
    static func subtracting(_ range: NSRange, from mark: NSRange) -> [NSRange] {
        guard touches(mark, range) else { return [mark] }
        guard mark.length > 0, range.length > 0 else { return [] }
        var pieces: [NSRange] = []
        if range.location > mark.location {
            pieces.append(NSRange(location: mark.location, length: range.location - mark.location))
        }
        if NSMaxRange(range) < NSMaxRange(mark) {
            pieces.append(NSRange(location: NSMaxRange(range), length: NSMaxRange(mark) - NSMaxRange(range)))
        }
        return pieces
    }

    /// `ranges` sorted, with any that overlap or touch made one, and a point
    /// inside or at the edge of a range taken into it. Given a text, two
    /// ranges with only a space or two between them are joined too, so
    /// "slow red" marks as one passage, not two words.
    static func coalesced(_ ranges: [NSRange], joiningAcross text: NSString?) -> [NSRange] {
        let sorted = ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            let gap = NSRange(location: NSMaxRange(last), length: max(0, range.location - NSMaxRange(last)))
            let spaced = text.map { isSpaces(gap, in: $0) } ?? false
            if range.location <= NSMaxRange(last) || (spaced && last.length > 0 && range.length > 0) {
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
              oldTokens[prefix].units == newTokens[prefix].units { prefix += 1 }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].units == newTokens[newTokens.count - 1 - suffix].units {
            suffix += 1
        }
        // Compared as numbers, one for each distinct token: the difference
        // compares tokens far more often than there are tokens, and a whole
        // rewrite of a long draft spent seconds comparing code units.
        var numbers: [[UInt16]: Int] = [:]
        func number(_ token: Token) -> Int {
            if let known = numbers[token.units] { return known }
            numbers[token.units] = numbers.count
            return numbers.count - 1
        }
        let oldMiddle = oldTokens[prefix..<(oldTokens.count - suffix)].map(number)
        let newMiddle = newTokens[prefix..<(newTokens.count - suffix)].map(number)
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
            if let last = segments.last, last.isEqual == isEqual {
                segments[segments.count - 1] = Segment(
                    old: NSRange(location: last.old.location, length: last.old.length + oldLength),
                    new: NSRange(location: last.new.location, length: last.new.length + newLength),
                    isEqual: isEqual
                )
            } else {
                segments.append(Segment(
                    old: NSRange(location: oldOffset, length: oldLength),
                    new: NSRange(location: newOffset, length: newLength),
                    isEqual: isEqual
                ))
            }
            oldOffset += oldLength
            newOffset += newLength
        }
        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            var oldLength = 0
            var newLength = 0
            while oldIndex < oldTokens.count, removed.contains(oldIndex) {
                oldLength += oldTokens[oldIndex].units.count
                oldIndex += 1
            }
            while newIndex < newTokens.count, inserted.contains(newIndex) {
                newLength += newTokens[newIndex].units.count
                newIndex += 1
            }
            append(old: oldLength, new: newLength, isEqual: false)
            if oldIndex < oldTokens.count, newIndex < newTokens.count,
               !removed.contains(oldIndex), !inserted.contains(newIndex) {
                append(old: oldTokens[oldIndex].units.count, new: newTokens[newIndex].units.count, isEqual: true)
                oldIndex += 1
                newIndex += 1
            } else if oldLength == 0, newLength == 0 {
                // Cannot happen for a difference of the two token lists:
                // what neither removed nor inserted pairs in order. Should
                // it, the rest is one change rather than a loop for ever.
                let restOld = oldTokens[oldIndex...].reduce(0) { $0 + $1.units.count }
                let restNew = newTokens[newIndex...].reduce(0) { $0 + $1.units.count }
                append(old: restOld, new: restNew, isEqual: false)
                break
            }
        }
        self.segments = Self.absorbingSmallEqualities(segments, oldText: old as NSString)
    }

    /// Segments with every short run that stayed the same between two
    /// changes taken into one change with them: a word or two of the old
    /// text the difference happened to pair with the new — the "a" of "not
    /// a promise of comfort but" kept in "a call" — split one change into
    /// two, which marked as two places words were taken out with the "a"
    /// standing unmarked between them. A reader sees one change there.
    static func absorbingSmallEqualities(_ segments: [Segment], oldText: NSString) -> [Segment] {
        guard segments.count >= 3 else { return segments }
        var result: [Segment] = []
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            if segment.isEqual, let previous = result.last, !previous.isEqual, index + 1 < segments.count,
               !segments[index + 1].isEqual, isSmall(segment.old, in: oldText) {
                let next = segments[index + 1]
                result[result.count - 1] = Segment(
                    old: NSRange(location: previous.old.location, length: NSMaxRange(next.old) - previous.old.location),
                    new: NSRange(location: previous.new.location, length: NSMaxRange(next.new) - previous.new.location),
                    isEqual: false
                )
                index += 2
                continue
            }
            result.append(segment)
            index += 1
        }
        return result
    }

    /// At most a short word and the spaces beside it, on one line.
    private static func isSmall(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length <= 4 else { return false }
        return !text.substring(with: range).contains { $0.isNewline }
    }

    /// What of `range` of the old text survives in the new, as pieces: the
    /// words that stayed, moved to where they are now. Changed words are
    /// left out — the writer's own, or the assistant's, which a caller marks
    /// as new work. A point keeps its place unless something was written or
    /// taken out right where it stood.
    func carried(_ range: NSRange) -> [NSRange] {
        if range.length == 0 {
            let point = range.location
            let disturbed = segments.contains { segment in
                !segment.isEqual && point >= segment.old.location && point <= NSMaxRange(segment.old)
            }
            if disturbed { return [] }
            for segment in segments where segment.isEqual
            && point >= segment.old.location && point <= NSMaxRange(segment.old) {
                return [NSRange(location: segment.new.location + point - segment.old.location, length: 0)]
            }
            return []
        }
        var pieces: [NSRange] = []
        for segment in segments where segment.isEqual {
            let overlap = NSIntersectionRange(range, segment.old)
            guard overlap.length > 0 else { continue }
            pieces.append(NSRange(location: segment.new.location + overlap.location - segment.old.location, length: overlap.length))
        }
        return pieces
    }

    /// A token, compared by its UTF-16 code units rather than as a String:
    /// two spellings of one character are equal Strings of different
    /// lengths, and the offsets here are lengths.
    struct Token {
        let units: [UInt16]
    }

    /// Words, runs of spaces, and every other character on its own.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentKind = 0
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(Token(units: Array(current.utf16)))
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
