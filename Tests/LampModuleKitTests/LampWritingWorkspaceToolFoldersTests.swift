import Testing
@testable import LampModuleKit

/// A tool's folder anywhere under a writing's sources marks what is inside it
/// as the tool's output, not the writer's (`decisions/0023`).
struct LampWritingWorkspaceToolFoldersTests {
    @Test func whatIsInsideAtoolsFolderIsItsOutput() {
        #expect(LampWritingWorkspaceLayout.isToolOutput(relativePath: "deck-build/node_modules/a/index.js"))
        #expect(LampWritingWorkspaceLayout.isToolOutput(relativePath: "node_modules/x.js"))
        #expect(LampWritingWorkspaceLayout.isToolOutput(relativePath: "tool/venv/lib/site.py"))
        #expect(LampWritingWorkspaceLayout.isToolOutput(relativePath: "a/__pycache__/b.pyc"))
        #expect(LampWritingWorkspaceLayout.isToolOutput(relativePath: "repo/.git/HEAD"))
    }

    @Test func theWritersOwnFilesBesideItAreNot() {
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "deck-build/build.js"))
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "deck-build/package.json"))
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "deck-build/assets/slide.svg"))
        // Only exact names: a backup of one, or another spelling, is the writer's.
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "node_modules.bak/x.js"))
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "Node_Modules/x.js"))
        // A file called like a tool's folder is still a source.
        #expect(!LampWritingWorkspaceLayout.isToolOutput(relativePath: "notes/venv"))
    }
}
