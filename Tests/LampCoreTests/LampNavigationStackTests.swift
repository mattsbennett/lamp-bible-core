import Foundation
import Testing
@testable import LampCore

struct LampNavigationStackTests {
    @Test(arguments: [0, -1, Int.min])
    func malformedStoredCapacityIsNormalizedBeforeNavigation(capacity: Int) throws {
        let json = """
        {"backStack":[1,2,3],"current":4,"forwardStack":[5,6],"capacity":\(capacity)}
        """
        var history = try JSONDecoder().decode(LampNavigationStack<Int>.self, from: Data(json.utf8))
        #expect(history.capacity == 1)
        #expect(history.backStack == [3])
        #expect(history.forwardStack == [6])
        #expect(history.goBack() == 3)
        #expect(history.goForward() == 4)
        history.visit(7)
        #expect(history.current == 7)
        #expect(history.backStack == [4])
        #expect(!history.canGoForward)
    }

    @Test func olderSavedHistoryWithoutCapacityKeepsItsLocations() throws {
        let data = Data(#"{"backStack":[1,2],"current":3,"forwardStack":[4]}"#.utf8)
        let history = try JSONDecoder().decode(LampNavigationStack<Int>.self, from: data)
        #expect(history.capacity == 100)
        #expect(history.backStack == [1, 2])
        #expect(history.current == 3)
        #expect(history.forwardStack == [4])
        #expect(try JSONDecoder().decode(LampNavigationStack<Int>.self,
            from: JSONEncoder().encode(history)) == history)
    }
}
