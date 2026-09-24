import Foundation
import Testing
@testable import LampModuleKit

private struct BookBlockFixture: Decodable, Equatable {
    let type: String
    let content: String
}

struct LampPortableBookJSONTests {
    @Test func malformedLaterBookBlockDoesNotEraseEarlierContent() {
        let decoded = LampPortableBookJSON.decodeArray(
            #"[{"type":"paragraph","content":"First"},{"type":"paragraph","content":42},{"type":"heading","content":"Last"}]"#,
            as: BookBlockFixture.self
        )
        #expect(decoded.items == [
            BookBlockFixture(type: "paragraph", content: "First"),
            BookBlockFixture(type: "heading", content: "Last"),
        ])
        #expect(decoded.discardedCount == 1)
    }

    @Test func mediaPathsRejectTraversalAcrossBothLayouts() {
        #expect(LampPortableBookJSON.isSafeFilename("photo.jpg"))
        #expect(!LampPortableBookJSON.isSafeFilename("../photo.jpg"))
        #expect(LampPortableBookJSON.safeRelativeMediaPath("chapters/one/photo.jpg")
            == "chapters/one/photo.jpg")
        #expect(LampPortableBookJSON.safeRelativeMediaPath("chapters/%2E%2E/photo.jpg") == nil)
        #expect(LampPortableBookJSON.safeRelativeMediaPath("chapters\\photo.jpg") == nil)
    }

    @Test func richBookBlockRetainsTableAndAnnotationMetadata() throws {
        let json = #"""
        [{"type":"table","columnCount":2,"rows":[{"cells":[
          {"column":0,"colSpan":2,"header":true,"content":{"text":"John 1:1","annotations":[
            {"type":"scripture","start":0,"end":8,"data":{"sv":43001001,"source":"KJV","pageNum":12}}
          ]}}
        ]}]}]
        """#
        let decoded = LampPortableBookJSON.decodeArray(json, as: LampBookContentBlock.self)
        #expect(decoded.discardedCount == 0)
        let cell = try #require(decoded.items.first?.rows.first?.cells.first)
        #expect(cell.columnSpan == 2)
        #expect(cell.isHeader)
        #expect(cell.content.annotations.first?.data?.source == "KJV")
        #expect(cell.content.annotations.first?.data?.pageNumber == "12")
        let encoded = try JSONEncoder().encode(decoded.items)
        let roundTrip = try JSONDecoder().decode([LampBookContentBlock].self, from: encoded)
        #expect(roundTrip == decoded.items)
    }
}
