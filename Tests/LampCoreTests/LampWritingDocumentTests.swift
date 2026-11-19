import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

/// A writing's documents: which files they are, where they sit on the
/// server, the name a device's edits are kept under, and the store both apps
/// take a download in through.
struct LampWritingWorkspaceLayoutTests {
    /// The folder name is a stored format: every workspace on every device
    /// is named by it.
    @Test func aKnownIdentifierKeepsItsFolderName() {
        #expect(LampWritingWorkspaceLayout.directoryName(for: "7B4E2A10-9C3F-4D21-8A56-0E1F2C3D4B5A")
            == "7B4E2A10-9C3F-4D21-8A56-0E1F2C3D4B5A-e1288be9a6ffbc1d")
        #expect(LampWritingWorkspaceLayout.directoryName(for: "abc") == "abc-e71fa2190541574b")
        #expect(LampWritingWorkspaceLayout.directoryName(for: "///") == "devotional-eed41417e7153e64")
    }

    @Test func theWritersOwnFilesAreDocumentsAndLampsAreNot() {
        for name in ["outline.md", "Notes.markdown", "sources.txt", "a.text", "Outline (edits from iPhone, 2026-11-19 14.05).md"] {
            #expect(LampWritingWorkspaceLayout.isDocumentName(name), "\(name)")
        }
        for name in ["draft.md", "DRAFT.md", "AGENTS.md", "claude.md", "DEVOTIONAL_CONTEXT.md", "opencode.json",
                     ".\u{301}notes.md",
                     ".hidden.md", ".md", "a/b.md", "a:b.md", "a\\b.md", "line\nbreak.md", "outline", ""] {
            #expect(!LampWritingWorkspaceLayout.isDocumentName(name), "\(name)")
        }
    }

    /// A name spelled decomposed, as macOS can hand one back, is the same
    /// document at the same path as the composed spelling.
    @Test func aNameIsOnePathHoweverItIsSpelled() throws {
        let composed = "Notes \u{2013} R\u{F6}mer.md", decomposed = "Notes \u{2013} Ro\u{308}mer.md"
        let one = try LampWritingWorkspaceLayout.documentPath(writingID: "w", name: composed)
        let other = try LampWritingWorkspaceLayout.documentPath(writingID: "w", name: decomposed)
        #expect(one == other)
        #expect(one == "Workspaces/Writing/\(LampWritingWorkspaceLayout.directoryName(for: "w"))/Documents/\(composed)")
        let read = try #require(LampWritingWorkspaceLayout.document(ofPath: "Workspaces/Writing/f/Documents/\(decomposed)"))
        #expect(read.folder == "f" && read.name == composed && read.name.unicodeScalars.elementsEqual(composed.unicodeScalars))
        #expect(LampSyncFolderLayout.kind(of: one) == .writingDocument)
    }

    @Test func onlyTheDocumentsOfAWritingWorkspaceAreDocuments() throws {
        #expect(throws: LampSyncFolderLayout.PathError.self) {
            try LampWritingWorkspaceLayout.documentPath(writingID: "w", name: "draft.md")
        }
        for path in ["Workspaces/Writing/f/Documents/sub/a.md", "Workspaces/Writing/f/a.md",
                     "Workspaces/Writing/f/Context/a.md", "Workspaces/Other/f/Documents/a.md",
                     "Workspaces/Writing/f/DeletedFiles.json", "Workspaces/Writing/f/Documents/draft.md"] {
            #expect(LampWritingWorkspaceLayout.document(ofPath: path) == nil, "\(path)")
            #expect(LampSyncFolderLayout.kind(of: path) == .workspaceFile, "\(path)")
        }
        #expect(LampSyncFolderLayout.kind(of: "Workspaces/Writing/.f/Documents/a.md") == nil)
    }

    /// Whatever a device is called and however long the document's name,
    /// the copy's name is a document's, fits, says it is a copy, and keeps
    /// the document's kind of file.
    @Test func aKeptCopysNameIsAlwaysADocumentsName() {
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let devices = ["iPhone", "Matt's iPad", "a/b:c\\d", "(Work), Mac", "  ", "", "\n\t", ".hidden",
                       String(repeating: "\u{1F1E8}\u{1F1E6}", count: 28), ".\u{301}x",
                       String(repeating: "Ü", count: 300), "Ro\u{308}mer's \u{1F4F1}"]
        let names = ["outline.md", "Notes.TXT", "a.markdown", String(repeating: "long ", count: 60) + ".md",
                     String(repeating: "\u{1F4D6}", count: 70) + ".text", "x (edits from Mac, 2026-01-01 01.01).md"]
        for device in devices {
            for name in names {
                let copy = LampWritingWorkspaceLayout.keptCopyName(of: name, device: device, at: when, timeZone: utc)
                #expect(LampWritingWorkspaceLayout.isDocumentName(copy), "\(copy)")
                #expect(LampWritingWorkspaceLayout.isKeptCopy(copy), "\(copy)")
                #expect(copy.utf8.count <= LampWritingWorkspaceLayout.maximumKeptCopyBytes, "\(copy)")
                #expect((copy as NSString).pathExtension == (name as NSString).pathExtension, "\(copy)")
                #expect(copy.contains("2026-11-18 11.06"), "\(copy)")
            }
        }
        #expect(LampWritingWorkspaceLayout.keptCopyName(of: "outline.md", device: "iPhone", at: when, timeZone: utc)
            == "outline (edits from iPhone, 2026-11-18 11.06).md")
        #expect(!LampWritingWorkspaceLayout.isKeptCopy("outline.md"))
        #expect(!LampWritingWorkspaceLayout.isKeptCopy("notes (edits from me).md"))
    }

    /// A name already taken here gets a number, never the taken name.
    @Test func aKeptCopyNeverTakesANameInUse() {
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let first = LampWritingWorkspaceLayout.keptCopyName(of: "a.md", device: "iPhone", at: when, timeZone: utc)
        let second = LampWritingWorkspaceLayout.keptCopyName(
            of: "a.md", device: "iPhone", at: when, timeZone: utc, taken: { $0 == first }
        )
        #expect(second == "a (edits from iPhone, 2026-11-18 11.06 2).md")
        #expect(LampWritingWorkspaceLayout.isKeptCopy(second))
    }
}

struct LampWritingDocumentStoreTests {
    private func temporaryStore() throws -> LampWritingDocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LampWritingDocumentStore(rootURL: root)
    }

    private let path = try! LampWritingWorkspaceLayout.documentPath(writingID: "w", name: "outline.md")

    private func digest(_ text: String) -> String { LampSyncContentRevision.digest(for: Data(text.utf8)) }

    /// A new name that differs from one already there only in case is
    /// refused: one file here, two on the server.
    @Test func aNameDifferingOnlyInCaseIsRefused() throws {
        let store = try temporaryStore()
        #expect(try store.write(Data("a".utf8), writingID: "w", name: "Notes.md", replacing: nil))
        #expect(try !store.write(Data("b".utf8), writingID: "w", name: "notes.md", replacing: nil))
        #expect(try store.documents(writingID: "w").map(\.text) == ["a"])
    }

    @Test func aDownloadOfANewDocumentIsTaken() throws {
        let store = try temporaryStore()
        let decision = try store.takeIn(downloaded: Data("one".utf8), path: path, agreedDigest: nil, localDevice: "Mac")
        #expect(decision == .take)
        #expect(try store.documents(writingID: "w").map(\.text) == ["one"])
        #expect(try store.held().mapValues { $0.resolvingSymlinksInPath().path }
            == [path: store.url(writingID: "w", name: "outline.md").resolvingSymlinksInPath().path])
    }

    /// Edited here since last agreed, however the pass found it: the
    /// server's copy under the name, this device's edits beside it.
    @Test func anEditHeldHereIsKeptAsACopy() throws {
        let store = try temporaryStore()
        #expect(try store.write(Data("mine".utf8), writingID: "w", name: "outline.md", replacing: nil))
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        let decision = try store.takeIn(
            downloaded: Data("theirs".utf8), path: path, agreedDigest: digest("agreed"), localDevice: "iPhone", at: when
        )
        guard case .takeKeepingHeldAs(let copy) = decision else { Issue.record("\(decision)"); return }
        let documents = try store.documents(writingID: "w")
        #expect(Set(documents.map(\.text)) == ["mine", "theirs"])
        #expect(documents.first { $0.name == "outline.md" }?.text == "theirs")
        #expect(documents.first { $0.name == copy }?.isKeptCopy == true)
        #expect(try store.held().count == 2)

        // The same again keeps the copy already made and makes no other.
        #expect(try store.takeIn(downloaded: Data("theirs".utf8), path: path, agreedDigest: nil, localDevice: "iPhone") == .keep)
        #expect(try store.documents(writingID: "w").count == 2)
    }

    @Test func onlyTheServerMovedReplacesTheCopyHere() throws {
        let store = try temporaryStore()
        try store.write(Data("old".utf8), writingID: "w", name: "outline.md", replacing: nil)
        #expect(try store.takeIn(downloaded: Data("new".utf8), path: path, agreedDigest: digest("old"), localDevice: "Mac") == .take)
        #expect(try store.documents(writingID: "w").map(\.text) == ["new"])
    }

    /// A save over a copy that changed since the editor opened it writes
    /// nothing, so a download taken in between is never written over.
    @Test func aSaveOverAChangedCopyIsRefused() throws {
        let store = try temporaryStore()
        try store.write(Data("opened".utf8), writingID: "w", name: "outline.md", replacing: nil)
        try store.takeIn(downloaded: Data("arrived".utf8), path: path, agreedDigest: digest("opened"), localDevice: "Mac")
        #expect(try !store.write(Data("typed".utf8), writingID: "w", name: "outline.md", replacing: Data("opened".utf8)))
        #expect(try !store.write(Data("typed".utf8), writingID: "w", name: "outline.md", replacing: nil))
        #expect(try store.documents(writingID: "w").map(\.text) == ["arrived"])
        #expect(try store.write(Data("typed".utf8), writingID: "w", name: "outline.md", replacing: Data("arrived".utf8)))
        #expect(try store.documents(writingID: "w").map(\.text) == ["typed"])
    }

    @Test func aDeletionRemovesTheFileAndIsDatedAfterTheSaveItRemoves() throws {
        let store = try temporaryStore()
        try store.write(Data("x".utf8), writingID: "w", name: "outline.md", replacing: nil)
        let agreed = LampSyncContentRevision.digest(for: Data("x".utf8))
        #expect(try store.remove(path: path, agreedDigest: agreed, localDevice: "Mac") == nil)
        #expect(try store.documents(writingID: "w").isEmpty)
        try store.remove(writingID: "w", name: "outline.md")
        #expect(LampWritingDocumentStore.deletionTime(of: path, members: [path: 5_000], now: 4_000) == 5_001)
        #expect(LampWritingDocumentStore.deletionTime(of: path, members: [path: 5_000], now: 9_000) == 9_000)
        #expect(LampWritingDocumentStore.deletionTime(of: path, members: [:], now: 9_000) == 9_000)
    }

    /// A deletion made elsewhere never takes an edit made here since this
    /// device last agreed with the server: the edit is kept as a copy.
    @Test func aDeletionKeepsAnEditMadeHere() throws {
        let store = try temporaryStore()
        try store.write(Data("edited".utf8), writingID: "w", name: "outline.md", replacing: nil)
        let agreed = LampSyncContentRevision.digest(for: Data("as sent".utf8))
        let copy = try #require(try store.remove(path: path, agreedDigest: agreed, localDevice: "iPhone"))
        #expect(LampWritingWorkspaceLayout.isKeptCopy(copy))
        #expect(try store.documents(writingID: "w").map(\.name) == [copy])
        #expect(try store.documents(writingID: "w").map(\.text) == ["edited"])
        // Never agreed at all, as a document made here and not yet sent.
        try store.write(Data("new".utf8), writingID: "w", name: "outline.md", replacing: nil)
        #expect(try store.remove(path: path, agreedDigest: nil, localDevice: "iPhone") != nil)
        #expect(try store.documents(writingID: "w").count == 2)
    }

    /// A deleted writing's documents go with it: removed here, and every
    /// one held here or on the server recorded as deleted. A writing still
    /// held, however its id is spelled, keeps its own.
    @Test func aDeletedWritingsDocumentsGoWithIt() throws {
        let store = try temporaryStore()
        try store.write(Data("a".utf8), writingID: "gone", name: "outline.md", replacing: nil)
        try store.write(Data("b".utf8), writingID: "kept", name: "outline.md", replacing: nil)
        let onServer = try LampWritingWorkspaceLayout.documentPath(writingID: "gone", name: "sources.md")
        let held = try LampWritingWorkspaceLayout.documentPath(writingID: "gone", name: "outline.md")
        let other = try LampWritingWorkspaceLayout.documentPath(writingID: "kept", name: "outline.md")
        let deletions = try store.deletions(
            deleted: ["gone", "KEPT"], held: ["kept"], members: [onServer: 5_000, other: 1], now: 4_000
        )
        #expect(deletions == [held: 4_000, onServer: 5_001])
        #expect(try store.documents(writingID: "gone").isEmpty)
        #expect(try store.documents(writingID: "kept").map(\.text) == ["b"])
    }

    /// The workspace's other files, Lamp's own and the draft, are never
    /// listed or gathered.
    @Test func onlyDocumentsAreListed() throws {
        let store = try temporaryStore()
        let folder = store.folderURL(writingID: "w")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("context"), withIntermediateDirectories: true)
        for name in ["draft.md", "AGENTS.md", "opencode.json", ".x.md", "context/a.md"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("y".utf8).write(to: folder.appendingPathComponent("Ro\u{308}mer.md"))
        let documents = try store.documents(writingID: "w")
        #expect(documents.map(\.name) == ["R\u{F6}mer.md"])
        #expect(try store.held().keys.sorted() == [try LampWritingWorkspaceLayout.documentPath(writingID: "w", name: "R\u{F6}mer.md")])
    }
}
