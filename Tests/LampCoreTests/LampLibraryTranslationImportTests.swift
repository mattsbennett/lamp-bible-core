import LampCore
import LampModuleKit
import Testing

struct LampLibraryTranslationImportTests {
    private let bundledKJV = LampInstalledModule(
        id: "KJVs", kind: .translation, name: "King James Version", abbreviation: "KJV", isBundled: true
    )

    @Test func onlyATranslationTheUserInstalledIsReplaced() {
        let earlier = LampInstalledModule(id: "imported-nasb", kind: .translation, name: "NASB 1995", abbreviation: "nasb")
        let replacing = LampTranslationImporter.destination(abbreviation: "NASB", installed: [bundledKJV, earlier])
        #expect(replacing.moduleID == "imported-nasb")
        #expect(replacing.replacedModuleID == "imported-nasb")

        let dictionary = LampInstalledModule(id: "imported-NASB", kind: .dictionary, name: "Not a Bible")
        let avoiding = LampTranslationImporter.destination(abbreviation: "NASB", installed: [dictionary])
        #expect(avoiding.moduleID == "imported-NASB-2")
        #expect(avoiding.replacedModuleID == nil)

        let bundled = LampInstalledModule(id: "imported-KJV", kind: .translation, name: "Bundled", isBundled: true)
        #expect(LampTranslationImporter.destination(abbreviation: "KJV", installed: [bundled]).moduleID == "imported-KJV-2")
    }

    @Test func aTranslationAlreadyShownUnderTheAbbreviationIsFound() {
        let destination = LampTranslationImporter.destination(abbreviation: "kjv", installed: [bundledKJV])
        #expect(LampTranslationImporter.translation(sharingAbbreviation: "kjv", installed: [bundledKJV], except: destination) == bundledKJV)
    }
}
