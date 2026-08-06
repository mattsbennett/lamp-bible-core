import Foundation
import LampModuleKit

/// A bounded, read-only, agent-facing view of a Lamp library.
///
/// This deliberately exposes semantic operations rather than database tables or
/// portable module schemas. The same API backs local MCP clients and remains
/// useful to other agent transports without coupling LampCore to MCP itself.
public actor LampAgentLibrary {
    private let library: LampLibrary
    private var policy: LampAgentAccessPolicy

    public init(library: LampLibrary, policy: LampAgentAccessPolicy = .init()) {
        self.library = library
        self.policy = policy
    }

    public init(
        libraryRootURL: URL,
        bundledModulesArchiveURL: URL? = nil,
        policy: LampAgentAccessPolicy = .init()
    ) {
        library = LampLibrary(
            rootURL: libraryRootURL,
            bundledModulesArchiveURL: bundledModulesArchiveURL
        )
        self.policy = policy
    }

    public func updatePolicy(_ policy: LampAgentAccessPolicy) {
        self.policy = policy
    }

    public func listModules(kinds: Set<LampModuleKind>? = nil) async throws -> [LampAgentModule] {
        try requireEnabled()
        var modules = try await permittedInstalledModules(kinds: kinds).map(Self.agentModule)
        if policy.includesPersonalContent {
            let personal: [LampAgentModule] = [
                LampAgentModule(
                    id: "personal-devotionals",
                    kind: .devotional,
                    name: "My Devotionals",
                    isPersonal: true
                ),
                LampAgentModule(
                    id: "personal-notes",
                    kind: .notes,
                    name: "My Notes",
                    isPersonal: true
                ),
                LampAgentModule(
                    id: "personal-highlights",
                    kind: .highlights,
                    name: "My Highlights",
                    isPersonal: true
                ),
            ]
            modules += personal.filter { module in
                (kinds == nil || kinds?.contains(module.kind) == true)
                    && policy.allows(moduleID: module.id)
            }
        }
        return modules.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func searchLibrary(
        query: String,
        kinds: Set<LampModuleKind>? = nil,
        moduleIDs: Set<String>? = nil,
        limit: Int = 20
    ) async throws -> [LampAgentSearchResult] {
        try requireEnabled()
        let allowedIDs = try await permittedModuleIDs(requested: moduleIDs, kinds: kinds)
        let boundedLimit = min(max(limit, 1), policy.maximumSearchResults)
        let results = try await library.searchModules(
            query: query,
            kinds: kinds,
            moduleIDs: allowedIDs,
            limit: boundedLimit
        )
        return results.map { result in
            LampAgentSearchResult(
                id: result.id,
                kind: result.kind,
                moduleID: result.moduleID,
                moduleName: result.moduleName,
                title: result.title,
                subtitle: result.subtitle,
                snippet: limitedText(result.snippet),
                reference: result.referenceDescription
            )
        }
    }

    public func readPassage(
        reference: String,
        translationIDs: [String]? = nil,
        includeHeadings: Bool = true,
        includeAnnotations: Bool = false
    ) async throws -> [LampAgentTranslationPassage] {
        try requireEnabled()
        let range = try LampReferenceParser.parse(reference)
        let translations = try await selectedModules(
            kind: .translation,
            requestedIDs: translationIDs.map(Set.init),
            defaultLimit: 3
        )
        guard !translations.isEmpty else { throw LampAgentError.noMatchingModule(.translation) }

        var passages: [LampAgentTranslationPassage] = []
        for translation in translations {
            let books = Dictionary(
                uniqueKeysWithValues: try await library.translationBooks(moduleID: translation.id)
                    .map { ($0.id, $0) }
            )
            try validate(range, against: books, source: reference)
            var verses: [LampAgentVerse] = []
            var headings: [LampAgentHeading] = []
            var foundMore = false

            passage: for bookNumber in range.start.book...range.end.book {
                guard let book = books[bookNumber] else {
                    throw LampAgentError.invalidReference(reference)
                }
                let firstChapter = bookNumber == range.start.book ? range.start.chapter : 1
                let lastChapter = bookNumber == range.end.book ? range.end.chapter : book.chapterCount
                for chapterNumber in firstChapter...lastChapter {
                    let chapter = try await library.chapter(
                        moduleID: translation.id,
                        bookNumber: bookNumber,
                        chapterNumber: chapterNumber
                    )
                    let firstVerse = bookNumber == range.start.book
                            && chapterNumber == range.start.chapter
                        ? range.start.verse ?? 1 : 1
                    let lastVerse = bookNumber == range.end.book
                            && chapterNumber == range.end.chapter
                        ? range.end.verse ?? Int.max : Int.max
                    let matching = chapter.verses.filter {
                        $0.number >= firstVerse && $0.number <= lastVerse
                    }
                    for verse in matching {
                        if verses.count == policy.maximumPassageVerses {
                            foundMore = true
                            break passage
                        }
                        verses.append(agentVerse(verse, includeAnnotations: includeAnnotations))
                    }
                    if includeHeadings {
                        headings += chapter.headings.compactMap { heading in
                            guard heading.beforeVerse >= firstVerse,
                                  heading.beforeVerse <= lastVerse else { return nil }
                            let headingReference = bookNumber * 1_000_000
                                + chapterNumber * 1_000 + heading.beforeVerse
                            return LampAgentHeading(
                                beforeReference: LampBibleReferenceFormatter.describeRange(
                                    from: headingReference,
                                    to: headingReference
                                ),
                                level: heading.level,
                                text: heading.text
                            )
                        }
                    }
                }
            }

            guard let first = verses.first?.referenceID,
                  let last = verses.last?.referenceID else {
                throw LampAgentError.itemNotFound(reference)
            }
            passages.append(LampAgentTranslationPassage(
                translationID: translation.id,
                translationName: translation.name,
                translationAbbreviation: translation.abbreviation,
                reference: LampBibleReferenceFormatter.describeRange(from: first, to: last),
                verses: verses,
                headings: headings.filter { heading in
                    guard let parsed = try? LampReferenceParser.parse(heading.beforeReference),
                          let value = parsed.start.reference else { return false }
                    return value >= first && value <= last
                },
                wasTruncated: foundMore
            ))
        }
        return passages
    }

    public func readCommentary(
        reference: String,
        moduleIDs: Set<String>? = nil,
        limit: Int = 30
    ) async throws -> [LampAgentCommentary] {
        try requireEnabled()
        let range = try LampReferenceParser.parse(reference)
        let modules = try await selectedModules(
            kind: .commentary,
            requestedIDs: moduleIDs,
            defaultLimit: nil
        )
        guard !modules.isEmpty else { throw LampAgentError.noMatchingModule(.commentary) }
        let allowedIDs = Set(modules.map(\.id))
        let startReference = packed(range.start, missingVerse: 1)
        let endReference = packed(range.end, missingVerse: 999)
        var seen = Set<String>()
        var results: [LampAgentCommentary] = []

        outer: for bookNumber in range.start.book...range.end.book {
            let firstChapter = bookNumber == range.start.book ? range.start.chapter : 1
            let lastChapter = bookNumber == range.end.book ? range.end.chapter : 999
            for chapterNumber in firstChapter...lastChapter {
                let units = try await library.commentary(
                    bookNumber: bookNumber,
                    chapterNumber: chapterNumber,
                    moduleIDs: allowedIDs
                )
                for unit in units {
                    let unitEnd = unit.endReference ?? unit.startReference
                    guard unit.startReference <= endReference, unitEnd >= startReference,
                          seen.insert(unit.id).inserted else { continue }
                    results.append(LampAgentCommentary(
                        unitID: unit.unitID,
                        moduleID: unit.moduleID,
                        moduleName: unit.moduleName,
                        seriesAbbreviation: unit.seriesAbbreviation,
                        reference: LampBibleReferenceFormatter.describeRange(
                            from: unit.startReference,
                            to: unitEnd
                        ),
                        title: unit.title,
                        introduction: limitedOptionalText(unit.introduction),
                        translation: limitedOptionalText(unit.translation),
                        commentary: limitedOptionalText(unit.commentary),
                        footnotes: limitedOptionalText(unit.footnotes)
                    ))
                    if results.count == min(max(limit, 1), policy.maximumSearchResults) {
                        break outer
                    }
                }
                // A parser-valid cross-book request can contain many chapters.
                // Stop at the canonical chapter count rather than probing to 999.
                if bookNumber != range.end.book,
                   chapterNumber >= Self.canonicalChapterCounts[bookNumber - 1] {
                    break
                }
            }
        }
        return results
    }

    public func searchDictionary(
        query: String,
        moduleIDs: Set<String>? = nil,
        limit: Int = 20
    ) async throws -> [LampAgentDictionaryEntry] {
        try requireEnabled()
        let modules = try await selectedModules(
            kind: .dictionary,
            requestedIDs: moduleIDs,
            defaultLimit: nil
        )
        guard !modules.isEmpty else { throw LampAgentError.noMatchingModule(.dictionary) }
        return try await library.searchDictionaries(
            query: query,
            moduleIDs: Set(modules.map(\.id)),
            limit: min(max(limit, 1), policy.maximumSearchResults)
        ).map(LampAgentDictionaryEntry.init)
    }

    public func lookupDictionaryKeys(
        _ keys: [String],
        moduleIDs: Set<String>? = nil
    ) async throws -> [LampAgentDictionaryEntry] {
        try requireEnabled()
        let modules = try await selectedModules(
            kind: .dictionary,
            requestedIDs: moduleIDs,
            defaultLimit: nil
        )
        guard !modules.isEmpty else { throw LampAgentError.noMatchingModule(.dictionary) }
        return try await library.dictionaryEntries(
            keys: Array(keys.prefix(50)),
            moduleIDs: Set(modules.map(\.id))
        ).map(LampAgentDictionaryEntry.init)
    }

    public func listReadingPlans() async throws -> [LampAgentReadingPlan] {
        try requireEnabled()
        let allowed = Set(try await permittedInstalledModules(kinds: [.plan]).map(\.id))
        return try await library.readingPlans()
            .filter { allowed.contains($0.id) }
            .map(LampAgentReadingPlan.init)
    }

    public func readPlanDay(moduleID: String, day: Int) async throws -> LampAgentReadingPlanDay {
        try requireAllowed(moduleID)
        guard try await permittedInstalledModules(kinds: [.plan]).contains(where: { $0.id == moduleID }) else {
            throw LampAgentError.moduleNotAllowed(moduleID)
        }
        guard let result = try await library.readingPlanDay(moduleID: moduleID, day: day) else {
            throw LampAgentError.itemNotFound("\(moduleID), day \(day)")
        }
        return LampAgentReadingPlanDay(result)
    }

    public func listBooks() async throws -> [LampAgentBook] {
        try requireEnabled()
        let allowed = Set(try await permittedInstalledModules(kinds: [.book]).map(\.id))
        return try await library.bookModules(moduleIDs: allowed).map(LampAgentBook.init)
    }

    public func listBookSections(moduleID: String) async throws -> [LampAgentBookSectionSummary] {
        try requireAllowed(moduleID)
        guard try await permittedInstalledModules(kinds: [.book])
            .contains(where: { $0.id == moduleID }) else {
            throw LampAgentError.moduleNotAllowed(moduleID)
        }
        return try await library.bookSections(moduleID: moduleID)
            .map(LampAgentBookSectionSummary.init)
    }

    public func readBookSection(
        moduleID: String,
        sectionID: String
    ) async throws -> LampAgentBookSection {
        try requireAllowed(moduleID)
        guard try await permittedInstalledModules(kinds: [.book])
            .contains(where: { $0.id == moduleID }) else {
            throw LampAgentError.moduleNotAllowed(moduleID)
        }
        guard let section = try await library.bookSections(moduleID: moduleID)
            .first(where: { $0.sectionID == sectionID }) else {
            throw LampAgentError.itemNotFound("\(moduleID), section \(sectionID)")
        }
        return LampAgentBookSection(section, content: limitedText(section.content))
    }

    public func readDevotional(moduleID: String, devotionalID: String) async throws -> LampAgentDevotional {
        try requireEnabled()
        if moduleID == "personal-devotionals" {
            guard policy.includesPersonalContent, policy.allows(moduleID: moduleID) else {
                throw LampAgentError.moduleNotAllowed(moduleID)
            }
        } else {
            try requireAllowed(moduleID)
            guard try await permittedInstalledModules(kinds: [.devotional])
                .contains(where: { $0.id == moduleID }) else {
                throw LampAgentError.moduleNotAllowed(moduleID)
            }
        }
        guard let devotional = try await library.devotionals(moduleIDs: [moduleID])
            .first(where: { $0.id == devotionalID }) else {
            throw LampAgentError.itemNotFound(devotionalID)
        }
        return LampAgentDevotional(devotional, content: limitedText(devotional.content))
    }

    public func listQuizModules(planID: String? = nil) async throws -> [LampAgentQuizModule] {
        try requireEnabled()
        let allowed = Set(try await permittedInstalledModules(kinds: [.quiz]).map(\.id))
        return try await library.quizModules(planID: planID)
            .filter { allowed.contains($0.id) }
            .map(LampAgentQuizModule.init)
    }

    public func readQuizQuestions(
        moduleID: String,
        day: Int,
        reference: String? = nil,
        ageGroup: String? = nil
    ) async throws -> [LampAgentQuizQuestion] {
        try requireAllowed(moduleID)
        guard try await permittedInstalledModules(kinds: [.quiz]).contains(where: { $0.id == moduleID }) else {
            throw LampAgentError.moduleNotAllowed(moduleID)
        }
        let range = try reference.map(LampReferenceParser.parse)
        return try await library.quizQuestions(
            moduleID: moduleID,
            day: day,
            startReference: range.map { packed($0.start, missingVerse: 1) },
            endReference: range.map { packed($0.end, missingVerse: 999) },
            ageGroup: ageGroup
        ).map(LampAgentQuizQuestion.init)
    }

    public func readStudyMaterial(
        reference: String,
        translationID: String
    ) async throws -> LampAgentStudyMaterial {
        try requireEnabled()
        let parsed = try LampReferenceParser.parse(reference)
        guard parsed.start == parsed.end, let referenceID = parsed.start.reference else {
            throw LampAgentError.invalidReference(reference)
        }
        guard try await selectedModules(
            kind: .translation,
            requestedIDs: [translationID],
            defaultLimit: nil
        ).contains(where: { $0.id == translationID }) else {
            throw LampAgentError.moduleNotAllowed(translationID)
        }

        let data = try await library.verseStudyData(moduleID: translationID, reference: referenceID)
        var notes: [LampVerseNote] = []
        var highlights: [LampVerseHighlight] = []
        if policy.includesPersonalContent {
            if policy.allows(moduleID: "personal-notes") {
                notes += try await library.verseNotes(reference: referenceID)
            }
            if policy.allows(moduleID: "personal-highlights") {
                highlights += try await library.verseHighlights(
                    translationID: translationID,
                    reference: referenceID
                )
            }
        }
        for module in try await permittedInstalledModules(kinds: [.notes]) {
            notes += try await library.moduleVerseNotes(moduleID: module.id, reference: referenceID)
        }
        for module in try await permittedInstalledModules(kinds: [.highlights]) {
            highlights += try await library.moduleVerseHighlights(moduleID: module.id, reference: referenceID)
        }
        return LampAgentStudyMaterial(
            translationID: translationID,
            reference: LampBibleReferenceFormatter.describeRange(from: referenceID, to: referenceID),
            annotations: data?.annotations.map(agentAnnotation) ?? [],
            footnotes: data?.footnotes.map { limitedText($0.content) } ?? [],
            notes: notes.map(LampAgentNote.init),
            highlights: highlights.map(LampAgentHighlight.init)
        )
    }

    // MARK: - Policy and mapping

    private func requireEnabled() throws {
        guard policy.isEnabled else { throw LampAgentError.disabled }
    }

    private func requireAllowed(_ moduleID: String) throws {
        try requireEnabled()
        guard policy.allows(moduleID: moduleID) else {
            throw LampAgentError.moduleNotAllowed(moduleID)
        }
    }

    private func permittedInstalledModules(
        kinds: Set<LampModuleKind>? = nil
    ) async throws -> [LampInstalledModule] {
        try requireEnabled()
        return try await library.installedModules().filter {
            policy.allows(moduleID: $0.id) && (kinds == nil || kinds?.contains($0.kind) == true)
        }
    }

    private func selectedModules(
        kind: LampModuleKind,
        requestedIDs: Set<String>?,
        defaultLimit: Int?
    ) async throws -> [LampInstalledModule] {
        let permitted = try await permittedInstalledModules(kinds: [kind])
        if let requestedIDs {
            let selected = permitted.filter { requestedIDs.contains($0.id) }
            for requested in requestedIDs where !selected.contains(where: { $0.id == requested }) {
                if !policy.allows(moduleID: requested) {
                    throw LampAgentError.moduleNotAllowed(requested)
                }
            }
            return selected
        }
        return defaultLimit.map { Array(permitted.prefix($0)) } ?? permitted
    }

    private func permittedModuleIDs(
        requested: Set<String>?,
        kinds: Set<LampModuleKind>?
    ) async throws -> Set<String> {
        var allowed = Set(try await permittedInstalledModules(kinds: kinds).map(\.id))
        if policy.includesPersonalContent {
            let virtual: [(String, LampModuleKind)] = [
                ("personal-devotionals", .devotional),
                ("personal-notes", .notes),
                ("personal-highlights", .highlights),
            ]
            for (id, kind) in virtual where
                policy.allows(moduleID: id) && (kinds == nil || kinds?.contains(kind) == true) {
                allowed.insert(id)
            }
            if policy.allows(moduleID: "personal-highlights"),
               kinds == nil || kinds?.contains(.highlights) == true {
                let setIDs = (try? await library.highlightSets())?.map(\.id) ?? []
                allowed.formUnion(setIDs)
            }
        }
        return requested.map { allowed.intersection($0) } ?? allowed
    }

    private static func agentModule(_ module: LampInstalledModule) -> LampAgentModule {
        LampAgentModule(
            id: module.id,
            kind: module.kind,
            name: module.name,
            abbreviation: module.abbreviation,
            language: module.language,
            isBundled: module.isBundled
        )
    }

    private func agentVerse(
        _ verse: LampVerse,
        includeAnnotations: Bool
    ) -> LampAgentVerse {
        LampAgentVerse(
            referenceID: verse.id,
            reference: LampBibleReferenceFormatter.describeRange(from: verse.id, to: verse.id),
            number: verse.number,
            text: verse.text,
            beginsParagraph: verse.beginsParagraph,
            annotations: includeAnnotations ? verse.annotations.map(agentAnnotation) : []
        )
    }

    private func agentAnnotation(_ annotation: LampVerseAnnotation) -> LampAgentAnnotation {
        LampAgentAnnotation(
            kind: annotation.kind,
            text: annotation.text,
            startOffset: annotation.startOffset,
            endOffset: annotation.endOffset,
            strongs: annotation.strongs,
            lemma: annotation.lemma,
            morphology: annotation.morphology,
            scriptureReference: annotation.scriptureDescription
        )
    }

    private func limitedText(_ value: String) -> String {
        guard value.count > policy.maximumItemCharacters else { return value }
        return String(value.prefix(policy.maximumItemCharacters)) + "\n\n[Result truncated by Lamp Bible]"
    }

    private func limitedOptionalText(_ value: String?) -> String? {
        value.map(limitedText)
    }

    private func packed(_ point: LampAgentReferencePoint, missingVerse: Int) -> Int {
        point.book * 1_000_000 + point.chapter * 1_000 + (point.verse ?? missingVerse)
    }

    private func validate(
        _ range: LampAgentReferenceRange,
        against books: [Int: LampTranslationBook],
        source: String
    ) throws {
        guard let startBook = books[range.start.book],
              let endBook = books[range.end.book],
              (1...startBook.chapterCount).contains(range.start.chapter),
              (1...endBook.chapterCount).contains(range.end.chapter) else {
            throw LampAgentError.invalidReference(source)
        }
    }

    private static let canonicalChapterCounts = [
        50, 40, 27, 36, 34, 24, 21, 4, 31, 24, 22, 25, 29, 36, 10, 13, 10,
        42, 150, 31, 12, 8, 66, 52, 5, 48, 12, 14, 3, 9, 1, 4, 7, 3, 3, 3,
        2, 14, 4, 28, 16, 24, 21, 28, 16, 16, 13, 6, 6, 4, 4, 5, 3, 6, 4, 3,
        1, 13, 5, 5, 3, 5, 1, 1, 1, 22,
    ]
}
