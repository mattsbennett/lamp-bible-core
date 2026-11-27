import CryptoKit
import Foundation
@testable import LampCore

/// Review records built through the real API, for the goldens and the
/// measurement harness.
///
/// Every id a record holds is minted at random, and `encoded()` sorts by
/// id, so a record built twice differs. Once built, each id is replaced by
/// one numbered in the order the record first names it, which is the order
/// it was made in. Every date is fixed. So the same code builds the same
/// bytes, and a change to what the code does shows in them.
enum ReviewFixtures {
    struct Fixture {
        let name: String
        let review: LampWritingReview
        /// The text the record was last carried to.
        let text: String
        /// Texts it has not been carried to, each with what it tests.
        let variants: [(name: String, text: String)]
    }

    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    static func date(_ step: Int) -> Date {
        epoch.addingTimeInterval(TimeInterval(step) * 60)
    }

    /// A numbered id, so the order ids sort in is the order they were made.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    // MARK: Text

    /// A small seeded generator, so a fixture is the same on every run.
    struct Seeded {
        private var state: UInt64

        init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }

        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    /// Words that repeat, so contexts repeat and the looser readings of
    /// `find` are reached, with composed characters, a decomposed accent,
    /// an emoji and CJK among them.
    static let vocabulary = [
        "grace", "and", "peace", "to", "you", "from", "God", "our", "Father", "the", "Lord",
        "a", "lamp", "unto", "my", "feet", "light", "path", "word", "is", "of", "in", "that",
        "faith", "hope", "love", "but", "the", "greatest", "these", "café", "cafe\u{301}",
        "naïve", "🙂", "光", "道", "it", "was", "said", "\"so\"", "it's", "--", "it", "a",
    ]

    static func sentence(_ random: inout Seeded) -> String {
        let count = 6 + random.below(10)
        var words = (0..<count).map { _ in random.pick(vocabulary) }
        words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        if random.below(5) == 0 { words[random.below(count)] = "*" + random.pick(vocabulary) + "*" }
        if random.below(7) == 0 { words[random.below(count)] = "[" + random.pick(vocabulary) + "](https://x.test)" }
        return words.joined(separator: " ") + random.pick([".", ".", ".", "?", "!", ";"])
    }

    static func paragraph(_ random: inout Seeded) -> String {
        let body = (0..<(2 + random.below(5))).map { _ in sentence(&random) }.joined(separator: " ")
        switch random.below(9) {
        case 0: return "## " + sentence(&random)
        case 1: return "- " + sentence(&random) + "\n- " + sentence(&random)
        case 2: return "> " + body
        case 3: return "[^\(1 + random.below(3))]: " + body
        default: return body
        }
    }

    /// About `units` UTF-16 units of Markdown, in paragraphs.
    static func text(seed: UInt64, units: Int) -> String {
        var random = Seeded(seed)
        var paragraphs: [String] = []
        var length = 0
        while length < units {
            let next = paragraph(&random)
            paragraphs.append(next)
            length += (next as NSString).length + 2
        }
        // A paragraph standing twice, so some passages have no unique
        // context at all.
        if paragraphs.count > 4 { paragraphs.insert(paragraphs[1], at: paragraphs.count - 1) }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: Edits

    /// A word boundary at or after `location`.
    static func boundary(near location: Int, in text: NSString) -> Int {
        var at = min(max(0, location), text.length)
        while at < text.length, text.character(at: at) != 0x20 { at += 1 }
        return at
    }

    /// The assistant's turn: a few words replaced, a sentence put in, and
    /// a few words taken out, at seeded places.
    static func assistantTurn(_ text: String, _ random: inout Seeded) -> String {
        let result = NSMutableString(string: text)
        for _ in 0..<(1 + random.below(3)) {
            let start = boundary(near: random.below(result.length), in: result)
            let end = boundary(near: start + 1 + random.below(30), in: result)
            guard end > start else { continue }
            switch random.below(3) {
            case 0: result.replaceCharacters(in: NSRange(location: start, length: end - start), with: " " + sentence(&random))
            case 1: result.replaceCharacters(in: NSRange(location: start, length: end - start), with: "")
            default: result.insert(" " + sentence(&random), at: start)
            }
        }
        return result as String
    }

    /// The writer typing a word at a seeded place.
    static func writerTyping(_ text: String, _ random: inout Seeded) -> String {
        let result = NSMutableString(string: text)
        let at = boundary(near: random.below(result.length), in: result)
        result.insert(" " + random.pick(vocabulary), at: at)
        return result as String
    }

    // MARK: Building

    /// A record over `units` of text: `turns` assistant turns with the
    /// writer typing between them, then clears of every kind — part of a
    /// passage, a caret, a whole passage — and one long passage cleared a
    /// word at a time, the way a writer reads one through, which is what
    /// fills a record with clearances.
    static func build(
        name: String, seed: UInt64, units: Int, turns: Int, wordClears: Int,
        merging: Bool = false, renumbering: Bool = true
    ) -> Fixture {
        var random = Seeded(seed)
        var text = Self.text(seed: seed, units: units)
        var review = LampWritingReview(writingID: name)
        var step = 0
        for turn in 0..<turns {
            step += 1
            let next = assistantTurn(text, &random)
            review = review.markingAssistantChange(from: text, to: next, turnID: id(900_000 + turn), at: date(step))
            text = next
            if random.below(3) == 0 {
                step += 1
                let typed = writerTyping(text, &random)
                review = review.carryingWriterEdit(from: text, to: typed, at: date(step))
                text = typed
            }
        }
        // One long passage, read through a word at a time.
        step += 1
        let source = text as NSString
        let start = boundary(near: source.length / 3, in: source)
        let long = (0..<12).map { _ in sentence(&random) }.joined(separator: " ")
        let rewritten = source.replacingCharacters(in: NSRange(location: start, length: 0), with: " " + long)
        review = review.markingAssistantChange(from: text, to: rewritten, turnID: id(999_999), at: date(step))
        text = rewritten
        let longRange = NSRange(location: start + 1, length: (long as NSString).length)
        var word = longRange.location
        for _ in 0..<wordClears {
            step += 1
            let ns = text as NSString
            while word < NSMaxRange(longRange), ns.character(at: word) == 0x20 { word += 1 }
            var end = word
            while end < NSMaxRange(longRange), ns.character(at: end) != 0x20 { end += 1 }
            guard end > word else { break }
            review = review.clearing(NSRange(location: word, length: end - word), in: text, at: date(step))
            // Every other word, so the passage is left in pieces.
            word = end + 1
            while word < NSMaxRange(longRange), ns.character(at: word) != 0x20 { word += 1 }
        }
        // Clears of every other kind, on the passages standing.
        for (index, mark) in review.located(in: text).enumerated() where index % 3 == 0 {
            step += 1
            let range = mark.ranges[0]
            let cleared: NSRange
            switch index % 4 {
            case 0: cleared = NSRange(location: range.location + range.length / 2, length: 0)
            case 1: cleared = NSRange(location: range.location, length: max(0, range.length / 2))
            case 2: cleared = range
            default: cleared = NSRange(location: max(0, range.location - 3), length: range.length + 6)
            }
            guard NSMaxRange(cleared) <= (text as NSString).length else { continue }
            review = review.clearing(cleared, in: text, at: date(step))
        }
        // A writer's edit carried, so some pieces are anchored in the text
        // before it and some in the text after.
        step += 1
        let last = writerTyping(text, &random)
        review = review.carryingWriterEdit(from: text, to: last, at: date(step))
        text = last
        if merging {
            review = renumbered(review)
            (review, text) = merged(review, text, &random, step: &step)
        }
        if renumbering { review = renumbered(review) }

        var stale = Seeded(seed ^ 0xA5A5)
        let ns = text as NSString
        let duplicated = text + "\n\n" + ns.substring(with: NSRange(location: ns.length / 2, length: min(400, ns.length / 2)))
        return Fixture(
            name: name, review: review, text: text,
            variants: [
                ("anchored", text),
                // Nothing in the record is anchored here.
                ("typed", writerTyping(text, &stale)),
                // Half a passage's context now stands twice.
                ("duplicated", duplicated),
                // Marked words rewritten, so some pieces are found by
                // their context alone and some not at all.
                ("rewritten", assistantTurn(text, &stale)),
            ]
        )
    }

    /// Two devices' copies merged: one cleared parts of some passages, and
    /// the other typed into the same passages twice, so its copy of each
    /// mark is the higher version and wins. What the first cleared is then
    /// taken out of marks that still hold it, which is the only place
    /// `located` subtracts anything: a clear made here has already
    /// rewritten the mark's own pieces.
    static func merged(
        _ review: LampWritingReview, _ text: String, _ random: inout Seeded, step: inout Int
    ) -> (LampWritingReview, String) {
        var clearing = review
        var typing = review
        var typed = text
        let targets = review.located(in: text).enumerated().filter { $0.offset % 3 == 1 }.map(\.element)
        for (index, mark) in targets.enumerated() {
            step += 1
            let range = mark.ranges[0]
            let cleared = index % 4 == 3
                ? NSRange(location: range.location, length: 0)
                : NSRange(location: range.location, length: range.length / 2)
            clearing = clearing.clearing(cleared, in: text, at: date(step))
        }
        for _ in 0..<2 {
            for mark in targets {
                guard let now = typing.located(in: typed).first(where: { $0.id == mark.id })?.ranges.last,
                      now.length > 1 else { continue }
                step += 1
                let ns = NSMutableString(string: typed)
                ns.insert(random.pick(vocabulary) + " ", at: boundary(near: now.location + now.length / 2, in: ns) + 1)
                let next = ns as String
                typing = typing.carryingWriterEdit(from: typed, to: next, at: date(step))
                typed = next
            }
        }
        // The merge orders by id, so the clears' new ids are numbered
        // first, or the order would be chance.
        return (renumbered(clearing).merged(with: typing), typed)
    }

    /// `review` with every id replaced by a numbered one, in the order the
    /// record first names it. An id already numbered keeps its number.
    static func renumbered(_ review: LampWritingReview) -> LampWritingReview {
        var order: [UUID] = []
        var seen = Set<UUID>()
        var taken = 0
        func note(_ id: UUID?) {
            guard let id, !seen.contains(id) else { return }
            seen.insert(id)
            if let number = number(of: id) { taken = max(taken, number) } else { order.append(id) }
        }
        for mark in review.marks { note(mark.id); note(mark.turnID) }
        for retired in review.retired { note(retired.id) }
        for clearance in review.clearances { note(clearance.id); note(clearance.markID) }
        for wording in review.wordings { note(wording.markID) }
        for restoration in review.restorations { note(restoration.markID) }
        for voided in review.voidedWordings { note(voided) }
        var json = String(decoding: try! review.encoded(), as: UTF8.self)
        for (index, old) in order.enumerated() {
            json = json.replacingOccurrences(of: old.uuidString, with: id(taken + index + 1).uuidString)
        }
        return try! LampWritingReview.decoded(from: Data(json.utf8))
    }

    static let numberedPrefix = "00000000-0000-4000-8000-"

    static func number(of id: UUID) -> Int? {
        id.uuidString.hasPrefix(numberedPrefix) ? Int(id.uuidString.suffix(12)) : nil
    }

    // MARK: Canonical dumps

    static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: [.caseInsensitive]
    )

    /// `text` with every id the fixture numbered named by its number, and
    /// every id made since named `new`: those are minted at random.
    static func canonicalIDs(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in uuidPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let uuid = ns.substring(with: match.range).uppercased()
            if uuid.hasPrefix(numberedPrefix) {
                result += "#" + String(Int(uuid.suffix(12))!)
            } else {
                result += "new"
            }
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }

    /// A record as its encoded bytes say it, canonically: ids named, and
    /// each list sorted by what its entries say, since `encoded()` sorts
    /// them by ids that are minted at random.
    static func dump(_ review: LampWritingReview) -> String {
        let object = try! JSONSerialization.jsonObject(with: try! review.encoded()) as! [String: Any]
        var lines: [String] = []
        for key in object.keys.sorted() {
            let value = object[key]!
            if let list = value as? [Any] {
                let entries = list.map { canonicalIDs(json($0)) }.sorted()
                lines.append("\(key): [\n" + entries.joined(separator: "\n") + "\n]")
            } else {
                lines.append("\(key): " + canonicalIDs(json(value)))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ value: Any) -> String {
        if let string = value as? String { return String(reflecting: string) }
        if let number = value as? NSNumber { return number.stringValue }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    static func dump(_ ranges: [NSRange]) -> String {
        ranges.map { "\($0.location)+\($0.length)" }.joined(separator: " ")
    }

    static func dump(_ located: [LampWritingReview.Located]) -> String {
        canonicalIDs(located.map { "\($0.id.uuidString): \(dump($0.ranges))" }.joined(separator: "\n"))
    }

    static func dump(_ restorable: [LampWritingReview.Restorable]) -> String {
        canonicalIDs(restorable.map {
            "\($0.markID.uuidString) \(dump([$0.range])) \(String(reflecting: $0.words)) -> \(String(reflecting: $0.restored)) unread:\($0.wasUnread)"
        }.joined(separator: "\n"))
    }

    static func dump(_ change: LampWritingReview.Change?) -> String {
        guard let change else { return "nil" }
        let ids = canonicalIDs(change.id).split(separator: ",").sorted().joined(separator: ",")
        return "[\(ids)] now:\(String(reflecting: change.now)) before:\(String(reflecting: change.before)) reason:\(String(reflecting: change.reason))"
    }

    static func dump(_ outcome: LampWritingReview.RestoreOutcome) -> String {
        switch outcome {
        case .nothingTouched: return "nothingTouched"
        case .notExact: return "notExact"
        case .notKept: return "notKept"
        case .plan(let plan):
            return "plan " + canonicalIDs(plan.edits.map {
                "\($0.markID.uuidString) \(dump([$0.range])) \(String(reflecting: $0.replacement)) for \(String(reflecting: $0.discarded)) unread:\($0.unread)"
            }.joined(separator: "; "))
        }
    }

    static func dump(_ drawing: LampWritingReview.Drawing) -> String {
        [
            "ranges: " + dump(drawing.ranges),
            "passages: \(drawing.passageCount)",
            "marked: " + String(reflecting: drawing.markedMarkdown),
            "restorable:\n" + dump(drawing.restorable),
            "changes:\n" + drawing.changes.map(dump).joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
