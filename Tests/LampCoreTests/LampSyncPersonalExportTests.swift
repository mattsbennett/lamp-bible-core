import Testing
@testable import LampCore

struct LampSyncPersonalExportTests {
    @Test func skipsOnlyAnEmptyHighlightSet() async throws {
        let ready = try await LampSyncPersonalExport.highlightsIfPresent { "highlights.lamp" }
        #expect(ready == "highlights.lamp")

        let empty: String? = try await LampSyncPersonalExport.highlightsIfPresent {
            throw LampLibraryError.noPersonalHighlights(translationID: "TEST")
        }
        #expect(empty == nil)

        do {
            let _: String? = try await LampSyncPersonalExport.highlightsIfPresent {
                throw LampLibraryError.invalidPersonalContent("damaged highlights")
            }
            Issue.record("An export failure must stop sync publication")
        } catch let error as LampLibraryError {
            #expect(error == .invalidPersonalContent("damaged highlights"))
        }
    }
}
