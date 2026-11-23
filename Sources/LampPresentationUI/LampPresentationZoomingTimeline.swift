import LampCore
import SwiftUI

/// A timeline too long for one slide, seen through a view that moves along
/// it and in and out of it (`LampPresentationTimelineZoom`).
///
/// Every event is laid out once, at the size a zoomed-in view reads at, and
/// the view decides how large each is drawn and where. Zoomed in, a few
/// events fill the width; zoomed out, all of them do, drawn smaller: the
/// events fade out to leave their dates and marks, and the dates thin out
/// so none is drawn over another. Zoomed in, a small line under the timeline
/// shows the whole of it and where the view is.
///
/// What moves is the view's place in its sequence of views, `position`: a
/// whole number at each view, between them as the presenter animates from
/// one to the next, and with Reduce Motion it cuts. Between two views the
/// view zooms about the one point both show in the same place, so zooming
/// into a stretch at either end of the timeline never swings away from it,
/// and at an even pace, its width moving by the same ratio each moment; two
/// views of one width move straight along.
struct LampZoomingTimeline: View, Animatable {
    var count: Int
    var span: Int
    var explored: ClosedRange<Int>
    /// Where the view rests at each step (`timelineViews(on:)`).
    var views: [LampPresentationTimelineView]
    /// Which of `views` the view is at; between two while it moves.
    var position: Double
    /// The size a zoomed-in view sets its events at, in points.
    var size: CGFloat
    /// The room kept for each event beneath the line: the tallest, measured.
    var eventHeight: CGFloat
    var accent: Color
    var ink: Color
    /// The widest date as drawn zoomed in, measured, to tell how many can be
    /// drawn in the whole view without one running into the next.
    var dateWidth: CGFloat
    var date: (Int) -> AnyView
    var event: (Int) -> AnyView

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    /// The view at `position`: its left edge and how many events it spans,
    /// and how strongly the stretch explored is marked, 0 to 1.
    private var camera: (start: Double, shown: Double, band: Double) {
        Self.camera(views: views, position: position, count: count)
    }

    static func camera(
        views: [LampPresentationTimelineView],
        position: Double,
        count: Int
    ) -> (start: Double, shown: Double, band: Double) {
        guard let last = views.indices.last else { return (0, Double(count), 0) }
        let clamped = min(max(position, 0), Double(last))
        let from = min(Int(clamped.rounded(.down)), last)
        let to = min(from + 1, last)
        let t = clamped - Double(from)
        let a = views[from]
        let b = views[to]
        let shown = exp(log(a.count) + (log(b.count) - log(a.count)) * t)
        let start: Double
        if abs(a.count - b.count) < 0.000_1 {
            start = a.start + (b.start - a.start) * t
        } else {
            // The point both views show in the same place stays put.
            let fixed = (a.start * b.count - b.start * a.count) / (b.count - a.count)
            start = fixed - (fixed - a.start) * shown / a.count
        }
        let band = (a.marksExplored ? 1 - t : 0) + (b.marksExplored ? t : 0)
        return (start, shown, from == to ? (a.marksExplored ? 1 : 0) : band)
    }

    private var dateHeight: CGFloat { size * 0.72 * 1.32 * 2 }
    private var gap: CGFloat { size * 0.3 }
    private var dot: CGFloat { size * 0.36 }
    private var mapHeight: CGFloat { size * 1.1 }
    private var axis: CGFloat { dateHeight + gap + dot / 2 }

    /// Fixed, so the slide around the timeline never moves as it zooms.
    var height: CGFloat { axis + dot / 2 + gap + eventHeight + mapHeight }

    var body: some View {
        GeometryReader { geometry in
            drawn(width: geometry.size.width)
        }
        .frame(height: height)
    }

    private func drawn(width: CGFloat) -> some View {
        let camera = self.camera
        let shown = camera.shown
        let start = camera.start
        let band = camera.band
        // A zoomed-in view's column, where every event is laid out, and
        // this view's, which it is drawn into.
        let laidOut = width / CGFloat(span)
        let column = width / CGFloat(shown)
        let scale = column / laidOut
        // How far in the view is, from 0 for the whole timeline to 1 for a
        // view of `span` events.
        let zoomed = min(max((Double(count) - shown) / Double(max(count - span, 1)), 0), 1)
        let dateScale = max(scale, 0.55)
        // Events show only close in, and never in the whole view, however
        // little wider than a zoomed-in one it is.
        let whole = Double(span) / Double(count)
        let fadeFrom = max(0.4, whole)
        let fadeTo = fadeFrom + (1 - fadeFrom) * 0.75
        let eventOpacity = min(max((Double(scale) - fadeFrom) / (fadeTo - fadeFrom), 0), 1)
        func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5 - CGFloat(start)) * column }
        // An event leaving the view fades as it goes: whole while its
        // column is in view, gone by the time its middle reaches the edge,
        // so nothing still drawn is cut there.
        func inView(_ index: Int) -> Double {
            let beyond = max(column / 2 - x(index), x(index) - (width - column / 2), 0)
            return min(max(1 - Double(beyond / (column / 2)), 0), 1)
        }
        // Only the events in view, and one either side so none pops in at
        // an edge.
        let first = max(Int(start.rounded(.down)) - 1, 0)
        let last = min(Int((start + shown).rounded(.up)) + 1, count - 1)
        let indices = first <= last ? Array(first...last) : []
        return ZStack(alignment: .topLeading) {
            // The line and its marks are cut at the edge: the line running
            // on past it says the timeline goes on.
            ZStack(alignment: .topLeading) {
                exploredBand(x: x, column: column, dateScale: dateScale, band: band)
                Rectangle()
                    .fill(accent.opacity(0.55))
                    .frame(width: max(x(count - 1) - x(0), 0), height: max(2, size * 0.06 * dateScale))
                    .position(x: (x(0) + x(count - 1)) / 2, y: axis)
                ForEach(indices, id: \.self) { index in
                    Circle()
                        .fill(accent)
                        .frame(width: dot * dateScale, height: dot * dateScale)
                        .position(x: x(index), y: axis)
                }
            }
            .frame(width: width, height: height - mapHeight)
            .clipped()
            // Held to the timeline's own width, so a date or event on its
            // way out never crosses a passage's rule or a picture beside it.
            ZStack(alignment: .topLeading) {
                ForEach(indices, id: \.self) { index in
                    date(index)
                        .frame(width: laidOut, height: dateHeight, alignment: .bottom)
                        .scaleEffect(dateScale, anchor: .bottom)
                        .position(x: dateX(index, at: x(index), width: width, dateScale: dateScale, zoomed: zoomed),
                                  y: axis - dot / 2 * dateScale - gap * dateScale - dateHeight / 2)
                        .opacity(dateOpacity(index, width: width, scale: scale) * inView(index))
                    event(index)
                        .frame(width: laidOut, height: eventHeight, alignment: .top)
                        .scaleEffect(scale, anchor: .top)
                        .position(x: x(index), y: axis + dot / 2 * dateScale + gap * scale + eventHeight / 2)
                        .opacity(eventOpacity * inView(index))
                }
            }
            .frame(width: width, height: height - mapHeight, alignment: .topLeading)
            .clipped()
            overview(width: width, start: start, shown: shown)
                .opacity(zoomed)
                .position(x: width / 2, y: height - mapHeight / 2)
        }
    }

    /// Where a date is drawn across: over its mark, except that in the whole
    /// view a date wider than its column at either end is drawn in from the
    /// edge rather than cut by it. Zoomed in, every date fits its column.
    private func dateX(_ index: Int, at x: CGFloat, width: CGFloat, dateScale: CGFloat, zoomed: Double) -> CGFloat {
        let half = min(dateWidth, width / CGFloat(span)) * dateScale / 2
        guard width > half * 2 else { return x }
        let held = min(max(x, half), width - half)
        return x + (held - x) * CGFloat(1 - zoomed)
    }

    /// The stretch explored, marked behind it once the view is back out.
    private func exploredBand(x: (Int) -> CGFloat, column: CGFloat, dateScale: CGFloat, band: Double) -> some View {
        let left = x(explored.lowerBound) - column / 2
        let right = x(explored.upperBound) + column / 2
        let top = axis - dot / 2 * dateScale - gap * dateScale - dateHeight * dateScale - size * 0.2
        let bottom = axis + size * 0.6
        return RoundedRectangle(cornerRadius: size * 0.2)
            .fill(accent.opacity(0.16))
            .frame(width: max(right - left, 0), height: max(bottom - top, 0))
            .position(x: (left + right) / 2, y: (top + bottom) / 2)
            .opacity(band)
    }

    /// How fully a date is drawn. The whole view keeps a date where it has
    /// room, measured to the dates either side at the same spacing where
    /// they are drawn, so an end date drawn in from the edge is not run
    /// into; the first date always, then every second, every fourth, and so
    /// on, so the dates kept are evenly spaced. That is decided once, for
    /// the whole view at rest, so no view at rest leaves a date half drawn.
    /// A date the whole view leaves out fades in as the view comes in from
    /// the whole to where every date fits its column.
    private func dateOpacity(_ index: Int, width: CGFloat, scale: CGFloat) -> Double {
        // Measured from the whole view itself, which for a timeline little
        // longer than its view is already nearly zoomed in: none of its
        // dates left out may show there at all.
        let whole = Double(span) / Double(count)
        let from = max(0.75, whole)
        let near = from >= 1 ? 1 : min(max((Double(scale) - from) / (1 - from), 0), 1)
        guard index > 0 else { return 1 }
        let column = width / CGFloat(count)
        let dateScale = max(CGFloat(span) / CGFloat(count), 0.55)
        // Measured by the widest date, so the dates kept are evenly spaced
        // rather than a short one kept beside a long one gone.
        let wide = (min(dateWidth, width / CGFloat(span)) + size * 0.3) * dateScale
        func drawn(_ index: Int) -> CGFloat {
            dateX(index, at: (CGFloat(index) + 0.5) * column, width: width, dateScale: dateScale, zoomed: 0)
        }
        let stride = index & -index
        let here = drawn(index)
        let kept = [index - stride, index + stride]
            .filter { (0..<count).contains($0) }
            .allSatisfy { abs(drawn($0) - here) >= wide }
        return kept ? 1 : near
    }

    /// The whole timeline small, under the zoomed-in view, with the stretch
    /// in view bracketed.
    private func overview(width: CGFloat, start: Double, shown: Double) -> some View {
        let length = min(width * 0.36, size * 14)
        let step = length / CGFloat(max(count, 1))
        let stroke = max(1.5, size * 0.05)
        let left = CGFloat(start) * step
        let span = CGFloat(shown) * step
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(ink.opacity(0.3))
                .frame(width: length, height: stroke)
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(ink.opacity(0.45))
                    .frame(width: size * 0.14, height: size * 0.14)
                    .offset(x: (CGFloat(index) + 0.5) * step - size * 0.07)
            }
            RoundedRectangle(cornerRadius: size * 0.12)
                .stroke(accent, lineWidth: stroke)
                .frame(width: max(span, size * 0.3), height: size * 0.5)
                .offset(x: left)
        }
        .frame(width: length, height: size * 0.5, alignment: .leading)
        .accessibilityHidden(true)
    }
}
