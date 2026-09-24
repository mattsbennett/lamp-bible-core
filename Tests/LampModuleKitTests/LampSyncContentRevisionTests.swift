import Foundation
import Testing
@testable import LampModuleKit

struct LampSyncContentRevisionTests {
    @Test func tokenDependsOnBytes() {
        #expect(
            LampSyncContentRevision.token(for: Data("abc".utf8)) ==
                "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            LampSyncContentRevision.token(for: Data("abc".utf8)) !=
                LampSyncContentRevision.token(for: Data("abd".utf8))
        )
    }

    @Test func observedBodyMustMatchExpectedRevision() {
        let original = Data("original".utf8)
        let changed = Data("changed".utf8)
        let digest = LampSyncContentRevision.digest(for: original)
        let token = LampSyncContentRevision.token(for: original)
        #expect(LampSyncContentRevision.matchesDigest(nil, observed: nil))
        #expect(LampSyncContentRevision.matchesToken(nil, observed: nil))
        #expect(LampSyncContentRevision.matchesDigest(digest, observed: original))
        #expect(LampSyncContentRevision.matchesToken(token, observed: original))
        #expect(!LampSyncContentRevision.matchesDigest(digest, observed: changed))
        #expect(!LampSyncContentRevision.matchesToken(token, observed: changed))
        #expect(!LampSyncContentRevision.matchesDigest(nil, observed: original))
        #expect(!LampSyncContentRevision.matchesToken(token, observed: nil))
    }

    @Test func mediaWithoutMergeBaseCannotReplaceDifferentBytes() {
        let local = Data("local photo".utf8)
        #expect(LampSyncContentRevision.allowsUnbasedWrite(local, over: nil))
        #expect(LampSyncContentRevision.allowsUnbasedWrite(local, over: local))
        #expect(!LampSyncContentRevision.allowsUnbasedWrite(
            local, over: Data("remote photo".utf8)
        ))
    }
}
