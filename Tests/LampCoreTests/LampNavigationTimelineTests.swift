import Testing
@testable import LampCore

struct LampNavigationTimelineTests {
    @Test func preservesExistingChapterVisitsAndPositions() {
        var history = LampNavigationTimeline<Int>(capacity: 3)
        let chapter: (Int) -> AnyHashable = { AnyHashable($0 / 1_000) }
        history.visit(1_001, identity: chapter, preserveForwardForExistingIdentity: true)
        history.visit(2_001, identity: chapter, preserveForwardForExistingIdentity: true)
        history.visit(3_001, identity: chapter, preserveForwardForExistingIdentity: true)
        #expect(history.goBack() == 2_001)
        history.replaceCurrent(with: 2_019) { chapter($0) == chapter($1) }
        history.visit(1_009, identity: chapter, preserveForwardForExistingIdentity: true)
        #expect(history.entries == [2_019, 3_001, 1_009])
        #expect(history.current == 1_009)
        history.visit(4_001, identity: chapter, preserveForwardForExistingIdentity: true)
        #expect(history.entries == [3_001, 1_009, 4_001])
    }

    @Test func branchesAndMovesBothDirections() {
        var history = LampNavigationTimeline<String>(capacity: 3)
        for value in ["A", "B", "C"] { history.visit(value, identity: { AnyHashable($0) }) }
        #expect(history.goBack() == "B")
        #expect(history.goBack() == "A")
        #expect(history.goForward() == "B")
        history.visit("D", identity: { AnyHashable($0) })
        #expect(history.entries == ["A", "B", "D"])
        #expect(!history.canGoForward)
    }
}
