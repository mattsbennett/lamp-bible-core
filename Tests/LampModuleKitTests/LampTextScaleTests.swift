import Testing
@testable import LampModuleKit

struct LampTextScaleTests {
    @Test func bookScalesAndTypefacesAreTheOnesBothAppsStore() {
        #expect(LampTextScale.bookText.range == 13...34)
        #expect(LampTextScale.bookText.defaultValue == 18)
        #expect(LampTextScale.bookLineSpacing.range == 0...16)
        #expect(LampTextScale.bookLineSpacing.defaultValue == 6)
        #expect(LampProseTypeface.allCases.map(\.rawValue) == ["serif", "sansSerif"])
    }

    @Test func steppingSnapsOntoTheGridInTheDirectionOfTravel() {
        let scale = LampTextScale.bookText
        #expect(scale.stepped(20.5, by: 1) == 21)
        #expect(scale.stepped(20.5, by: -1) == 20)
        #expect(scale.stepped(34, by: 1) == 34)
        #expect(!scale.canIncrease(34))
        #expect(scale.canDecrease(14))
    }
}
