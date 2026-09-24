import Testing
@testable import LampCore

struct LampExternalBibleLinkTests {
    @Test func formatsEveryExternalApplicationFromOneBookCatalog() {
        let start = 43_003_016
        let end = 43_003_018

        #expect(LampExternalBibleApplication.accordance.url(
            startReference: start, endReference: end
        )?.absoluteString == "accord://read/John_3:16-John_3:18")
        #expect(LampExternalBibleApplication.eSword.url(
            startReference: start
        )?.absoluteString == "e-sword://john.3:16")
        #expect(LampExternalBibleApplication.logos.url(
            startReference: start
        )?.absoluteString == "https://ref.ly/john3:16")
        #expect(LampExternalBibleApplication.oliveTree.url(
            startReference: start
        )?.absoluteString == "olivetree://bible/43.3.16")
        #expect(LampExternalBibleApplication.youVersion.url(
            startReference: start, endReference: end
        )?.absoluteString == "youversion://bible?reference=John.3.16-18")
        #expect(LampExternalBibleApplication.youVersion.url(
            startReference: start, endReference: 43_004_001
        )?.absoluteString == "youversion://bible?reference=John.3")
    }

    @Test func installedBookMetadataCanOverrideCanonicalCatalog() {
        let link = LampExternalBibleApplication.accordance.url(
            startReference: 43_003_016, endReference: 43_003_018
        ) { number in
            LampExternalBibleBook(number: number, name: "John", osisID: "Jn")
        }
        #expect(link?.absoluteString == "accord://read/Jn_3:16-Jn_3:18")
        #expect(LampExternalBibleApplication.logos.url(
            startReference: 43_003_016
        ) { _ in nil } == nil)
    }
}
