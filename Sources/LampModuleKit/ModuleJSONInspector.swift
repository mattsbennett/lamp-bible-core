import Foundation

/// Detects Lamp module JSON and performs fast structural and semantic checks.
///
/// JSON Schema remains canonical in `lamp-bible-modules/schemas`. This inspector
/// adds checks that JSON Schema cannot express well, such as BBCCCVVV consistency
/// and duplicate entry keys.
public struct ModuleJSONInspector: Sendable {
    public init() {}

    public func inspect(_ data: Data) throws -> ModuleInspection {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModuleInspectionError.invalidJSON(error.localizedDescription)
        }

        guard let root = json as? [String: Any] else {
            throw ModuleInspectionError.rootMustBeObject
        }

        let meta = object(root["meta"]) ?? root
        let declaredType = string(meta["type"]) ?? string(root["type"])
        let kind = declaredType.flatMap(LampModuleKind.init(schemaValue:)) ?? inferKind(root: root, meta: meta)
        let metadata = ModuleMetadataSummary(
            id: string(meta["id"]) ?? string(root["id"]),
            name: string(meta["name"]) ?? string(meta["title"]) ?? string(root["name"]),
            schemaVersion: string(meta["schemaVersion"]),
            declaredType: declaredType
        )

        var issues: [ModuleValidationIssue] = []
        if kind == nil {
            issues.append(.init(
                severity: .error,
                path: declaredType == nil ? "/meta/type" : "/meta/type",
                message: declaredType.map { "Unsupported module type ‘\($0)’." }
                    ?? "Could not detect the module type."
            ))
        }

        if let kind {
            validateRequiredStructure(kind: kind, root: root, meta: meta, issues: &issues)
            validateIdentifier(metadata.id, kind: kind, issues: &issues)
            validateSemantics(kind: kind, root: root, issues: &issues)
        }

        return ModuleInspection(
            kind: kind,
            metadata: metadata,
            statistics: statistics(kind: kind, root: root),
            issues: issues.sorted(by: issueSort)
        )
    }

    private func inferKind(root: [String: Any], meta: [String: Any]) -> LampModuleKind? {
        if root["books"] is [Any] { return .translation }
        if root["entries"] is [Any] { return .dictionary }

        if root["days"] is [Any] {
            if meta["planId"] != nil || meta["ageGroups"] != nil { return .quiz }
            return .plan
        }

        if root["verses"] is [Any], meta["translationId"] != nil { return .highlights }
        if root["sections"] is [Any], meta["title"] != nil { return .book }
        if root["content"] != nil, meta["title"] != nil { return .devotional }

        if root["chapters"] is [Any], root["book"] != nil {
            if meta["seriesFull"] != nil || meta["seriesAbbrev"] != nil || meta["title"] != nil {
                return .commentary
            }
            return .notes
        }

        return nil
    }

    private func validateRequiredStructure(
        kind: LampModuleKind,
        root: [String: Any],
        meta: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        requireObject(root, key: "meta", issues: &issues)

        switch kind {
        case .translation:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name", "abbreviation", "language"], issues: &issues)
            requireArray(root, key: "books", issues: &issues)
        case .dictionary:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name"], issues: &issues)
            requireArray(root, key: "entries", issues: &issues)
        case .commentary:
            requireStrings(meta, keys: ["schemaVersion", "seriesAbbrev", "seriesFull"], issues: &issues)
            if (string(meta["title"]) ?? string(meta["name"]))?.isEmpty != false {
                issues.append(.init(
                    severity: .error,
                    path: "/meta/title",
                    message: "Expected a non-empty title or name."
                ))
            }
            requireInteger(root, key: "bookNumber", issues: &issues)
            requireString(root, key: "book", basePath: "", issues: &issues)
            requireArray(root, key: "chapters", issues: &issues)
        case .book:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "title", "language"], issues: &issues)
            requireArray(root, key: "sections", issues: &issues)
        case .devotional:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "title"], issues: &issues)
            if root["content"] == nil {
                issues.append(.init(severity: .error, path: "/content", message: "Missing required content."))
            }
        case .notes:
            requireStrings(meta, keys: ["id", "type"], issues: &issues)
            requireInteger(root, key: "bookNumber", issues: &issues)
            requireString(root, key: "book", basePath: "", issues: &issues)
            requireArray(root, key: "chapters", issues: &issues)
        case .plan:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name"], issues: &issues)
            requireArray(root, key: "days", issues: &issues)
        case .highlights:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "translationId"], issues: &issues)
            requireArray(root, key: "verses", issues: &issues)
        case .quiz:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "planId", "name"], issues: &issues)
            guard meta["ageGroups"] is [Any] else {
                issues.append(.init(severity: .error, path: "/meta/ageGroups", message: "Expected an array."))
                return
            }
            requireArray(root, key: "days", issues: &issues)
        }
    }

    private func validateIdentifier(
        _ id: String?,
        kind: LampModuleKind,
        issues: inout [ModuleValidationIssue]
    ) {
        guard kind != .commentary, let id else { return }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        if id.isEmpty || id.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            issues.append(.init(
                severity: .warning,
                path: "/meta/id",
                message: "Use only letters, numbers, periods, underscores, and hyphens so the ID is safe as a .lamp filename."
            ))
        }
    }

    private func validateSemantics(
        kind: LampModuleKind,
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        switch kind {
        case .translation:
            validateTranslationReferences(root: root, issues: &issues)
        case .dictionary:
            validateDictionaryKeys(root: root, issues: &issues)
        case .book:
            validateBook(root: root, issues: &issues)
        case .devotional:
            if let content = root["content"], !JSONSupport.isMeaningful(content) {
                issues.append(.init(
                    severity: .error,
                    path: "/content",
                    message: "Expected non-empty devotional content."
                ))
            }
        case .plan:
            validatePlanDays(root: root, issues: &issues)
        case .notes:
            validateNotes(root: root, issues: &issues)
        case .highlights:
            validateHighlights(root: root, issues: &issues)
        case .quiz:
            validateQuiz(root: root, issues: &issues)
        case .commentary:
            break
        }
    }

    private func validateBook(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let sections = array(root["sections"]) else { return }
        if sections.isEmpty {
            issues.append(.init(
                severity: .error,
                path: "/sections",
                message: "Expected at least one book section."
            ))
            return
        }

        let allowedTypes: Set<String> = [
            "front-matter", "part", "chapter", "section",
            "appendix", "back-matter", "other",
        ]
        var firstPathByID: [String: String] = [:]

        func validateSections(_ values: [Any], path: String) {
            for (index, value) in values.enumerated() {
                let sectionPath = "\(path)/\(index)"
                guard let section = object(value) else {
                    issues.append(.init(severity: .error, path: sectionPath, message: "Expected an object."))
                    continue
                }

                guard let id = string(section["id"]), !id.isEmpty else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/id",
                        message: "Expected a non-empty section ID."
                    ))
                    continue
                }
                if let firstPath = firstPathByID[id] {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/id",
                        message: "Duplicate section ID ‘\(id)’; it first appears at \(firstPath)/id."
                    ))
                } else {
                    firstPathByID[id] = sectionPath
                }

                if string(section["title"])?.isEmpty != false {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/title",
                        message: "Expected a non-empty section title."
                    ))
                }
                if let type = string(section["type"]), allowedTypes.contains(type) {
                    // Valid.
                } else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/type",
                        message: "Expected a supported book section type."
                    ))
                }

                let content = array(section["content"])
                let children = array(section["sections"])
                if section["content"] != nil, content == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/content",
                        message: "Expected an array."
                    ))
                }
                if section["sections"] != nil, children == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/sections",
                        message: "Expected an array."
                    ))
                }
                if (content?.isEmpty ?? true) && (children?.isEmpty ?? true) {
                    issues.append(.init(
                        severity: .error,
                        path: sectionPath,
                        message: "A book section needs content or child sections."
                    ))
                }

                if let orderValue = section["order"],
                   integer(orderValue).map({ $0 >= 0 }) != true {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/order",
                        message: "Expected a non-negative integer."
                    ))
                }

                if let scriptureValues = section["keyScriptures"] {
                    guard let scriptures = array(scriptureValues) else {
                        issues.append(.init(
                            severity: .error,
                            path: "\(sectionPath)/keyScriptures",
                            message: "Expected an array."
                        ))
                        continue
                    }
                    for (scriptureIndex, scriptureValue) in scriptures.enumerated() {
                        let scripturePath = "\(sectionPath)/keyScriptures/\(scriptureIndex)"
                        guard let scripture = object(scriptureValue),
                              let start = integer(scripture["sv"]) else {
                            issues.append(.init(
                                severity: .error,
                                path: scripturePath,
                                message: "Expected an object with an integer sv reference."
                            ))
                            continue
                        }
                        if let endValue = scripture["ev"] {
                            guard let end = integer(endValue) else {
                                issues.append(.init(
                                    severity: .error,
                                    path: "\(scripturePath)/ev",
                                    message: "Expected an integer BBCCCVVV reference."
                                ))
                                continue
                            }
                            if end < start {
                                issues.append(.init(
                                    severity: .error,
                                    path: "\(scripturePath)/ev",
                                    message: "End reference \(end) precedes start reference \(start)."
                                ))
                            }
                        }
                    }
                }

                if let children {
                    validateSections(children, path: "\(sectionPath)/sections")
                }
            }
        }

        validateSections(sections, path: "/sections")
    }

    private func validateQuiz(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        validatePlanDays(root: root, issues: &issues)
        let meta = object(root["meta"])
        let ageGroups = array(meta?["ageGroups"]) ?? []
        var ageGroupIDs: Set<String> = []
        for (index, value) in ageGroups.enumerated() {
            let path = "/meta/ageGroups/\(index)"
            guard let group = object(value),
                  let id = string(group["id"]), !id.isEmpty,
                  let label = string(group["label"]), !label.isEmpty,
                  let ageRange = string(group["ageRange"]), !ageRange.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Expected non-empty id, label, and ageRange values."
                ))
                continue
            }
            if !ageGroupIDs.insert(id).inserted {
                issues.append(.init(
                    severity: .error,
                    path: "\(path)/id",
                    message: "Duplicate age-group ID ‘\(id)’."
                ))
            }
        }

        for (dayIndex, dayValue) in (array(root["days"]) ?? []).enumerated() {
            guard let day = object(dayValue) else { continue }
            for (readingIndex, readingValue) in (array(day["readings"]) ?? []).enumerated() {
                let readingPath = "/days/\(dayIndex)/readings/\(readingIndex)"
                guard let reading = object(readingValue),
                      let quizzes = object(reading["quizzes"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(readingPath)/quizzes",
                        message: "Expected an object keyed by age-group ID."
                    ))
                    continue
                }
                for (ageGroupID, questionValue) in quizzes {
                    let path = "\(readingPath)/quizzes/\(ageGroupID)"
                    if !ageGroupIDs.contains(ageGroupID) {
                        issues.append(.init(
                            severity: .error,
                            path: path,
                            message: "Quiz questions use undefined age group ‘\(ageGroupID)’."
                        ))
                    }
                    guard let questions = array(questionValue) else {
                        issues.append(.init(severity: .error, path: path, message: "Expected an array."))
                        continue
                    }
                    for (questionIndex, value) in questions.enumerated() {
                        let questionPath = "\(path)/\(questionIndex)"
                        guard let question = object(value) else {
                            issues.append(.init(severity: .error, path: questionPath, message: "Expected an object."))
                            continue
                        }
                        for key in ["question", "answer"] where question[key].map(isMeaningfulText) != true {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/\(key)",
                                message: "Expected a string or annotated text."
                            ))
                        }
                        if string(question["theme"])?.isEmpty != false {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/theme",
                                message: "Expected a non-empty theme."
                            ))
                        }
                        if !(question["christFocused"] is Bool) {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/christFocused",
                                message: "Expected a Boolean."
                            ))
                        }
                        if array(question["references"]) == nil {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/references",
                                message: "Expected an array of verse references."
                            ))
                        }
                    }
                }
            }
        }
    }

    private func isMeaningfulText(_ value: Any) -> Bool {
        if let string = string(value) { return !string.isEmpty }
        return object(value).flatMap { string($0["text"]) }?.isEmpty == false
    }

    private func validateTranslationReferences(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let books = array(root["books"]) else { return }

        for (bookIndex, value) in books.enumerated() {
            guard let book = object(value), let bookNumber = integer(book["number"]),
                  let chapters = array(book["chapters"]) else { continue }

            for (chapterIndex, value) in chapters.enumerated() {
                guard let chapter = object(value), let chapterNumber = integer(chapter["chapter"]),
                      let verses = array(chapter["verses"]) else { continue }

                for (verseIndex, value) in verses.enumerated() {
                    guard let verse = object(value), let verseNumber = integer(verse["v"]),
                          let reference = integer(verse["ref"]) else { continue }
                    let expected = bookNumber * 1_000_000 + chapterNumber * 1_000 + verseNumber
                    if reference != expected {
                        issues.append(.init(
                            severity: .error,
                            path: "/books/\(bookIndex)/chapters/\(chapterIndex)/verses/\(verseIndex)/ref",
                            message: "Reference \(reference) does not match book \(bookNumber), chapter \(chapterNumber), verse \(verseNumber); expected \(expected)."
                        ))
                    }
                }
            }
        }
    }

    private func validateDictionaryKeys(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let entries = array(root["entries"]) else { return }
        var firstIndexByKey: [String: Int] = [:]

        for (index, value) in entries.enumerated() {
            guard let entry = object(value), let key = string(entry["key"]), !key.isEmpty else { continue }
            if let firstIndex = firstIndexByKey[key] {
                issues.append(.init(
                    severity: .error,
                    path: "/entries/\(index)/key",
                    message: "Duplicate entry key ‘\(key)’; it first appears at /entries/\(firstIndex)/key."
                ))
            } else {
                firstIndexByKey[key] = index
            }
        }
    }

    private func validatePlanDays(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let days = array(root["days"]) else { return }
        var firstIndexByDay: [Int: Int] = [:]

        for (dayIndex, value) in days.enumerated() {
            guard let day = object(value) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)",
                    message: "Expected an object."
                ))
                continue
            }
            guard let dayNumber = integer(day["day"]), (1...366).contains(dayNumber) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/day",
                    message: "Expected a day number from 1 through 366."
                ))
                continue
            }
            if let firstIndex = firstIndexByDay[dayNumber] {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/day",
                    message: "Duplicate day \(dayNumber); it first appears at /days/\(firstIndex)/day."
                ))
            } else {
                firstIndexByDay[dayNumber] = dayIndex
            }

            guard let readings = array(day["readings"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/readings",
                    message: "Expected an array."
                ))
                continue
            }
            for (readingIndex, value) in readings.enumerated() {
                let path = "/days/\(dayIndex)/readings/\(readingIndex)"
                guard let reading = object(value),
                      let start = integer(reading["sv"]),
                      let end = integer(reading["ev"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: path,
                        message: "Expected integer sv and ev references."
                    ))
                    continue
                }
                if start > end {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/ev",
                        message: "End reference \(end) precedes start reference \(start)."
                    ))
                }
            }
        }
    }

    private func validateNotes(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let bookNumber = integer(root["bookNumber"]),
              let chapters = array(root["chapters"]) else { return }
        if !(1...66).contains(bookNumber) {
            issues.append(.init(
                severity: .error,
                path: "/bookNumber",
                message: "Expected a canonical book number from 1 through 66."
            ))
        }
        if let media = root["media"], array(media) == nil {
            issues.append(.init(
                severity: .error,
                path: "/media",
                message: "Expected an array."
            ))
        }

        var chapterIndexes: [Int: Int] = [:]
        var verseIndexes: [Int: String] = [:]
        for (chapterIndex, chapterValue) in chapters.enumerated() {
            let chapterPath = "/chapters/\(chapterIndex)"
            guard let chapter = object(chapterValue) else {
                issues.append(.init(severity: .error, path: chapterPath, message: "Expected an object."))
                continue
            }
            guard let chapterNumber = integer(chapter["chapter"]), chapterNumber > 0 else {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/chapter",
                    message: "Expected a positive chapter number."
                ))
                continue
            }
            if let firstIndex = chapterIndexes[chapterNumber] {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/chapter",
                    message: "Duplicate chapter \(chapterNumber); it first appears at /chapters/\(firstIndex)/chapter."
                ))
            } else {
                chapterIndexes[chapterNumber] = chapterIndex
            }

            if let introduction = chapter["introduction"] {
                validateTextContent(
                    introduction,
                    path: "\(chapterPath)/introduction",
                    issues: &issues
                )
            }
            if let footnotes = chapter["footnotes"], array(footnotes) == nil {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/footnotes",
                    message: "Expected an array."
                ))
            }
            guard let versesValue = chapter["verses"] else { continue }
            guard let verses = array(versesValue) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/verses",
                    message: "Expected an array."
                ))
                continue
            }
            for (verseIndex, verseValue) in verses.enumerated() {
                let versePath = "\(chapterPath)/verses/\(verseIndex)"
                guard let verse = object(verseValue) else {
                    issues.append(.init(severity: .error, path: versePath, message: "Expected an object."))
                    continue
                }
                guard let reference = integer(verse["sv"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Expected an integer BBCCCVVV reference."
                    ))
                    continue
                }
                let expectedBook = reference / 1_000_000
                let expectedChapter = (reference / 1_000) % 1_000
                let expectedVerse = reference % 1_000
                if expectedBook != bookNumber || expectedChapter != chapterNumber || expectedVerse < 1 {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Reference \(reference) does not belong to book \(bookNumber), chapter \(chapterNumber)."
                    ))
                }
                if let firstPath = verseIndexes[reference] {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Duplicate note reference \(reference); it first appears at \(firstPath)."
                    ))
                } else {
                    verseIndexes[reference] = "\(versePath)/sv"
                }
                if let endValue = verse["ev"] {
                    if let endReference = integer(endValue) {
                        if endReference < reference {
                            issues.append(.init(
                                severity: .error,
                                path: "\(versePath)/ev",
                                message: "End reference \(endReference) precedes start reference \(reference)."
                            ))
                        }
                    } else {
                        issues.append(.init(
                            severity: .error,
                            path: "\(versePath)/ev",
                            message: "Expected an integer BBCCCVVV reference."
                        ))
                    }
                }
                if let commentary = verse["commentary"] {
                    validateTextContent(commentary, path: "\(versePath)/commentary", issues: &issues)
                } else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/commentary",
                        message: "Missing required note content."
                    ))
                }
                if let footnotes = verse["footnotes"], array(footnotes) == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/footnotes",
                        message: "Expected an array."
                    ))
                }
            }
        }
    }

    private func validateHighlights(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let verses = array(root["verses"]) else { return }
        var verseIndexes: [Int: Int] = [:]
        for (verseIndex, verseValue) in verses.enumerated() {
            let versePath = "/verses/\(verseIndex)"
            guard let verse = object(verseValue) else {
                issues.append(.init(severity: .error, path: versePath, message: "Expected an object."))
                continue
            }
            guard let reference = integer(verse["ref"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Expected an integer BBCCCVVV reference."
                ))
                continue
            }
            let book = reference / 1_000_000
            let chapter = (reference / 1_000) % 1_000
            let verseNumber = reference % 1_000
            if !(1...66).contains(book) || chapter < 1 || verseNumber < 1 {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Expected a valid BBCCCVVV verse reference."
                ))
            }
            if let firstIndex = verseIndexes[reference] {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Duplicate highlight reference \(reference); it first appears at /verses/\(firstIndex)/ref."
                ))
            } else {
                verseIndexes[reference] = verseIndex
            }
            guard let highlights = array(verse["highlights"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/highlights",
                    message: "Expected an array."
                ))
                continue
            }
            for (highlightIndex, highlightValue) in highlights.enumerated() {
                let path = "\(versePath)/highlights/\(highlightIndex)"
                guard let highlight = object(highlightValue) else {
                    issues.append(.init(severity: .error, path: path, message: "Expected an object."))
                    continue
                }
                guard let start = integer(highlight["sc"]), start >= 0 else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/sc",
                        message: "Expected a nonnegative start offset."
                    ))
                    continue
                }
                guard let end = integer(highlight["ec"]), end > start else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/ec",
                        message: "Expected an end offset greater than the start offset."
                    ))
                    continue
                }
                guard let style = integer(highlight["style"]), (0...3).contains(style) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/style",
                        message: "Expected style 0, 1, 2, or 3."
                    ))
                    continue
                }
                if let color = highlight["color"], !(color is String) {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/color",
                        message: "Expected a color name or hex string."
                    ))
                }
            }
        }

        let meta = object(root["meta"])
        if let themesValue = meta?["themes"], array(themesValue) == nil {
            issues.append(.init(
                severity: .error,
                path: "/meta/themes",
                message: "Expected an array."
            ))
        }
        let themes = meta.flatMap { array($0["themes"]) } ?? []
        var themeKeys: Set<String> = []
        for (themeIndex, themeValue) in themes.enumerated() {
            let path = "/meta/themes/\(themeIndex)"
            guard let theme = object(themeValue),
                  let color = string(theme["color"]), !color.isEmpty,
                  let style = integer(theme["style"]), (0...3).contains(style),
                  let name = string(theme["name"]), !name.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Expected color, style 0 through 3, and a non-empty theme name."
                ))
                continue
            }
            let key = "\(color.uppercased()):\(style)"
            if !themeKeys.insert(key).inserted {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Duplicate theme for color \(color) and style \(style)."
                ))
            }
        }
    }

    private func validateTextContent(
        _ value: Any,
        path: String,
        issues: inout [ModuleValidationIssue]
    ) {
        if let text = string(value) {
            if text.isEmpty {
                issues.append(.init(severity: .error, path: path, message: "Expected non-empty text."))
            }
            return
        }
        if let value = object(value), let text = string(value["text"]), !text.isEmpty {
            return
        }
        issues.append(.init(
            severity: .error,
            path: path,
            message: "Expected a string or an annotated-text object with non-empty text."
        ))
    }

    private func statistics(kind: LampModuleKind?, root: [String: Any]) -> [String: Int] {
        guard let kind else { return [:] }

        switch kind {
        case .translation:
            let books = array(root["books"]) ?? []
            let chapters = books.flatMap { object($0).flatMap { array($0["chapters"]) } ?? [] }
            let verses = chapters.flatMap { object($0).flatMap { array($0["verses"]) } ?? [] }
            return ["books": books.count, "chapters": chapters.count, "verses": verses.count]
        case .dictionary:
            return ["entries": array(root["entries"])?.count ?? 0]
        case .commentary:
            return ["chapters": array(root["chapters"])?.count ?? 0]
        case .book:
            func counts(_ values: [Any]) -> (sections: Int, blocks: Int) {
                values.reduce(into: (sections: 0, blocks: 0)) { result, value in
                    guard let section = object(value) else { return }
                    result.sections += 1
                    result.blocks += array(section["content"])?.count ?? 0
                    let childCounts = counts(array(section["sections"]) ?? [])
                    result.sections += childCounts.sections
                    result.blocks += childCounts.blocks
                }
            }
            let result = counts(array(root["sections"]) ?? [])
            return ["sections": result.sections, "contentBlocks": result.blocks]
        case .notes:
            let chapters = array(root["chapters"]) ?? []
            let notes = chapters.reduce(into: 0) { count, value in
                guard let chapter = object(value) else { return }
                if chapter["introduction"] != nil { count += 1 }
                count += array(chapter["verses"])?.count ?? 0
            }
            return ["chapters": chapters.count, "notes": notes]
        case .devotional:
            return ["contentBlocks": array(root["content"])?.count ?? (root["content"] == nil ? 0 : 1)]
        case .plan, .quiz:
            return ["days": array(root["days"])?.count ?? 0]
        case .highlights:
            let verses = array(root["verses"]) ?? []
            let highlights = verses.reduce(into: 0) { count, value in
                count += object(value).flatMap { array($0["highlights"]) }?.count ?? 0
            }
            return ["verses": verses.count, "highlights": highlights]
        }
    }

    private func requireStrings(
        _ object: [String: Any],
        keys: [String],
        issues: inout [ModuleValidationIssue]
    ) {
        for key in keys {
            requireString(object, key: key, basePath: "/meta", issues: &issues)
        }
    }

    private func requireString(
        _ object: [String: Any],
        key: String,
        basePath: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard let value = string(object[key]), !value.isEmpty else {
            issues.append(.init(severity: .error, path: "\(basePath)/\(key)", message: "Expected a non-empty string."))
            return
        }
    }

    private func requireObject(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard object(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an object."))
            return
        }
    }

    private func requireArray(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard array(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an array."))
            return
        }
    }

    private func requireInteger(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard integer(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an integer."))
            return
        }
    }

    private func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private func issueSort(_ lhs: ModuleValidationIssue, _ rhs: ModuleValidationIssue) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity == .error }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.message < rhs.message
    }
}
