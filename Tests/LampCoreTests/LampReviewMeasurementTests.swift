import Darwin
import Foundation
import Testing
@testable import LampCore

/// R0 of `Documentation/ReviewMarksPerformancePlan.md`: what drawing,
/// clearing, carrying and restoring a writing's review marks cost, measured
/// the same way before and after each change.
///
/// Skipped unless `LAMP_REVIEW=1`. Run in Release, alone, on a quiet
/// machine (check the load average, and that no compiler is running):
///
///     LAMP_REVIEW=1 swift test -c release --filter LampReviewMeasurementTests
///
/// The record measured is a real writing's when `LAMP_REVIEW_RECORD` names
/// its marks file and `LAMP_REVIEW_TEXT` the text it is drawn in; those are
/// private, and stay outside the repository. Without them it is a synthetic
/// record of the same shape, built through the API (`ReviewFixtures`).
///
/// With `LAMP_REVIEW_HASHES` naming a file, the real record's answers are
/// hashed as the goldens hash theirs: written there if the file is missing,
/// and compared with it if not. That holds the private record to what the
/// code before the pass answered.
///
/// Every line of output begins `REVIEW`: the median wall time of five runs,
/// and the median instructions retired, which a loaded machine moves far
/// less. Nothing asserts a timing.
@Suite(.serialized)
struct LampReviewMeasurementTests {
    static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["LAMP_REVIEW"] == "1"
    }

    struct Case {
        let name: String
        let review: LampWritingReview
        let text: String
    }

    static func load() throws -> Case {
        let environment = ProcessInfo.processInfo.environment
        if let record = environment["LAMP_REVIEW_RECORD"], let textPath = environment["LAMP_REVIEW_TEXT"] {
            var text = try String(contentsOfFile: textPath, encoding: .utf8)
            if environment["LAMP_REVIEW_TEXT_KEEP_NEWLINE"] != "1", text.hasSuffix("\n") { text.removeLast() }
            let review = try LampWritingReview.decoded(from: Data(contentsOf: URL(fileURLWithPath: record)))
            return Case(name: "record", review: review, text: text)
        }
        let fixture = ReviewFixtures.build(
            name: "synthetic", seed: 3, units: 57_000, turns: 120, wordClears: 450, renumbering: false
        )
        // Drawn in a text it was never carried to, as a record is that
        // another device or a held copy last anchored.
        return Case(name: "synthetic", review: fixture.review, text: fixture.variants[1].text)
    }

    // MARK: Measuring

    static func instructions() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_instructions : 0
    }

    /// The median of five runs of `body`, after one to warm it.
    @discardableResult
    static func measure<T>(_ label: String, runs: Int = 5, _ body: () throws -> T) rethrows -> T {
        var result = try body()
        var times: [Double] = []
        var counts: [UInt64] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let before = instructions()
            let elapsed = try clock.measure { result = try body() }
            counts.append(instructions() &- before)
            times.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let ms = times.sorted()[runs / 2]
        let mega = Double(counts.sorted()[runs / 2]) / 1e6
        print("REVIEW \(label): \(String(format: "%.1f", ms)) ms, \(String(format: "%.0f", mega)) M instructions")
        return result
    }

    static func describe(_ c: Case) {
        let review = c.review
        let here = LampWritingReview.digest(of: c.text)
        let pieces = review.marks.flatMap(\.pieces) + review.clearances.flatMap(\.pieces)
        print("REVIEW \(c.name): \((c.text as NSString).length) units, \(review.marks.count) marks of \(review.marks.flatMap(\.pieces).count) pieces, \(review.clearances.count) clearances of \(review.clearances.flatMap(\.pieces).count) pieces, \(review.retired.count) retired, \(review.wordings.count) wordings; \(pieces.filter { $0.anchoredIn != here }.count) pieces anchored elsewhere")
    }

    /// The mark with the most pieces, and one with the fewest that is
    /// still drawn, where each stands.
    static func bigAndSmall(_ review: LampWritingReview, in text: String) -> (big: NSRange, small: NSRange)? {
        let located = review.located(in: text)
        let pieces = Dictionary(review.marks.map { ($0.id, $0.pieces.count) }, uniquingKeysWith: max)
        guard let big = located.max(by: { pieces[$0.id, default: 0] < pieces[$1.id, default: 0] }),
              let small = located.filter({ $0.ranges.count == 1 && $0.ranges[0].length > 3 })
                .min(by: { pieces[$0.id, default: 0] < pieces[$1.id, default: 0] })
        else { return nil }
        return (big.ranges[big.ranges.count / 2], small.ranges[0])
    }

    static func typing(_ word: String, at location: Int, in text: String) -> String {
        let ns = NSMutableString(string: text)
        ns.insert(word + " ", at: ReviewFixtures.boundary(near: location, in: ns) + 1)
        return ns as String
    }

    // MARK: Scenarios

    /// S1: one draw, and its stages, as the old probe timed them.
    @Test(.enabled(if: enabled())) func s1Drawing() throws {
        let c = try Self.load()
        Self.describe(c)
        let anchored = Self.measure("S1 anchored") { c.review.anchored(in: c.text) }
        let located = Self.measure("S1 located (anchored)") { anchored.located(in: c.text) }
        Self.measure("S1 located (unanchored)") { c.review.located(in: c.text) }
        let ranges = LampWritingReview.coalesced(located.flatMap(\.ranges), joiningAcross: nil)
        Self.measure("S1 restorable (anchored, finds again)") { anchored.restorable(in: c.text) }
        Self.measure("S1 changes (anchored, finds again)") { anchored.changes(in: c.text, ranges: ranges) }
        let marked = Self.measure("S1 markedMarkdown") { LampWritingReview.markedMarkdown(c.text, ranges: ranges) }
        Self.measure("S1 drawable") { LampWritingReviewMarkdown.drawable(marked ?? "") }
        Self.measure("S1 drawing") { c.review.drawing(in: c.text) }
        Self.measure("S1 drawing (not placing)") { c.review.drawing(in: c.text, forPlacing: false) }
        Self.measure("S1 passageCount (unanchored)") { c.review.passageCount(in: c.text) }
        #expect(!located.isEmpty)
    }

    /// S2: a draw after one word typed, a quarter of the way in, and inside
    /// the passage in the most pieces.
    @Test(.enabled(if: enabled())) func s2DrawAfterTyping() throws {
        let c = try Self.load()
        let length = (c.text as NSString).length
        let marks = try #require(Self.bigAndSmall(c.review, in: c.text))
        for (label, at) in [("at 25%", length / 4), ("in the big mark", marks.big.location)] {
            let typed = Self.typing("grace", at: at, in: c.text)
            let carried = Self.measure("S2 \(label): carry") { c.review.carryingToText(typed, from: [c.text]) }
            Self.measure("S2 \(label): draw") { carried.drawing(in: typed) }
        }
    }

    /// S3: a draw with 24 held texts, a word typed between each.
    @Test(.enabled(if: enabled())) func s3DrawWithHeldTexts() throws {
        let c = try Self.load()
        var random = ReviewFixtures.Seeded(24)
        var held = [c.text]
        for _ in 0..<24 { held.append(ReviewFixtures.writerTyping(held.last!, &random)) }
        let now = held.removeLast()
        let carried = Self.measure("S3 carry from 24") { c.review.carryingToText(now, from: held) }
        Self.measure("S3 draw") { carried.drawing(in: now) }
    }

    /// S4: a ✓ inside the passage in the most pieces, and on a small one,
    /// and the draw after each.
    @Test(.enabled(if: enabled())) func s4Clearing() throws {
        let c = try Self.load()
        let marks = try #require(Self.bigAndSmall(c.review, in: c.text))
        for (label, range) in [("big", marks.big), ("small", marks.small)] {
            let cleared = Self.measure("S4 \(label): clear") {
                c.review.clearing(range, in: c.text, carryingFrom: [])
            }
            Self.measure("S4 \(label): draw after") { cleared.drawing(in: c.text) }
            let block = LampWritingReviewMarkdown.wholeBlock(range, of: c.text)
            Self.measure("S4 \(label): wholeBlock") { LampWritingReviewMarkdown.wholeBlock(block, of: c.text) }
        }
    }

    /// S5: a save's carry, through the store, with its file and lock.
    @Test(.enabled(if: enabled())) func s5SaveCarry() throws {
        let c = try Self.load()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        try store.save(c.review)
        let saved = Self.typing("peace", at: (c.text as NSString).length / 2, in: c.text)
        try Self.measure("S5 save's carry") {
            try store.save(c.review)
            return try store.update(writingID: c.review.writingID, document: c.review.document) {
                $0.carryingToText(saved, from: [c.text])
            }
        }
        try Self.measure("S5 read") { try store.review(writingID: c.review.writingID, document: c.review.document) }
    }

    /// S6: restoring, by range and by marks.
    @Test(.enabled(if: enabled())) func s6Restoring() throws {
        let c = try Self.load()
        let offered = c.review.restorable(in: c.text)
        let range = try #require(offered.first?.range ?? Self.bigAndSmall(c.review, in: c.text)?.small)
        Self.measure("S6 restoring range") { c.review.restoring(range, in: c.text) }
        if let mark = offered.first?.markID {
            Self.measure("S6 restoring marks") { c.review.restoring(marks: [mark], in: c.text) }
        }
        let drawn = c.review.highlightedRanges(in: c.text)
        Self.measure("S6 restoring every drawn range") { c.review.restoring(drawn, in: c.text) }
    }

    /// The real record's answers, against those the code before the pass
    /// gave (`LAMP_REVIEW_HASHES`).
    @Test(.enabled(if: enabled() && ProcessInfo.processInfo.environment["LAMP_REVIEW_HASHES"] != nil))
    func theRecordAnswersAsItDid() throws {
        let c = try Self.load()
        // Numbered, so that the ids a clear mints, which differ every run,
        // can be told from the record's own.
        let fixture = ReviewFixtures.Fixture(name: c.name, review: ReviewFixtures.renumbered(c.review), text: c.text, variants: [
            ("as-drawn", c.text),
            ("typed", Self.typing("grace", at: (c.text as NSString).length / 4, in: c.text)),
        ])
        var lines: [String] = []
        for (name, dump) in LampWritingReviewGoldenTests.answers(fixture) {
            lines.append("\(name) \(ReviewFixtures.hash(dump))")
        }
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAMP_REVIEW_HASHES"]!)
        let now = lines.joined(separator: "\n") + "\n"
        if let before = try? String(contentsOf: file, encoding: .utf8) {
            let was = Set(before.split(separator: "\n").map(String.init))
            let moved = lines.filter { !was.contains($0) }
            print("REVIEW hashes: \(lines.count - moved.count) of \(lines.count) as before")
            #expect(moved.isEmpty, "answers that moved: \(moved.map { $0.split(separator: " ")[0] })")
        } else {
            try now.write(to: file, atomically: true, encoding: .utf8)
            print("REVIEW hashes: \(lines.count) written to \(file.path)")
        }
    }
}
