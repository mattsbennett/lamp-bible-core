import Foundation

/// One text, searched for many needles: where a needle stands only once.
///
/// The review record proves a piece's context stands once in a text by
/// finding every copy of it there, and a draw asks that of thousands of
/// pieces. Scanning the whole text for each was most of the second a draw
/// took on a writing the assistant had worked over (0035). Here the copies
/// are found from an index of where each run of four UTF-16 units stands,
/// built the first time a needle is long enough to use it; each candidate
/// is then confirmed by Core Foundation's own literal comparison at that
/// place. So which copies count is decided exactly as before, and only the
/// places looked at change.
///
/// A needle shorter than the run, or a search made for one look, scans as
/// before: an index costs more to build than one scan of the text.
///
/// Not shared between threads: one is made for one piece of work.
final class LampTextSearch {
    let text: NSString
    private let length: Int
    private let indexing: Bool
    private var index: [UInt64: [Int32]]?

    static let run = 4

    init(_ text: NSString, indexing: Bool = true) {
        self.text = text
        self.length = text.length
        self.indexing = indexing
    }

    /// The one copy of `needle` that `accepts`, or nil where there is none
    /// or more than one. Copies may overlap, as a scan from each match's
    /// next unit finds them.
    func only(_ needle: String, where accepts: (NSRange) -> Bool = { _ in true }) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        // The units Core Foundation compares. Swift's own view of a string
        // cut inside a surrogate pair reads the half left as U+FFFD, and an
        // index of those would miss a copy the comparison finds.
        let bridged = needle as NSString
        var units = [unichar](repeating: 0, count: bridged.length)
        bridged.getCharacters(&units, range: NSRange(location: 0, length: bridged.length))
        guard indexing, units.count >= Self.run else { return scanned(needle, where: accepts) }
        guard units.count <= length else { return nil }
        let index = builtIndex()
        // The rarest run in the needle names the fewest places to look.
        var fewest: [Int32]?
        var offset = 0
        for start in 0...(units.count - Self.run) {
            guard let places = index[Self.key(units, at: start)] else { return nil }
            if fewest == nil || places.count < fewest!.count {
                fewest = places
                offset = start
            }
        }
        var match: NSRange?
        for place in fewest! {
            let location = Int(place) - offset
            guard location >= 0 else { continue }
            guard location + units.count <= length else { break }
            let found = text.range(
                of: needle, options: [.literal, .anchored],
                range: NSRange(location: location, length: length - location)
            )
            guard found.location == location else { continue }
            if accepts(found) {
                if match != nil { return nil }
                match = found
            }
        }
        return match
    }

    /// `only` by scanning the whole text from each match on.
    private func scanned(_ needle: String, where accepts: (NSRange) -> Bool) -> NSRange? {
        var match: NSRange?
        var search = NSRange(location: 0, length: length)
        while true {
            let found = text.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            if accepts(found) {
                if match != nil { return nil }
                match = found
            }
            let next = found.location + 1
            guard next <= length else { break }
            search = NSRange(location: next, length: length - next)
        }
        return match
    }

    private func builtIndex() -> [UInt64: [Int32]] {
        if let index { return index }
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        var built: [UInt64: [Int32]] = [:]
        if length >= Self.run {
            built.reserveCapacity(length / 2)
            for start in 0...(length - Self.run) {
                built[Self.key(units, at: start), default: []].append(Int32(start))
            }
        }
        index = built
        return built
    }

    private static func key(_ units: [unichar], at start: Int) -> UInt64 {
        UInt64(units[start]) << 48 | UInt64(units[start + 1]) << 32
            | UInt64(units[start + 2]) << 16 | UInt64(units[start + 3])
    }
}
