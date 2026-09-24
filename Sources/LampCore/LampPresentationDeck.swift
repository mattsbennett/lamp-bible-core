import Foundation

/// A portable, editable presentation authored by Lamp Bible.
///
/// The format is intentionally semantic. Authors choose layouts and content
/// roles while platform renderers own typography and geometry.
public struct LampPresentationDeck: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var source: LampPresentationSource?
    public var aspectRatio: LampPresentationAspectRatio
    public var theme: LampPresentationTheme
    public var slides: [LampPresentationSlide]

    public init(
        schemaVersion: Int = LampPresentationDeck.currentSchemaVersion,
        id: String = UUID().uuidString.lowercased(),
        title: String,
        source: LampPresentationSource? = nil,
        aspectRatio: LampPresentationAspectRatio = .widescreen,
        theme: LampPresentationTheme = .lampDark,
        slides: [LampPresentationSlide]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.source = source
        self.aspectRatio = aspectRatio
        self.theme = theme
        self.slides = slides
    }

    public static func starter(
        title: String = "Untitled Presentation",
        subtitle: String? = nil,
        source: LampPresentationSource? = nil
    ) -> LampPresentationDeck {
        var titleBlocks = [
            LampPresentationBlock(kind: .title, text: title),
        ]
        if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titleBlocks.append(LampPresentationBlock(kind: .subtitle, text: subtitle))
        }
        return LampPresentationDeck(
            title: title,
            source: source,
            slides: [
                LampPresentationSlide(layout: .title, blocks: titleBlocks),
                LampPresentationSlide(
                    layout: .titleAndBody,
                    blocks: [
                        LampPresentationBlock(kind: .title, text: "Main Idea"),
                        LampPresentationBlock(kind: .body, text: "Add the central thought here."),
                    ],
                    speakerNotes: "Use these notes as prompts; they are never shown on the slide."
                ),
                LampPresentationSlide(
                    layout: .closing,
                    blocks: [LampPresentationBlock(kind: .title, text: "Reflection")]
                ),
            ]
        )
    }
}

public struct LampPresentationSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case devotional
        case writing
        case scripture
        case standalone
    }

    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public enum LampPresentationAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case widescreen
    case standard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .widescreen: "Widescreen (16:9)"
        case .standard: "Standard (4:3)"
        }
    }

    public var ratio: Double {
        switch self {
        case .widescreen: 16.0 / 9.0
        case .standard: 4.0 / 3.0
        }
    }
}

public struct LampPresentationTheme: Codable, Equatable, Sendable {
    public var id: String
    public var backgroundColor: String
    public var foregroundColor: String
    public var accentColor: String
    public var typeface: String?

    public init(
        id: String,
        backgroundColor: String,
        foregroundColor: String,
        accentColor: String,
        typeface: String? = nil
    ) {
        self.id = id
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
        self.typeface = typeface
    }

    public static let lampDark = LampPresentationTheme(
        id: "lamp-dark",
        backgroundColor: "#111827",
        foregroundColor: "#F9FAFB",
        accentColor: "#F59E0B"
    )

    public static let parchment = LampPresentationTheme(
        id: "parchment",
        backgroundColor: "#F4EBD8",
        foregroundColor: "#29221B",
        accentColor: "#8B4513"
    )
}

public enum LampPresentationSlideLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case title
    case titleAndBody = "title-and-body"
    case scripture
    case quotation
    case twoColumn = "two-column"
    case image
    case closing
    case blank

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .titleAndBody: "Title & Body"
        case .scripture: "Scripture"
        case .quotation: "Quotation"
        case .twoColumn: "Two Columns"
        case .image: "Image"
        case .closing: "Closing"
        case .blank: "Blank"
        }
    }
}

public struct LampPresentationSlide: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var layout: LampPresentationSlideLayout
    public var blocks: [LampPresentationBlock]
    public var speakerNotes: String
    public var isHidden: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        layout: LampPresentationSlideLayout,
        blocks: [LampPresentationBlock] = [],
        speakerNotes: String = "",
        isHidden: Bool = false
    ) {
        self.id = id
        self.layout = layout
        self.blocks = blocks
        self.speakerNotes = speakerNotes
        self.isHidden = isHidden
    }

    public var displayTitle: String {
        blocks.first { $0.kind == .title }?.text
            ?? blocks.first { !$0.text.isEmpty }?.text
            ?? "Untitled Slide"
    }
}

public enum LampPresentationBlockKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case title
    case subtitle
    case body
    case scripture
    case quotation
    case citation
    case image
    case caption

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }
}

public enum LampPresentationListStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case unordered
    case ordered

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unordered: "Bullets"
        case .ordered: "Numbers"
        }
    }
}

public struct LampPresentationScriptureReference: Codable, Equatable, Sendable {
    public var translationID: String
    public var bookNumber: Int
    public var chapterNumber: Int
    public var startVerse: Int
    public var endVerse: Int

    public init(
        translationID: String,
        bookNumber: Int,
        chapterNumber: Int,
        startVerse: Int,
        endVerse: Int? = nil
    ) {
        self.translationID = translationID
        self.bookNumber = bookNumber
        self.chapterNumber = chapterNumber
        self.startVerse = startVerse
        self.endVerse = endVerse ?? startVerse
    }
}

public struct LampPresentationBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: LampPresentationBlockKind
    public var text: String
    public var assetPath: String?
    public var altText: String?
    public var listStyle: LampPresentationListStyle?
    public var scriptureReference: LampPresentationScriptureReference?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: LampPresentationBlockKind,
        text: String = "",
        assetPath: String? = nil,
        altText: String? = nil,
        listStyle: LampPresentationListStyle? = nil,
        scriptureReference: LampPresentationScriptureReference? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.assetPath = assetPath
        self.altText = altText
        self.listStyle = listStyle
        self.scriptureReference = scriptureReference
    }
}

public struct LampPresentationDeckIssue: Codable, Equatable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var path: String
    public var message: String

    public var id: String { "\(severity.rawValue):\(path):\(message)" }

    public init(severity: Severity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public enum LampPresentationDeckValidator {
    public static func validate(_ deck: LampPresentationDeck) -> [LampPresentationDeckIssue] {
        var issues: [LampPresentationDeckIssue] = []
        func issue(
            _ severity: LampPresentationDeckIssue.Severity,
            _ path: String,
            _ message: String
        ) {
            issues.append(.init(severity: severity, path: path, message: message))
        }

        if deck.schemaVersion != LampPresentationDeck.currentSchemaVersion {
            issue(
                .error,
                "schemaVersion",
                "Expected schema version \(LampPresentationDeck.currentSchemaVersion)."
            )
        }
        if deck.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "id", "A deck ID is required.")
        }
        if deck.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "title", "A deck title is required.")
        }
        if deck.slides.isEmpty {
            issue(.error, "slides", "A deck must contain at least one slide.")
        }
        if let source = deck.source,
           source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "source.id", "A linked source must have an ID.")
        }
        if deck.theme.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "theme.id", "A theme ID is required.")
        }
        if let typeface = deck.theme.typeface,
           typeface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(.error, "theme.typeface", "A typeface must name a font family or system style.")
        }
        for (key, value) in [
            ("theme.backgroundColor", deck.theme.backgroundColor),
            ("theme.foregroundColor", deck.theme.foregroundColor),
            ("theme.accentColor", deck.theme.accentColor),
        ] where !isHexColor(value) {
            issue(.error, key, "Use a six-digit hexadecimal colour such as #111827.")
        }

        let slideIDs = deck.slides.map(\.id)
        for duplicate in duplicates(in: slideIDs) {
            issue(.error, "slides", "Slide ID '\(duplicate)' is duplicated.")
        }

        for (slideIndex, slide) in deck.slides.enumerated() {
            let slidePath = "slides[\(slideIndex)]"
            if slide.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issue(.error, "\(slidePath).id", "A slide ID is required.")
            }
            if slide.layout != .blank && slide.blocks.isEmpty {
                issue(.error, "\(slidePath).blocks", "This layout needs at least one content block.")
            }
            if slide.speakerNotes.count > 5_000 {
                issue(.warning, "\(slidePath).speakerNotes", "Speaker notes exceed 5,000 characters.")
            }

            let blockIDs = slide.blocks.map(\.id)
            for duplicate in duplicates(in: blockIDs) {
                issue(.error, "\(slidePath).blocks", "Block ID '\(duplicate)' is duplicated.")
            }
            for (blockIndex, block) in slide.blocks.enumerated() {
                let blockPath = "\(slidePath).blocks[\(blockIndex)]"
                if block.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issue(.error, "\(blockPath).id", "A content block ID is required.")
                }
                if block.kind == .image {
                    if block.assetPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        issue(.error, "\(blockPath).assetPath", "An image block needs an asset path.")
                    }
                    if block.altText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        issue(.warning, "\(blockPath).altText", "Describe the image for accessibility.")
                    }
                } else if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issue(.error, "\(blockPath).text", "This content block cannot be empty.")
                }
                if block.listStyle != nil && block.kind != .body {
                    issue(.error, "\(blockPath).listStyle", "List formatting is supported on body content.")
                }
                if let reference = block.scriptureReference {
                    if block.kind != .scripture {
                        issue(
                            .error,
                            "\(blockPath).scriptureReference",
                            "A scripture reference is supported on scripture content."
                        )
                    }
                    if reference.translationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        issue(.error, "\(blockPath).scriptureReference.translationID", "A translation ID is required.")
                    }
                    if reference.bookNumber < 1 {
                        issue(.error, "\(blockPath).scriptureReference.bookNumber", "A book number is required.")
                    }
                    if reference.chapterNumber < 1 {
                        issue(.error, "\(blockPath).scriptureReference.chapterNumber", "A chapter number is required.")
                    }
                    if reference.startVerse < 1 || reference.endVerse < reference.startVerse {
                        issue(
                            .error,
                            "\(blockPath).scriptureReference",
                            "Use a positive verse range in ascending order."
                        )
                    }
                }
                if block.kind == .title && block.text.count > 90 {
                    issue(.warning, "\(blockPath).text", "This title may be too long for a slide.")
                }
                if block.kind == .body && block.text.count > 700 {
                    issue(.warning, "\(blockPath).text", "This body may be too dense for a slide.")
                }
            }
        }
        return issues
    }

    public static func errors(in deck: LampPresentationDeck) -> [LampPresentationDeckIssue] {
        validate(deck).filter { $0.severity == .error }
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(
            of: "^#[0-9A-Fa-f]{6}$",
            options: .regularExpression
        ) != nil
    }

    private static func duplicates(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }
}

public struct LampPresentationDeckStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var decksDirectoryURL: URL {
        rootURL.appendingPathComponent("Presentations", isDirectory: true)
    }

    public func decks() throws -> [LampPresentationDeck] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: decksDirectoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: decksDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "lampdeck" }
        .compactMap { try? decode(Data(contentsOf: $0)) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func deck(id: String) throws -> LampPresentationDeck? {
        let url = deckURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    @discardableResult
    public func save(_ deck: LampPresentationDeck) throws -> URL {
        let errors = LampPresentationDeckValidator.errors(in: deck)
        guard errors.isEmpty else {
            throw LampPresentationDeckStoreError.invalidDeck(errors)
        }
        try FileManager.default.createDirectory(
            at: decksDirectoryURL,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(deck)
        let destination = deckURL(for: deck.id)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    public func delete(id: String) throws {
        let url = deckURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func decode(_ data: Data) throws -> LampPresentationDeck {
        let deck = try Self.decoder.decode(LampPresentationDeck.self, from: data)
        let errors = LampPresentationDeckValidator.errors(in: deck)
        guard errors.isEmpty else {
            throw LampPresentationDeckStoreError.invalidDeck(errors)
        }
        return deck
    }

    public func encoded(_ deck: LampPresentationDeck) throws -> Data {
        let errors = LampPresentationDeckValidator.errors(in: deck)
        guard errors.isEmpty else {
            throw LampPresentationDeckStoreError.invalidDeck(errors)
        }
        return try Self.encoder.encode(deck)
    }

    private func deckURL(for id: String) -> URL {
        decksDirectoryURL
            .appendingPathComponent(storageKey(for: id))
            .appendingPathExtension("lampdeck")
    }

    private func storageKey(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let readable = id.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(readable.prefix(96))
        return result.isEmpty ? "deck" : result
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

public enum LampPresentationDeckStoreError: LocalizedError, Equatable {
    case invalidDeck([LampPresentationDeckIssue])

    public var errorDescription: String? {
        switch self {
        case .invalidDeck(let issues):
            let details = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "The presentation deck is invalid.\n\(details)"
        }
    }
}
