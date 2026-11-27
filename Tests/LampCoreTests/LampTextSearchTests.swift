import Foundation
import Testing
@testable import LampCore

/// `LampTextSearch.only` against the scan it replaced
/// (`LampWritingReviewReference.only`), answer for answer.
struct LampTextSearchTests {
    /// Texts whose units are hard on an index: surrogate pairs, combining
    /// marks, runs of one unit, and a passage standing twice.
    static let texts: [String] = [
        ReviewFixtures.text(seed: 5, units: 3_000),
        String(repeating: "aaaa ab", count: 200),
        "🙂🙂x🙂 cafe\u{301} café 光道光 " + String(repeating: "🙂a\u{301}", count: 50) + " 👨‍👩‍👧 end",
        "short",
        "",
    ]

    static func needles(in text: String, _ random: inout ReviewFixtures.Seeded) -> [String] {
        let ns = text as NSString
        var result = ["", "a", "ab", "abc", "abcd", "zzzzzzzz", "🙂", "\u{301}", "e\u{301}"]
        guard ns.length > 0 else { return result }
        for _ in 0..<300 {
            // Any unit, so needles start and end inside surrogate pairs and
            // before combining marks too.
            let start = random.below(ns.length)
            let length = 1 + random.below(min(48, ns.length - start))
            result.append(ns.substring(with: NSRange(location: start, length: length)))
        }
        return result
    }

    @Test func findsWhatTheScanFound() {
        var random = ReviewFixtures.Seeded(42)
        for text in Self.texts {
            let ns = text as NSString
            let search = LampTextSearch(ns)
            let unindexed = LampTextSearch(ns, indexing: false)
            for needle in Self.needles(in: text, &random) {
                let expected = LampWritingReviewReference.only(needle, in: ns)
                #expect(search.only(needle) == expected, "\(String(reflecting: needle)) in \(String(reflecting: text.prefix(20)))")
                #expect(unindexed.only(needle) == expected)
                // A condition that turns some copies away, as `find`'s
                // edges do.
                let even: (NSRange) -> Bool = { $0.location % 2 == 0 }
                #expect(search.only(needle, where: even) == LampWritingReviewReference.only(needle, in: ns, where: even),
                        "\(String(reflecting: needle)), even places")
            }
        }
    }

    /// Copies that overlap are each counted, as a scan from each match's
    /// next unit counts them.
    @Test func countsCopiesThatOverlap() {
        let search = LampTextSearch("xaaaaax" as NSString)
        #expect(search.only("aaaa") == nil)
        #expect(search.only("aaaa", where: { $0.location == 2 }) == NSRange(location: 2, length: 4))
        #expect(search.only("xaaaa") == NSRange(location: 0, length: 5))
    }

    /// The marks found through the shared search are those the reference
    /// `located` finds, in every fixture's every text.
    @Test func locatesWhatTheReferenceLocates() {
        for fixture in LampWritingReviewGoldenTests.fixtures {
            for (name, text) in fixture.variants {
                for strictly in [false, true] {
                    #expect(
                        fixture.review.located(in: text, strictly: strictly)
                            == LampWritingReviewReference.located(fixture.review, in: text, strictly: strictly),
                        "\(fixture.name)/\(name) strictly: \(strictly)"
                    )
                }
            }
        }
    }

    /// A piece kept with a space at its edge, which an older writer or
    /// another device can leave, and points cleared at that edge. The
    /// first clearance trims every range, so the order they come in
    /// decides whether a point at the space takes the piece: the skipped
    /// steps must keep that exactly.
    @Test func locatesUntrimmedPiecesAsTheReferenceDoes() {
        let text = "The lamp is a light unto my feet and a lamp unto my path."
        let ns = text as NSString
        let word = ns.range(of: " light")
        let far = ns.range(of: "path")
        let mark = LampWritingReview.Mark(
            id: ReviewFixtures.id(1),
            pieces: [LampWritingReview.piece(word, in: ns), LampWritingReview.piece(far, in: ns)],
            markedAt: ReviewFixtures.date(0), turnID: nil
        )
        func clearance(_ id: Int, _ range: NSRange) -> LampWritingReview.Clearance {
            LampWritingReview.Clearance(
                id: ReviewFixtures.id(id), markID: mark.id,
                pieces: [LampWritingReview.piece(range, in: ns)], clearedAt: ReviewFixtures.date(1)
            )
        }
        let atTheSpace = clearance(2, NSRange(location: word.location, length: 0))
        let elsewhere = clearance(3, ns.range(of: "feet"))
        let inside = clearance(4, NSRange(location: far.location + 1, length: 1))
        let orders = [
            [atTheSpace], [elsewhere, atTheSpace], [atTheSpace, elsewhere],
            [elsewhere, inside, atTheSpace], [inside, elsewhere], [elsewhere, elsewhere, inside],
        ]
        for order in orders {
            let review = LampWritingReview(writingID: "w", marks: [mark], clearances: order)
            #expect(review.located(in: text) == LampWritingReviewReference.located(review, in: text),
                    "\(order.map { ReviewFixtures.canonicalIDs($0.id.uuidString) })")
        }
        // The point at the space takes the piece only when it comes first.
        #expect(LampWritingReview(writingID: "w", marks: [mark], clearances: [atTheSpace]).located(in: text)
            .first?.ranges == [far])
        #expect(LampWritingReview(writingID: "w", marks: [mark], clearances: [elsewhere, atTheSpace]).located(in: text)
            .first?.ranges.count == 2)
    }
}
