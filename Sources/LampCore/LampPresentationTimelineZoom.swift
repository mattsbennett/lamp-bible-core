import Foundation

/// A timeline too long to read across one slide, shown whole and then a few
/// events at a time.
///
/// The slide arrives showing the whole timeline. Each click moves the view:
/// in to the first `span` events of the stretch explored, along it, and back
/// out to the whole, where the stretch explored is marked. Each move along
/// keeps the last event of the view before in sight, at its left, so the
/// room sees which way the timeline went.
///
/// `from` and `through` are the first and last events explored, counted from
/// 1; absent, the timeline is explored end to end.
///
/// An older Lamp, which does not know this, draws the timeline whole.
public struct LampPresentationTimelineZoom: Codable, Equatable, Sendable {
    public var span: Int
    public var from: Int?
    public var through: Int?

    public init(span: Int = Self.defaultSpan, from: Int? = nil, through: Int? = nil) {
        self.span = span
        self.from = from
        self.through = through
    }

    /// How many events a zoomed-in view shows, unless the deck says.
    public static let defaultSpan = 4

    /// The fewest and most events a zoomed-in view shows. Fewer than two
    /// is no longer a timeline; more than a timeline that is not zoomed
    /// sets across a slide is too small to read.
    public static let spans = 2...LampPresentationFigure.mostTimelineEntries

    /// More events than a zoomed timeline's whole view can still show as a
    /// line of distinct marks.
    public static let mostEvents = 40

    private enum CodingKeys: String, CodingKey {
        case span, from, through
    }

    /// Never fails: a zoom written by a newer app, or written wrongly, zooms
    /// as near as it can rather than stopping the deck opening.
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        span = (try? container?.decodeIfPresent(Int.self, forKey: .span)) ?? Self.defaultSpan
        from = try? container?.decodeIfPresent(Int.self, forKey: .from)
        through = try? container?.decodeIfPresent(Int.self, forKey: .through)
    }
}

/// Where a zoomed timeline's view rests at one step: the events from `start`
/// (counted from 0, measured to the view's left edge) across `count` events.
/// `marksExplored` is the last, whole view, which marks the stretch explored.
public struct LampPresentationTimelineView: Equatable, Sendable {
    public var start: Double
    public var count: Double
    public var marksExplored: Bool

    public init(start: Double, count: Double, marksExplored: Bool = false) {
        self.start = start
        self.count = count
        self.marksExplored = marksExplored
    }
}

extension LampPresentationBlock {
    /// The zoom drawn: the block's own, on a timeline that is drawn and has
    /// more events than a view shows. Nil draws the timeline whole.
    public func drawnZoom(on layout: LampPresentationSlideLayout) -> LampPresentationTimelineZoom? {
        guard let zoom, drawnFigure(on: layout) == .timeline else { return nil }
        let span = min(max(zoom.span, LampPresentationTimelineZoom.spans.lowerBound),
                       LampPresentationTimelineZoom.spans.upperBound)
        guard listItemRuns.count > span else { return nil }
        return LampPresentationTimelineZoom(span: span, from: zoom.from, through: zoom.through)
    }

    /// The events a zoom explores, counted from 0: its `from` through its
    /// `through`, each held to the timeline, else every event.
    public func exploredEvents(on layout: LampPresentationSlideLayout) -> ClosedRange<Int>? {
        guard let zoom = drawnZoom(on: layout) else { return nil }
        let count = listItemRuns.count
        // Held to the events before counting from 0, so no number written
        // in a deck can overflow.
        let low = min(max(zoom.from ?? 1, 1), count) - 1
        let high = max(min(max(zoom.through ?? count, 1), count) - 1, low)
        return low...high
    }

    /// Where a zoomed timeline's view rests at each of its steps: the whole,
    /// each view along the stretch explored, and the whole again with that
    /// stretch marked. Empty for a timeline drawn whole.
    public func timelineViews(on layout: LampPresentationSlideLayout) -> [LampPresentationTimelineView] {
        guard let zoom = drawnZoom(on: layout), let explored = exploredEvents(on: layout) else { return [] }
        let count = listItemRuns.count
        let span = zoom.span
        let lastStart = count - span
        func held(_ start: Int) -> Int { min(max(start, 0), lastStart) }
        var starts: [Int]
        if explored.count <= span {
            // A stretch that fits one view sits in the middle of it.
            starts = [held(explored.lowerBound - (span - explored.count) / 2)]
        } else {
            // Each move keeps the last event of the view before.
            let stride = max(span - 1, 1)
            starts = []
            var start = explored.lowerBound
            while start + span - 1 < explored.upperBound {
                starts.append(held(start))
                start += stride
            }
            starts.append(held(explored.upperBound - span + 1))
        }
        // Held to the timeline's ends, two views can come out the same.
        var distinct: [Int] = []
        for start in starts where distinct.last != start { distinct.append(start) }
        let whole = LampPresentationTimelineView(start: 0, count: Double(count))
        return [whole]
            + distinct.map { LampPresentationTimelineView(start: Double($0), count: Double(span)) }
            + [LampPresentationTimelineView(start: 0, count: Double(count), marksExplored: true)]
    }

    /// How much of this block's text the slide shows at once, for judging
    /// whether it is crowded: a zoomed timeline's `span` longest events, since
    /// no view shows more; anything else, all of it.
    public func shownTextLength(on layout: LampPresentationSlideLayout) -> Int {
        guard let zoom = drawnZoom(on: layout) else { return text.count }
        let lengths = listItemRuns.map { $0.reduce(0) { $0 + $1.text.count } }.sorted(by: >)
        return lengths.prefix(zoom.span).reduce(0, +)
    }

    /// What a listener hears of a zoomed timeline at `view`: the events in
    /// view, or the whole with the stretch explored named once it is marked.
    public func spokenTimeline(_ view: LampPresentationTimelineView, on layout: LampPresentationSlideLayout) -> String {
        let lines = listItemRuns.map { $0.map(\.text).joined() }
        let first = max(Int(view.start.rounded()), 0)
        let last = min(first + Int(view.count.rounded()), lines.count)
        if last - first < lines.count, first < last {
            return "Timeline, events \(first + 1) to \(last) of \(lines.count): "
                + lines[first..<last].joined(separator: ". ")
        }
        var heading = "Timeline of \(lines.count) events"
        if view.marksExplored, let explored = exploredEvents(on: layout) {
            heading += ", events \(explored.lowerBound + 1) to \(explored.upperBound + 1) marked"
        }
        return heading + ": " + lines.joined(separator: ". ")
    }
}
