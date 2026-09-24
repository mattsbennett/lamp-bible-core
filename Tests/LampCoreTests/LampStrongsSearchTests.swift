import Testing
@testable import LampCore

struct LampStrongsSearchTests {
    @Test func marksOnlyMatchingAnnotationsAndMergesRanges() {
        let json = #"[{"start":0,"end":4,"data":{"strongs":"G3056"}},{"start":3,"end":6,"data":{"strongs":"g3056"}},{"start":7,"end":10,"data":{"strongs":"H1"}}]"#
        #expect(LampStrongsSearch.markedText("worded abc", annotationsJSON: json, key: "G3056")
            == "<mark>worded</mark> abc")
        #expect(LampStrongsSearch.sqlLikePattern(for: " G3056 ")
            == "%\"strongs\":%\"G3056\"%")
        #expect(LampStrongsSearch.markedText("worded abc", annotationsJSON: nil, key: "G3056")
            == "worded abc")
    }
}
