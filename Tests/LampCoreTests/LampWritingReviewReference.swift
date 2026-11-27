import Foundation
@testable import LampCore

/// The review record's searching as it was before
/// `ReviewMarksPerformancePlan.md`, kept as the reference its faster
/// replacements are tested against, answer for answer.
///
/// Copied from core `b714fa0`. Not to be changed: a reference that moves
/// with the code it checks checks nothing.
enum LampWritingReviewReference {
    /// The one copy of `needle` in `text` that `accepts`, or nil where there
    /// is none or more than one: every copy, found by scanning the whole
    /// text from each match on.
    static func only(_ needle: String, in text: NSString, where accepts: (NSRange) -> Bool = { _ in true }) -> NSRange? {
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

    /// `located(in:strictly:)` with every clearance's every range taken out
    /// of every range of its mark, one step at a time.
    static func located(
        _ review: LampWritingReview, in text: String, strictly: Bool = false
    ) -> [LampWritingReview.Located] {
        typealias R = LampWritingReview
        let source = text as NSString
        let here = R.digest(of: text)
        func find(_ piece: R.Piece) -> NSRange? {
            piece.anchoredIn == here ? R.exact(piece, in: source) : R.find(piece, in: source, strictly: strictly)
        }
        var cleared: [UUID: [NSRange]] = [:]
        for clearance in review.clearances {
            for piece in clearance.pieces {
                if let range = find(piece) {
                    cleared[clearance.markID, default: []].append(range)
                }
            }
        }
        return review.marks.compactMap { mark -> R.Located? in
            var ranges = mark.pieces.compactMap { find($0) }
            for range in cleared[mark.id] ?? [] {
                ranges = ranges.flatMap { R.subtracting(range, from: $0) }.compactMap { R.remainder($0, in: source) }
            }
            ranges = R.coalesced(ranges, joiningAcross: nil)
            return ranges.isEmpty ? nil : R.Located(id: mark.id, ranges: ranges)
        }
        .sorted { ($0.ranges[0].location, $0.ranges[0].length) < ($1.ranges[0].location, $1.ranges[0].length) }
    }
}
