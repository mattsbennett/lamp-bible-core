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

    /// The Greek default is a product decision, not an accident of the alphabet:
    /// a reader who has chosen no dictionary gets Strong's, then TBESG, and a
    /// dictionary that merely sorts early (Dodson) never takes the place.
    @Test func theGreekDictionaryDefaultIsStrongsThenTBESG() {
        let byName = ["dodson_greek", "strongs_greek", "tbesg", "wsd_greek"]
        #expect(LampModuleSelection.ordered(
            byName, preferredIDs: LampModuleSelection.preferredGreekDictionaryIDs, id: { $0 }
        ) == ["strongs_greek", "tbesg", "dodson_greek", "wsd_greek"])
        // Neither preference installed: the by-name order stands untouched.
        #expect(LampModuleSelection.ordered(
            ["dodson_greek", "wsd_greek"],
            preferredIDs: LampModuleSelection.preferredGreekDictionaryIDs, id: { $0 }
        ) == ["dodson_greek", "wsd_greek"])
        // TBESG alone takes the default rather than leaving it to the alphabet.
        #expect(LampModuleSelection.ordered(
            ["dodson_greek", "tbesg"],
            preferredIDs: LampModuleSelection.preferredGreekDictionaryIDs, id: { $0 }
        ).first == "tbesg")
    }
}
