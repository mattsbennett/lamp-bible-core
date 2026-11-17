import Testing
@testable import LampModuleKit

/// The translations whose IDs dropped their "s", and how an ID under either
/// name is read.
struct LampTranslationIDTests {
    @Test func eachRenamedIDHasItsNewOne() {
        #expect(LampTranslationID.renamed == [
            "ASVs": "ASV", "BSBs": "BSB", "KJVs": "KJV", "WEBs": "WEB",
            "ESVs": "ESV", "NETs": "NET", "ABPs": "ABP",
        ])
        #expect(LampTranslationID.current("BSBs") == "BSB")
        #expect(LampTranslationID.current("BSB") == "BSB")
        #expect(LampTranslationID.current("NASB") == "NASB")
        #expect(LampTranslationID.isEarlier("KJVs"))
        #expect(!LampTranslationID.isEarlier("KJV"))
        #expect(!LampTranslationID.isEarlier("LXX"))
    }

    /// What an identity is built from: the same under either name, and for a
    /// translation never renamed, itself.
    @Test func theOriginalIDIsTheFirstUnderEitherName() {
        #expect(LampTranslationID.original("BSB") == "BSBs")
        #expect(LampTranslationID.original("BSBs") == "BSBs")
        #expect(LampTranslationID.original("NASB") == "NASB")
        #expect(LampTranslationID.equivalents(of: "ESVs") == ["ESV", "ESVs"])
        #expect(LampTranslationID.equivalents(of: "ESV") == ["ESV", "ESVs"])
        #expect(LampTranslationID.equivalents(of: "NIV") == ["NIV"])
        #expect(LampTranslationID.sameTranslation("ESV", "ESVs"))
        #expect(!LampTranslationID.sameTranslation("ESV", "NET"))
    }

    /// A reference reads as the module it names where that is held, and
    /// otherwise as the one its name now belongs to; two held side by side
    /// are never confused.
    @Test func aReferenceReadsAsTheModuleHeld() {
        #expect(LampTranslationID.held("BSB", among: ["BSBs", "NASB"]) == "BSBs")
        #expect(LampTranslationID.held("BSBs", among: ["BSB"]) == "BSB")
        #expect(LampTranslationID.held("ESVs", among: ["ESVs", "ESV"]) == "ESVs")
        #expect(LampTranslationID.held("ESV", among: ["ESVs", "ESV"]) == "ESV")
        #expect(LampTranslationID.held("NASB", among: ["NASB"]) == "NASB")
        #expect(LampTranslationID.held("NIV", among: ["NASB"]) == nil)
    }

    /// A list keeps its order and each held translation once, the first
    /// place it was named.
    @Test func aListNamesEachHeldTranslationOnce() {
        #expect(LampTranslationID.held(["BSBs", "ESV"], among: ["BSB", "ESV"]) == ["BSB", "ESV"])
        #expect(LampTranslationID.held(["BSBs", "BSB"], among: ["BSBs", "BSB"]) == ["BSBs", "BSB"])
        #expect(LampTranslationID.held(["BSBs", "BSB"], among: ["BSB"]) == ["BSB"])
        #expect(LampTranslationID.held(["NIV", "KJVs"], among: ["KJV"]) == ["KJV"])
    }

    /// The default set's real ID, from a file that spelled it as a module ID,
    /// is named by the translation's first ID whichever of its IDs the file
    /// gives, so every device names it alike.
    @Test func theDefaultSetIsNamedByTheFirstID() {
        #expect(LampWebDAVPersonalArchiveAdapter.canonicalDefaultSetID(
            "personal-highlights-BSBs", translationID: "BSBs"
        ) == "personal-highlights:BSBs")
        #expect(LampWebDAVPersonalArchiveAdapter.canonicalDefaultSetID(
            "personal-highlights-BSB", translationID: "BSB"
        ) == "personal-highlights:BSBs")
        #expect(LampWebDAVPersonalArchiveAdapter.canonicalDefaultSetID(
            "personal-highlights-NASB", translationID: "NASB"
        ) == "personal-highlights:NASB")
        #expect(LampWebDAVPersonalArchiveAdapter.canonicalDefaultSetID(
            "somebody's-set", translationID: "BSB"
        ) == "somebody's-set")
    }
}
