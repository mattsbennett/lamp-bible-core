import Foundation

/// Translations grouped by the language they are written in, as a picker
/// lists them: the reader's own language first, then any other modern
/// language by name, then the biblical languages last. Within a language,
/// whole Bibles come first and translations of part of it after them, so
/// the Septuagint or a New Testament is not what a reader reaches for
/// first when choosing what to read.
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
        /// Whole Bibles first, then the rest, each in the order given.
        public let items: [Item]
        /// `items` split into whole Bibles and parts, only those with any,
        /// in that order. One part holding everything when the caller does
        /// not say which are whole.
        public let parts: [Part<Item>]
    }

    /// The whole Bibles of a language, or the translations of part of it.
    public struct Part<Item>: Identifiable {
        public enum Scope: String, Sendable {
            case wholeBible
            case partOfTheBible
        }

        public let scope: Scope
        public let items: [Item]

        public var id: String { scope.rawValue }

        /// A heading for the part, where it needs one: the parts of the
        /// Bible are named, the whole Bibles above them are not, being
        /// what a language's list is chiefly of.
        public var title: String? {
            switch scope {
            case .wholeBible: nil
            case .partOfTheBible: "Part of the Bible"
            }
        }
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

    /// A declared language's name as a reader knows it: Greek and Hebrew
    /// for the biblical languages, where the locale says "Ancient Greek"
    /// and has no name at all for biblical Hebrew's code; the locale's
    /// name for any other, or the code itself where it has none. Nil for
    /// none declared.
    public static func name(of code: String?, locale: Locale = .current) -> String? {
        guard let primary = primary(code) else { return nil }
        switch primary {
        case "grc": return "Greek"
        case "hbo": return "Hebrew"
        case "arc": return "Aramaic"
        default: return locale.localizedString(forLanguageCode: primary) ?? primary
        }
    }

    /// The side of Strong's a text or a lexicon in an original language
    /// keys by.
    public enum StrongsSide: Sendable, Equatable {
        /// Greek: the New Testament and the Septuagint.
        case greek
        /// Hebrew and Aramaic, which Strong's numbers together.
        case hebrew
    }

    /// Which side of Strong's a declared language is on, read loosely:
    /// codes or English names, ancient or modern ("grc", "el", "Koine
    /// Greek"; "hbo", "he", "Aramaic"), since modules declare all of
    /// these. Nil for any other language, or none.
    public static func strongsSide(of declared: String?) -> StrongsSide? {
        guard let declared = declared?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !declared.isEmpty else { return nil }
        switch declared {
        case "greek", "ancient greek", "koine greek": return .greek
        case "hebrew", "aramaic", "biblical hebrew": return .hebrew
        default: break
        }
        switch primary(declared) {
        case "grc", "el", "ell", "gre": return .greek
        case "hbo", "he", "heb", "arc": return .hebrew
        default: return nil
        }
    }

    /// `items` grouped by language, each group keeping the order it was
    /// given in, and within it whole Bibles before parts where
    /// `holdsWholeBible` says which is which.
    public static func grouped<Item>(
        _ items: [Item],
        language: (Item) -> String?,
        holdsWholeBible: ((Item) -> Bool)? = nil,
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
        return keys.map { key in
            let members = byLanguage[key] ?? []
            let parts: [Part<Item>]
            if let holdsWholeBible {
                parts = [
                    Part(scope: .wholeBible, items: members.filter(holdsWholeBible)),
                    Part(scope: .partOfTheBible, items: members.filter { !holdsWholeBible($0) }),
                ].filter { !$0.items.isEmpty }
            } else {
                parts = [Part(scope: .wholeBible, items: members)]
            }
            return Group(id: key, title: title(key), items: parts.flatMap(\.items), parts: parts)
        }
    }
}
