import Testing
@testable import LampModuleKit

struct LampTextScaleTests {
    private let scale = LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 16)

    @Test func bookScalesAndTypefacesAreTheOnesBothAppsStore() {
        #expect(LampTextScale.bookText.range == 13...34)
        #expect(LampTextScale.bookText.defaultValue == 18)
        #expect(LampTextScale.bookLineSpacing.range == 0...16)
        #expect(LampTextScale.bookLineSpacing.defaultValue == 6)
        #expect(LampProseTypeface.allCases.map(\.rawValue) == ["serif", "sansSerif"])
    }

    @Test func clampingHoldsValuesInsideTheRange() {
        #expect(scale.clamped(9) == 13)
        #expect(scale.clamped(40) == 20)
        #expect(scale.clamped(15) == 15)
    }

    @Test func steppingMovesByWholeSteps() {
        #expect(scale.stepped(16, by: 1) == 17)
        #expect(scale.stepped(16, by: -1) == 15)
        #expect(scale.stepped(16, by: 3) == 19)
    }

    @Test func steppingStopsAtTheBounds() {
        #expect(scale.stepped(20, by: 1) == 20)
        #expect(scale.stepped(13, by: -1) == 13)
        #expect(scale.stepped(19, by: 5) == 20)
    }

    @Test func steppingSnapsOntoTheGridInTheDirectionOfTravel() {
        // A slider, or a size stored under an older step, can leave a half
        // point behind; a step lands on the grid rather than carrying it on.
        #expect(scale.stepped(16.5, by: 1) == 17)
        #expect(scale.stepped(16.5, by: -1) == 16)
    }

    @Test func steppingFromOutsideTheRangeReentersIt() {
        #expect(scale.stepped(40, by: 1) == 20)
        #expect(scale.stepped(40, by: -1) == 19)
        #expect(scale.stepped(2, by: 1) == 14)
    }

    @Test func boundsSayWhetherThereIsRoomToMove() {
        #expect(scale.canIncrease(19))
        #expect(!scale.canIncrease(20))
        #expect(scale.canDecrease(14))
        #expect(!scale.canDecrease(13))
        #expect(!scale.canIncrease(40))
        #expect(!scale.canDecrease(2))
    }

    @Test func theDefaultIsHeldInsideTheRange() {
        #expect(LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 4).defaultValue == 13)
        #expect(LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 99).defaultValue == 20)
        #expect(LampTextScale.bookText.range.contains(LampTextScale.bookText.defaultValue))
        #expect(LampTextScale.bookLineSpacing.range.contains(LampTextScale.bookLineSpacing.defaultValue))
    }
}
