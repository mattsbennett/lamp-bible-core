import Testing
@testable import LampCore

struct LampModuleSelectionTests {
    @Test func staleAndDuplicatePreferencesDoNotDuplicateOrDropInstalledModules() {
        let preferred = LampModuleSelection.identifiers(in: " old, B, B,, A ")
        #expect(preferred == ["old", "B", "A"])
        #expect(LampModuleSelection.visible(
            ["A", "B", "C", "D"], hiddenIDs: ["A"], preferredIDs: preferred, id: { $0 }
        ) == ["B", "C", "D"])
    }

    @Test func multipleEntriesInOneDictionaryKeepTheirOrderAndContent() {
        let entries = [("B", "first"), ("A", "other"), ("B", "second"), ("C", "new")]
        let ordered = LampModuleSelection.ordered(entries, preferredIDs: ["B", "B"]) { $0.0 }
        #expect(ordered.map(\.1) == ["first", "second", "other", "new"])
        #expect(LampModuleSelection.ordered(["B", "A"], preferredIDs: [], id: { $0 }) == ["B", "A"])
    }
}
