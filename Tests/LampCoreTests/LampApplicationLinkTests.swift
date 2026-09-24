import Foundation
import Testing
@testable import LampCore

struct LampApplicationLinkTests {
    @Test func preservesLegacyAndModernScriptureLinks() throws {
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://verse/43003016/43003018?translation=KJV"
        ))) == .verse(reference: 43_003_016, endReference: 43_003_018, translationID: "KJV"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://john3:16"
        ))) == .verse(reference: 43_003_016, endReference: nil, translationID: nil))

        let encoded = try #require(LampApplicationLink.verseURL(
            reference: 43_003_016, endReference: 43_003_018,
            translationID: "My Bible"
        ))
        #expect(encoded.absoluteString ==
            "lampbible://reference/john3:16-18?translation=My%20Bible")
        #expect(LampApplicationLink(url: encoded) ==
            .verse(reference: 43_003_016, endReference: 43_003_018,
                   translationID: "My Bible"))
    }

    @Test func readsBothAppsRoutesWithoutDiscardingArguments() throws {
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://reading/43003016/43003018?external=1"
        ))) == .reading(reference: 43_003_016, endReference: 43_003_018,
                       openExternal: true))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://strongs/G1234"
        ))) == .strongs("G1234"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://read?reference=43003016&translation=KJV"
        ))) == .reader(reference: 43_003_016, translationID: "KJV"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://books?module=BOOK&section=one"
        ))) == .book(moduleID: "BOOK", sectionID: "one"))
        #expect(LampApplicationLink(url: URL(fileURLWithPath: "/tmp/test.lamp")) ==
            .moduleFile(URL(fileURLWithPath: "/tmp/test.lamp")))
    }
}
