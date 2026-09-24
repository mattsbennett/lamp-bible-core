import Testing
@testable import LampModuleKit

struct LampSyncThreeWaySetTests {
    @Test func preservesIndependentCompletionsAndDeletions() {
        let result = LampSyncThreeWaySet.merge(
            base: Set(["kept", "removed-locally", "removed-remotely"]),
            local: Set(["kept", "removed-remotely", "added-locally"]),
            remote: Set(["kept", "removed-locally", "added-remotely"])
        )
        #expect(result == Set(["kept", "added-locally", "added-remotely"]))
    }

    @Test func membershipMatchesTheThreeWayTruthTable() {
        for wasPresent in [false, true] {
            for locallyPresent in [false, true] {
                for remotelyPresent in [false, true] {
                    let result = LampSyncThreeWaySet.merge(
                        base: wasPresent ? Set([1]) : [],
                        local: locallyPresent ? Set([1]) : [],
                        remote: remotelyPresent ? Set([1]) : []
                    )
                    let expected = wasPresent
                        ? locallyPresent && remotelyPresent
                        : locallyPresent || remotelyPresent
                    #expect(result.contains(1) == expected)
                }
            }
        }
    }

    @Test func wholeValueChoiceRejectsDivergentEdits() {
        #expect(LampSyncThreeWayValue.decide(base: "a", local: "b", remote: "a") == .local)
        #expect(LampSyncThreeWayValue.decide(base: "a", local: "a", remote: "b") == .remote)
        #expect(LampSyncThreeWayValue.decide(base: "a", local: "b", remote: "b") == .local)
        #expect(LampSyncThreeWayValue.decide(base: "a", local: "b", remote: "c") == .conflict)
    }
}
