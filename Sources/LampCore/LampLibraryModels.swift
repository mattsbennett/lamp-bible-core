import Foundation
import LampModuleKit

public struct LampInstalledModule: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: LampModuleKind
    public let name: String
    public let abbreviation: String?
    public let language: String?
    public let compressedByteCount: Int
    public let isBundled: Bool

    public init(
        id: String,
        kind: LampModuleKind,
        name: String,
        abbreviation: String? = nil,
        language: String? = nil,
        compressedByteCount: Int = 0,
        isBundled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.abbreviation = abbreviation
        self.language = language
        self.compressedByteCount = compressedByteCount
        self.isBundled = isBundled
    }
}

/// Portable formats available when exporting an installed user module.
public enum LampModuleExportFormat: String, CaseIterable, Identifiable, Sendable {
    case lamp
    case markdown

    public var id: String { rawValue }
}

/// The editable collections Lamp Bible creates for every library, independent
/// of any imported module files.
public enum LampPersonalModule: String, CaseIterable, Identifiable, Sendable {
    case writing = "personal-devotionals"
    case notes = "personal-notes"
    case highlights = "personal-highlights"

    public var id: String { rawValue }

    public var kind: LampModuleKind {
        switch self {
        case .writing: .devotional
        case .notes: .notes
        case .highlights: .highlights
        }
    }

    public var name: String {
        switch self {
        case .writing: "My Writing"
        case .notes: "My Notes"
        case .highlights: "My Highlights"
        }
    }
}

public struct LampTranslationBook: Identifiable, Equatable, Sendable {
    public let id: Int
    public let osisID: String
    public let name: String
    public let testament: String
    public let chapterCount: Int

    public init(
        id: Int,
        osisID: String,
        name: String,
        testament: String,
        chapterCount: Int
    ) {
        self.id = id
        self.osisID = osisID
        self.name = name
        self.testament = testament
        self.chapterCount = chapterCount
    }
}

public struct LampVerse: Identifiable, Equatable, Sendable {
    public let id: Int
    public let number: Int
    public let text: String
    public let beginsParagraph: Bool
    public let annotations: [LampVerseAnnotation]
    public let hasFootnotes: Bool
    public let poetry: LampVersePoetry?

    public init(
        id: Int,
        number: Int,
        text: String,
        beginsParagraph: Bool,
        annotations: [LampVerseAnnotation] = [],
        hasFootnotes: Bool = false,
        poetry: LampVersePoetry? = nil
    ) {
        self.id = id
        self.number = number
        self.text = text
        self.beginsParagraph = beginsParagraph
        self.annotations = annotations
        self.hasFootnotes = hasFootnotes
        self.poetry = poetry
    }
}

public struct LampVersePoetry: Equatable, Sendable {
    public let indent: Int
    public let stanzaBreak: Bool

    public init(indent: Int = 0, stanzaBreak: Bool = false) {
        self.indent = indent
        self.stanzaBreak = stanzaBreak
    }
}

public struct LampHeading: Identifiable, Equatable, Sendable {
    public let id: Int
    public let beforeVerse: Int
    public let level: Int
    public let text: String

    public init(id: Int, beforeVerse: Int, level: Int, text: String) {
        self.id = id
        self.beforeVerse = beforeVerse
        self.level = level
        self.text = text
    }
}

public struct LampChapter: Equatable, Sendable {
    public let translationID: String
    public let book: LampTranslationBook
    public let number: Int
    public let verses: [LampVerse]
    public let headings: [LampHeading]

    public init(
        translationID: String,
        book: LampTranslationBook,
        number: Int,
        verses: [LampVerse],
        headings: [LampHeading]
    ) {
        self.translationID = translationID
        self.book = book
        self.number = number
        self.verses = verses
        self.headings = headings
    }
}

public struct LampTranslationSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(translationID):\(reference)" }

    public let translationID: String
    public let translationName: String
    public let translationAbbreviation: String?
    public let reference: Int
    public let bookNumber: Int
    public let bookName: String
    public let chapterNumber: Int
    public let verseNumber: Int
    public let text: String

    public init(
        translationID: String,
        translationName: String,
        translationAbbreviation: String? = nil,
        reference: Int,
        bookNumber: Int,
        bookName: String,
        chapterNumber: Int,
        verseNumber: Int,
        text: String
    ) {
        self.translationID = translationID
        self.translationName = translationName
        self.translationAbbreviation = translationAbbreviation
        self.reference = reference
        self.bookNumber = bookNumber
        self.bookName = bookName
        self.chapterNumber = chapterNumber
        self.verseNumber = verseNumber
        self.text = text
    }

    public var displayReference: String {
        "\(bookName) \(chapterNumber):\(verseNumber)"
    }
}

public struct LampModuleSearchResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: LampModuleKind
    public let moduleID: String
    public let moduleName: String
    public let title: String
    public let subtitle: String?
    public let snippet: String
    public let startReference: Int?
    public let endReference: Int?

    public init(
        id: String,
        kind: LampModuleKind,
        moduleID: String,
        moduleName: String,
        title: String,
        subtitle: String? = nil,
        snippet: String,
        startReference: Int? = nil,
        endReference: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.startReference = startReference
        self.endReference = endReference
    }

    public var referenceDescription: String? {
        guard let startReference else { return nil }
        return LampBibleReferenceFormatter.describeRange(
            from: startReference,
            to: endReference ?? startReference
        )
    }
}

public struct LampVerseAnnotation: Identifiable, Equatable, Sendable {
    public var id: String {
        [kind, String(startOffset), String(endOffset), strongs, lemma]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    public let kind: String
    public let startOffset: Int
    public let endOffset: Int
    public let text: String?
    public let strongs: String?
    public let morphology: String?
    public let lemma: String?
    public let startReference: Int?
    public let endReference: Int?

    public init(
        kind: String,
        startOffset: Int,
        endOffset: Int,
        text: String? = nil,
        strongs: String? = nil,
        morphology: String? = nil,
        lemma: String? = nil,
        startReference: Int? = nil,
        endReference: Int? = nil
    ) {
        self.kind = kind
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.text = text
        self.strongs = strongs
        self.morphology = morphology
        self.lemma = lemma
        self.startReference = startReference
        self.endReference = endReference
    }

    public var scriptureDescription: String? {
        guard let startReference else { return nil }
        return LampBibleReferenceFormatter.describeRange(
            from: startReference,
            to: endReference ?? startReference
        )
    }
}

public struct LampVerseFootnote: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String?
    public let content: String

    public init(id: String, kind: String? = nil, content: String) {
        self.id = id
        self.kind = kind
        self.content = content
    }
}

public struct LampVerseFootnoteReference: Identifiable, Equatable, Sendable {
    public var id: String { "\(footnoteID):\(offset)" }

    public let footnoteID: String
    public let offset: Int

    public init(footnoteID: String, offset: Int) {
        self.footnoteID = footnoteID
        self.offset = offset
    }
}

public struct LampVerseStudyData: Equatable, Sendable {
    public let translationID: String
    public let reference: Int
    public let annotations: [LampVerseAnnotation]
    public let footnotes: [LampVerseFootnote]
    public let footnoteReferences: [LampVerseFootnoteReference]

    public init(
        translationID: String,
        reference: Int,
        annotations: [LampVerseAnnotation],
        footnotes: [LampVerseFootnote],
        footnoteReferences: [LampVerseFootnoteReference]
    ) {
        self.translationID = translationID
        self.reference = reference
        self.annotations = annotations
        self.footnotes = footnotes
        self.footnoteReferences = footnoteReferences
    }

    public var lexicalAnnotations: [LampVerseAnnotation] {
        annotations.filter { $0.strongs != nil || $0.lemma != nil || $0.morphology != nil }
    }

    public var scriptureAnnotations: [LampVerseAnnotation] {
        annotations.filter { $0.startReference != nil }
    }

    public var isEmpty: Bool {
        annotations.isEmpty && footnotes.isEmpty
    }
}

public struct LampDictionarySense: Equatable, Sendable {
    public let partOfSpeech: String?
    public let gloss: String?
    public let shortDefinition: String?
    public let definition: String?
    public let derivation: String?
    public let usage: String?
    public let scriptureLinks: [LampScriptureLink]
    public let dictionaryLinks: [LampDictionaryLink]

    public init(
        partOfSpeech: String? = nil,
        gloss: String? = nil,
        shortDefinition: String? = nil,
        definition: String? = nil,
        derivation: String? = nil,
        usage: String? = nil,
        scriptureLinks: [LampScriptureLink] = [],
        dictionaryLinks: [LampDictionaryLink] = []
    ) {
        self.partOfSpeech = partOfSpeech
        self.gloss = gloss
        self.shortDefinition = shortDefinition
        self.definition = definition
        self.derivation = derivation
        self.usage = usage
        self.scriptureLinks = scriptureLinks
        self.dictionaryLinks = dictionaryLinks
    }
}

/// An inline link from one dictionary entry to another, most commonly a Strong's
/// derivation such as "from G25". The label is preserved separately because many
/// lexicons include the related lemma alongside the key.
public struct LampDictionaryLink: Identifiable, Equatable, Sendable {
    public var id: String { "\(key):\(text ?? "")" }

    public let text: String?
    public let key: String

    public init(text: String? = nil, key: String) {
        self.text = text
        self.key = key
    }

    public var displayDescription: String { text ?? key }
}

public struct LampDictionaryResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(moduleID):\(entryID)" }

    public let entryID: String
    public let moduleID: String
    public let moduleName: String
    public let key: String
    public let lemma: String
    public let transliteration: String?
    public let pronunciation: String?
    public let senses: [LampDictionarySense]

    public init(
        entryID: String,
        moduleID: String,
        moduleName: String,
        key: String,
        lemma: String,
        transliteration: String? = nil,
        pronunciation: String? = nil,
        senses: [LampDictionarySense]
    ) {
        self.entryID = entryID
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.key = key
        self.lemma = lemma
        self.transliteration = transliteration
        self.pronunciation = pronunciation
        self.senses = senses
    }

    public var summary: String? {
        senses.lazy.compactMap { $0.shortDefinition ?? $0.gloss ?? $0.definition }.first
    }
}

public struct LampCommentaryUnit: Identifiable, Equatable, Sendable {
    public var id: String { "\(moduleID):\(unitID)" }

    public let unitID: String
    public let moduleID: String
    public let moduleName: String
    public let seriesAbbreviation: String?
    public let bookNumber: Int
    public let chapterNumber: Int?
    public let startReference: Int
    public let endReference: Int?
    public let unitType: String
    public let level: Int
    public let title: String?
    public let introduction: String?
    public let translation: String?
    public let commentary: String?
    public let footnotes: String?
    public let scriptureLinks: [LampScriptureLink]
    public let orderIndex: Int

    public init(
        unitID: String,
        moduleID: String,
        moduleName: String,
        seriesAbbreviation: String? = nil,
        bookNumber: Int,
        chapterNumber: Int?,
        startReference: Int,
        endReference: Int?,
        unitType: String,
        level: Int,
        title: String? = nil,
        introduction: String? = nil,
        translation: String? = nil,
        commentary: String? = nil,
        footnotes: String? = nil,
        scriptureLinks: [LampScriptureLink] = [],
        orderIndex: Int
    ) {
        self.unitID = unitID
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.seriesAbbreviation = seriesAbbreviation
        self.bookNumber = bookNumber
        self.chapterNumber = chapterNumber
        self.startReference = startReference
        self.endReference = endReference
        self.unitType = unitType
        self.level = level
        self.title = title
        self.introduction = introduction
        self.translation = translation
        self.commentary = commentary
        self.footnotes = footnotes
        self.scriptureLinks = scriptureLinks
        self.orderIndex = orderIndex
    }
}

public struct LampScriptureLink: Identifiable, Equatable, Sendable {
    public var id: String { "\(startReference):\(endReference ?? startReference):\(text ?? "")" }

    public let text: String?
    public let startReference: Int
    public let endReference: Int?

    public init(text: String? = nil, startReference: Int, endReference: Int? = nil) {
        self.text = text
        self.startReference = startReference
        self.endReference = endReference
    }

    public var displayDescription: String {
        text ?? LampBibleReferenceFormatter.describeRange(
            from: startReference,
            to: endReference ?? startReference
        )
    }
}

public struct LampDevotional: Identifiable, Equatable, Sendable {
    public let id: String
    public let moduleID: String
    public let moduleName: String
    public let title: String
    public let subtitle: String?
    public let author: String?
    public let date: String?
    public let tags: [String]
    public let category: String?
    public let seriesName: String?
    public let seriesOrder: Int?
    public let keyScriptures: [LampScriptureLink]
    public let summary: String?
    public let content: String
    /// Original structured blocks from a devotional module, retained while the body is unchanged.
    public var contentJSON: String?
    public let footnotes: String?
    /// Original wire JSON is kept so metadata added by a newer client survives.
    public var mediaJSON: String?
    public let created: Date?
    public let lastModified: Date?
    public let isEditable: Bool

    public init(
        id: String,
        moduleID: String,
        moduleName: String,
        title: String,
        subtitle: String? = nil,
        author: String? = nil,
        date: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        seriesName: String? = nil,
        seriesOrder: Int? = nil,
        keyScriptures: [LampScriptureLink] = [],
        summary: String? = nil,
        content: String,
        contentJSON: String? = nil,
        footnotes: String? = nil,
        mediaJSON: String? = nil,
        created: Date? = nil,
        lastModified: Date? = nil,
        isEditable: Bool = false
    ) {
        self.id = id
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.date = date
        self.tags = tags
        self.category = category
        self.seriesName = seriesName
        self.seriesOrder = seriesOrder
        self.keyScriptures = keyScriptures
        self.summary = summary
        self.content = content
        self.contentJSON = contentJSON
        self.footnotes = footnotes
        self.mediaJSON = mediaJSON
        self.created = created
        self.lastModified = lastModified
        self.isEditable = isEditable
    }

    public var mediaReferences: [LampDevotionalMediaReference] {
        guard let mediaJSON else { return [] }
        return (try? JSONDecoder().decode(
            [LampDevotionalMediaReference].self, from: Data(mediaJSON.utf8)
        )) ?? []
    }

    /// Rich iOS blocks are rendered from their original JSON without changing
    /// the flattened text used by the portable library's merge decisions.
    public var displayMarkdown: String {
        guard let contentJSON,
              let markdown = LampPortableDevotionalContent.markdown(from: contentJSON),
              !markdown.isEmpty || content.isEmpty else { return content }
        return markdown
    }
}

public struct LampBook: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let author: String?
    public let editor: String?
    public let publisher: String?
    public let year: Int?
    public let edition: String?
    public let isbn: String?
    public let language: String
    public let textDirection: String
    public let copyright: String?
    public let license: String?
    public let version: String?
    public let tags: [String]
    public let coverMediaID: String?
    public let isEditable: Bool
    public let created: Date?
    public let lastModified: Date?
    public let footnotesJSON: String?
    public let mediaJSON: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        author: String? = nil,
        editor: String? = nil,
        publisher: String? = nil,
        year: Int? = nil,
        edition: String? = nil,
        isbn: String? = nil,
        language: String,
        textDirection: String = "ltr",
        copyright: String? = nil,
        license: String? = nil,
        version: String? = nil,
        tags: [String] = [],
        coverMediaID: String? = nil,
        isEditable: Bool = false,
        created: Date? = nil,
        lastModified: Date? = nil,
        footnotesJSON: String? = nil,
        mediaJSON: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.author = author
        self.editor = editor
        self.publisher = publisher
        self.year = year
        self.edition = edition
        self.isbn = isbn
        self.language = language
        self.textDirection = textDirection
        self.copyright = copyright
        self.license = license
        self.version = version
        self.tags = tags
        self.coverMediaID = coverMediaID
        self.isEditable = isEditable
        self.created = created
        self.lastModified = lastModified
        self.footnotesJSON = footnotesJSON
        self.mediaJSON = mediaJSON
    }
}

public struct LampBookSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let moduleID: String
    public let sectionID: String
    public let parentID: String?
    public let type: String
    public let number: String?
    public let title: String
    public let subtitle: String?
    public let depth: Int
    public let orderIndex: Int
    public let keyScriptures: [LampScriptureLink]
    public let contentJSON: String
    public let content: String

    public init(
        id: String,
        moduleID: String,
        sectionID: String,
        parentID: String? = nil,
        type: String,
        number: String? = nil,
        title: String,
        subtitle: String? = nil,
        depth: Int,
        orderIndex: Int,
        keyScriptures: [LampScriptureLink] = [],
        contentJSON: String,
        content: String
    ) {
        self.id = id
        self.moduleID = moduleID
        self.sectionID = sectionID
        self.parentID = parentID
        self.type = type
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.depth = depth
        self.orderIndex = orderIndex
        self.keyScriptures = keyScriptures
        self.contentJSON = contentJSON
        self.content = content
    }
}

public struct LampQuizAgeGroup: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let label: String
    public let ageRange: String

    public init(id: String, label: String, ageRange: String) {
        self.id = id
        self.label = label
        self.ageRange = ageRange
    }
}

public struct LampQuizModule: Identifiable, Equatable, Sendable {
    public let id: String
    public let planID: String
    public let name: String
    public let description: String?
    public let questionsPerReading: Int
    public let ageGroups: [LampQuizAgeGroup]

    public init(
        id: String,
        planID: String,
        name: String,
        description: String? = nil,
        questionsPerReading: Int,
        ageGroups: [LampQuizAgeGroup]
    ) {
        self.id = id
        self.planID = planID
        self.name = name
        self.description = description
        self.questionsPerReading = questionsPerReading
        self.ageGroups = ageGroups
    }
}

public struct LampQuizQuestion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let moduleID: String
    public let day: Int
    public let startReference: Int
    public let endReference: Int
    public let ageGroup: String
    public let questionIndex: Int
    public let question: String
    public let questionAnnotations: [LampVerseAnnotation]
    public let answer: String
    public let answerAnnotations: [LampVerseAnnotation]
    public let theme: String
    public let isChristFocused: Bool
    public let references: [Int]
    public let crossReferences: [Int]

    public init(
        id: Int64,
        moduleID: String,
        day: Int,
        startReference: Int,
        endReference: Int,
        ageGroup: String,
        questionIndex: Int,
        question: String,
        questionAnnotations: [LampVerseAnnotation] = [],
        answer: String,
        answerAnnotations: [LampVerseAnnotation] = [],
        theme: String,
        isChristFocused: Bool,
        references: [Int] = [],
        crossReferences: [Int] = []
    ) {
        self.id = id
        self.moduleID = moduleID
        self.day = day
        self.startReference = startReference
        self.endReference = endReference
        self.ageGroup = ageGroup
        self.questionIndex = questionIndex
        self.question = question
        self.questionAnnotations = questionAnnotations
        self.answer = answer
        self.answerAnnotations = answerAnnotations
        self.theme = theme
        self.isChristFocused = isChristFocused
        self.references = references
        self.crossReferences = crossReferences
    }

    public var readingDescription: String {
        LampBibleReferenceFormatter.describeRange(from: startReference, to: endReference)
    }
}

public struct LampVerseNote: Identifiable, Equatable, Sendable {
    public let id: String
    public let moduleID: String
    public let reference: Int
    public let title: String?
    public let content: String
    public let verseReferences: [Int]
    public let footnotes: [LampVerseFootnote]
    public let lastModified: Date

    public init(
        id: String = UUID().uuidString,
        moduleID: String = "personal-notes",
        reference: Int,
        title: String? = nil,
        content: String,
        verseReferences: [Int] = [],
        footnotes: [LampVerseFootnote] = [],
        lastModified: Date = Date()
    ) {
        self.id = id
        self.moduleID = moduleID
        self.reference = reference
        self.title = title
        self.content = content
        self.verseReferences = verseReferences
        self.footnotes = footnotes
        self.lastModified = lastModified
    }

    public var bookNumber: Int { reference / 1_000_000 }
    public var chapterNumber: Int { (reference / 1_000) % 1_000 }
    public var verseNumber: Int { reference % 1_000 }
}

public enum LampHighlightStyle: Int, CaseIterable, Codable, Equatable, Sendable {
    case highlight = 0
    case underlineSolid = 1
    case underlineDashed = 2
    case underlineDotted = 3
}

public struct LampHighlightSet: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let translationID: String
    public let created: Date
    public let lastModified: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        translationID: String,
        created: Date = Date(),
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.translationID = translationID
        self.created = created
        self.lastModified = lastModified
    }
}

public struct LampHighlightTheme: Identifiable, Equatable, Sendable {
    public var id: String { "\(setID):\(color):\(style.rawValue)" }
    public let setID: String
    public let color: String
    public let style: LampHighlightStyle
    public let name: String
    public let description: String?

    public init(
        setID: String,
        color: String,
        style: LampHighlightStyle,
        name: String,
        description: String? = nil
    ) {
        self.setID = setID
        self.color = color.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        self.style = style
        self.name = name
        self.description = description
    }
}

public struct LampVerseHighlight: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let setID: String
    public let translationID: String
    public let reference: Int
    public let startOffset: Int
    public let endOffset: Int
    public let style: LampHighlightStyle
    public let color: String?

    public init(
        id: Int64,
        setID: String,
        translationID: String,
        reference: Int,
        startOffset: Int,
        endOffset: Int,
        style: LampHighlightStyle = .highlight,
        color: String? = nil
    ) {
        self.id = id
        self.setID = setID
        self.translationID = translationID
        self.reference = reference
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.style = style
        self.color = color
    }

    public var bookNumber: Int { reference / 1_000_000 }
    public var chapterNumber: Int { (reference / 1_000) % 1_000 }
    public var verseNumber: Int { reference % 1_000 }
}

public struct LampPortableStudyDocument: Equatable, Sendable {
    public let moduleID: String
    public let kind: LampModuleKind
    public let name: String
    public let jsonData: Data

    public init(
        moduleID: String,
        kind: LampModuleKind,
        name: String,
        jsonData: Data
    ) {
        self.moduleID = moduleID
        self.kind = kind
        self.name = name
        self.jsonData = jsonData
    }

    public var suggestedJSONFilename: String { "\(moduleID).json" }
    public var suggestedModuleFilename: String { "\(moduleID).lamp" }
}

public struct LampStudyImportResult: Equatable, Sendable {
    public let moduleID: String
    public let kind: LampModuleKind
    public let importedCount: Int
    public let skippedCount: Int

    public init(
        moduleID: String,
        kind: LampModuleKind,
        importedCount: Int,
        skippedCount: Int
    ) {
        self.moduleID = moduleID
        self.kind = kind
        self.importedCount = importedCount
        self.skippedCount = skippedCount
    }
}

public struct LampPortableBackupSummary: Codable, Equatable, Sendable {
    public let moduleCount: Int
    public let noteDocumentCount: Int
    public let highlightDocumentCount: Int
    public let devotionalDocumentCount: Int

    public init(
        moduleCount: Int,
        noteDocumentCount: Int,
        highlightDocumentCount: Int,
        devotionalDocumentCount: Int
    ) {
        self.moduleCount = moduleCount
        self.noteDocumentCount = noteDocumentCount
        self.highlightDocumentCount = highlightDocumentCount
        self.devotionalDocumentCount = devotionalDocumentCount
    }

    public var itemCount: Int {
        moduleCount + noteDocumentCount + highlightDocumentCount + devotionalDocumentCount
    }
}

public struct LampPortableBackupImportResult: Equatable, Sendable {
    public let installedModules: Int
    public let importedStudyEntries: Int
    public let importedDevotionals: Int

    public init(installedModules: Int, importedStudyEntries: Int, importedDevotionals: Int) {
        self.installedModules = installedModules
        self.importedStudyEntries = importedStudyEntries
        self.importedDevotionals = importedDevotionals
    }
}

public struct LampReadingPlan: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let author: String?
    public let fullDescription: String?
    public let duration: Int
    public let readingsPerDay: Int?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        author: String? = nil,
        fullDescription: String? = nil,
        duration: Int,
        readingsPerDay: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.fullDescription = fullDescription
        self.duration = duration
        self.readingsPerDay = readingsPerDay
    }
}

public struct LampPlanReading: Identifiable, Equatable, Sendable {
    public let id: Int
    public let startReference: Int
    public let endReference: Int

    public init(id: Int, startReference: Int, endReference: Int) {
        self.id = id
        self.startReference = startReference
        self.endReference = endReference
    }

    public var displayDescription: String {
        LampBibleReferenceFormatter.describeRange(from: startReference, to: endReference)
    }

    public func completionID(planID: String, day: Int, year: Int) -> String {
        "\(planID)_\(day)_r\(id)_\(year)"
    }
}

public struct LampReadingPlanDay: Identifiable, Equatable, Sendable {
    public var id: String { "\(planID):\(day)" }

    public let planID: String
    public let day: Int
    public let readings: [LampPlanReading]

    public init(planID: String, day: Int, readings: [LampPlanReading]) {
        self.planID = planID
        self.day = day
        self.readings = readings
    }
}

public struct LampCompletedReading: Identifiable, Equatable, Sendable {
    public let id: String
    public let planID: String
    public let day: Int
    public let readingIndex: Int
    public let year: Int
    public let completedAt: Date

    public init(
        id: String,
        planID: String,
        day: Int,
        readingIndex: Int,
        year: Int,
        completedAt: Date
    ) {
        self.id = id
        self.planID = planID
        self.day = day
        self.readingIndex = readingIndex
        self.year = year
        self.completedAt = completedAt
    }
}

public enum LampPlanCalendar {
    public static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let leapYear = calendar.range(of: .day, in: .year, for: date)?.count == 366
        return !leapYear && day >= 60 ? day + 1 : day
    }

    /// Resolves the plan's stable 366-slot day number back to a date. Day 60 is
    /// reserved for February 29, so it intentionally has no date in non-leap years.
    public static func date(
        forDayNumber dayNumber: Int,
        year: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard (1...366).contains(dayNumber),
              let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let daysInYear = calendar.range(of: .day, in: .year, for: startOfYear)?.count else {
            return nil
        }
        let isLeapYear = daysInYear == 366
        if !isLeapYear && dayNumber == 60 { return nil }
        let ordinalDay = !isLeapYear && dayNumber > 60 ? dayNumber - 1 : dayNumber
        guard ordinalDay <= daysInYear,
              let date = calendar.date(byAdding: .day, value: ordinalDay - 1, to: startOfYear),
              calendar.component(.year, from: date) == year else {
            return nil
        }
        return date
    }
}

public enum LampBibleReferenceFormatter {
    public static func describeRange(from startReference: Int, to endReference: Int) -> String {
        let start = components(of: startReference)
        let end = components(of: endReference)
        let startBook = bookName(start.book)
        let endBook = bookName(end.book)

        if start.book == end.book {
            if start.chapter == end.chapter {
                if start.verse == 1 && end.verse == 999 {
                    return "\(startBook) \(start.chapter)"
                }
                if start.verse == end.verse {
                    return "\(startBook) \(start.chapter):\(start.verse)"
                }
                return "\(startBook) \(start.chapter):\(start.verse)–\(end.verse)"
            }
            if start.verse == 1 && end.verse == 999 {
                return "\(startBook) \(start.chapter)–\(end.chapter)"
            }
            return "\(startBook) \(start.chapter):\(start.verse)–\(end.chapter):\(end.verse)"
        }

        return "\(startBook) \(start.chapter):\(start.verse)–\(endBook) \(end.chapter):\(end.verse)"
    }

    public static func components(of reference: Int) -> (book: Int, chapter: Int, verse: Int) {
        (reference / 1_000_000, (reference / 1_000) % 1_000, reference % 1_000)
    }

    public static func bookName(_ number: Int) -> String {
        guard books.indices.contains(number - 1) else { return "Book \(number)" }
        return books[number - 1]
    }

    public static func bookAbbreviation(_ number: Int) -> String {
        guard bookAbbreviations.indices.contains(number - 1) else { return "Book\(number)" }
        return bookAbbreviations[number - 1]
    }

    private static let books = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth",
        "1 Samuel", "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah",
        "Esther", "Job", "Psalms", "Proverbs", "Ecclesiastes", "Song of Songs", "Isaiah", "Jeremiah",
        "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah",
        "Nahum", "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew", "Mark", "Luke",
        "John", "Acts", "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians",
        "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon",
        "Hebrews", "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude", "Revelation",
    ]

    private static let bookAbbreviations = [
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
        "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
        "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
        "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic",
        "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt", "Mark", "Luke",
        "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil",
        "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm",
        "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John", "Jude", "Rev",
    ]
}

public enum LampLibraryError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileExtension
    case decompressionFailed
    case integrityCheckFailed(String)
    case unsupportedModuleSchema
    case missingModuleMetadata
    case unsafeModuleIdentifier(String)
    case moduleNotFound(String)
    case notATranslation(String)
    case emptyChapter(book: Int, chapter: Int)
    case noPersonalNotes(book: Int)
    case noPersonalHighlights(translationID: String)
    case invalidStudyDataExtension
    case invalidPersonalContent(String)
    case syncConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileExtension:
            return "Choose a file with the .lamp extension."
        case .decompressionFailed:
            return "The file is not a valid compressed Lamp module."
        case .integrityCheckFailed(let reason):
            return "The module database failed its integrity check: \(reason)"
        case .unsupportedModuleSchema:
            return "This .lamp database uses an unsupported module schema."
        case .missingModuleMetadata:
            return "The module database does not contain readable metadata."
        case .unsafeModuleIdentifier(let identifier):
            return "The module identifier ‘\(identifier)’ is not safe to install."
        case .moduleNotFound(let identifier):
            return "The module ‘\(identifier)’ is not installed."
        case .notATranslation(let identifier):
            return "The module ‘\(identifier)’ is not a Bible translation."
        case .emptyChapter(let book, let chapter):
            return "No verses were found for book \(book), chapter \(chapter)."
        case .noPersonalNotes(let book):
            return "There are no saved personal notes for \(LampBibleReferenceFormatter.bookName(book))."
        case .noPersonalHighlights(let translationID):
            return "There are no saved personal highlights for \(translationID)."
        case .invalidStudyDataExtension:
            return "Choose canonical study data in a .json or .lamp file."
        case .invalidPersonalContent(let reason):
            return reason
        case .syncConflict(let identifier):
            return "Two versions of \(identifier) have the same change time but different content. Sync stopped to preserve both."
        }
    }
}
