import Foundation
import Testing
@testable import LampCore

struct LampTranslationLanguagesTests {
    @Test func translationsGroupByTheLanguageTheyDeclare() {
        let items: [(id: String, language: String?)] = [
            ("BSBs", "en"), ("LXX", "grc"), ("LSG", "fr"), ("TAHOT", "hbo"), ("KJVs", "en"),
            ("TAGNT", "grc-x-koine"), ("RVR", "es"), ("Mystery", nil), ("HMOD", "he"),
        ]
        let groups = LampTranslationLanguages.grouped(items, language: \.language, locale: Locale(identifier: "en_US"))
        #expect(groups.map(\.title) == ["English", "French", "Hebrew", "Spanish", "Other Languages", "Biblical Languages"])
        #expect(groups.first?.items.map(\.id) == ["BSBs", "KJVs"])
        #expect(groups.last?.items.map(\.id) == ["LXX", "TAHOT", "TAGNT"])
        #expect(LampTranslationLanguages.isBiblical("hbo"))
        #expect(!LampTranslationLanguages.isBiblical("he"))
        #expect(!LampTranslationLanguages.isBiblical(nil))
    }

    @Test func aReaderInAnotherLanguageSeesTheirsFirst() {
        let items: [(id: String, language: String?)] = [("BSBs", "en"), ("LSG", "fr")]
        let groups = LampTranslationLanguages.grouped(items, language: \.language, locale: Locale(identifier: "fr_FR"))
        #expect(groups.map(\.id) == ["fr", "en"])
        #expect(groups.first?.title == "français")
    }
}
