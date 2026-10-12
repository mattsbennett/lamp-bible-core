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
    /// Where each slide's speaker notes come from. Absent means `authored`.
    public var speakerNotesSource: LampPresentationSpeakerNotesSource?

    public init(
        schemaVersion: Int = LampPresentationDeck.currentSchemaVersion,
        id: String = UUID().uuidString.lowercased(),
        title: String,
        source: LampPresentationSource? = nil,
        aspectRatio: LampPresentationAspectRatio = .widescreen,
        theme: LampPresentationTheme = .lampDark,
        slides: [LampPresentationSlide],
        speakerNotesSource: LampPresentationSpeakerNotesSource? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.source = source
        self.aspectRatio = aspectRatio
        self.theme = theme
        self.slides = slides
        self.speakerNotesSource = speakerNotesSource
    }

    /// Whether this deck's notes are derived from the writing it is linked to.
    public var followsManuscript: Bool { speakerNotesSource == .manuscript }

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

/// Where a deck's speaker notes come from.
public enum LampPresentationSpeakerNotesSource: String, Codable, CaseIterable, Sendable {
    /// Written on each slide and left alone. The default when absent.
    case authored
    /// Derived from the writing the deck is linked to, split slide by slide at
    /// each slide's `notesAnchor`, and re-derived whenever the prose changes.
    case manuscript
}

/// Whether a block's words are checked against the manuscript.
public enum LampPresentationManuscriptCheck: String, Codable, CaseIterable, Sendable {
    case skip
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
    /// The opening words of the passage spoken over this slide, used when the
    /// deck's notes follow a manuscript. A slide without one stays silent, and
    /// the passage in progress stays with the previous anchored slide — which
    /// is how a title slide carries no notes.
    public var notesAnchor: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        layout: LampPresentationSlideLayout,
        blocks: [LampPresentationBlock] = [],
        speakerNotes: String = "",
        isHidden: Bool = false,
        notesAnchor: String? = nil
    ) {
        self.id = id
        self.layout = layout
        self.blocks = blocks
        self.notesAnchor = notesAnchor
        self.speakerNotes = speakerNotes
        self.isHidden = isHidden
    }

    /// A one-line label for this slide in an editor's list, a viewer's grid, or
    /// a remote's slide chooser.
    ///
    /// Plenty of slides carry no title block — scripture and quotation slides
    /// usually do not — so rather than spilling a whole passage into a label,
    /// prefer the short blocks that already name the slide, and only shorten
    /// body text when nothing better exists.
    public var displayTitle: String {
        if let title = text(of: .title) { return title }
        if let citation = text(of: .citation) { return citation }
        if let subtitle = text(of: .subtitle) { return subtitle }
        if let described = blocks.lazy.compactMap(Self.label(for:)).first {
            return Self.shortened(described)
        }
        return layout.displayName
    }

    private func text(of kind: LampPresentationBlockKind) -> String? {
        blocks.lazy
            .filter { $0.kind == kind }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// What a block contributes to a label. An image has no text, but its
    /// description names it better than the layout would.
    private static func label(for block: LampPresentationBlock) -> String? {
        let candidate = block.kind == .image
            ? (block.altText ?? "")
            : block.text
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line, cut at a word boundary. Lists and multi-line bodies collapse
    /// to a single line first so a label never carries a newline into a layout
    /// that cannot show one.
    private static func shortened(_ value: String, limit: Int = 48) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let clipped = collapsed.prefix(limit)
        let cut = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
        let trimmed = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? String(clipped) : trimmed) + "…"
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
    /// Opts this block out of the check that its words still appear in the
    /// manuscript, for a slide that deliberately shows fuller text than the
    /// prose quotes.
    public var manuscriptCheck: LampPresentationManuscriptCheck?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: LampPresentationBlockKind,
        text: String = "",
        assetPath: String? = nil,
        altText: String? = nil,
        listStyle: LampPresentationListStyle? = nil,
        scriptureReference: LampPresentationScriptureReference? = nil,
        manuscriptCheck: LampPresentationManuscriptCheck? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.assetPath = assetPath
        self.altText = altText
        self.listStyle = listStyle
        self.scriptureReference = scriptureReference
        self.manuscriptCheck = manuscriptCheck
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

        // A custom theme can pass every format check and still be unreadable
        // from the back of a room.
        for (key, value, floor, role) in [
            ("theme.foregroundColor", deck.theme.foregroundColor, 4.5, "Body text"),
            ("theme.accentColor", deck.theme.accentColor, 3.0, "Accent text"),
        ] {
            guard let ratio = contrastRatio(value, deck.theme.backgroundColor) else { continue }
            if ratio < floor {
                issue(
                    .warning,
                    key,
                    "\(role) contrasts with the background at only "
                        + "\(formattedRatio(ratio)):1; aim for \(formattedRatio(floor)):1 or more."
                )
            }
        }

        if deck.followsManuscript {
            if let kind = deck.source?.kind, kind != .devotional, kind != .writing {
                issue(
                    .warning,
                    "speakerNotesSource",
                    "Notes can only follow a devotional or writing source, and this deck's "
                        + "is \(kind.rawValue). Its notes will stay as written."
                )
            } else if deck.source == nil {
                issue(
                    .warning,
                    "speakerNotesSource",
                    "Notes follow the manuscript but this deck is linked to no writing."
                )
            }
            if deck.slides.allSatisfy({ ($0.notesAnchor ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty }) {
                issue(
                    .warning,
                    "slides",
                    "Notes follow the manuscript but no slide says where its passage "
                        + "begins. Give each spoken slide a notesAnchor."
                )
            }
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

            // Blocks a layout will never draw. The deck is still valid — an
            // older deck should not stop opening — but the author has said
            // something the slide cannot show, and silence here is what sent
            // deck authors reading the renderer to find out.
            let plan = slide.plan
            for ignored in plan.ignored {
                let index = slide.blocks.firstIndex(of: ignored).map(String.init) ?? "?"
                issue(
                    .warning,
                    "\(slidePath).blocks[\(index)]",
                    "A \(slide.layout.rawValue) slide does not draw \(ignored.kind.rawValue) "
                        + "content\(ignoredHint(for: ignored, layout: slide.layout)). "
                        + "Move it to another slide or change the layout."
                )
            }

            // Text scales down to 45% before it is clipped, so an over-full
            // slide passes every other check and simply becomes unreadable.
            if let crowding = crowdingMessage(for: plan, layout: slide.layout) {
                issue(.warning, "\(slidePath).blocks", crowding)
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
                    } else if let assetPath = block.assetPath,
                              !isSafeAssetPath(assetPath) {
                        // Decks travel between machines, so a path that climbs
                        // out of the presentations directory is refused here
                        // rather than at every reader.
                        issue(
                            .error,
                            "\(blockPath).assetPath",
                            "Use a relative path inside the presentation folder, such as Assets/photo.jpg."
                        )
                    }
                    if block.altText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        issue(.warning, "\(blockPath).altText", "Describe the image for accessibility.")
                    }
                } else if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issue(.error, "\(blockPath).text", "This content block cannot be empty.")
                }
                if block.manuscriptCheck != nil {
                    let checkable = block.kind == .quotation || block.kind == .scripture
                    if !checkable {
                        issue(
                            .warning,
                            "\(blockPath).manuscriptCheck",
                            "Only quotation and scripture content is checked against the "
                                + "manuscript, so this has no effect."
                        )
                    }
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

    /// Validates a deck and additionally checks that every image it names is
    /// really there, which the pure format check cannot know.
    ///
    /// `assetExists` is asked for each safe `assetPath`, relative to the
    /// presentation folder. A named file that is absent renders as a
    /// placeholder on every platform, so it is reported rather than fatal.
    public static func validate(
        _ deck: LampPresentationDeck,
        assetExists: (String) -> Bool
    ) -> [LampPresentationDeckIssue] {
        var issues = validate(deck)
        for (slideIndex, slide) in deck.slides.enumerated() {
            for (blockIndex, block) in slide.blocks.enumerated() {
                guard block.kind == .image,
                      let assetPath = block.assetPath,
                      isSafeAssetPath(assetPath),
                      !assetExists(assetPath)
                else { continue }
                issues.append(.init(
                    severity: .warning,
                    path: "slides[\(slideIndex)].blocks[\(blockIndex)].assetPath",
                    message: "No file at '\(assetPath)'. The slide renders a placeholder "
                        + "until the image is delivered beside the deck."
                ))
            }
        }
        return issues
    }

    public static func errors(in deck: LampPresentationDeck) -> [LampPresentationDeckIssue] {
        validate(deck).filter { $0.severity == .error }
    }

    /// A relative path that stays inside the presentations directory.
    ///
    /// Rejects absolute paths, Windows-style drive and UNC paths, any `..`
    /// component, and paths with an empty or hidden component, so a deck can
    /// only ever name a file the library actually owns.
    public static func isSafeAssetPath(_ assetPath: String) -> Bool {
        let value = assetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 1_024 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.hasPrefix("\\") else { return false }
        guard !value.contains("\\"), !value.contains(":") else { return false }
        guard value.unicodeScalars.allSatisfy({ $0 != "\0" }) else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
        }
    }

    /// Why a block went undrawn, when the reason is worth naming.
    private static func ignoredHint(
        for block: LampPresentationBlock,
        layout: LampPresentationSlideLayout
    ) -> String {
        switch (layout, block.kind) {
        case (.scripture, .title), (.quotation, .title):
            return " — these layouts are set without a heading"
        case (.title, _), (.closing, _):
            return " beyond its heading and one line beneath it"
        case (.twoColumn, .body):
            return " beyond its first two columns"
        case (_, .caption):
            return " without an image to caption"
        case (_, .image):
            return " more than once"
        default:
            return ""
        }
    }

    /// Whether a slide is carrying more than it can show at a readable size.
    ///
    /// This is an estimate from character counts, not a measurement: the
    /// renderer is the only thing that can say for certain, and it is not
    /// available here. The thresholds are deliberately generous so that only a
    /// slide well past full is named.
    private static func crowdingMessage(
        for plan: LampPresentationSlidePlan,
        layout: LampPresentationSlideLayout
    ) -> String? {
        let prose = (plan.prose + plan.columns + plan.citations)
            .reduce(0) { $0 + $1.text.count }
        guard prose > 0 else { return nil }
        // A picture takes about half the slide, so the prose beside it has
        // roughly half the room.
        let ceiling = plan.image == nil ? 900 : 450
        guard prose > ceiling else { return nil }
        let shape = plan.image == nil
            ? "this slide"
            : "the half of this slide left by its image"
        return "About \(prose) characters of text for \(shape). Text shrinks to fit "
            + "before it is clipped, so split this across slides to keep it readable."
    }

    /// WCAG relative-luminance contrast between two deck colours, or nil when
    /// either is not a colour this format accepts.
    static func contrastRatio(_ first: String, _ second: String) -> Double? {
        guard let a = relativeLuminance(first), let b = relativeLuminance(second) else {
            return nil
        }
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ value: String) -> Double? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt64(hex, radix: 16) else { return nil }
        let channels = [
            Double((rgb >> 16) & 0xff) / 255,
            Double((rgb >> 8) & 0xff) / 255,
            Double(rgb & 0xff) / 255,
        ].map { channel -> Double in
            channel <= 0.039_28
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private static func formattedRatio(_ value: Double) -> String {
        String(format: "%.1f", value)
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
    /// The directory decks live in, under a library root and, with the
    /// portable workspaces prefix, inside a backup or sync archive.
    public static let directoryName = "Presentations"

    /// Images referenced by `assetPath` live here, beside the decks.
    public static let assetsDirectoryName = "Assets"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var decksDirectoryURL: URL {
        rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var assetsDirectoryURL: URL {
        decksDirectoryURL.appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    /// Resolves a block's `assetPath` against this library.
    ///
    /// Decks arrive over sync from other machines, so a path is only ever
    /// resolved inside the presentations directory: anything absolute, or that
    /// climbs out with `..`, resolves to nil rather than reading a file the
    /// deck has no business naming. `LampPresentationDeckValidator` rejects
    /// such paths too, but a reader should not depend on having validated.
    public func assetURL(forAssetPath assetPath: String) -> URL? {
        guard LampPresentationDeckValidator.isSafeAssetPath(assetPath) else { return nil }
        let resolved = decksDirectoryURL
            .appendingPathComponent(assetPath)
            .standardizedFileURL
        let base = decksDirectoryURL.standardizedFileURL.path
        guard resolved.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return resolved
    }

    public func assetURL(for block: LampPresentationBlock) -> URL? {
        guard let assetPath = block.assetPath else { return nil }
        return assetURL(forAssetPath: assetPath)
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
        let url = deckFileURL(for: id)
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
        let destination = deckFileURL(for: deck.id)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    /// Copies the images a deck names from a folder delivered beside it into
    /// this library's asset directory, and reports what arrived.
    ///
    /// An agent writing a deck cannot put files in the library — it is told not
    /// to, and the path is not its to know — so it leaves them in an `Assets`
    /// folder next to the deck and Lamp brings them in. Only paths the deck
    /// actually references are copied, and only safe ones, so the folder cannot
    /// be used to write anywhere else.
    @discardableResult
    public func importAssets(
        from directory: URL,
        referencedBy deck: LampPresentationDeck,
        fileManager: FileManager = .default
    ) throws -> (imported: [String], missing: [String]) {
        let referenced = Set(
            deck.slides
                .flatMap(\.blocks)
                .compactMap(\.assetPath)
                .filter(LampPresentationDeckValidator.isSafeAssetPath)
        ).sorted()
        guard !referenced.isEmpty else { return ([], []) }

        var imported: [String] = []
        var missing: [String] = []
        let base = directory.standardizedFileURL
        for assetPath in referenced {
            let source = base.appendingPathComponent(assetPath).standardizedFileURL
            let root = base.path.hasSuffix("/") ? base.path : base.path + "/"
            // `isSafeAssetPath` already refuses `..`, but a symbolic link in the
            // delivered folder could still point outside it.
            let isSymbolicLink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true
            guard source.path.hasPrefix(root),
                  !isSymbolicLink,
                  fileManager.fileExists(atPath: source.path),
                  let destination = assetURL(forAssetPath: assetPath)
            else {
                if assetURL(forAssetPath: assetPath).map({
                    !fileManager.fileExists(atPath: $0.path)
                }) ?? true {
                    missing.append(assetPath)
                }
                continue
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                // Same name, new bytes: the deck's own reference is the record
                // of which image belongs to it, so the newer file wins.
                guard (try? Data(contentsOf: destination)) != (try? Data(contentsOf: source)) else {
                    imported.append(assetPath)
                    continue
                }
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            imported.append(assetPath)
        }
        return (imported, missing)
    }

    public func delete(id: String) throws {
        let url = deckFileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func decode(_ data: Data) throws -> LampPresentationDeck {
        try Self.decode(data)
    }

    /// Encodes a deck without refusing one that has validation errors, for a
    /// tool whose job is to write a deck back while it is still being fixed.
    /// Everything that stores a deck uses `encoded`, which validates first.
    public static func encodedUnvalidated(_ deck: LampPresentationDeck) throws -> Data {
        try encoder.encode(deck)
    }

    /// Decodes a deck without refusing one that has validation errors.
    ///
    /// Everything that stores or presents a deck goes through `decode`, which
    /// refuses a malformed one. A tool that exists to show an author what they
    /// have written needs the opposite: a deck mid-repair is exactly the one
    /// worth looking at, and its problems are reported rather than hidden.
    public static func decodeUnvalidated(_ data: Data) throws -> LampPresentationDeck {
        try decoder.decode(LampPresentationDeck.self, from: data)
    }

    /// Decoding and validation need no library root, so readers that only
    /// inspect deck bytes — a sync pull, a file import — use this directly.
    public static func decode(_ data: Data) throws -> LampPresentationDeck {
        let deck = try decoder.decode(LampPresentationDeck.self, from: data)
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

    /// The one file this store uses for a deck, so a caller that needs the
    /// file itself — to stamp a synced modification date, say — does not have
    /// to reproduce the naming rule.
    public func deckFileURL(for id: String) -> URL {
        decksDirectoryURL
            .appendingPathComponent(storageKey(for: id))
            .appendingPathExtension(LampPresentationDeckPortableLayout.deckExtension)
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
