import Foundation

/// Translations grouped by the language they are written in, as a picker
/// lists them: the reader's own language first, then any other modern
/// language by name, then the biblical languages last.
///
/// "Biblical Languages" rather than "Original Languages": the Greek
/// Septuagint is written in a biblical language but is itself a
/// translation of the Hebrew, so "original" would say something untrue of
/// it. Grouping is by what a module declares (`language`), never guessed
/// from its name.
public enum LampTranslationLanguages {
    public struct Group<Item>: Identifiable {
        /// The language code the group gathers, `biblical` for the biblical
        /// languages, or `other` for modules that declare none.
        public let id: String
        public let title: String
        public let items: [Item]
    }

    /// Koine and classical Greek, Biblical Hebrew and Aramaic. Modern Greek
    /// (`el`) and Hebrew (`he`) are modern languages and are not here.
    public static let biblicalCodes: Set<String> = ["grc", "hbo", "arc"]

    /// The primary subtag of a declared language: "grc" from "grc-x-koine".
    static func primary(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else { return nil }
        return code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
    }

    public static func isBiblical(_ code: String?) -> Bool {
        primary(code).map(biblicalCodes.contains) ?? false
    }

    /// `items` grouped by language, each group keeping the order it was
    /// given in.
    public static func grouped<Item>(
        _ items: [Item],
        language: (Item) -> String?,
        locale: Locale = .current
    ) -> [Group<Item>] {
        var byLanguage: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let code = primary(language(item))
            let key = code.map { biblicalCodes.contains($0) ? "biblical" : $0 } ?? "other"
            if byLanguage[key] == nil { order.append(key) }
            byLanguage[key, default: []].append(item)
        }
        let own = primary(locale.language.languageCode?.identifier) ?? "en"
        func title(_ key: String) -> String {
            switch key {
            case "biblical": "Biblical Languages"
            case "other": "Other Languages"
            default: locale.localizedString(forLanguageCode: key) ?? key
            }
        }
        // The reader's language, then other modern languages by name, then
        // undeclared, then the biblical languages.
        func rank(_ key: String) -> Int {
            switch key {
            case own: 0
            case "other": 2
            case "biblical": 3
            default: 1
            }
        }
        let keys = order.sorted { left, right in
            let (a, b) = (rank(left), rank(right))
            if a != b { return a < b }
            return title(left).localizedStandardCompare(title(right)) == .orderedAscending
        }
        return keys.map { Group(id: $0, title: title($0), items: byLanguage[$0] ?? []) }
    }
}
