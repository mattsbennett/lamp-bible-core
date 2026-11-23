import Foundation

/// A body block's lines drawn as a figure rather than as text.
///
/// The figure is the block's own words, one entry to a line, so a deck reads
/// the same everywhere: an older Lamp, or anything that does not know the
/// figure, shows the lines as the list they are.
///
/// - `timeline`: each line is a date, a dash, and what happened — "c. 1000
///   BC — David king in Jerusalem". The entries stand in the order written,
///   evenly along a line, the date above and the event below.
/// - `chiasm`: each line a member of a mirrored structure, the first paired
///   with the last, the second with the second-last, and any odd line the
///   centre. Lettered A, B, C … C′, B′, A′, and stepped in toward the centre.
/// - `parallel`: lines in pairs, as Hebrew poetry sets them: the second of
///   each pair answering the first, lettered A and A′, set in beneath it.
/// - `map`: each line a place the Bible names, drawn where OpenBible.info
///   places it (`LampMapPlaces`), on a map of the land around them; with a
///   dash, the words after it are what the map calls the place. See
///   `LampPresentationMap`.
public enum LampPresentationFigure: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case timeline
    case chiasm
    case parallel
    case map

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Text"
        case .timeline: "Timeline"
        case .chiasm: "Chiasm"
        case .parallel: "Parallel"
        case .map: "Map"
        }
    }

    /// A figure this app does not know is drawn as text, so a deck written by
    /// a newer app still opens rather than failing as a whole.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }

    /// More entries than a timeline can set across a slide and still read
    /// from the back of a room.
    public static let mostTimelineEntries = 8

    /// What separates a timeline entry's date from its event: a dash with a
    /// space either side (em, en or hyphen), or a bar. A colon is not one,
    /// since "John 3:16" would split.
    static let timelineSeparators = [" \u{2014} ", " \u{2013} ", " - ", " | "]

    /// Where a timeline line divides into its date and its event, as offsets
    /// into the line's characters: the date before `dateEnd`, the event from
    /// `eventStart`. Nil when the line has no separator, which is drawn as an
    /// event with no date.
    public static func timelineSplit(_ line: String) -> (dateEnd: Int, eventStart: Int)? {
        let characters = Array(line)
        var best: (Int, Int)?
        for separator in timelineSeparators {
            let pattern = Array(separator)
            guard characters.count >= pattern.count else { continue }
            for start in 0...(characters.count - pattern.count)
            where characters[start..<(start + pattern.count)].elementsEqual(pattern) {
                if best.map({ start < $0.0 }) ?? true { best = (start, start + pattern.count) }
                break
            }
        }
        guard let best, best.0 > 0, best.1 < characters.count else { return nil }
        return (best.0, best.1)
    }

    /// The letter a structure gives the line at `index` of `count`: A, B, C
    /// … then primed on the way back out for a chiasm, and A, A′, B, B′ for
    /// parallel lines.
    public func letter(at index: Int, of count: Int) -> String {
        func letter(_ n: Int) -> String {
            let scalar = UnicodeScalar(UInt32(65 + n % 26)).map(String.init) ?? "?"
            return n >= 26 ? scalar + String(n / 26) : scalar
        }
        switch self {
        case .chiasm:
            let mirrored = count - 1 - index
            return index <= mirrored ? letter(index) : letter(mirrored) + "\u{2032}"
        case .parallel:
            return letter(index / 2) + (index % 2 == 1 ? "\u{2032}" : "")
        case .none, .timeline, .map:
            return ""
        }
    }

    /// How many steps in a structure's line is set: toward the centre for a
    /// chiasm, the answering line of a pair for parallel lines.
    public func indent(at index: Int, of count: Int) -> Int {
        switch self {
        case .chiasm: min(index, count - 1 - index)
        case .parallel: index % 2
        case .none, .timeline, .map: 0
        }
    }
}

extension LampPresentationFigure {
    /// The layouts that draw a figure: those setting their body blocks as
    /// prose, whose reveals bring a figure in a line at a time. A title's
    /// line, a word's gloss and a column are too narrow for one or reveal
    /// whole, so there the lines are drawn as the list they are.
    public static func isDrawn(on layout: LampPresentationSlideLayout) -> Bool {
        switch layout {
        case .titleAndBody, .blank, .scripture, .quotation: true
        case .title, .closing, .twoColumn, .image: false
        }
    }

    /// A timeline line's date and event, the separator between them left
    /// out; the whole line as its event where it has no date.
    public static func timelineEntry(
        _ runs: [LampPresentationTextRun]
    ) -> (date: [LampPresentationTextRun], event: [LampPresentationTextRun]) {
        guard let split = timelineSplit(runs.map(\.text).joined()) else { return ([], runs) }
        let (date, rest) = LampPresentationTextRun.split(runs, at: split.dateEnd)
        return (date, LampPresentationTextRun.split(rest, at: split.eventStart - split.dateEnd).after)
    }
}

extension LampPresentationBlock {
    /// The figure this block is drawn as: its own, on a body block with lines
    /// to draw, else none. Where the layout draws figures at all is
    /// `drawnFigure(on:)`.
    public var drawnFigure: LampPresentationFigure {
        guard kind == .body, let figure, figure != .none, !listItemRuns.isEmpty else { return .none }
        return figure
    }

    /// The figure this block is drawn as on `layout`.
    public func drawnFigure(on layout: LampPresentationSlideLayout) -> LampPresentationFigure {
        LampPresentationFigure.isDrawn(on: layout) ? drawnFigure : .none
    }

    /// Runs drawn with their emphasis: for a timeline, its dates and events
    /// alone, since the separator between them is not drawn.
    func drawnMarkedRuns(on layout: LampPresentationSlideLayout) -> [LampPresentationTextRun] {
        // A map prints its places' names plain.
        if drawnFigure(on: layout) == .map { return [] }
        guard drawnFigure(on: layout) == .timeline else { return drawnRuns(on: layout) }
        return listItemRuns.flatMap { line in
            let entry = LampPresentationFigure.timelineEntry(line)
            return entry.date + entry.event
        }
    }
}

extension LampPresentationTextRun {
    /// `runs` divided at `offset` characters, emphasis kept on both sides.
    public static func split(
        _ runs: [LampPresentationTextRun],
        at offset: Int
    ) -> (before: [LampPresentationTextRun], after: [LampPresentationTextRun]) {
        var before: [LampPresentationTextRun] = []
        var after: [LampPresentationTextRun] = []
        var consumed = 0
        for run in runs {
            let count = run.text.count
            if consumed + count <= offset {
                before.append(run)
            } else if consumed >= offset {
                after.append(run)
            } else {
                let cut = run.text.index(run.text.startIndex, offsetBy: offset - consumed)
                before.append(.init(text: String(run.text[..<cut]), mark: run.mark))
                after.append(.init(text: String(run.text[cut...]), mark: run.mark))
            }
            consumed += count
        }
        return (before, after)
    }
}
