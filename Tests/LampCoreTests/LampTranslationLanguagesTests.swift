import Foundation
import Testing
@testable import LampCore
import LampModuleKit

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

    @Test func wholeBiblesComeBeforePartsWithinALanguage() {
        let items: [(id: String, language: String?, whole: Bool)] = [
            ("Brenton", "en", false), ("BSB", "en", true), ("TAGNT", "grc", false),
            ("WEB", "en", true), ("LXX", "grc", false), ("RV1909", "es", true),
        ]
        let groups = LampTranslationLanguages.grouped(
            items, language: \.language, holdsWholeBible: \.whole, locale: Locale(identifier: "en_US")
        )
        let english = groups[0]
        #expect(english.items.map(\.id) == ["BSB", "WEB", "Brenton"])
        #expect(english.parts.map(\.scope) == [.wholeBible, .partOfTheBible])
        #expect(english.parts.map(\.title) == [nil, "Part of the Bible"])
        #expect(english.parts.last?.items.map(\.id) == ["Brenton"])
        // A language with only one kind has only that part, still named
        // where it is a part, so the biblical languages say they are.
        #expect(groups[1].parts.map(\.scope) == [.wholeBible])
        #expect(groups[2].parts.map(\.scope) == [.partOfTheBible])
        #expect(groups[2].items.map(\.id) == ["TAGNT", "LXX"])
        // Not told which are whole, a group is one untitled part as before.
        let plain = LampTranslationLanguages.grouped(items, language: \.language, locale: Locale(identifier: "en_US"))
        #expect(plain[0].items.map(\.id) == ["Brenton", "BSB", "WEB"])
        #expect(plain[0].parts.count == 1 && plain[0].parts[0].title == nil)
    }

    @Test func aWholeBibleHoldsEveryOneOfTheSixtySixBooks() {
        #expect(LampCanonicalBooks.holdsEveryBook(1...66))
        #expect(LampCanonicalBooks.holdsEveryBook(Array(1...66) + [67, 66]))
        #expect(!LampCanonicalBooks.holdsEveryBook(Array(1...66).filter { $0 != 16 }))
        #expect(!LampCanonicalBooks.holdsEveryBook(40...66))
        #expect(!LampCanonicalBooks.holdsEveryBook([]))
    }

    @Test func aReaderInAnotherLanguageSeesTheirsFirst() {
        let items: [(id: String, language: String?)] = [("BSBs", "en"), ("LSG", "fr")]
        let groups = LampTranslationLanguages.grouped(items, language: \.language, locale: Locale(identifier: "fr_FR"))
        #expect(groups.map(\.id) == ["fr", "en"])
        #expect(groups.first?.title == "français")
    }
}
