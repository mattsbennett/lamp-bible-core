import Foundation

/// Where an imported translation is installed.
public struct LampTranslationImportDestination: Equatable, Sendable {
    public let moduleID: String
    /// The earlier import this one replaces, in that module's own spelling,
    /// so the same file is written over.
    public let replacedModuleID: String?
}

/// A language a user can give an imported translation.
public struct LampTranslationLanguage: Equatable, Sendable {
    public let code: String
    public let name: String
}

/// What both apps decide and say while a user reviews an import, so the
/// Mac and the phone agree.
extension LampTranslationImporter {
    /// Importing an abbreviation again replaces the earlier import — the way
    /// to take in a corrected file — rather than adding a second copy. An ID
    /// held by anything else (a bundled module, another kind) is avoided.
    ///
    /// `replaceableTranslationIDs` are the translations a user installed;
    /// `otherModuleIDs` every other module the library holds.
    public static func destination(
        abbreviation: String,
        replaceableTranslationIDs: Set<String>,
        otherModuleIDs: Set<String>
    ) -> LampTranslationImportDestination {
        let moduleID = moduleID(forAbbreviation: abbreviation)
        if let earlier = replaceableTranslationIDs.first(where: { $0.lowercased() == moduleID.lowercased() }) {
            return LampTranslationImportDestination(moduleID: earlier, replacedModuleID: earlier)
        }
        return LampTranslationImportDestination(
            moduleID: Self.moduleID(forAbbreviation: abbreviation, avoiding: otherModuleIDs),
            replacedModuleID: nil
        )
    }

    /// Another translation already shown under `abbreviation`, if any.
    public static func translationID(
        sharingAbbreviation abbreviation: String,
        abbreviationsByTranslationID: [String: String],
        except destination: LampTranslationImportDestination
    ) -> String? {
        let wanted = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return abbreviationsByTranslationID
            .filter { $0.key != destination.moduleID && $0.value.lowercased() == wanted }
            .keys.sorted().first
    }

    /// Every language with a two-letter code, by name, with `code` among them
    /// even if Foundation can't name it — so a picker always shows what the
    /// file said.
    public static func languageOptions(including code: String) -> [LampTranslationLanguage] {
        languages.contains { $0.code == code } ? languages : [LampTranslationLanguage(code: code, name: code)] + languages
    }

    private static let languages: [LampTranslationLanguage] = Locale.LanguageCode.isoLanguageCodes
        .compactMap { language -> LampTranslationLanguage? in
            guard language.identifier.count == 2,
                  let name = Locale.current.localizedString(forLanguageCode: language.identifier) else { return nil }
            return LampTranslationLanguage(code: language.identifier, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

extension LampTranslationImportReport {
    /// "66 books, 1,189 chapters and 31,102 verses"
    public var contentsDescription: String {
        "\(Self.counted(bookCount, "book")), \(Self.counted(chapterCount, "chapter")) and \(Self.counted(verseCount, "verse"))"
    }

    /// What the import left out or changed, one sentence each; empty when it
    /// took everything as it was.
    public var notices: [String] {
        var lines: [String] = []
        if !skippedBooks.isEmpty {
            lines.append("Left out, as they aren’t among the 66 books: \(skippedBooks.joined(separator: ", ")).")
        }
        if !verseBridges.isEmpty {
            let count = verseBridges.count
            lines.append(
                "\(Self.counted(count, "bridged verse")) \(count == 1 ? "is" : "are") kept under \(count == 1 ? "its" : "their") first number: \(Self.references(verseBridges))."
            )
        }
        if !duplicateVerses.isEmpty {
            lines.append("Left out, as \(duplicateVerses.count == 1 ? "it appears" : "they appear") twice: \(Self.references(duplicateVerses)).")
        }
        if !unrecognizedMarkup.isEmpty {
            let markup = unrecognizedMarkup
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            lines.append("Formatting Lamp doesn’t know was dropped and its words kept: \(markup).")
        }
        return lines
    }

    public func completionMessage(translationName: String, replaced: Bool) -> String {
        "\(replaced ? "Replaced" : "Imported") \(translationName): \(contentsDescription)."
    }

    private static func references(_ references: [Int]) -> String {
        let shown = references.prefix(5).map { reference -> String in
            let name = LampCanonicalBooks.book(reference / 1_000_000)?.name ?? "Book \(reference / 1_000_000)"
            return "\(name) \(reference / 1_000 % 1_000):\(reference % 1_000)"
        }
        let rest = references.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
