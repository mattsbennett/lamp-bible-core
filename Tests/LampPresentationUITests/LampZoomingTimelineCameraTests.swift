import Testing
@testable import LampCore
@testable import LampPresentationUI

/// The path a zoomed timeline's view takes between two of its views.
struct LampZoomingTimelineCameraTests {
    private let whole = LampPresentationTimelineView(start: 0, count: 40)

    @Test func zoomingIntoAnEndKeepsItInViewAllTheWay() {
        let end = LampPresentationTimelineView(start: 36, count: 4)
        for step in 0...10 {
            let camera = LampZoomingTimeline.camera(views: [whole, end], position: Double(step) / 10, count: 40)
            #expect(camera.start <= 36.000_1 && camera.start + camera.shown >= 39.999_9, "at \(step)")
        }
    }

    @Test func aZoomGoesAtAnEvenPaceAndAMoveAlongIsStraight() {
        let near = LampPresentationTimelineView(start: 3, count: 4)
        let half = LampZoomingTimeline.camera(views: [whole, near], position: 0.5, count: 40)
        #expect(abs(half.shown - (40.0 * 4).squareRoot()) < 0.000_1)
        let along = LampPresentationTimelineView(start: 6, count: 4)
        let moved = LampZoomingTimeline.camera(views: [near, along], position: 0.5, count: 40)
        #expect(abs(moved.start - 4.5) < 0.000_1 && moved.shown == 4)
    }

    @Test func theStretchIsMarkedAsTheViewReturnsToTheWhole() {
        let near = LampPresentationTimelineView(start: 3, count: 4)
        let marked = LampPresentationTimelineView(start: 0, count: 40, marksExplored: true)
        let views = [whole, near, marked]
        #expect(LampZoomingTimeline.camera(views: views, position: 1, count: 40).band == 0)
        #expect(LampZoomingTimeline.camera(views: views, position: 1.5, count: 40).band == 0.5)
        #expect(LampZoomingTimeline.camera(views: views, position: 2, count: 40).band == 1)
    }
}
