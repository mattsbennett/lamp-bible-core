import Foundation
import Testing
@testable import LampCore

/// What the review record's drawing, finding, clearing, carrying and
/// restoring answer, frozen before `ReviewMarksPerformancePlan.md`'s
/// changes and held after them. Those changes are meant to make the same
/// answers faster, so any answer that moves is a defect in them.
///
/// Each answer is dumped canonically (`ReviewFixtures`) and hashed. The
/// hashes were taken from core `b714fa0`, the code before the pass. A
/// failure names each answer that moved; to see how, dump it from both
/// revisions with `LAMP_REVIEW_GOLDEN_DUMP=<folder>` and diff the folders.
///
/// Only a change meant to alter an answer may refreeze these, and its
/// decision record says which answers and why.
struct LampWritingReviewGoldenTests {
    static func built() -> [ReviewFixtures.Fixture] {
        [
            ReviewFixtures.build(name: "small", seed: 1, units: 2_500, turns: 6, wordClears: 12),
            ReviewFixtures.build(name: "worked", seed: 7, units: 6_000, turns: 18, wordClears: 40),
            ReviewFixtures.build(name: "merged", seed: 11, units: 5_000, turns: 14, wordClears: 30, merging: true),
        ]
    }

    static let fixtures = built()

    /// Every answer, by name.
    static func answers(_ fixture: ReviewFixtures.Fixture) -> [(name: String, dump: String)] {
        typealias F = ReviewFixtures
        let review = fixture.review
        var result: [(String, String)] = [("\(fixture.name)/record", F.dump(review))]
        for (variant, text) in fixture.variants {
            let key = "\(fixture.name)/\(variant)"
            let length = (text as NSString).length
            let located = review.located(in: text)
            result.append(("\(key)/located", F.dump(located)))
            result.append(("\(key)/located-strictly", F.dump(review.located(in: text, strictly: true))))
            result.append(("\(key)/anchored", F.dump(review.anchored(in: text))))
            result.append(("\(key)/drawing", F.dump(review.drawing(in: text))))
            result.append(("\(key)/drawing-unplaced", F.dump(review.drawing(in: text, forPlacing: false))))
            result.append(("\(key)/highlighted", F.dump(review.highlightedRanges(in: text))))
            result.append(("\(key)/passages", "\(review.passageCount(in: text))"))
            result.append(("\(key)/restorable", F.dump(review.restorable(in: text))))
            result.append(("\(key)/changes", review.changes(in: text, ranges: review.highlightedRanges(in: text)).map(F.dump).joined(separator: "\n")))
            if let marked = review.markedMarkdown(in: text) {
                result.append(("\(key)/drawable", LampWritingReviewMarkdown.drawable(marked)))
            }
            result.append(("\(key)/carried", F.dump(review.carryingToText(text, from: [fixture.text], at: F.date(50_000)))))
            result.append(("\(key)/carried-writer", F.dump(review.carryingWriterEdit(from: fixture.text, to: text, at: F.date(50_001)))))

            // Clears and restores of every shape: a passage's first range,
            // a caret inside the most broken passage, a stretch over two
            // passages, a whole block, and words nobody marked.
            let broken = located.max { $0.ranges.count < $1.ranges.count }
            var asked: [(String, NSRange)] = []
            if let first = located.first?.ranges.first { asked.append(("first", first)) }
            if let broken, let middle = broken.ranges.dropFirst(broken.ranges.count / 2).first {
                asked.append(("caret", NSRange(location: middle.location + middle.length / 2, length: 0)))
                asked.append(("piece", middle))
            }
            if located.count > 2 {
                let start = located[1].ranges[0].location
                let end = NSMaxRange(located[2].ranges.last!)
                asked.append(("across", NSRange(location: start, length: max(0, end - start))))
            }
            asked.append(("unmarked", NSRange(location: 0, length: min(3, length))))
            asked.append(("everything", NSRange(location: 0, length: length)))
            for (label, range) in asked where NSMaxRange(range) <= length {
                result.append(("\(key)/clear-\(label)", F.dump(review.clearing(range, in: text, at: F.date(60_000)))))
                result.append(("\(key)/clear-carrying-\(label)", F.dump(review.clearing(range, in: text, carryingFrom: [fixture.text], at: F.date(60_001)))))
                result.append(("\(key)/whole-block-\(label)", F.dump([LampWritingReviewMarkdown.wholeBlock(range, of: text)])))
                result.append(("\(key)/restore-\(label)", F.dump(review.restoring(range, in: text))))
            }
            let restores = review.restoring(asked.map(\.1).filter { NSMaxRange($0) <= length }, in: text)
            result.append(("\(key)/restore-ranges", restores.map {
                F.canonicalIDs($0.marks.map(\.uuidString).joined(separator: ",")) + " " + F.dump($0.outcome)
            }.joined(separator: "\n")))
            for (index, mark) in located.enumerated() where index % 5 == 0 {
                result.append(("\(key)/restore-mark-\(index)", F.dump(review.restoring(marks: [mark.id], in: text))))
            }
            if located.count > 1 {
                result.append(("\(key)/restore-marks-pair", F.dump(review.restoring(marks: [located[0].id, located[1].id], in: text))))
            }
        }
        return result
    }

    /// Ids are minted at random, so a fixture whose order depended on them
    /// would differ from one build to the next.
    @Test func theFixturesAreTheSameEveryTimeTheyAreBuilt() {
        for (again, first) in zip(Self.built(), Self.fixtures) {
            #expect(ReviewFixtures.dump(again.review) == ReviewFixtures.dump(first.review), "\(first.name)")
            #expect(again.variants.map(\.text) == first.variants.map(\.text), "\(first.name)")
        }
    }

    /// The fixtures reach what they are for: stale pieces, a passage in
    /// many pieces, clearances, wordings, and answers of every kind.
    @Test func theFixturesReachEveryReading() {
        let worked = Self.fixtures[1]
        let review = worked.review
        #expect(review.marks.count > 20)
        #expect(review.clearances.count > 30)
        #expect(review.marks.contains { $0.pieces.count > 10 })
        #expect(!review.wordings.isEmpty)
        #expect(!review.retired.isEmpty)
        let typed = worked.variants.first { $0.name == "typed" }!.text
        let here = LampWritingReview.digest(of: typed)
        #expect(review.marks.allSatisfy { $0.pieces.allSatisfy { $0.anchoredIn != here } })
        let answers = Self.answers(worked).map(\.dump).joined()
        #expect(answers.contains("plan "))
        #expect(answers.contains("notExact") || answers.contains("notKept"))
    }

    @Test func everyAnswerIsWhatItWas() throws {
        var hashes: [String: String] = [:]
        for fixture in Self.fixtures {
            for (name, dump) in Self.answers(fixture) {
                #expect(hashes[name] == nil, "\(name) is named twice")
                hashes[name] = ReviewFixtures.hash(dump)
                if let folder = ProcessInfo.processInfo.environment["LAMP_REVIEW_GOLDEN_DUMP"] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(name.replacingOccurrences(of: "/", with: "_") + ".txt")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try dump.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        if ProcessInfo.processInfo.environment["LAMP_REVIEW_GOLDEN_PRINT"] == "1" {
            for name in hashes.keys.sorted() { print("GOLDEN \"\(name)\": \"\(hashes[name]!)\",") }
        }
        let moved = Self.expected.keys.sorted().filter { hashes[$0] != Self.expected[$0] }
        let unfrozen = hashes.keys.sorted().filter { Self.expected[$0] == nil }
        #expect(moved.isEmpty, "answers that moved: \(moved)")
        #expect(unfrozen.isEmpty, "answers with no frozen hash: \(unfrozen)")
    }

    static let expected: [String: String] = [
        "merged/anchored/anchored": "5cc276d485a39298",
        "merged/anchored/carried-writer": "fbd0b784d90fc49b",
        "merged/anchored/carried": "52e2a948708bb95a",
        "merged/anchored/changes": "80334a6e71ab94ce",
        "merged/anchored/clear-across": "d9f427b8c9aae689",
        "merged/anchored/clear-caret": "66892552cfb6b4aa",
        "merged/anchored/clear-carrying-across": "19be87eb5da5eaaa",
        "merged/anchored/clear-carrying-caret": "401487cccb97eea8",
        "merged/anchored/clear-carrying-everything": "afdb8eec711270cb",
        "merged/anchored/clear-carrying-first": "fd8576eb25cf9db9",
        "merged/anchored/clear-carrying-piece": "3853f5d9c734d437",
        "merged/anchored/clear-carrying-unmarked": "fbd0b784d90fc49b",
        "merged/anchored/clear-everything": "454504d1945afa9b",
        "merged/anchored/clear-first": "6e07c6fa8763a9a6",
        "merged/anchored/clear-piece": "d608723132a225fd",
        "merged/anchored/clear-unmarked": "52e2a948708bb95a",
        "merged/anchored/drawable": "cd3eb907b2c6c031",
        "merged/anchored/drawing-unplaced": "6b8e7eaf581b1248",
        "merged/anchored/drawing": "fc81e6dcda4c303a",
        "merged/anchored/highlighted": "15dbc8990e850923",
        "merged/anchored/located-strictly": "21e64e245a38da26",
        "merged/anchored/located": "a70f38e14c954df3",
        "merged/anchored/passages": "2fca346db6561871",
        "merged/anchored/restorable": "40b12d2412640217",
        "merged/anchored/restore-across": "395b9e027a4cc401",
        "merged/anchored/restore-caret": "395b9e027a4cc401",
        "merged/anchored/restore-everything": "395b9e027a4cc401",
        "merged/anchored/restore-first": "5207062d0b94c4e1",
        "merged/anchored/restore-mark-0": "5207062d0b94c4e1",
        "merged/anchored/restore-mark-10": "faf5e47854a5e206",
        "merged/anchored/restore-mark-15": "395b9e027a4cc401",
        "merged/anchored/restore-mark-5": "f88c6e5ee36ccf00",
        "merged/anchored/restore-marks-pair": "395b9e027a4cc401",
        "merged/anchored/restore-piece": "395b9e027a4cc401",
        "merged/anchored/restore-ranges": "4a7e17d0adec16e5",
        "merged/anchored/restore-unmarked": "12b592998ce0cbff",
        "merged/anchored/whole-block-across": "ae542296cf2f4f37",
        "merged/anchored/whole-block-caret": "64e21b9ac68c45b2",
        "merged/anchored/whole-block-everything": "81e74444ee6bc3fa",
        "merged/anchored/whole-block-first": "518adce35c60ffbd",
        "merged/anchored/whole-block-piece": "e62cdf4692a3099c",
        "merged/anchored/whole-block-unmarked": "252d65014d4ad038",
        "merged/duplicated/anchored": "0b67b6b9f8da9ffd",
        "merged/duplicated/carried-writer": "1a28e7f83d74df26",
        "merged/duplicated/carried": "1a28e7f83d74df26",
        "merged/duplicated/changes": "d5f8c13543e17714",
        "merged/duplicated/clear-across": "d9f427b8c9aae689",
        "merged/duplicated/clear-caret": "47e6faf9fc985d02",
        "merged/duplicated/clear-carrying-across": "19be87eb5da5eaaa",
        "merged/duplicated/clear-carrying-caret": "237aeea3f8ebb87b",
        "merged/duplicated/clear-carrying-everything": "afdb8eec711270cb",
        "merged/duplicated/clear-carrying-first": "fd8576eb25cf9db9",
        "merged/duplicated/clear-carrying-piece": "c83a682e94b6aca8",
        "merged/duplicated/clear-carrying-unmarked": "fbd0b784d90fc49b",
        "merged/duplicated/clear-everything": "454504d1945afa9b",
        "merged/duplicated/clear-first": "6e07c6fa8763a9a6",
        "merged/duplicated/clear-piece": "d50430cef0d03d65",
        "merged/duplicated/clear-unmarked": "52e2a948708bb95a",
        "merged/duplicated/drawable": "2b0779b84034b413",
        "merged/duplicated/drawing-unplaced": "a0de10b3c674bbae",
        "merged/duplicated/drawing": "e31b225c2127d02b",
        "merged/duplicated/highlighted": "63b49345e2ad4e77",
        "merged/duplicated/located-strictly": "d66fd3f146e77dde",
        "merged/duplicated/located": "551eda99576c7453",
        "merged/duplicated/passages": "44cb730c420480a0",
        "merged/duplicated/restorable": "40b12d2412640217",
        "merged/duplicated/restore-across": "395b9e027a4cc401",
        "merged/duplicated/restore-caret": "395b9e027a4cc401",
        "merged/duplicated/restore-everything": "395b9e027a4cc401",
        "merged/duplicated/restore-first": "5207062d0b94c4e1",
        "merged/duplicated/restore-mark-0": "5207062d0b94c4e1",
        "merged/duplicated/restore-mark-10": "faf5e47854a5e206",
        "merged/duplicated/restore-mark-15": "395b9e027a4cc401",
        "merged/duplicated/restore-mark-5": "f88c6e5ee36ccf00",
        "merged/duplicated/restore-marks-pair": "395b9e027a4cc401",
        "merged/duplicated/restore-piece": "395b9e027a4cc401",
        "merged/duplicated/restore-ranges": "4a7e17d0adec16e5",
        "merged/duplicated/restore-unmarked": "12b592998ce0cbff",
        "merged/duplicated/whole-block-across": "ae542296cf2f4f37",
        "merged/duplicated/whole-block-caret": "8eb6b2cfaca810cd",
        "merged/duplicated/whole-block-everything": "d895c2985d417159",
        "merged/duplicated/whole-block-first": "518adce35c60ffbd",
        "merged/duplicated/whole-block-piece": "80b0318a1efa6689",
        "merged/duplicated/whole-block-unmarked": "252d65014d4ad038",
        "merged/record": "fbd0b784d90fc49b",
        "merged/rewritten/anchored": "7d2d7b645958dcd1",
        "merged/rewritten/carried-writer": "1f7a69739c60ac68",
        "merged/rewritten/carried": "1f7a69739c60ac68",
        "merged/rewritten/changes": "090b3577b11713a8",
        "merged/rewritten/clear-across": "d9f427b8c9aae689",
        "merged/rewritten/clear-caret": "0d9de2fc361f7f3b",
        "merged/rewritten/clear-carrying-across": "19be87eb5da5eaaa",
        "merged/rewritten/clear-carrying-caret": "9dab256107fba5c5",
        "merged/rewritten/clear-carrying-everything": "afdb8eec711270cb",
        "merged/rewritten/clear-carrying-first": "fd8576eb25cf9db9",
        "merged/rewritten/clear-carrying-piece": "4f6a96ad35ff06a0",
        "merged/rewritten/clear-carrying-unmarked": "fbd0b784d90fc49b",
        "merged/rewritten/clear-everything": "454504d1945afa9b",
        "merged/rewritten/clear-first": "6e07c6fa8763a9a6",
        "merged/rewritten/clear-piece": "998d1ef590aacaff",
        "merged/rewritten/clear-unmarked": "52e2a948708bb95a",
        "merged/rewritten/drawable": "8f8242a3d45b92b5",
        "merged/rewritten/drawing-unplaced": "840ebd937383e236",
        "merged/rewritten/drawing": "ed28338c60650bd0",
        "merged/rewritten/highlighted": "9193ca76a87cfde2",
        "merged/rewritten/located-strictly": "723e1b5cb54aa38d",
        "merged/rewritten/located": "5646fa952f2fed26",
        "merged/rewritten/passages": "73475cb40a568e8d",
        "merged/rewritten/restorable": "1a49dbe47bac2157",
        "merged/rewritten/restore-across": "395b9e027a4cc401",
        "merged/rewritten/restore-caret": "395b9e027a4cc401",
        "merged/rewritten/restore-everything": "395b9e027a4cc401",
        "merged/rewritten/restore-first": "5207062d0b94c4e1",
        "merged/rewritten/restore-mark-0": "5207062d0b94c4e1",
        "merged/rewritten/restore-mark-10": "58b9517d1289a4d4",
        "merged/rewritten/restore-mark-15": "395b9e027a4cc401",
        "merged/rewritten/restore-mark-5": "e27c7723897e779d",
        "merged/rewritten/restore-marks-pair": "395b9e027a4cc401",
        "merged/rewritten/restore-piece": "395b9e027a4cc401",
        "merged/rewritten/restore-ranges": "4a7e17d0adec16e5",
        "merged/rewritten/restore-unmarked": "12b592998ce0cbff",
        "merged/rewritten/whole-block-across": "ae542296cf2f4f37",
        "merged/rewritten/whole-block-caret": "1240704321ba7e33",
        "merged/rewritten/whole-block-everything": "78ebe0e9940930c0",
        "merged/rewritten/whole-block-first": "518adce35c60ffbd",
        "merged/rewritten/whole-block-piece": "ecbcaa914a559fd9",
        "merged/rewritten/whole-block-unmarked": "252d65014d4ad038",
        "merged/typed/anchored": "c2359cabe39d70d2",
        "merged/typed/carried-writer": "165e3f5af9bb27a5",
        "merged/typed/carried": "165e3f5af9bb27a5",
        "merged/typed/changes": "d5f8c13543e17714",
        "merged/typed/clear-across": "d9f427b8c9aae689",
        "merged/typed/clear-caret": "551db875c4c8f7d8",
        "merged/typed/clear-carrying-across": "19be87eb5da5eaaa",
        "merged/typed/clear-carrying-caret": "7485dcb19596edd5",
        "merged/typed/clear-carrying-everything": "afdb8eec711270cb",
        "merged/typed/clear-carrying-first": "fd8576eb25cf9db9",
        "merged/typed/clear-carrying-piece": "ed44d40742abc0a5",
        "merged/typed/clear-carrying-unmarked": "fbd0b784d90fc49b",
        "merged/typed/clear-everything": "454504d1945afa9b",
        "merged/typed/clear-first": "6e07c6fa8763a9a6",
        "merged/typed/clear-piece": "bd770c54385136cb",
        "merged/typed/clear-unmarked": "52e2a948708bb95a",
        "merged/typed/drawable": "9820d8a0111325f8",
        "merged/typed/drawing-unplaced": "f2aed20da998d776",
        "merged/typed/drawing": "a2f3ded698198919",
        "merged/typed/highlighted": "8f54b6e51c4d8da4",
        "merged/typed/located-strictly": "30e9ec5ab3f41b55",
        "merged/typed/located": "8d2714525b8d1676",
        "merged/typed/passages": "44cb730c420480a0",
        "merged/typed/restorable": "6d6186874e9f33c4",
        "merged/typed/restore-across": "395b9e027a4cc401",
        "merged/typed/restore-caret": "395b9e027a4cc401",
        "merged/typed/restore-everything": "395b9e027a4cc401",
        "merged/typed/restore-first": "5207062d0b94c4e1",
        "merged/typed/restore-mark-0": "5207062d0b94c4e1",
        "merged/typed/restore-mark-10": "faf5e47854a5e206",
        "merged/typed/restore-mark-15": "395b9e027a4cc401",
        "merged/typed/restore-mark-5": "f88c6e5ee36ccf00",
        "merged/typed/restore-marks-pair": "395b9e027a4cc401",
        "merged/typed/restore-piece": "395b9e027a4cc401",
        "merged/typed/restore-ranges": "4a7e17d0adec16e5",
        "merged/typed/restore-unmarked": "12b592998ce0cbff",
        "merged/typed/whole-block-across": "ae542296cf2f4f37",
        "merged/typed/whole-block-caret": "8eb6b2cfaca810cd",
        "merged/typed/whole-block-everything": "8744b37bd45f5e3d",
        "merged/typed/whole-block-first": "518adce35c60ffbd",
        "merged/typed/whole-block-piece": "80b0318a1efa6689",
        "merged/typed/whole-block-unmarked": "252d65014d4ad038",
        "small/anchored/anchored": "714dccd63ba4ec03",
        "small/anchored/carried-writer": "a9cac34ec91fa56c",
        "small/anchored/carried": "a9cac34ec91fa56c",
        "small/anchored/changes": "43ec48899ab00119",
        "small/anchored/clear-across": "9ecf321cda5d1e69",
        "small/anchored/clear-caret": "737558e82ee0ab6c",
        "small/anchored/clear-carrying-across": "f90fe89ff24bf1dd",
        "small/anchored/clear-carrying-caret": "1e995cee82235e3d",
        "small/anchored/clear-carrying-everything": "017eb61981858dee",
        "small/anchored/clear-carrying-first": "2e93cce35130d268",
        "small/anchored/clear-carrying-piece": "007e18780c845dde",
        "small/anchored/clear-carrying-unmarked": "a9cac34ec91fa56c",
        "small/anchored/clear-everything": "e37129c9f4e992cc",
        "small/anchored/clear-first": "287c63d94c3c623b",
        "small/anchored/clear-piece": "e36e01e82b8be9d7",
        "small/anchored/clear-unmarked": "a9cac34ec91fa56c",
        "small/anchored/drawable": "e2417fdd27bb9695",
        "small/anchored/drawing-unplaced": "a78292e5ad53bf9c",
        "small/anchored/drawing": "00be153d4894896c",
        "small/anchored/highlighted": "1a0356c515232af6",
        "small/anchored/located-strictly": "bb63452e1109ac09",
        "small/anchored/located": "bb63452e1109ac09",
        "small/anchored/passages": "9400f1b21cb527d7",
        "small/anchored/restorable": "a2cb5533cafb900a",
        "small/anchored/restore-across": "77b9378a0f4509be",
        "small/anchored/restore-caret": "395b9e027a4cc401",
        "small/anchored/restore-everything": "395b9e027a4cc401",
        "small/anchored/restore-first": "395b9e027a4cc401",
        "small/anchored/restore-mark-0": "395b9e027a4cc401",
        "small/anchored/restore-mark-5": "1748bb4322c74bcc",
        "small/anchored/restore-marks-pair": "395b9e027a4cc401",
        "small/anchored/restore-piece": "395b9e027a4cc401",
        "small/anchored/restore-ranges": "10b6fb38bcbe52a9",
        "small/anchored/restore-unmarked": "12b592998ce0cbff",
        "small/anchored/whole-block-across": "628a38234f66143c",
        "small/anchored/whole-block-caret": "da98ec3f35783bbb",
        "small/anchored/whole-block-everything": "c11a4c53849da882",
        "small/anchored/whole-block-first": "20ea1e3ea0cb585e",
        "small/anchored/whole-block-piece": "748dbe8272906d7b",
        "small/anchored/whole-block-unmarked": "252d65014d4ad038",
        "small/duplicated/anchored": "6e070592b33341e9",
        "small/duplicated/carried-writer": "e2c17f2f9b7a5efc",
        "small/duplicated/carried": "e2c17f2f9b7a5efc",
        "small/duplicated/changes": "e6729b99bd830651",
        "small/duplicated/clear-across": "24d4237e96b9f6b3",
        "small/duplicated/clear-caret": "b62712b276a867b0",
        "small/duplicated/clear-carrying-across": "9e5da9adb70a2d2d",
        "small/duplicated/clear-carrying-caret": "e9613617933cc38b",
        "small/duplicated/clear-carrying-everything": "017eb61981858dee",
        "small/duplicated/clear-carrying-first": "b45de75cb1aebf9c",
        "small/duplicated/clear-carrying-piece": "ba1cdad03557e99f",
        "small/duplicated/clear-carrying-unmarked": "a9cac34ec91fa56c",
        "small/duplicated/clear-everything": "3db89940d9fab059",
        "small/duplicated/clear-first": "6ec1b91198142a27",
        "small/duplicated/clear-piece": "7396f487e475ffb2",
        "small/duplicated/clear-unmarked": "a9cac34ec91fa56c",
        "small/duplicated/drawable": "b91b74f142223c0e",
        "small/duplicated/drawing-unplaced": "c9d7b58d3e206b17",
        "small/duplicated/drawing": "40ffdbaeb11dd112",
        "small/duplicated/highlighted": "6438d6c124e3ac23",
        "small/duplicated/located-strictly": "442c51d8037e3f9d",
        "small/duplicated/located": "442c51d8037e3f9d",
        "small/duplicated/passages": "4523540f1504cd17",
        "small/duplicated/restorable": "5d131aa0b772ad1e",
        "small/duplicated/restore-across": "e2511a4760c549c3",
        "small/duplicated/restore-caret": "395b9e027a4cc401",
        "small/duplicated/restore-everything": "395b9e027a4cc401",
        "small/duplicated/restore-first": "395b9e027a4cc401",
        "small/duplicated/restore-mark-0": "395b9e027a4cc401",
        "small/duplicated/restore-marks-pair": "395b9e027a4cc401",
        "small/duplicated/restore-piece": "395b9e027a4cc401",
        "small/duplicated/restore-ranges": "ba99680dbdb55625",
        "small/duplicated/restore-unmarked": "12b592998ce0cbff",
        "small/duplicated/whole-block-across": "2369557590d7477b",
        "small/duplicated/whole-block-caret": "da98ec3f35783bbb",
        "small/duplicated/whole-block-everything": "a226ca21665e013a",
        "small/duplicated/whole-block-first": "20ea1e3ea0cb585e",
        "small/duplicated/whole-block-piece": "748dbe8272906d7b",
        "small/duplicated/whole-block-unmarked": "252d65014d4ad038",
        "small/record": "a9cac34ec91fa56c",
        "small/rewritten/anchored": "f2f9e92e588103d3",
        "small/rewritten/carried-writer": "0a828b2fd9d48f82",
        "small/rewritten/carried": "0a828b2fd9d48f82",
        "small/rewritten/changes": "43ec48899ab00119",
        "small/rewritten/clear-across": "9ecf321cda5d1e69",
        "small/rewritten/clear-caret": "b4252fff93d8b414",
        "small/rewritten/clear-carrying-across": "f90fe89ff24bf1dd",
        "small/rewritten/clear-carrying-caret": "141a2a8a3d85d79d",
        "small/rewritten/clear-carrying-everything": "017eb61981858dee",
        "small/rewritten/clear-carrying-first": "b362c33c75395931",
        "small/rewritten/clear-carrying-piece": "f9467f942d33cef3",
        "small/rewritten/clear-carrying-unmarked": "a9cac34ec91fa56c",
        "small/rewritten/clear-everything": "e37129c9f4e992cc",
        "small/rewritten/clear-first": "9f67d8ed43322e66",
        "small/rewritten/clear-piece": "8092b808243f21a2",
        "small/rewritten/clear-unmarked": "a9cac34ec91fa56c",
        "small/rewritten/drawable": "717c78ca98e862f9",
        "small/rewritten/drawing-unplaced": "af6ac5ec65fa4b08",
        "small/rewritten/drawing": "2e6d7721a96bf64e",
        "small/rewritten/highlighted": "6645ba2f37587b6f",
        "small/rewritten/located-strictly": "fb3141d03abe5d97",
        "small/rewritten/located": "fb3141d03abe5d97",
        "small/rewritten/passages": "9400f1b21cb527d7",
        "small/rewritten/restorable": "24101e1b7f0a1876",
        "small/rewritten/restore-across": "13144b6e543377ec",
        "small/rewritten/restore-caret": "395b9e027a4cc401",
        "small/rewritten/restore-everything": "395b9e027a4cc401",
        "small/rewritten/restore-first": "395b9e027a4cc401",
        "small/rewritten/restore-mark-0": "395b9e027a4cc401",
        "small/rewritten/restore-mark-5": "a5e00e5464ed2ed8",
        "small/rewritten/restore-marks-pair": "395b9e027a4cc401",
        "small/rewritten/restore-piece": "395b9e027a4cc401",
        "small/rewritten/restore-ranges": "5d950256c8029a7b",
        "small/rewritten/restore-unmarked": "12b592998ce0cbff",
        "small/rewritten/whole-block-across": "2a9e797b055f8b05",
        "small/rewritten/whole-block-caret": "da98ec3f35783bbb",
        "small/rewritten/whole-block-everything": "074b993daaf32992",
        "small/rewritten/whole-block-first": "20ea1e3ea0cb585e",
        "small/rewritten/whole-block-piece": "748dbe8272906d7b",
        "small/rewritten/whole-block-unmarked": "252d65014d4ad038",
        "small/typed/anchored": "5cef8e1fbd43be71",
        "small/typed/carried-writer": "eb03872cbc9112e2",
        "small/typed/carried": "eb03872cbc9112e2",
        "small/typed/changes": "43ec48899ab00119",
        "small/typed/clear-across": "9ecf321cda5d1e69",
        "small/typed/clear-caret": "ffbba48e240971d6",
        "small/typed/clear-carrying-across": "f90fe89ff24bf1dd",
        "small/typed/clear-carrying-caret": "25e8e7238b36d5c7",
        "small/typed/clear-carrying-everything": "017eb61981858dee",
        "small/typed/clear-carrying-first": "717b77fff470e65e",
        "small/typed/clear-carrying-piece": "3c02262e40063071",
        "small/typed/clear-carrying-unmarked": "a9cac34ec91fa56c",
        "small/typed/clear-everything": "e37129c9f4e992cc",
        "small/typed/clear-first": "2959d3b3aaa532be",
        "small/typed/clear-piece": "f5d2f7b19bd767fa",
        "small/typed/clear-unmarked": "a9cac34ec91fa56c",
        "small/typed/drawable": "cffa4b4007bbc8d2",
        "small/typed/drawing-unplaced": "4341d9c2d7bff401",
        "small/typed/drawing": "7b6aef4310a75879",
        "small/typed/highlighted": "356aeac1e4ad22a1",
        "small/typed/located-strictly": "824580b8106cd053",
        "small/typed/located": "824580b8106cd053",
        "small/typed/passages": "9400f1b21cb527d7",
        "small/typed/restorable": "33222b82edf83b92",
        "small/typed/restore-across": "20a1d4bdfa62b973",
        "small/typed/restore-caret": "395b9e027a4cc401",
        "small/typed/restore-everything": "395b9e027a4cc401",
        "small/typed/restore-first": "395b9e027a4cc401",
        "small/typed/restore-mark-0": "395b9e027a4cc401",
        "small/typed/restore-mark-5": "f634c37503b33fcd",
        "small/typed/restore-marks-pair": "395b9e027a4cc401",
        "small/typed/restore-piece": "395b9e027a4cc401",
        "small/typed/restore-ranges": "1e096c4f3b291f77",
        "small/typed/restore-unmarked": "12b592998ce0cbff",
        "small/typed/whole-block-across": "e6b6a5ea9a030e28",
        "small/typed/whole-block-caret": "da98ec3f35783bbb",
        "small/typed/whole-block-everything": "c1bd055f55f3a236",
        "small/typed/whole-block-first": "20ea1e3ea0cb585e",
        "small/typed/whole-block-piece": "748dbe8272906d7b",
        "small/typed/whole-block-unmarked": "252d65014d4ad038",
        "worked/anchored/anchored": "5597ea0f72aba339",
        "worked/anchored/carried-writer": "f26737e6dacc1c3f",
        "worked/anchored/carried": "f26737e6dacc1c3f",
        "worked/anchored/changes": "0f05a18339f575f8",
        "worked/anchored/clear-across": "18166d5c1b023fd2",
        "worked/anchored/clear-caret": "eb8cb9bf73296121",
        "worked/anchored/clear-carrying-across": "b03336a1d6a3f587",
        "worked/anchored/clear-carrying-caret": "2098d58928b56dbc",
        "worked/anchored/clear-carrying-everything": "26117fdf77b0b600",
        "worked/anchored/clear-carrying-first": "05e55d1b7260e06f",
        "worked/anchored/clear-carrying-piece": "2f0ad262cb2185ca",
        "worked/anchored/clear-carrying-unmarked": "f26737e6dacc1c3f",
        "worked/anchored/clear-everything": "b5f118b02f9a47a9",
        "worked/anchored/clear-first": "43f38a2151607742",
        "worked/anchored/clear-piece": "96f691d362d344be",
        "worked/anchored/clear-unmarked": "f26737e6dacc1c3f",
        "worked/anchored/drawable": "17eaeac1c7511baa",
        "worked/anchored/drawing-unplaced": "3c8f19afb0a16a2d",
        "worked/anchored/drawing": "44dd68de8d394d4c",
        "worked/anchored/highlighted": "c9a175200878cd3d",
        "worked/anchored/located-strictly": "668aa7ee5b5cf3b5",
        "worked/anchored/located": "668aa7ee5b5cf3b5",
        "worked/anchored/passages": "3e1e967e9b793e90",
        "worked/anchored/restorable": "14ff5740b94c57ef",
        "worked/anchored/restore-across": "98c0f7573ab4c86b",
        "worked/anchored/restore-caret": "395b9e027a4cc401",
        "worked/anchored/restore-everything": "395b9e027a4cc401",
        "worked/anchored/restore-first": "1c0d3796ed291ba1",
        "worked/anchored/restore-mark-0": "1c0d3796ed291ba1",
        "worked/anchored/restore-mark-10": "395b9e027a4cc401",
        "worked/anchored/restore-mark-15": "ace73a7d3ee2d533",
        "worked/anchored/restore-mark-20": "ffda6491b0a8f80b",
        "worked/anchored/restore-mark-5": "395b9e027a4cc401",
        "worked/anchored/restore-marks-pair": "914f857ad283610b",
        "worked/anchored/restore-piece": "395b9e027a4cc401",
        "worked/anchored/restore-ranges": "b998012e6462682b",
        "worked/anchored/restore-unmarked": "12b592998ce0cbff",
        "worked/anchored/whole-block-across": "8f61149e06e2d8ec",
        "worked/anchored/whole-block-caret": "098de50af39f6741",
        "worked/anchored/whole-block-everything": "97839ccb3a3d88d3",
        "worked/anchored/whole-block-first": "9174fe4d044748cc",
        "worked/anchored/whole-block-piece": "ce7484dc4c6d4e47",
        "worked/anchored/whole-block-unmarked": "252d65014d4ad038",
        "worked/duplicated/anchored": "79eb8d913145baa8",
        "worked/duplicated/carried-writer": "21842a7ea41af10e",
        "worked/duplicated/carried": "21842a7ea41af10e",
        "worked/duplicated/changes": "76f6201c34c4c0f3",
        "worked/duplicated/clear-across": "18166d5c1b023fd2",
        "worked/duplicated/clear-caret": "641e8dd4a707c77d",
        "worked/duplicated/clear-carrying-across": "b03336a1d6a3f587",
        "worked/duplicated/clear-carrying-caret": "fd16a20728e7d364",
        "worked/duplicated/clear-carrying-everything": "26117fdf77b0b600",
        "worked/duplicated/clear-carrying-first": "05e55d1b7260e06f",
        "worked/duplicated/clear-carrying-piece": "c166dfc4fade8255",
        "worked/duplicated/clear-carrying-unmarked": "f26737e6dacc1c3f",
        "worked/duplicated/clear-everything": "b5f118b02f9a47a9",
        "worked/duplicated/clear-first": "43f38a2151607742",
        "worked/duplicated/clear-piece": "8aff9d471dde8368",
        "worked/duplicated/clear-unmarked": "f26737e6dacc1c3f",
        "worked/duplicated/drawable": "e6d9e5646b80451a",
        "worked/duplicated/drawing-unplaced": "dd1082f86021186b",
        "worked/duplicated/drawing": "9c0ff99e65676f2f",
        "worked/duplicated/highlighted": "b6493c4efde685bb",
        "worked/duplicated/located-strictly": "1443864184ec5dd8",
        "worked/duplicated/located": "1443864184ec5dd8",
        "worked/duplicated/passages": "02d20bbd7e394ad5",
        "worked/duplicated/restorable": "14ff5740b94c57ef",
        "worked/duplicated/restore-across": "98c0f7573ab4c86b",
        "worked/duplicated/restore-caret": "395b9e027a4cc401",
        "worked/duplicated/restore-everything": "395b9e027a4cc401",
        "worked/duplicated/restore-first": "1c0d3796ed291ba1",
        "worked/duplicated/restore-mark-0": "1c0d3796ed291ba1",
        "worked/duplicated/restore-mark-10": "395b9e027a4cc401",
        "worked/duplicated/restore-mark-15": "ace73a7d3ee2d533",
        "worked/duplicated/restore-mark-20": "ffda6491b0a8f80b",
        "worked/duplicated/restore-mark-5": "395b9e027a4cc401",
        "worked/duplicated/restore-marks-pair": "914f857ad283610b",
        "worked/duplicated/restore-piece": "395b9e027a4cc401",
        "worked/duplicated/restore-ranges": "b998012e6462682b",
        "worked/duplicated/restore-unmarked": "12b592998ce0cbff",
        "worked/duplicated/whole-block-across": "8f61149e06e2d8ec",
        "worked/duplicated/whole-block-caret": "6fe903d9ecad4688",
        "worked/duplicated/whole-block-everything": "3dcae3e6a42e905b",
        "worked/duplicated/whole-block-first": "9174fe4d044748cc",
        "worked/duplicated/whole-block-piece": "02b81782d30cd48e",
        "worked/duplicated/whole-block-unmarked": "252d65014d4ad038",
        "worked/record": "f26737e6dacc1c3f",
        "worked/rewritten/anchored": "ca7a54b6b51376c3",
        "worked/rewritten/carried-writer": "75445be620965afb",
        "worked/rewritten/carried": "75445be620965afb",
        "worked/rewritten/changes": "76f6201c34c4c0f3",
        "worked/rewritten/clear-across": "18166d5c1b023fd2",
        "worked/rewritten/clear-caret": "4de632005dff6857",
        "worked/rewritten/clear-carrying-across": "b03336a1d6a3f587",
        "worked/rewritten/clear-carrying-caret": "27241a69d3997ee7",
        "worked/rewritten/clear-carrying-everything": "26117fdf77b0b600",
        "worked/rewritten/clear-carrying-first": "05e55d1b7260e06f",
        "worked/rewritten/clear-carrying-piece": "89ba446483bcba6b",
        "worked/rewritten/clear-carrying-unmarked": "f26737e6dacc1c3f",
        "worked/rewritten/clear-everything": "b5f118b02f9a47a9",
        "worked/rewritten/clear-first": "43f38a2151607742",
        "worked/rewritten/clear-piece": "52649a966fd71479",
        "worked/rewritten/clear-unmarked": "f26737e6dacc1c3f",
        "worked/rewritten/drawable": "4f903ad8591f2edc",
        "worked/rewritten/drawing-unplaced": "e60af4cb9182b6ed",
        "worked/rewritten/drawing": "219f0bfd364bb446",
        "worked/rewritten/highlighted": "8e5ba6d24473717e",
        "worked/rewritten/located-strictly": "ff58f406be93f20c",
        "worked/rewritten/located": "ff58f406be93f20c",
        "worked/rewritten/passages": "02d20bbd7e394ad5",
        "worked/rewritten/restorable": "45d33de65c4ae688",
        "worked/rewritten/restore-across": "6d9f55f195678293",
        "worked/rewritten/restore-caret": "395b9e027a4cc401",
        "worked/rewritten/restore-everything": "395b9e027a4cc401",
        "worked/rewritten/restore-first": "b6428de428636144",
        "worked/rewritten/restore-mark-0": "b6428de428636144",
        "worked/rewritten/restore-mark-10": "395b9e027a4cc401",
        "worked/rewritten/restore-mark-15": "b82a4f2b91a1fb6e",
        "worked/rewritten/restore-mark-20": "89c378b216f27002",
        "worked/rewritten/restore-mark-5": "395b9e027a4cc401",
        "worked/rewritten/restore-marks-pair": "959fa8c2bc4d1eb7",
        "worked/rewritten/restore-piece": "395b9e027a4cc401",
        "worked/rewritten/restore-ranges": "71cd2eec86848ff5",
        "worked/rewritten/restore-unmarked": "12b592998ce0cbff",
        "worked/rewritten/whole-block-across": "796ffe1166bf99fb",
        "worked/rewritten/whole-block-caret": "3b5410ba5facf349",
        "worked/rewritten/whole-block-everything": "1e786935c9cb4040",
        "worked/rewritten/whole-block-first": "b0c1b448985f8c6c",
        "worked/rewritten/whole-block-piece": "885f7e3ee1fbe4e2",
        "worked/rewritten/whole-block-unmarked": "252d65014d4ad038",
        "worked/typed/anchored": "ce4b76ce7f44a136",
        "worked/typed/carried-writer": "cfbc95506ab9d18e",
        "worked/typed/carried": "cfbc95506ab9d18e",
        "worked/typed/changes": "76f6201c34c4c0f3",
        "worked/typed/clear-across": "18166d5c1b023fd2",
        "worked/typed/clear-caret": "efe415aa5a703fac",
        "worked/typed/clear-carrying-across": "b03336a1d6a3f587",
        "worked/typed/clear-carrying-caret": "3541fcb6a1775e92",
        "worked/typed/clear-carrying-everything": "26117fdf77b0b600",
        "worked/typed/clear-carrying-first": "05e55d1b7260e06f",
        "worked/typed/clear-carrying-piece": "3a39432727723673",
        "worked/typed/clear-carrying-unmarked": "f26737e6dacc1c3f",
        "worked/typed/clear-everything": "b5f118b02f9a47a9",
        "worked/typed/clear-first": "43f38a2151607742",
        "worked/typed/clear-piece": "27e28817b16f2860",
        "worked/typed/clear-unmarked": "f26737e6dacc1c3f",
        "worked/typed/drawable": "9f8bc50fa8a9b028",
        "worked/typed/drawing-unplaced": "a0fe9f821e699784",
        "worked/typed/drawing": "4b3d20517fbaf214",
        "worked/typed/highlighted": "a9cecb7cd6b37428",
        "worked/typed/located-strictly": "fce64055b361b7fa",
        "worked/typed/located": "311a991c4733c146",
        "worked/typed/passages": "02d20bbd7e394ad5",
        "worked/typed/restorable": "c415507a8c79318b",
        "worked/typed/restore-across": "98c0f7573ab4c86b",
        "worked/typed/restore-caret": "395b9e027a4cc401",
        "worked/typed/restore-everything": "395b9e027a4cc401",
        "worked/typed/restore-first": "1c0d3796ed291ba1",
        "worked/typed/restore-mark-0": "1c0d3796ed291ba1",
        "worked/typed/restore-mark-10": "395b9e027a4cc401",
        "worked/typed/restore-mark-15": "c6a0a8f55935a8a3",
        "worked/typed/restore-mark-20": "79447efdc79431a1",
        "worked/typed/restore-mark-5": "395b9e027a4cc401",
        "worked/typed/restore-marks-pair": "914f857ad283610b",
        "worked/typed/restore-piece": "395b9e027a4cc401",
        "worked/typed/restore-ranges": "b998012e6462682b",
        "worked/typed/restore-unmarked": "12b592998ce0cbff",
        "worked/typed/whole-block-across": "8f61149e06e2d8ec",
        "worked/typed/whole-block-caret": "7cdb30f286790d51",
        "worked/typed/whole-block-everything": "c79f925166a5d152",
        "worked/typed/whole-block-first": "9174fe4d044748cc",
        "worked/typed/whole-block-piece": "97cba1c42243821a",
        "worked/typed/whole-block-unmarked": "252d65014d4ad038",
    ]
}
