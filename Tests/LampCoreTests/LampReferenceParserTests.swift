import Testing
@testable import LampCore

struct LampReferenceParserTests {
    @Test(arguments: [
        "John 1:1-", "-John 1:1", "John 0:1", "John 1:0", "John 1000:1",
        "John 1:1000", "John 1:99999999999999999999", "John 1:1-1000",
        "John 1:1-2:0", "John 1:1-1000:1",
    ])
    func rejectsIncompleteOrUnrepresentableReferences(source: String) {
        #expect(throws: LampAgentError.self) { try LampReferenceParser.parse(source) }
    }

    @Test(arguments: [("Exo. 1:1", 2), ("Psa 119:176", 19), ("Eze. 1:1", 26), ("1 Sam. 1:1", 9)])
    func legacyDictionaryAbbreviationsUseTheSharedCatalog(source: String, book: Int) throws {
        #expect(try LampReferenceParser.parse(source).start.book == book)
    }
}
