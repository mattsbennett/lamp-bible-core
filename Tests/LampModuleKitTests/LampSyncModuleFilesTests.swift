import Testing
@testable import LampModuleKit

struct LampSyncModuleFilesTests {
    @Test func missingRemoteRevisionAlwaysRequiresImport() {
        #expect(LampSyncModuleFiles.needsImport(
            isNew: false,
            installedPath: "notes.lamp", remotePath: "notes.lamp",
            installedRevision: nil, remoteRevision: nil
        ))
        #expect(LampSyncModuleFiles.needsImport(
            isNew: false,
            installedPath: "notes.lamp", remotePath: "notes.lamp",
            installedRevision: "\"old\"", remoteRevision: nil
        ))
        #expect(!LampSyncModuleFiles.needsImport(
            isNew: false,
            installedPath: "notes.lamp", remotePath: "notes.lamp",
            installedRevision: "\"same\"", remoteRevision: "\"same\""
        ))
    }

    @Test func canonicalFormatWinsAndInstalledPathBreaksTies() {
        let paths = ["notes.json", "notes.lamp", "notes.db.zlib"]
        #expect(LampSyncModuleFiles.preferredPath(
            among: paths, installedPath: "notes.json"
        ) == "notes.lamp")
        #expect(LampSyncModuleFiles.preferredPath(
            among: paths, installedPath: nil
        ) == "notes.lamp")
        #expect(LampSyncModuleFiles.preferredPath(
            among: paths, installedPath: "missing.db"
        ) == "notes.lamp")
        #expect(LampSyncModuleFiles.preferredPath(
            among: [], installedPath: "notes.json"
        ) == nil)
        #expect(LampSyncModuleFiles.preferredPath(
            among: ["bible-notes.lamp", "notes.lamp"], installedPath: "notes.lamp"
        ) == "notes.lamp")
    }

    @Test func aggregateJSONKeepsModulesWithoutCanonicalSuccessors() {
        let chosen = LampSyncModuleFiles.preferredPathsByIdentity([
            .init(identity: "first", path: "combined.json"),
            .init(identity: "second", path: "combined.json"),
            .init(identity: "first", path: "first.LAMP"),
        ])
        #expect(chosen["first"] == "first.LAMP")
        #expect(chosen["second"] == "combined.json")
        #expect(LampSyncModuleFiles.canonicalIdentity("bible-notes", isNotes: true) == "notes")
        #expect(LampSyncModuleFiles.canonicalIdentity("bible-notes", isNotes: false) == "bible-notes")
        #expect(LampSyncModuleFiles.matchesContentIdentity(
            listedID: "bible-notes", contentID: "notes", isNotes: true
        ))
        #expect(!LampSyncModuleFiles.matchesContentIdentity(
            listedID: "first", contentID: "second", isNotes: false
        ))
    }

    @Test func supersededCanonicalFileCannotHideActiveLegacyEdit() {
        let chosen = LampSyncModuleFiles.preferredPathsByIdentity([
            .init(identity: "first", path: "first.lamp", isSuperseded: true),
            .init(identity: "first", path: "combined.json"),
            .init(identity: "second", path: "combined.json"),
            .init(identity: "third", path: "third.lamp", isSuperseded: true),
        ])
        #expect(chosen["first"] == "combined.json")
        #expect(chosen["second"] == "combined.json")
        #expect(chosen["third"] == nil)
    }

    @Test func selectsOneActiveCandidateAndKeepsItsOriginalIndex() {
        let candidates: [LampSyncModuleFiles.Candidate] = [
            .init(identity: "first", path: "first.lamp", isSuperseded: true),
            .init(identity: "first", path: "first.lamp"),
            .init(identity: "first", path: "first.lamp"),
            .init(identity: "second", path: "combined.json"),
            .init(identity: "second", path: "second.lamp", isSuperseded: true),
            .init(identity: "third", path: "third.lamp", isSuperseded: true),
        ]
        #expect(LampSyncModuleFiles.preferredCandidateIndices(candidates) == [1, 3])
    }

    @Test func portableFilenameRecognitionIsCaseInsensitive() {
        #expect(LampSyncModuleFiles.moduleID(from: "Upper.LAMP") == "Upper")
        #expect(LampSyncModuleFiles.moduleID(from: "Upper.DB.ZLIB") == "Upper")
        #expect(LampSyncModuleFiles.moduleID(from: "Upper.DB") == "Upper")
        #expect(LampSyncModuleFiles.moduleID(from: "Upper.JSON") == "Upper")
        #expect(LampSyncModuleFiles.moduleID(from: "readme.txt") == nil)
        #expect(LampSyncModuleFiles.moduleID(from: ".lamp") == nil)
    }
}
