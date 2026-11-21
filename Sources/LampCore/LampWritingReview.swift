import CryptoKit
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

    /// How many restorations are kept, and for how long.
    ///
    /// They are kept to be told to the assistant, so that it does not make
    /// again a change the writer has just put back. That is a thing of the
    /// next turns, not of for ever, and nothing prunes this record on a
    /// schedule — so a restore drops the ones that have had their day rather
    /// than letting the file, and the note built from it, only grow.
    public static let restorationsKept = 20
    public static let restorationWindow: TimeInterval = 7 * 24 * 60 * 60

    public var formatVersion: Int
    public var writingID: String
    /// The marks still to be read, in no order that means anything.
    public var marks: [Mark]
    /// Marks cleared whole.
    public var retired: [Retirement]
    /// Parts of marks cleared.
    public var clearances: [Clearance]
    /// What stood where each mark stands, for a writer who wants it back.
    public var wordings: [Wording]
    /// The wordings put back, for the assistant to be told of.
    public var restorations: [Restoration]

    public init(
        writingID: String, marks: [Mark] = [], retired: [Retirement] = [], clearances: [Clearance] = [],
        wordings: [Wording] = [], restorations: [Restoration] = []
    ) {
        self.formatVersion = Self.formatVersion
        self.writingID = writingID
        self.marks = marks
        self.retired = retired
        self.clearances = clearances
        self.wordings = wordings
        self.restorations = restorations
    }

    /// Some words of a mark, or a place where words were taken out and none
    /// put in (`text` empty), with what stood either side.
    public struct Piece: Codable, Hashable, Sendable {
        public let text: String
        public let before: String
        public let after: String
        /// Where the piece was when it was last anchored, in the text that
        /// `anchoredIn` names.
        public let hint: Int
        /// The text the piece was last anchored in (`digest(of:)`): there it
        /// stands exactly where `hint` says, and from there a carry to
        /// another text takes it. Each piece names its own, so one word of
        /// a mark rewritten elsewhere does not keep the rest from moving.
        /// Nil where it is not known, as in a record made before it was kept.
        public let anchoredIn: String?

        public init(text: String, before: String, after: String, hint: Int, anchoredIn: String? = nil) {
            self.text = text
            self.before = before
            self.after = after
            self.hint = hint
            self.anchoredIn = anchoredIn
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

    /// What stood where a mark stands, so the writer can put it back.
    ///
    /// Kept beside the marks rather than on them, and merged by union.
    /// A mark's own fields are settled by `later(_:_:)`, which at an equal
    /// version takes the greater encoding — and with sorted keys a copy
    /// carrying one more key is always the smaller of the two, so a device
    /// running a core that knows nothing of this would strip it and win
    /// every tie. A union has no tie to lose: whichever side has the entry
    /// keeps it.
    public struct Wording: Codable, Equatable, Hashable, Sendable {
        public let markID: UUID
        /// The words the assistant replaced; empty where it only put words
        /// in, which a restore takes back out.
        public let old: String
        /// The spaces and line breaks the mark's range was trimmed of
        /// (`trimmed(_:in:)`), which a restore takes with it. A mark covers
        /// the words a reader sees changed, so a restore of those alone
        /// would leave the space the assistant put in beside them: "one two"
        /// made "one three two" and restored would read "one  two", and an
        /// inserted paragraph would leave an empty one behind.
        public let lead: String
        public let trail: String
        /// `digest(of:)` the words as they were marked. A restore is offered
        /// only while exactly those words still stand: inside a passage the
        /// writer has since edited, nothing here can tell their words from
        /// the assistant's, and a restore would take both.
        public let markedDigest: String
        /// Whether the words coming back were themselves marked and unread
        /// when this mark was made — a second draft within one turn, or a
        /// turn writing inside a passage still to be read. Put back
        /// unmarked, they would be unread work that looked read.
        public let wasUnread: Bool

        public init(
            markID: UUID, old: String, lead: String, trail: String, markedDigest: String, wasUnread: Bool
        ) {
            self.markID = markID
            self.old = old
            self.lead = lead
            self.trail = trail
            self.markedDigest = markedDigest
            self.wasUnread = wasUnread
        }
    }

    /// A wording the writer put back, for the assistant to be told of.
    ///
    /// It hears only what is still marked, in the note each turn is sent
    /// with, so a change put back is a change it knows nothing about: it
    /// would make it again, and mark it again. Recorded here because this
    /// record is what reaches the Mac that hosts the turn when the restore
    /// was made on a phone.
    public struct Restoration: Codable, Equatable, Hashable, Sendable {
        public let markID: UUID
        public let turnID: UUID?
        /// The words put back, and the assistant's that went.
        public let restored: String
        public let discarded: String
        public let restoredAt: Date

        public init(
            markID: UUID, turnID: UUID?, restored: String, discarded: String, restoredAt: Date
        ) {
            self.markID = markID
            self.turnID = turnID
            self.restored = restored
            self.discarded = discarded
            self.restoredAt = LampWritingReview.toTheMillisecond(restoredAt)
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

    /// What a piece's `anchoredIn` names a text by: a digest of its UTF-16
    /// code units, the units every offset here counts in.
    public static func digest(of text: String) -> String {
        let units = Array(text.utf16)
        let hash = units.withUnsafeBytes { SHA256.hash(data: $0) }
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The digests of the texts some mark or clearance is anchored in.
    public var anchors: Set<String> {
        Set((marks.flatMap(\.pieces) + clearances.flatMap(\.pieces)).compactMap(\.anchoredIn))
    }

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
    /// sides. A piece anchored in this very text is found where it says,
    /// and only there.
    func located(in text: String, strictly: Bool) -> [Located] {
        let source = text as NSString
        let here = Self.digest(of: text)
        func find(_ piece: Piece) -> NSRange? {
            piece.anchoredIn == here ? Self.exact(piece, in: source) : Self.find(piece, in: source, strictly: strictly)
        }
        var cleared: [UUID: [NSRange]] = [:]
        for clearance in clearances {
            for piece in clearance.pieces {
                if let range = find(piece) {
                    cleared[clearance.markID, default: []].append(range)
                }
            }
        }
        return marks.compactMap { mark -> Located? in
            var ranges = mark.pieces.compactMap { find($0) }
            for range in cleared[mark.id] ?? [] {
                ranges = ranges.flatMap { Self.subtracting(range, from: $0) }.compactMap { Self.remainder($0, in: source) }
            }
            ranges = Self.coalesced(ranges, joiningAcross: nil)
            return ranges.isEmpty ? nil : Located(id: mark.id, ranges: ranges)
        }
        .sorted { ($0.ranges[0].location, $0.ranges[0].length) < ($1.ranges[0].location, $1.ranges[0].length) }
    }

    /// A piece in the text it is anchored in: where its hint says, if its
    /// words are there.
    static func exact(_ piece: Piece, in text: NSString) -> NSRange? {
        let range = NSRange(location: piece.hint, length: (piece.text as NSString).length)
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              text.substring(with: range) == piece.text else { return nil }
        return range
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

    /// What an editor rewrites when it writes Markdown back: no letter, and
    /// a digit only as a list's number — at the start of its line after any
    /// indent, followed by `.` or `)` and a space — so a renumbered list is
    /// spelling and "chapter 1" against "chapter 2" is not.
    private static func isMarkup(_ range: NSRange, in text: NSString) -> Bool {
        let string = text.substring(with: range)
        guard !string.contains(where: { $0.isLetter }) else { return false }
        // Any other kind of number — ², ½, a digit from another script —
        // is substance, not a list's numbering.
        guard !string.contains(where: { $0.isNumber && !("0"..."9").contains($0) }) else { return false }
        guard string.contains(where: { $0.isNumber }) else { return true }
        let digits = try! NSRegularExpression(pattern: #"[0-9]+"#)
        return digits.matches(in: text as String, range: range).allSatisfy { isListNumber($0.range, in: text) }
    }

    /// Whether a run of digits is a list's number: first on its line after
    /// any indent and quote markers, then `.` or `)` and a space, and not in
    /// code — a fenced block, or a line indented as code.
    private static func isListNumber(_ digits: NSRange, in text: NSString) -> Bool {
        let line = text.lineRange(for: NSRange(location: digits.location, length: 0))
        let lead = text.substring(with: NSRange(location: line.location, length: digits.location - line.location))
        guard lead.allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) else { return false }
        // Four spaces or a tab of indent, quote markers aside, is code.
        let indent = lead.split(separator: ">", omittingEmptySubsequences: false).last.map(String.init) ?? lead
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        guard width < (lead.contains(">") ? 5 : 4) else { return false }
        let after = NSRange(location: NSMaxRange(digits), length: min(2, text.length - NSMaxRange(digits)))
        guard text.substring(with: after).range(of: #"^[.)][ \t]"#, options: .regularExpression) != nil else { return false }
        return !isInFencedCode(before: line.location, in: text)
    }

    /// Whether a line starting at `location` is inside a fenced code block,
    /// as CommonMark reads fences: one opens with three or more backticks or
    /// tildes, and closes only with a line of the same character, at least
    /// as long, and nothing after it but spaces.
    private static func isInFencedCode(before location: Int, in text: NSString) -> Bool {
        var open: (character: Character, length: Int)?
        for line in text.substring(to: location).components(separatedBy: "\n") {
            // A fence is indented three spaces at most, after any quote
            // markers, each of which takes one space after it with it; four
            // is code, and neither opens nor closes one.
            var unquoted = Substring(line)
            while true {
                let lead = unquoted.prefix { $0 == " " }
                guard lead.count <= 3, unquoted.dropFirst(lead.count).first == ">" else { break }
                unquoted = unquoted.dropFirst(lead.count + 1)
                if unquoted.first == " " { unquoted = unquoted.dropFirst() }
            }
            let indent = unquoted.prefix { $0 == " " }.count
            guard indent <= 3 else { continue }
            let trimmed = unquoted.dropFirst(indent)
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { continue }
            if let fence = open {
                if first == fence.character, run >= fence.length,
                   trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    open = nil
                }
            } else {
                open = (first, run)
            }
        }
        return open != nil
    }

    /// `range` of an editor's Markdown, placed in the Markdown held, where the
    /// two differ only in how the editor writes the same document back — a
    /// list's `*` returned as `-`, an emphasis's `_` as `*`, however many of
    /// them. Refused where any difference holds a letter or a digit: that is
    /// another text, not another spelling of this one, and a range — a
    /// caret most of all, which covers no words to check — would land on
    /// words the editor never showed. Placed by an alignment that keeps
    /// every run that stayed the same, short words included, and refused
    /// unless the words it covers are the same in both.
    private static func mapped(_ range: NSRange, from editor: String, to text: String) -> NSRange? {
        let alignment = LampTextAlignment(from: editor, to: text, absorbingSmallEqualities: false)
        let editorText = editor as NSString
        let heldText = text as NSString
        func spelling(_ segment: LampTextAlignment.Segment) -> Bool {
            let old = editorText.substring(with: segment.old)
            let new = heldText.substring(with: segment.new)
            // One character written two ways, é as e and an accent, is the
            // same text however it is stored.
            if old.precomposedStringWithCanonicalMapping == new.precomposedStringWithCanonicalMapping { return true }
            return isMarkup(segment.old, in: editorText) && isMarkup(segment.new, in: heldText)
        }
        guard alignment.segments.allSatisfy({ $0.isEqual || spelling($0) }) else { return nil }
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
        // Standing marks are carried by every run that stayed, short words
        // included; the assistant's change is marked as a reader sees it,
        // a word kept inside a removal taken into the change.
        var result = carried(to: new, from: [old], at: date)
        let alignment = LampTextAlignment(from: old, to: new)
        let target = new as NSString
        let source = old as NSString
        // Each change with the whole of its new range beside the trimmed one
        // the mark covers, and the old words it stands in the place of: what
        // a restore needs, and what nothing else here keeps.
        let changes = alignment.segments.filter { !$0.isEqual }
            .map { (trimmed: Self.trimmed($0.new, in: target), whole: $0.new, old: $0.old) }
        // What of the old text was still to be read. Words put back there by
        // a restore are read work only if they were read before.
        let unread = located(in: old).flatMap(\.ranges)
        let anchor = Self.digest(of: new)
        for range in Self.coalesced(changes.map { $0.trimmed }, joiningAcross: target) {
            let mark = Mark(
                pieces: [Self.piece(range, in: target, anchoredIn: anchor)], markedAt: date, turnID: turnID
            )
            result.marks.append(mark)
            // Several changes can coalesce into one mark — across a space,
            // or across a word or two that stayed — and the old words the
            // whole of it replaced run from the first to the last, which is
            // contiguous because the segments tile both texts. A mark no
            // change can be found for keeps no wording, and is not offered.
            let covered = changes.filter {
                $0.trimmed.location >= range.location && NSMaxRange($0.trimmed) <= NSMaxRange(range)
            }
            guard let first = covered.min(by: { $0.whole.location < $1.whole.location }),
                  let last = covered.max(by: { NSMaxRange($0.whole) < NSMaxRange($1.whole) })
            else { continue }
            let replaced = NSRange(
                location: first.old.location, length: NSMaxRange(last.old) - first.old.location
            )
            let lead = NSRange(
                location: first.whole.location, length: max(0, range.location - first.whole.location)
            )
            let trail = NSRange(
                location: NSMaxRange(range), length: max(0, NSMaxRange(last.whole) - NSMaxRange(range))
            )
            result.wordings.append(Wording(
                markID: mark.id,
                old: source.substring(with: replaced),
                lead: lead.length > 0 ? target.substring(with: lead) : "",
                trail: trail.length > 0 ? target.substring(with: trail) : "",
                markedDigest: Self.digest(of: target.substring(with: range)),
                wasUnread: replaced.length > 0 && unread.contains { Self.touches($0, replaced) }
            ))
        }
        return result
    }

    /// The record after the writer changed the writing from `old` to `new`.
    /// What they typed is theirs and is not marked; marked words they took
    /// out go with the mark; the rest of a mark they typed into stays; a
    /// place words were taken out goes once they write there.
    ///
    /// Only what is anchored in `old` is carried: a mark anchored in some
    /// other text — made by a turn while this carry waited behind another,
    /// or left by a clear in text not yet saved — is not this edit's to
    /// move, and is left as it is. Equal to `self` where nothing is
    /// anchored in `old`.
    public func carryingWriterEdit(from old: String, to new: String, at date: Date = Date()) -> LampWritingReview {
        guard old != new, !marks.isEmpty else { return self }
        return carried(to: new, from: [old], at: date)
    }

    /// The record with whatever is anchored in one of the `known` texts
    /// carried from there to `text`, each from its own. For a caller that
    /// has seen several versions of the writing go by: the editor, whose
    /// clears anchor what is left in text not yet saved. The texts are
    /// hashed here, so a caller off the main actor pays for it there.
    public func carryingToText(_ text: String, from known: [String], at date: Date = Date()) -> LampWritingReview {
        guard !marks.isEmpty else { return self }
        return carried(to: text, from: known.filter { $0 != text }, at: date)
    }

    /// The record with everything in `range` of `text` cleared. A mark only
    /// partly inside keeps its part outside; a point inside or at either end
    /// is cleared.
    public func clearing(_ range: NSRange, in text: String, at date: Date = Date()) -> LampWritingReview {
        let source = text as NSString
        let anchor = Self.digest(of: text)
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
                    markID: mark.id, pieces: Self.wordPieces(of: part, in: source, anchoredIn: anchor), clearedAt: date
                ))
            }
            result.marks.append(Mark(
                id: mark.id, pieces: kept.map { Self.piece($0, in: source, anchoredIn: anchor) },
                version: mark.version + 1, markedAt: mark.markedAt, turnID: mark.turnID
            ))
        }
        return result.tidied()
    }

    /// `clearing(_:in:)` made in `text`, the marks carried there from
    /// `known` first, changing only the marks the clear touches: every
    /// other mark, and its clearances, stays exactly as it was.
    ///
    /// For a clear made in the text an editor's page held as it was
    /// pressed, which can be a moment older or newer than the latest marks.
    /// Carried whole into that text, a mark with no words in it (made by a
    /// turn the page had not shown yet) would be retired by a clear of some
    /// other passage, and a mark the page had not caught up with would be
    /// moved to text that is already gone.
    public func clearing(
        _ range: NSRange, in text: String, carryingFrom known: [String], at date: Date = Date()
    ) -> LampWritingReview {
        let live = carryingToText(text, from: known, at: date)
        let cleared = live.clearing(range, in: text, at: date)
        let liveMarks = Dictionary(live.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveRetired = Set(live.retired.map(\.id))
        let liveClearances = Set(live.clearances.map(\.id))
        var touched = Set(cleared.retired.map(\.id)).subtracting(liveRetired)
        touched.formUnion(cleared.marks.filter { liveMarks[$0.id] != $0 }.map(\.id))
        touched.formUnion(cleared.clearances.filter { !liveClearances.contains($0.id) }.map(\.markID))
        guard !touched.isEmpty else { return self }
        let clearedMarks = Dictionary(cleared.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = self
        result.marks = marks.compactMap { touched.contains($0.id) ? clearedMarks[$0.id] : $0 }
        result.retired += cleared.retired.filter { touched.contains($0.id) }
        result.clearances = clearances.filter { !touched.contains($0.markID) }
            + cleared.clearances.filter { touched.contains($0.markID) }
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

    // MARK: Putting a wording back

    /// A mark whose words can be put back exactly as they stood.
    public struct Restorable: Equatable, Sendable {
        public let markID: UUID
        /// What a restore replaces: the mark's words, and the spaces the
        /// assistant put in with them.
        public let range: NSRange
        /// What stands there now, and what would stand there instead — both,
        /// because a writer about to press this is comparing, and because
        /// where the assistant only took words out there is nothing to see.
        public let words: String
        public let restored: String
        /// Whether what comes back is itself still to be read.
        public let wasUnread: Bool

        public init(
            markID: UUID, range: NSRange, words: String, restored: String, wasUnread: Bool
        ) {
            self.markID = markID
            self.range = range
            self.words = words
            self.restored = restored
            self.wasUnread = wasUnread
        }
    }

    /// One text put in the place of another.
    public struct Edit: Equatable, Sendable {
        public let markID: UUID
        public let range: NSRange
        public let replacement: String
        /// Whether what it puts back is still to be read.
        public let unread: Bool
    }

    /// The marks to put back and the edits that do it, **last first**, so
    /// that each range still means what it meant when the plan was made.
    public struct RestorePlan: Equatable, Sendable {
        public let edits: [Edit]
        public var marks: [UUID] { edits.map(\.markID) }
    }

    /// The marks in `text` that can be put back, in the order they stand.
    ///
    /// A mark is offered whole and only while it is still exactly the words
    /// that were marked: one piece, nothing cleared out of it, and the
    /// spaces the assistant put in still beside it. A passage the writer has
    /// typed into is not offered at all — nothing here can tell their words
    /// from the assistant's inside it, and a restore would take both. A mark
    /// made before wordings were kept, or whose wording a writer that knew
    /// nothing of them dropped, has none and is not offered.
    public func restorable(in text: String) -> [Restorable] {
        guard !wordings.isEmpty else { return [] }
        let source = text as NSString
        let byMark = Dictionary(wordings.map { ($0.markID, $0) }, uniquingKeysWith: { first, _ in first })
        let cleared = Set(clearances.map(\.markID))
        var result: [Restorable] = []
        for mark in located(in: text) {
            guard let wording = byMark[mark.id], !cleared.contains(mark.id), mark.ranges.count == 1
            else { continue }
            let range = mark.ranges[0]
            guard Self.digest(of: source.substring(with: range)) == wording.markedDigest,
                  let extended = Self.extended(range, by: wording, in: source)
            else { continue }
            result.append(Restorable(
                markID: mark.id,
                range: extended,
                words: source.substring(with: extended),
                restored: wording.old,
                wasUnread: wording.wasUnread
            ))
        }
        return result
    }

    /// What a restore of `range` would come to.
    ///
    /// Three answers rather than a plan or nothing, because a writer told
    /// no is owed which no it was: a selection standing in no marked
    /// passage at all is a different thing from one whose passage cannot be
    /// put back, and only the record knows which.
    public enum RestoreOutcome: Equatable, Sendable {
        /// The selection stands in nothing the assistant changed.
        case nothingTouched
        /// It does, and what stood there is kept, but the words have moved
        /// since: typed into, partly read, or the spaces beside them gone.
        /// The writer did this, and can be told so.
        case notExact
        /// What stood there was never kept: the change was made before Lamp
        /// kept it, or by a device whose Lamp does not. Nothing the writer
        /// did, so they are not told they edited it.
        case notKept
        case plan(RestorePlan)
    }

    /// Every mark the selection touches put back.
    ///
    /// All of them or none: a restore cannot be made of part of a passage,
    /// the way a clear can, so a selection holding one mark that has been
    /// typed into is refused whole rather than quietly leaving it behind.
    /// Refused too where two marks claim the same spaces between them,
    /// which one restore would take twice.
    public func restoring(_ range: NSRange, in text: String) -> RestoreOutcome {
        if let plan = restorePlan(for: range, in: text) { return .plan(plan) }
        let touched = located(in: text).filter { $0.ranges.contains { Self.touches($0, range) } }
        guard !touched.isEmpty else { return .nothingTouched }
        // Which of them stopped it, and whether that is the writer's doing:
        // a passage whose wording was never kept did not become unrestorable
        // through anything they did, and telling them they edited it would
        // be a lie they would go looking for.
        let offered = Set(restorable(in: text).map(\.markID))
        let kept = Set(wordings.map(\.markID))
        let blocking = touched.map(\.id).filter { !offered.contains($0) }
        return blocking.contains(where: { kept.contains($0) }) ? .notExact : .notKept
    }

    public func restorePlan(for range: NSRange, in text: String) -> RestorePlan? {
        let touched = located(in: text).filter { $0.ranges.contains { Self.touches($0, range) } }
        guard !touched.isEmpty else { return nil }
        let offered = Dictionary(
            restorable(in: text).map { ($0.markID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var plan: [Restorable] = []
        for mark in touched {
            guard let one = offered[mark.id] else { return nil }
            plan.append(one)
        }
        let ordered = plan.sorted { $0.range.location < $1.range.location }
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            guard NSMaxRange(earlier.range) <= later.range.location else { return nil }
        }
        return RestorePlan(edits: ordered.reversed().map {
            Edit(markID: $0.markID, range: $0.range, replacement: $0.restored, unread: $0.wasUnread)
        })
    }

    /// The record after a plan was applied, the writing going from `text` to
    /// `restored`.
    ///
    /// The marks put back are retired, and what each held is recorded for
    /// the assistant to be told; words that were themselves still to be read
    /// are marked again, under fresh ids, since nobody has read them; and
    /// every other mark is carried across the text the restore made, which
    /// is nobody's new work.
    ///
    /// `restored` is what the surface that made the edits ended up holding,
    /// not what this worked out they would come to: the visual page writes
    /// its own Markdown, and a word of it may be spelled another way. So the
    /// words put back are found again in it by their own text, nearest where
    /// the edit was made, and one that cannot be found is left unmarked
    /// rather than marked somewhere else.
    ///
    /// A mark made here keeps no wording of its own: what stood before it is
    /// the assistant's wording that was just put back, and putting *that*
    /// back would be making the change again, not restoring anything.
    ///
    /// Only the marks put back change. Every other mark, and its clearances,
    /// stays exactly as it was stored — not carried across the restore —
    /// for the reason `clearing(_:in:carryingFrom:)` gives: the text a
    /// restore is made in can be a moment older or newer than the latest
    /// marks, and a mark with no words in it, made by a turn the editor has
    /// not shown yet, would be moved to text that is already gone, or
    /// retired outright, by a restore of some other passage. The marks are
    /// found in `text` by carrying from `known` first, which changes
    /// nothing stored.
    public func restoringWording(
        _ plan: RestorePlan, from text: String, to restored: String,
        carryingFrom known: [String] = [], at date: Date = Date()
    ) -> LampWritingReview {
        guard !plan.edits.isEmpty else { return self }
        let put = Set(plan.marks)
        let live = known.isEmpty ? self : carryingToText(text, from: known, at: date)
        let turns = Dictionary(live.marks.map { ($0.id, $0.turnID) }, uniquingKeysWith: { first, _ in first })
        let held = Dictionary(
            live.restorable(in: text).map { ($0.markID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var result = self
        for id in plan.marks {
            result.retired.append(Retirement(id: id, retiredAt: date))
            guard let one = held[id] else { continue }
            result.restorations.append(Restoration(
                markID: id, turnID: turns[id] ?? nil,
                restored: one.restored, discarded: one.words, restoredAt: date
            ))
        }
        result.marks.removeAll { put.contains($0.id) }
        result.restorations = Array(
            result.restorations
                .filter { date.timeIntervalSince($0.restoredAt) < Self.restorationWindow }
                .sorted { ($0.restoredAt, $0.markID.uuidString) > ($1.restoredAt, $1.markID.uuidString) }
                .prefix(Self.restorationsKept)
        )
        result = result.tidied()
        let target = restored as NSString
        let anchor = Self.digest(of: restored)
        for edit in plan.edits where edit.unread && !edit.replacement.isEmpty {
            guard let found = Self.nearest(edit.replacement, in: target, to: edit.range.location)
            else { continue }
            result.marks.append(Mark(
                pieces: [Self.piece(Self.trimmed(found, in: target), in: target, anchoredIn: anchor)],
                markedAt: date,
                turnID: turns[edit.markID] ?? nil
            ))
        }
        return result.tidied()
    }

    /// `range` with the spaces the assistant put in beside its words, where
    /// those still stand there; nil where they do not, which is the writer
    /// having typed at its edge.
    private static func extended(_ range: NSRange, by wording: Wording, in text: NSString) -> NSRange? {
        let lead = (wording.lead as NSString).length
        let trail = (wording.trail as NSString).length
        let start = range.location - lead
        let end = NSMaxRange(range) + trail
        guard start >= 0, end <= text.length,
              text.substring(with: NSRange(location: start, length: lead)) == wording.lead,
              text.substring(with: NSRange(location: NSMaxRange(range), length: trail)) == wording.trail
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Where `words` stand in `text` nearest `location`; nil where they do
    /// not stand there at all.
    private static func nearest(_ words: String, in text: NSString, to location: Int) -> NSRange? {
        guard !words.isEmpty else { return nil }
        var best: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: words, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            if best.map({ abs(found.location - location) < abs($0.location - location) }) ?? true {
                best = found
            }
            search = NSRange(
                location: found.location + 1, length: text.length - found.location - 1
            )
        }
        return best
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
        // A union, with nothing held back: a wording is made once and never
        // changed, and a copy written by a core that does not know of them
        // has none rather than an older one, so whichever side has it is
        // right. One whose mark has gone is dropped by tidying rather than
        // here, so that a merge is a union and nothing else — which is what
        // `mergeReview` is proved of in SyncMerge.lean, and what keeps two
        // devices' merges the same in any order or grouping.
        var wordingsByMark: [UUID: Wording] = [:]
        for wording in wordings + other.wordings {
            wordingsByMark[wording.markID] = wordingsByMark[wording.markID]
                .map { Self.later($0, wording) } ?? wording
        }
        // Kept though their mark is retired: a restore is what retired it,
        // and the assistant has still to be told.
        var restorationsByMark: [UUID: Restoration] = [:]
        for restoration in restorations + other.restorations {
            restorationsByMark[restoration.markID] = restorationsByMark[restoration.markID]
                .map { Self.later($0, restoration) } ?? restoration
        }
        var result = LampWritingReview(writingID: writingID)
        result.formatVersion = max(formatVersion, other.formatVersion)
        result.marks = marksByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.retired = retiredByID
            .map { Retirement(id: $0.key, retiredAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.clearances = clearancesByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.wordings = wordingsByMark.values.sorted { $0.markID.uuidString < $1.markID.uuidString }
        result.restorations = restorationsByMark.values
            .sorted { $0.markID.uuidString < $1.markID.uuidString }
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
        // A restoration is there to be told to the assistant, which happens
        // on the turns just after it. Past the same window as a retirement
        // it is only size, and a record that only grows is resent for ever.
        result.restorations.removeAll { $0.restoredAt < date }
        // A merge is a union, so it can leave the wording of a mark the
        // other copy had retired. Nothing offers it — a restore needs the
        // mark — and this is where it goes.
        return result.tidied()
    }

    /// Without the clearances and wordings of marks no longer held.
    private func tidied() -> LampWritingReview {
        let held = Set(marks.map(\.id))
        var result = self
        result.clearances.removeAll { !held.contains($0.markID) }
        result.wordings.removeAll { !held.contains($0.markID) }
        return result
    }

    // MARK: Encoding

    /// The file's bytes: the same for the same record on every device.
    public func encoded() throws -> Data {
        var sorted = self
        sorted.marks.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.retired.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.clearances.sort { $0.id.uuidString < $1.id.uuidString }
        sorted.wordings.sort { $0.markID.uuidString < $1.markID.uuidString }
        sorted.restorations.sort { $0.markID.uuidString < $1.markID.uuidString }
        return try Self.encoder.encode(sorted)
    }

    /// Written by hand for one reason: a record that has never held a
    /// wording or a restoration encodes to the bytes it always did, so
    /// nothing is resent for a field it has nothing to say in. Read by hand
    /// for the other: every record made before them has neither key, and so
    /// has every record a writer that does not know them has rewritten.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, writingID, marks, retired, clearances, wordings, restorations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        writingID = try container.decode(String.self, forKey: .writingID)
        marks = try container.decode([Mark].self, forKey: .marks)
        retired = try container.decode([Retirement].self, forKey: .retired)
        clearances = try container.decode([Clearance].self, forKey: .clearances)
        wordings = try container.decodeIfPresent([Wording].self, forKey: .wordings) ?? []
        restorations = try container.decodeIfPresent([Restoration].self, forKey: .restorations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(writingID, forKey: .writingID)
        try container.encode(marks, forKey: .marks)
        try container.encode(retired, forKey: .retired)
        try container.encode(clearances, forKey: .clearances)
        if !wordings.isEmpty { try container.encode(wordings, forKey: .wordings) }
        if !restorations.isEmpty { try container.encode(restorations, forKey: .restorations) }
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
    /// Every mark and clearance carried to `target`, each piece from its own
    /// text among `sources` (oldest first). A piece anchored in one of them
    /// is taken from there, exactly. One anchored in a text not among them —
    /// another device's, one long gone, or none recorded — is taken from the
    /// newest source in which it stands whole, where it says or exactly
    /// once — exactly once, never at its hint, which another text's hint does
    /// not prove. Uniqueness in some other text is a weaker proof than a
    /// piece's own, so that is only for a piece with none.
    ///
    /// A piece whose words, context and place all come through unchanged,
    /// and stand once, is kept as it was, so a save that touched no mark
    /// changes nothing. One whose place moved, or whose words repeat, is
    /// anchored again, in `target`, so it stays exact.
    /// A piece no source holds is kept as it is, to be carried later.
    private func carried(to target: String, from sources: [String], at date: Date) -> LampWritingReview {
        let targetText = target as NSString
        let here = Self.digest(of: target)
        let digests = sources.map(Self.digest(of:))
        var alignments: [Int: LampTextAlignment] = [:]
        func alignment(_ index: Int) -> LampTextAlignment {
            if let known = alignments[index] { return known }
            let made = LampTextAlignment(from: sources[index], to: target, absorbingSmallEqualities: false)
            alignments[index] = made
            return made
        }
        func resolved(_ piece: Piece) -> (source: Int, range: NSRange)? {
            if let anchor = piece.anchoredIn, let index = digests.lastIndex(of: anchor) {
                return Self.exact(piece, in: sources[index] as NSString).map { (index, $0) }
            }
            for index in sources.indices.reversed() {
                if let range = Self.unique(piece, in: sources[index] as NSString) { return (index, range) }
            }
            return nil
        }
        /// The pieces carried, and whether anything about them changed.
        func carry(_ pieces: [Piece]) -> (pieces: [Piece], changed: Bool) {
            var result: [Piece] = []
            var changed = false
            for piece in pieces {
                guard piece.anchoredIn != here, let (index, range) = resolved(piece) else {
                    result.append(piece)
                    continue
                }
                var survived = Self.coalesced(
                    alignment(index).carried(range).map { Self.trimmed($0, in: targetText) }, joiningAcross: nil
                )
                if survived.isEmpty, let kept = Self.survivingCopy(of: range, in: sources[index] as NSString,
                                                                   through: alignment(index), to: targetText) {
                    survived = [kept]
                }
                let moved = survived.map { Self.piece($0, in: targetText, anchoredIn: here) }
                // Kept as it was only where it can be found again without its
                // anchor: the same words, context and place, standing once.
                // A piece of a repeated passage is anchored here every time,
                // so it is placed exactly, never guessed among its copies.
                if moved.count == 1, moved[0].sameWords(as: piece), moved[0].hint == piece.hint,
                   Self.unique(moved[0], in: targetText) != nil {
                    result.append(piece)
                } else {
                    result += moved
                    changed = true
                }
            }
            return (result, changed)
        }
        var result = self
        result.marks = []
        for mark in marks {
            let carried = carry(mark.pieces)
            guard carried.changed else {
                result.marks.append(mark)
                continue
            }
            guard !carried.pieces.isEmpty else {
                result.retired.append(Retirement(id: mark.id, retiredAt: date))
                continue
            }
            result.marks.append(Mark(
                id: mark.id, pieces: carried.pieces, version: mark.version + 1,
                markedAt: mark.markedAt, turnID: mark.turnID
            ))
        }
        // Clearances follow the words they cleared, as marks do, so a mark's
        // later copy cannot show again what was cleared of an earlier one.
        result.clearances = clearances.map { clearance in
            let carried = carry(clearance.pieces)
            guard carried.changed else { return clearance }
            return Clearance(
                id: clearance.id, markID: clearance.markID, pieces: carried.pieces,
                version: clearance.version + 1, clearedAt: clearance.clearedAt
            )
        }
        result = result.tidied()
        return result.marks == marks && result.retired == retired && result.clearances == clearances ? self : result
    }

    /// Where a marked passage went when the difference says it was deleted
    /// but an identical copy of its words came through: the text cannot say
    /// which of two copies the writer took out, and the difference pairs
    /// the one kept with whichever it meets first. A mark is kept on the copy
    /// that survived rather than retired with the one paired away — where
    /// exactly one such copy survived, since with more the mark cannot be
    /// placed and is left to go.
    static func survivingCopy(
        of range: NSRange, in source: NSString, through alignment: LampTextAlignment, to target: NSString
    ) -> NSRange? {
        guard range.length > 0 else { return nil }
        let words = source.substring(with: range)
        // A copy keeps the marked passage's edges: words that began and ended
        // at word boundaries are not found inside a longer word.
        let edges = Edges(of: piece(range, in: source))
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: source.length)
        while true {
            let copy = source.range(of: words, options: .literal, range: search)
            if copy.location == NSNotFound { break }
            if copy != range, edges.hold(at: copy, in: source) {
                let carried = alignment.carried(copy)
                if carried.count == 1, carried[0].length == copy.length,
                   target.substring(with: carried[0]) == words, edges.hold(at: carried[0], in: target) {
                    found.append(carried[0])
                }
            }
            let next = copy.location + 1
            guard next <= source.length else { break }
            search = NSRange(location: next, length: source.length - next)
        }
        return found.count == 1 ? found[0] : nil
    }

    /// A piece whole with its context, where that stands exactly once.
    static func unique(_ piece: Piece, in text: NSString) -> NSRange? {
        guard let found = only(piece.before + piece.text + piece.after, in: text) else { return nil }
        return NSRange(location: found.location + (piece.before as NSString).length, length: (piece.text as NSString).length)
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
    /// Two copies of one wording or restoration, which are made once and
    /// never changed: the same one on both sides, whichever side merges.
    private static func later(_ lhs: Wording, _ rhs: Wording) -> Wording {
        guard lhs != rhs else { return lhs }
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }

    private static func later(_ lhs: Restoration, _ rhs: Restoration) -> Restoration {
        guard lhs != rhs else { return lhs }
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }

    static func wordPieces(of range: NSRange, in text: NSString, anchoredIn: String? = nil) -> [Piece] {
        guard range.length > 0 else { return [piece(range, in: text, anchoredIn: anchoredIn)] }
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
                pieces.append(piece(NSRange(location: start, length: location - start), in: text, anchoredIn: anchoredIn))
            }
        }
        return pieces.isEmpty ? [piece(range, in: text, anchoredIn: anchoredIn)] : pieces
    }

    static func piece(_ range: NSRange, in text: NSString, anchoredIn: String? = nil) -> Piece {
        let beforeStart = start(ofCharacters: contextLength, endingAt: range.location, in: text)
        let afterEnd = end(ofCharacters: contextLength, startingAt: NSMaxRange(range), in: text)
        return Piece(
            text: text.substring(with: range),
            before: text.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
            after: text.substring(with: NSRange(location: NSMaxRange(range), length: afterEnd - NSMaxRange(range))),
            hint: range.location,
            anchoredIn: anchoredIn
        )
    }

    /// Where `piece` is in `text`: its words with both sides of context,
    /// the copy nearest its hint where there are several; then with one
    /// side, then its words alone, if those stand only once. A point is
    /// found by its context.
    ///
    /// The looser readings keep the piece's edges: one that began at the
    /// start of a word is found only at the start of one, and one that ended
    /// at a word's end only at an end. Without that, a cleared "a" whose
    /// context had been rewritten was found inside "lamp", and cut the word.
    static func find(_ piece: Piece, in text: NSString, strictly: Bool = false) -> NSRange? {
        let length = (piece.text as NSString).length
        let offset = (piece.before as NSString).length
        // Whole, with its context, where it stands once. Not at its hint, nor
        // nearest it: a hint recorded in another text names nothing here,
        // and where the words repeat it would choose a copy never marked. A
        // piece in its own text is placed exactly before this is asked, and
        // a carry anchors every piece of a repeated passage in the text it
        // carries to, so a repeated piece is only ever placed that way.
        if let found = unique(piece, in: text) { return found }
        if strictly { return nil }
        let edges = Edges(of: piece)
        if !piece.before.isEmpty, let found = only(piece.before + piece.text, in: text, where: {
            edges.hold(at: NSRange(location: $0.location + offset, length: length), in: text)
        }) {
            return NSRange(location: found.location + offset, length: length)
        }
        if !piece.after.isEmpty, let found = only(piece.text + piece.after, in: text, where: {
            edges.hold(at: NSRange(location: $0.location, length: length), in: text)
        }) {
            return NSRange(location: found.location, length: length)
        }
        if length > 0, let found = only(piece.text, in: text, where: { edges.hold(at: $0, in: text) }) {
            return found
        }
        return nil
    }

    /// Whether a piece began and ended at the edges of words, as it was
    /// last anchored.
    private struct Edges {
        let start: Bool
        let end: Bool

        init(of piece: Piece) {
            start = Self.isWord(piece.text.unicodeScalars.first) && !Self.isWord(piece.before.unicodeScalars.last)
            end = Self.isWord(piece.text.unicodeScalars.last) && !Self.isWord(piece.after.unicodeScalars.first)
        }

        /// Whether `range` of `text` keeps those edges.
        func hold(at range: NSRange, in text: NSString) -> Bool {
            if start, range.location > 0,
               Self.isWord(Unicode.Scalar(text.character(at: text.rangeOfComposedCharacterSequence(at: range.location - 1).location))) {
                return false
            }
            if end, NSMaxRange(range) < text.length,
               Self.isWord(Unicode.Scalar(text.character(at: NSMaxRange(range)))) {
                return false
            }
            return true
        }

        private static func isWord(_ scalar: Unicode.Scalar?) -> Bool {
            scalar.map(CharacterSet.alphanumerics.contains) ?? false
        }
    }

    /// The one copy of `needle` in `text` that `accepts`, or nil where there
    /// is none or more than one.
    private static func only(_ needle: String, in text: NSString, where accepts: (NSRange) -> Bool = { _ in true }) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var match: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            if accepts(found) {
                if match != nil { return nil }
                match = found
            }
            let next = found.location + 1
            guard next <= text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        return match
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

    /// `absorbingSmallEqualities` takes a word or two that stayed the same
    /// between two changes into one change with them, as a reader sees it;
    /// placing a position from one text in the other wants every run that
    /// stayed, so it asks for none.
    init(from old: String, to new: String, absorbingSmallEqualities: Bool = true) {
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
        self.segments = absorbingSmallEqualities
            ? Self.absorbingSmallEqualities(segments, oldText: old as NSString)
            : segments
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
