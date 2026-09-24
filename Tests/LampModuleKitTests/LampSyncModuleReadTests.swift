import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncModuleReadTests {
    @Test func webDAVReadKeepsBodyAndOnlyItsStrongGetRevision() {
        let body = Data("new remote body".utf8)
        let strong = LampSyncModuleRead.webDAV(
            LampSyncRemoteFile(data: body, revision: "\"new\"")
        )
        #expect(strong.data == body)
        #expect(strong.revision == "\"new\"")

        let weak = LampSyncModuleRead.webDAV(
            LampSyncRemoteFile(data: body, revision: "W/\"old\"")
        )
        #expect(weak.data == body)
        #expect(weak.revision == nil)
    }

    @Test func contentReadDerivesRevisionFromReturnedBody() {
        let body = Data("cloud body".utf8)
        let snapshot = LampSyncModuleRead.content(body)
        #expect(snapshot.data == body)
        #expect(snapshot.revision == LampSyncContentRevision.digest(for: body))
    }
}
