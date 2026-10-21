import Foundation
import LampModuleKit
import Testing

struct LampTranslationImportReviewTests {
    @Test func aNewAbbreviationGetsItsOwnModule() {
        let destination = LampTranslationImporter.destination(
            abbreviation: "NASB", replaceableTranslationIDs: [], otherModuleIDs: ["KJVs"]
        )
        #expect(destination.moduleID == "imported-NASB")
        #expect(destination.replacedModuleID == nil)
    }

    @Test func importingAnAbbreviationAgainReplacesTheEarlierImportInItsOwnSpelling() {
        let destination = LampTranslationImporter.destination(
            abbreviation: "NASB", replaceableTranslationIDs: ["imported-nasb"], otherModuleIDs: ["KJVs"]
        )
        #expect(destination.moduleID == "imported-nasb")
        #expect(destination.replacedModuleID == "imported-nasb")
    }

    @Test func anIDHeldByAnythingElseIsAvoided() {
        let destination = LampTranslationImporter.destination(
            abbreviation: "NASB", replaceableTranslationIDs: [], otherModuleIDs: ["imported-NASB"]
        )
        #expect(destination.moduleID == "imported-NASB-2")
        #expect(destination.replacedModuleID == nil)
    }

    @Test func aSharedAbbreviationIsPointedOutUnlessItIsTheOneBeingReplaced() {
        let fresh = LampTranslationImporter.destination(abbreviation: "kjv", replaceableTranslationIDs: [], otherModuleIDs: ["KJVs"])
        #expect(LampTranslationImporter.translationID(
            sharingAbbreviation: "kjv", abbreviationsByTranslationID: ["KJVs": "KJV"], except: fresh
        ) == "KJVs")

        let replacing = LampTranslationImporter.destination(
            abbreviation: "ESV", replaceableTranslationIDs: ["imported-ESV"], otherModuleIDs: []
        )
        #expect(LampTranslationImporter.translationID(
            sharingAbbreviation: "ESV", abbreviationsByTranslationID: ["imported-ESV": "ESV"], except: replacing
        ) == nil)
    }

    @Test func theReportReadsAsSentences() {
        var report = LampTranslationImportReport()
        report.bookCount = 1
        report.chapterCount = 16
        report.verseCount = 433
        report.skippedBooks = ["TOB", "1MA"]
        report.verseBridges = [45_016_025]
        report.duplicateVerses = [45_001_001, 45_001_002]
        report.unrecognizedMarkup = ["\\zz": 2, "<foo>": 3]

        #expect(report.contentsDescription == "1 book, 16 chapters and 433 verses")
        #expect(report.notices == [
            "Left out, as they aren’t among the 66 books: TOB, 1MA.",
            "1 bridged verse is kept under its first number: Romans 16:25.",
            "Left out, as they appear twice: Romans 1:1, Romans 1:2.",
            "Formatting Lamp doesn’t know was dropped and its words kept: <foo> ×3, \\zz ×2.",
        ])
        #expect(report.completionMessage(translationName: "Romans Test", replaced: true)
            == "Replaced Romans Test: 1 book, 16 chapters and 433 verses.")
    }

    @Test func aCleanImportHasNothingToSayAndLongListsAreCut() {
        #expect(LampTranslationImportReport().notices.isEmpty)

        var report = LampTranslationImportReport()
        report.verseBridges = (1...7).map { 43_001_000 + $0 }
        #expect(report.notices == [
            "7 bridged verses are kept under their first number: John 1:1, John 1:2, John 1:3, John 1:4, John 1:5 and 2 more.",
        ])
    }

    @Test func theLanguagePickerAlwaysOffersWhatTheFileSaid() {
        let options = LampTranslationImporter.languageOptions(including: "en")
        #expect(options.contains { $0.code == "en" })
        #expect(options.allSatisfy { $0.code.count == 2 })
        #expect(LampTranslationImporter.languageOptions(including: "x-unknown").first?.code == "x-unknown")
    }
}
