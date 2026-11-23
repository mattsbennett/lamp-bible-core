import Foundation
import Testing
@testable import LampCore

/// A timeline shown whole, then a few events at a time, then whole again.
struct LampPresentationTimelineZoomTests {
    private func timeline(_ count: Int, zoom: LampPresentationTimelineZoom?) -> LampPresentationBlock {
        .init(
            id: "t",
            kind: .body,
            text: (1...count).map { "\($0) AD \u{2014} Event \($0)" }.joined(separator: "\n"),
            listStyle: .unordered,
            figure: .timeline,
            zoom: zoom
        )
    }

    @Test func theViewGoesInAlongAndBackOut() {
        let block = timeline(12, zoom: .init(span: 4))
        let views = block.timelineViews(on: .titleAndBody)
        // Whole; 0–3, 3–6, 6–9, then 8–11 to end on the last; whole, marked.
        #expect(views.map(\.start) == [0, 0, 3, 6, 8, 0])
        #expect(views.map(\.count) == [12, 4, 4, 4, 4, 12])
        #expect(views.map(\.marksExplored) == [false, false, false, false, false, true])
        #expect(block.exploredEvents(on: .titleAndBody) == 0...11)
    }

    @Test func aStretchIsExploredAndAShortOneSitsInTheMiddle() {
        let stretch = timeline(20, zoom: .init(span: 4, from: 6, through: 12))
        // Events 6 to 12 (5 to 11 from 0): 5–8, then 8–11.
        #expect(stretch.timelineViews(on: .titleAndBody).map(\.start) == [0, 5, 8, 0])
        let short = timeline(20, zoom: .init(span: 5, from: 10, through: 11))
        // Events 10 and 11 (9 and 10 from 0) in the middle of a view of five.
        #expect(short.timelineViews(on: .titleAndBody).map(\.start) == [0, 8, 0])
        // Held to the timeline's ends.
        let end = timeline(10, zoom: .init(span: 4, from: 10, through: 10))
        #expect(end.timelineViews(on: .titleAndBody).map(\.start) == [0, 6, 0])
    }

    @Test func aTimelineAViewShowsWholeIsNotZoomed() {
        let block = timeline(4, zoom: .init(span: 4))
        #expect(block.drawnZoom(on: .titleAndBody) == nil)
        #expect(block.timelineViews(on: .titleAndBody).isEmpty)
        let issues = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [block])])
        )
        #expect(issues.contains { $0.path == "slides[0].blocks[0].zoom" && $0.severity == .warning })
        // Nor is one on a layout that draws no figure.
        #expect(timeline(12, zoom: .init()).drawnZoom(on: .twoColumn) == nil)
    }

    @Test func eachMoveIsAClickWhetherOrNotTheSlideRevealsInParts() {
        let block = timeline(12, zoom: .init(span: 4))
        let title = LampPresentationBlock(id: "h", kind: .title, text: "The kings")
        var slide = LampPresentationSlide(layout: .titleAndBody, blocks: [title, block])
        var plan = slide.revealPlan
        #expect(plan.stepCount == 5)
        #expect(plan.isShown(.block("h"), atStep: 0))
        #expect(plan.isShown(.block("t"), atStep: 0))
        #expect((0...5).map { plan.view(of: "t", count: 6, atStep: $0) } == [0, 1, 2, 3, 4, 5])
        // Everywhere but the presenter draws the end: whole, marked.
        #expect(plan.view(of: "t", count: 6, atStep: nil) == 5)

        slide.reveal = .stepwise
        plan = slide.revealPlan
        // The timeline arrives whole, with its first view, and every event
        // at once: no event is a step of its own.
        #expect(plan.stepCount == 5)
        #expect(plan.isShown(.block("t"), atStep: 0))
        #expect(!plan.revealsItems(of: "t"))
        #expect(plan.view(of: "t", count: 6, atStep: 2) == 2)

        // With a passage before it, it arrives on the second click.
        let body = LampPresentationBlock(id: "p", kind: .body, text: "First.")
        slide.blocks = [title, body, block]
        plan = slide.revealPlan
        #expect(plan.stepCount == 6)
        #expect(!plan.isShown(.block("t"), atStep: 0))
        #expect(plan.view(of: "t", count: 6, atStep: 1) == 0)
        #expect(plan.view(of: "t", count: 6, atStep: 6) == 5)
    }

    @Test func aZoomWrittenWronglyStillOpens() throws {
        let json = #"{"id":"t","kind":"body","text":"a — b","figure":"timeline","zoom":{"span":"wide","from":2}}"#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(block.zoom == .init(span: LampPresentationTimelineZoom.defaultSpan, from: 2))
    }

    @Test func theValidatorSaysWhatAZoomDrawsDifferently() {
        func paths(_ block: LampPresentationBlock) -> [String] {
            LampPresentationDeckValidator.validate(
                LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [block])])
            ).filter { $0.severity == .warning }.map(\.path)
        }
        // Twelve events would be too crowded unzoomed, and are not zoomed.
        #expect(paths(timeline(12, zoom: nil)) == ["slides[0].blocks[0].figure"])
        #expect(paths(timeline(12, zoom: .init(span: 4))).isEmpty)
        #expect(paths(timeline(12, zoom: .init(span: 12))).contains("slides[0].blocks[0].zoom.span"))
        #expect(paths(timeline(12, zoom: .init(span: 4, from: 0, through: 13)))
            == ["slides[0].blocks[0].zoom.from", "slides[0].blocks[0].zoom.through"])
        #expect(paths(timeline(12, zoom: .init(span: 4, from: 8, through: 3))) == ["slides[0].blocks[0].zoom"])
        #expect(paths(timeline(41, zoom: .init())) == ["slides[0].blocks[0].figure"])
        var list = timeline(12, zoom: .init())
        list.figure = nil
        #expect(paths(list).contains("slides[0].blocks[0].zoom"))
    }

    @Test func noNumberWrittenInADeckOverflows() {
        let block = timeline(12, zoom: .init(span: 4, from: Int.min, through: Int.max))
        #expect(block.exploredEvents(on: .titleAndBody) == 0...11)
        let reversed = timeline(12, zoom: .init(span: 4, from: Int.max, through: Int.min))
        #expect(reversed.exploredEvents(on: .titleAndBody) == 11...11)
    }

    @Test func twoTimelinesArriveTogetherAndMoveInTurn() {
        var first = timeline(12, zoom: .init(span: 4))
        var second = timeline(12, zoom: .init(span: 4))
        first.id = "a"
        second.id = "b"
        let slide = LampPresentationSlide(layout: .blank, blocks: [first, second])
        let plan = slide.revealPlan
        // Four moves and back out, for each: ten clicks, none doing nothing.
        #expect(plan.stepCount == 10)
        let views = (0...10).map { (plan.view(of: "a", count: 6, atStep: $0), plan.view(of: "b", count: 6, atStep: $0)) }
        for step in 1...10 {
            #expect(views[step] != views[step - 1], "step \(step) moves nothing")
        }
    }

    @Test func aZoomedTimelinesEmphasisTakesNoStepOfItsOwn() {
        var block = timeline(12, zoom: .init(span: 4))
        block.emphasis = [.init(text: "Event 3")]
        var slide = LampPresentationSlide(layout: .titleAndBody, blocks: [block])
        slide.revealsEmphasis = true
        #expect(!slide.revealPlan.emphasisStep)
        #expect(slide.revealPlan.isEmphasisLit(atStep: 0))
    }

    @Test func aListenerHearsTheEventsInView() {
        let block = timeline(12, zoom: .init(span: 4, from: 5, through: 10))
        let views = block.timelineViews(on: .titleAndBody)
        #expect(block.spokenTimeline(views[1], on: .titleAndBody).hasPrefix("Timeline, events 5 to 8 of 12: 5 AD"))
        #expect(block.spokenTimeline(views[0], on: .titleAndBody).hasPrefix("Timeline of 12 events: 1 AD"))
        #expect(block.spokenTimeline(views.last!, on: .titleAndBody)
            .hasPrefix("Timeline of 12 events, events 5 to 10 marked: "))
    }

    @Test func aZoomedTimelineIsCrowdedOnlyByWhatAViewShows() {
        var block = timeline(24, zoom: .init(span: 4))
        block.text = (1...24).map { "\($0) AD \u{2014} The church gathers in a new city" }.joined(separator: "\n")
        #expect(block.text.count > 900)
        #expect(block.shownTextLength(on: .titleAndBody) < 200)
        let issues = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [block])])
        )
        #expect(!issues.contains { $0.path.hasSuffix(".text") || $0.path.hasSuffix(".blocks") })
    }
}
