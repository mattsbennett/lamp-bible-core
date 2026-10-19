import Foundation
import Testing
@testable import LampModuleKit

/// The two clients spell the same entry differently, and a text comparison
/// turns that into a conflict over something nobody changed.
struct LampSyncJSONComparisonTests {
    /// The real case: this package writes sorted keys, the phone writes
    /// declaration order. Five of the user's notes were reported as
    /// conflicts for exactly this on 2026-10-18.
    @Test func keyOrderIsNotAChange() {
        #expect(LampSyncJSONComparison.sameValue(
            #"[{"id":"a","text":"A note"}]"#,
            #"[{"text":"A note","id":"a"}]"#
        ))
    }

    /// The other half of that case: an empty list and a null column are the
    /// same absence, and so is a missing one.
    @Test func nothingNullAndEmptyAreTheSameAbsence() {
        #expect(LampSyncJSONComparison.sameValue("[]", nil))
        #expect(LampSyncJSONComparison.sameValue(nil, "null"))
        #expect(LampSyncJSONComparison.sameValue("  ", "[]"))
        #expect(LampSyncJSONComparison.sameValue("{}", nil))
    }

    @Test func differentContentIsStillDifferent() {
        #expect(!LampSyncJSONComparison.sameValue(
            #"[{"id":"a","text":"A note"}]"#,
            #"[{"id":"a","text":"Another note"}]"#
        ))
        // Present versus absent is a real difference, not a spelling.
        #expect(!LampSyncJSONComparison.sameValue(#"[{"id":"a"}]"#, nil))
        // Order within an array is meaning, unlike order of keys.
        #expect(!LampSyncJSONComparison.sameValue(#"["a","b"]"#, #"["b","a"]"#))
    }

    /// Nested objects are where key order differs most, since that is where
    /// an encoder's choices compound.
    @Test func keyOrderIsIgnoredAtEveryDepth() {
        #expect(LampSyncJSONComparison.sameValue(
            #"{"blocks":[{"type":"p","attrs":{"align":"left","id":1}}]}"#,
            #"{"blocks":[{"attrs":{"id":1,"align":"left"},"type":"p"}]}"#
        ))
    }

    /// A column that is not JSON is compared as written rather than guessed
    /// at, so this cannot quietly equate two unrelated strings.
    @Test func whatIsNotJSONIsComparedAsWritten() {
        #expect(LampSyncJSONComparison.sameValue("not json", "not json"))
        #expect(!LampSyncJSONComparison.sameValue("not json", "other text"))
        // One side JSON and the other not is a difference.
        #expect(!LampSyncJSONComparison.sameValue(#"["a"]"#, "a"))
    }
}
