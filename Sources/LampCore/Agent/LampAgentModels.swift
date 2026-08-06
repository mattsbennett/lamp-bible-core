import Foundation
import LampModuleKit

public struct LampAgentModule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: LampModuleKind
    public let name: String
    public let abbreviation: String?
    public let language: String?
    public let isBundled: Bool
    public let isPersonal: Bool

    public init(
        id: String,
        kind: LampModuleKind,
        name: String,
        abbreviation: String? = nil,
        language: String? = nil,
        isBundled: Bool = false,
        isPersonal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.abbreviation = abbreviation
        self.language = language
        self.isBundled = isBundled
        self.isPersonal = isPersonal
    }
}

public struct LampAgentReferencePoint: Codable, Equatable, Sendable {
    public let book: Int
    public let chapter: Int
    public let verse: Int?

    public init(book: Int, chapter: Int, verse: Int? = nil) {
        self.book = book
        self.chapter = chapter
        self.verse = verse
    }

    public var reference: Int? {
        verse.map { book * 1_000_000 + chapter * 1_000 + $0 }
    }
}

public struct LampAgentReferenceRange: Codable, Equatable, Sendable {
    public let start: LampAgentReferencePoint
    public let end: LampAgentReferencePoint

    public init(start: LampAgentReferencePoint, end: LampAgentReferencePoint) {
        self.start = start
        self.end = end
    }
}

public struct LampAgentSearchResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: LampModuleKind
    public let moduleID: String
    public let moduleName: String
    public let title: String
    public let subtitle: String?
    public let snippet: String
    public let reference: String?

    public init(
        id: String,
        kind: LampModuleKind,
        moduleID: String,
        moduleName: String,
        title: String,
        subtitle: String?,
        snippet: String,
        reference: String?
    ) {
        self.id = id
        self.kind = kind
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.reference = reference
    }
}

public struct LampAgentAnnotation: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String?
    public let startOffset: Int
    public let endOffset: Int
    public let strongs: String?
    public let lemma: String?
    public let morphology: String?
    public let scriptureReference: String?

    public init(
        kind: String,
        text: String?,
        startOffset: Int,
        endOffset: Int,
        strongs: String?,
        lemma: String?,
        morphology: String?,
        scriptureReference: String?
    ) {
        self.kind = kind
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.strongs = strongs
        self.lemma = lemma
        self.morphology = morphology
        self.scriptureReference = scriptureReference
    }
}

public struct LampAgentVerse: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { referenceID }
    public let referenceID: Int
    public let reference: String
    public let number: Int
    public let text: String
    public let beginsParagraph: Bool
    public let annotations: [LampAgentAnnotation]

    public init(
        referenceID: Int,
        reference: String,
        number: Int,
        text: String,
        beginsParagraph: Bool,
        annotations: [LampAgentAnnotation]
    ) {
        self.referenceID = referenceID
        self.reference = reference
        self.number = number
        self.text = text
        self.beginsParagraph = beginsParagraph
        self.annotations = annotations
    }
}

public struct LampAgentHeading: Codable, Equatable, Sendable {
    public let beforeReference: String
    public let level: Int
    public let text: String

    public init(beforeReference: String, level: Int, text: String) {
        self.beforeReference = beforeReference
        self.level = level
        self.text = text
    }
}

public struct LampAgentTranslationPassage: Codable, Equatable, Sendable {
    public let translationID: String
    public let translationName: String
    public let translationAbbreviation: String?
    public let reference: String
    public let verses: [LampAgentVerse]
    public let headings: [LampAgentHeading]
    public let wasTruncated: Bool

    public init(
        translationID: String,
        translationName: String,
        translationAbbreviation: String?,
        reference: String,
        verses: [LampAgentVerse],
        headings: [LampAgentHeading],
        wasTruncated: Bool
    ) {
        self.translationID = translationID
        self.translationName = translationName
        self.translationAbbreviation = translationAbbreviation
        self.reference = reference
        self.verses = verses
        self.headings = headings
        self.wasTruncated = wasTruncated
    }
}

public struct LampAgentCommentary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(moduleID):\(unitID)" }
    public let unitID: String
    public let moduleID: String
    public let moduleName: String
    public let seriesAbbreviation: String?
    public let reference: String
    public let title: String?
    public let introduction: String?
    public let translation: String?
    public let commentary: String?
    public let footnotes: String?

    public init(
        unitID: String,
        moduleID: String,
        moduleName: String,
        seriesAbbreviation: String?,
        reference: String,
        title: String?,
        introduction: String?,
        translation: String?,
        commentary: String?,
        footnotes: String?
    ) {
        self.unitID = unitID
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.seriesAbbreviation = seriesAbbreviation
        self.reference = reference
        self.title = title
        self.introduction = introduction
        self.translation = translation
        self.commentary = commentary
        self.footnotes = footnotes
    }
}

public struct LampAgentDictionarySense: Codable, Equatable, Sendable {
    public let partOfSpeech: String?
    public let gloss: String?
    public let shortDefinition: String?
    public let definition: String?
    public let usage: String?

    public init(_ sense: LampDictionarySense) {
        partOfSpeech = sense.partOfSpeech
        gloss = sense.gloss
        shortDefinition = sense.shortDefinition
        definition = sense.definition
        usage = sense.usage
    }
}

public struct LampAgentDictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(moduleID):\(entryID)" }
    public let entryID: String
    public let moduleID: String
    public let moduleName: String
    public let key: String
    public let lemma: String
    public let transliteration: String?
    public let pronunciation: String?
    public let senses: [LampAgentDictionarySense]

    public init(_ entry: LampDictionaryResult) {
        entryID = entry.entryID
        moduleID = entry.moduleID
        moduleName = entry.moduleName
        key = entry.key
        lemma = entry.lemma
        transliteration = entry.transliteration
        pronunciation = entry.pronunciation
        senses = entry.senses.map(LampAgentDictionarySense.init)
    }
}

public struct LampAgentReadingPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let author: String?
    public let fullDescription: String?
    public let duration: Int
    public let readingsPerDay: Int?

    public init(_ plan: LampReadingPlan) {
        id = plan.id
        name = plan.name
        description = plan.description
        author = plan.author
        fullDescription = plan.fullDescription
        duration = plan.duration
        readingsPerDay = plan.readingsPerDay
    }
}

public struct LampAgentPlanReading: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let reference: String

    public init(_ reading: LampPlanReading) {
        id = reading.id
        reference = reading.displayDescription
    }
}

public struct LampAgentReadingPlanDay: Codable, Equatable, Sendable {
    public let planID: String
    public let day: Int
    public let readings: [LampAgentPlanReading]

    public init(_ planDay: LampReadingPlanDay) {
        planID = planDay.planID
        day = planDay.day
        readings = planDay.readings.map(LampAgentPlanReading.init)
    }
}

public struct LampAgentDevotional: Codable, Equatable, Identifiable, Sendable {
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
    public let keyScriptures: [String]
    public let summary: String?
    public let content: String
    public let footnotes: String?

    public init(_ devotional: LampDevotional, content: String? = nil) {
        id = devotional.id
        moduleID = devotional.moduleID
        moduleName = devotional.moduleName
        title = devotional.title
        subtitle = devotional.subtitle
        author = devotional.author
        date = devotional.date
        tags = devotional.tags
        category = devotional.category
        seriesName = devotional.seriesName
        seriesOrder = devotional.seriesOrder
        keyScriptures = devotional.keyScriptures.map(\.displayDescription)
        summary = devotional.summary
        self.content = content ?? devotional.content
        footnotes = devotional.footnotes
    }
}

public struct LampAgentBook: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let description: String?
    public let author: String?
    public let editor: String?
    public let publisher: String?
    public let year: Int?
    public let language: String
    public let tags: [String]

    public init(_ book: LampBook) {
        id = book.id
        title = book.title
        subtitle = book.subtitle
        description = book.description
        author = book.author
        editor = book.editor
        publisher = book.publisher
        year = book.year
        language = book.language
        tags = book.tags
    }
}

public struct LampAgentBookSectionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sectionID }
    public let sectionID: String
    public let parentSectionID: String?
    public let type: String
    public let number: String?
    public let title: String
    public let subtitle: String?
    public let depth: Int
    public let keyScriptures: [String]

    public init(_ section: LampBookSection) {
        sectionID = section.sectionID
        parentSectionID = section.parentID.map { parentID in
            let prefix = "\(section.moduleID):"
            return parentID.hasPrefix(prefix) ? String(parentID.dropFirst(prefix.count)) : parentID
        }
        type = section.type
        number = section.number
        title = section.title
        subtitle = section.subtitle
        depth = section.depth
        keyScriptures = section.keyScriptures.map(\.displayDescription)
    }
}

public struct LampAgentBookSection: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(moduleID):\(section.sectionID)" }
    public let moduleID: String
    public let section: LampAgentBookSectionSummary
    public let content: String

    public init(_ section: LampBookSection, content: String? = nil) {
        moduleID = section.moduleID
        self.section = LampAgentBookSectionSummary(section)
        self.content = content ?? section.content
    }
}

public struct LampAgentQuizModule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let planID: String
    public let name: String
    public let description: String?
    public let questionsPerReading: Int
    public let ageGroups: [LampQuizAgeGroup]

    public init(_ module: LampQuizModule) {
        id = module.id
        planID = module.planID
        name = module.name
        description = module.description
        questionsPerReading = module.questionsPerReading
        ageGroups = module.ageGroups
    }
}

public struct LampAgentQuizQuestion: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let moduleID: String
    public let day: Int
    public let reference: String
    public let ageGroup: String
    public let questionIndex: Int
    public let question: String
    public let answer: String
    public let theme: String
    public let isChristFocused: Bool
    public let references: [String]
    public let crossReferences: [String]

    public init(_ question: LampQuizQuestion) {
        id = question.id
        moduleID = question.moduleID
        day = question.day
        reference = question.readingDescription
        ageGroup = question.ageGroup
        questionIndex = question.questionIndex
        self.question = question.question
        answer = question.answer
        theme = question.theme
        isChristFocused = question.isChristFocused
        references = question.references.map {
            LampBibleReferenceFormatter.describeRange(from: $0, to: $0)
        }
        crossReferences = question.crossReferences.map {
            LampBibleReferenceFormatter.describeRange(from: $0, to: $0)
        }
    }
}

public struct LampAgentNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let moduleID: String
    public let reference: String
    public let title: String?
    public let content: String
    public let verseReferences: [String]

    public init(_ note: LampVerseNote) {
        id = note.id
        moduleID = note.moduleID
        reference = LampBibleReferenceFormatter.describeRange(from: note.reference, to: note.reference)
        title = note.title
        content = note.content
        verseReferences = note.verseReferences.map {
            LampBibleReferenceFormatter.describeRange(from: $0, to: $0)
        }
    }
}

public struct LampAgentHighlight: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let setID: String
    public let translationID: String
    public let reference: String
    public let startOffset: Int
    public let endOffset: Int
    public let style: LampHighlightStyle
    public let color: String?

    public init(_ highlight: LampVerseHighlight) {
        id = highlight.id
        setID = highlight.setID
        translationID = highlight.translationID
        reference = LampBibleReferenceFormatter.describeRange(
            from: highlight.reference,
            to: highlight.reference
        )
        startOffset = highlight.startOffset
        endOffset = highlight.endOffset
        style = highlight.style
        color = highlight.color
    }
}

public struct LampAgentStudyMaterial: Codable, Equatable, Sendable {
    public let translationID: String
    public let reference: String
    public let annotations: [LampAgentAnnotation]
    public let footnotes: [String]
    public let notes: [LampAgentNote]
    public let highlights: [LampAgentHighlight]

    public init(
        translationID: String,
        reference: String,
        annotations: [LampAgentAnnotation],
        footnotes: [String],
        notes: [LampAgentNote],
        highlights: [LampAgentHighlight]
    ) {
        self.translationID = translationID
        self.reference = reference
        self.annotations = annotations
        self.footnotes = footnotes
        self.notes = notes
        self.highlights = highlights
    }
}

public enum LampAgentError: Error, LocalizedError, Equatable, Sendable {
    case disabled
    case invalidReference(String)
    case referenceRangeTooLarge(Int)
    case moduleNotAllowed(String)
    case noMatchingModule(LampModuleKind)
    case itemNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Lamp module access is disabled in Settings."
        case .invalidReference(let reference):
            "‘\(reference)’ is not a valid Bible reference. Try a form such as John 1:1–3."
        case .referenceRangeTooLarge(let maximum):
            "That passage is too large. Request at most \(maximum) verses at a time."
        case .moduleNotAllowed(let moduleID):
            "The module ‘\(moduleID)’ is not available to agents."
        case .noMatchingModule(let kind):
            "No permitted \(kind.rawValue) module is available."
        case .itemNotFound(let identifier):
            "No permitted library item matches ‘\(identifier)’."
        }
    }
}
