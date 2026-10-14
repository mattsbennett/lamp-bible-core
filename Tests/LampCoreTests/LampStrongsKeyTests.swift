import Testing
@testable import LampCore

struct LampStrongsKeyTests {
    @Test(arguments: [
        (" h07225 ", "H7225"), ("G03588a", "G3588A"), ("0776", "776"),
        ("th08804", "TH8804"), ("G0000", "G0"), (" ", ""),
    ])
    func normalizesImportedKeySpellings(input: String, expected: String) {
        #expect(LampStrongsKey.normalized(input) == expected)
    }

    @Test func matchingKeepsLanguagesAndSuffixesDistinct() {
        #expect(LampStrongsKey.matches("H7225", "h07225"))
        #expect(LampStrongsKey.matches("H776", "0776"))
        #expect(LampStrongsKey.matches("TH08804", "th8804"))
        #expect(!LampStrongsKey.matches("H3056", "G3056"))
        #expect(!LampStrongsKey.matches("G3588a", "G3588b"))
        #expect(!LampStrongsKey.matches("TH8804", "H8804"))
        #expect(!LampStrongsKey.matches("HWORD", "WORD"))
        #expect(!LampStrongsKey.matches("", ""))
        #expect(!LampStrongsKey.matches("H99999999999999999999", "H99999999999999999998"))
    }

    @Test func readerTargetsExpandListsWithoutUntranslatedMarkersOrDuplicates() {
        #expect(LampStrongsKey.readerLookupKeys([
            "H0853,H01254", "h1254; G3056|G3588a", " G03056 ", "",
        ]) == ["H1254", "G3056", "G3588A"])
        #expect(LampStrongsKey.readerLookupKeys(["H853"]) == [])
        #expect(!LampStrongsKey.hasAnnotations([nil, "", "   "]))
        #expect(LampStrongsKey.hasAnnotations([nil, " H7225 "]))
    }
}
