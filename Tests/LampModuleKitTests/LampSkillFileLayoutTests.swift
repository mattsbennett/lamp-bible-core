import Testing
@testable import LampModuleKit

/// The reader's own skills, published one file at a time under
/// `Workspaces/Skills`, and deleted everywhere one file at a time.
struct LampSkillFileLayoutTests {
    @Test func aSkillsFilesAreNamedByTheSkillAndTheirPathInIt() throws {
        let path = try LampWritingWorkspaceLayout.skillPath(name: "word-study", relativePath: "references/a.md")
        #expect(path == "Workspaces/Skills/word-study/references/a.md")
        let file = try #require(LampWritingWorkspaceLayout.skillFile(ofPath: path))
        #expect(file.name == "word-study")
        #expect(file.relativePath == "references/a.md")
        #expect(LampSyncLocalDeletion.target(of: path) == .skillFile(name: "word-study", relativePath: "references/a.md"))
        #expect(LampSyncLocalDeletion.target(of: path).isAllowed)
    }

    /// Only a skill's own name, and only paths that stay inside it.
    @Test func whatIsNotASkillsFileIsRefused() {
        for path in [
            "Workspaces/Skills/word-study",
            "Workspaces/Skills/Word Study/SKILL.md",
            "Workspaces/Skills/.lamp/SKILL.md",
            "Workspaces/Skills/word-study/../other/SKILL.md",
            "Workspaces/Skills/word-study//SKILL.md",
            "Workspaces/Writing/w/Skills/word-study/SKILL.md",
        ] {
            #expect(LampWritingWorkspaceLayout.skillFile(ofPath: path) == nil, "\(path)")
            if case .skillFile = LampSyncLocalDeletion.target(of: path) {
                Issue.record("\(path) was taken for a skill's file")
            }
        }
        #expect(throws: (any Error).self) {
            try LampWritingWorkspaceLayout.skillPath(name: "word-study", relativePath: "../a.md")
        }
    }

    /// In NFC, as a document's name is: two Macs spelling one file two ways
    /// must agree it is one file.
    @Test func aSkillsFileIsNamedInNFC() throws {
        let file = try #require(LampWritingWorkspaceLayout.skillFile(
            ofPath: "Workspaces/Skills/word-study/Ro\u{0308}mer.md"
        ))
        #expect(file.relativePath == "R\u{00F6}mer.md")
        // A name that begins with a combining mark is still split at its
        // slash.
        let marked = try #require(LampWritingWorkspaceLayout.skillFile(
            ofPath: "Workspaces/Skills/word-study/\u{0301}accent.md"
        ))
        #expect(marked.name == "word-study")
        #expect(LampWritingWorkspaceLayout.skillFile(ofPath: "Workspaces/Skills/word-study/a\\b.md") == nil)
        #expect(LampWritingWorkspaceLayout.skillFile(ofPath: "Workspaces/Skills/word-study/a\\\u{0301}b.md") == nil)
        #expect(throws: (any Error).self) {
            try LampWritingWorkspaceLayout.skillPath(name: "word-study/references", relativePath: "a.md")
        }
    }
}
