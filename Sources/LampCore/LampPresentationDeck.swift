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
    /// How one slide gives way to the next while presenting. Absent means a
    /// dissolve.
    public var transition: LampPresentationTransition?

    public init(
        schemaVersion: Int = LampPresentationDeck.currentSchemaVersion,
        id: String = UUID().uuidString.lowercased(),
        title: String,
        source: LampPresentationSource? = nil,
        aspectRatio: LampPresentationAspectRatio = .widescreen,
        theme: LampPresentationTheme = .lampDark,
        slides: [LampPresentationSlide],
        speakerNotesSource: LampPresentationSpeakerNotesSource? = nil,
        transition: LampPresentationTransition? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.source = source
        self.aspectRatio = aspectRatio
        self.theme = theme
        self.slides = slides
        self.speakerNotesSource = speakerNotesSource
        self.transition = transition
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

/// Whether Lamp sets a block's text, or draws it exactly as stored.
public enum LampPresentationTypography: String, Codable, CaseIterable, Sendable {
    case verbatim
}

/// Whether a block's words are checked against the manuscript.
public enum LampPresentationManuscriptCheck: String, Codable, CaseIterable, Sendable {
    case skip
}

/// Where an image is drawn. Absent means beside the prose, as images always
/// have been.
public enum LampPresentationImagePlacement: String, Codable, CaseIterable, Sendable {
    /// Fills the whole slide behind everything else on it.
    case background
}

extension LampPresentationDeck {
    /// The writing this deck was built from, if any. The format names the
    /// same thing two ways, `devotional` and `writing`: a check for one alone
    /// counts the other's decks as standalone.
    public var writingID: String? {
        guard let source, source.kind == .devotional || source.kind == .writing else { return nil }
        return source.id
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
    /// The deck's typeface: its body text, and its headings too unless
    /// `headingTypeface` names another.
    public var typeface: String?
    /// The typeface of titles, subtitles and column headings, when it differs
    /// from the body's. Absent means headings share `typeface`.
    public var headingTypeface: String?
    /// Colours emphasised words can be drawn in besides the accent, by name:
    /// one for each idea, person or side a deck sets apart. A block's
    /// `emphasis` names one; emphasis that names none takes the accent.
    public var highlights: [String: String]?

    public init(
        id: String,
        backgroundColor: String,
        foregroundColor: String,
        accentColor: String,
        typeface: String? = nil,
        headingTypeface: String? = nil,
        highlights: [String: String]? = nil
    ) {
        self.id = id
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
        self.typeface = typeface
        self.headingTypeface = headingTypeface
        self.highlights = highlights
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
        case .twoColumn: "Columns"
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
    /// Whether the slide's content arrives a part at a time while it is
    /// presented. Absent means all at once. See `revealPlan`.
    public var reveal: LampPresentationReveal?
    /// Whether the slide's emphasised words light up on a step of their own,
    /// after the rest of the slide has arrived. Absent means they are lit
    /// from the start.
    public var revealsEmphasis: Bool?
    /// This slide's own ground, as `#RRGGBB`, in place of the theme's: for a
    /// section break, or a slide set apart. The words take whichever of the
    /// theme's two ground colours reads on it; see
    /// `LampPresentationTheme.ink(on:)`. Absent means the theme's.
    public var backgroundColor: String?
    /// A form of the layout: a statement or a word on a title slide, a
    /// comparison on columns; see `LampPresentationSlideVariant`. Absent
    /// means the plain layout.
    public var variant: LampPresentationSlideVariant?

    public init(
        id: String = UUID().uuidString.lowercased(),
        layout: LampPresentationSlideLayout,
        blocks: [LampPresentationBlock] = [],
        speakerNotes: String = "",
        isHidden: Bool = false,
        notesAnchor: String? = nil,
        reveal: LampPresentationReveal? = nil,
        revealsEmphasis: Bool? = nil,
        backgroundColor: String? = nil,
        variant: LampPresentationSlideVariant? = nil
    ) {
        self.id = id
        self.layout = layout
        self.blocks = blocks
        self.notesAnchor = notesAnchor
        self.reveal = reveal
        self.revealsEmphasis = revealsEmphasis
        self.backgroundColor = backgroundColor
        self.variant = variant
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
    /// description names it better than the layout would, and an untitled
    /// chart is named by what it charts.
    private static func label(for block: LampPresentationBlock) -> String? {
        let candidate = block.kind == .image
            ? (block.altText ?? "")
            : block.kind == .chart && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (block.chart.map { "Chart of \($0.source.strongs)" } ?? "")
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
    case chart

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
    /// Draws this block's text exactly as stored, without the quotation marks
    /// and ellipses Lamp would otherwise add. For poetry, an excerpt opening
    /// with a lowercase name, or a deck that wants bare scripture.
    public var typography: LampPresentationTypography?
    /// Puts an image behind the slide instead of beside its prose.
    ///
    /// Lamp chooses the colour of the words over it, and darkens or lightens
    /// the picture behind them only as far as they need to be read.
    public var placement: LampPresentationImagePlacement?
    /// Words in this block drawn bold and in colour. The text itself is left
    /// as it is, so a check against a translation or a manuscript still
    /// reads the words alone.
    public var emphasis: [LampPresentationEmphasis]?
    /// What a chart block charts, and the values Lamp worked out for it.
    public var chart: LampPresentationChart?
    /// Where a picture's subject is, so a crop keeps it in view; see
    /// `LampPresentationFocus`. Absent means the centre.
    public var focus: LampPresentationFocus?
    /// A picture drawn in the theme's colours; see
    /// `LampPresentationImageTint`. Absent means as it is.
    public var tint: LampPresentationImageTint?
    /// A body block's lines drawn as a figure: a timeline, or a passage's
    /// structure; see `LampPresentationFigure`. Absent means drawn as text.
    public var figure: LampPresentationFigure?
    /// A timeline shown whole, then a few events at a time; see
    /// `LampPresentationTimelineZoom`. Absent means drawn whole.
    public var zoom: LampPresentationTimelineZoom?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: LampPresentationBlockKind,
        text: String = "",
        assetPath: String? = nil,
        altText: String? = nil,
        listStyle: LampPresentationListStyle? = nil,
        scriptureReference: LampPresentationScriptureReference? = nil,
        manuscriptCheck: LampPresentationManuscriptCheck? = nil,
        typography: LampPresentationTypography? = nil,
        placement: LampPresentationImagePlacement? = nil,
        emphasis: [LampPresentationEmphasis]? = nil,
        chart: LampPresentationChart? = nil,
        focus: LampPresentationFocus? = nil,
        tint: LampPresentationImageTint? = nil,
        figure: LampPresentationFigure? = nil,
        zoom: LampPresentationTimelineZoom? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.assetPath = assetPath
        self.altText = altText
        self.listStyle = listStyle
        self.scriptureReference = scriptureReference
        self.manuscriptCheck = manuscriptCheck
        self.typography = typography
        self.placement = placement
        self.emphasis = emphasis
        self.chart = chart
        self.focus = focus
        self.tint = tint
        self.figure = figure
        self.zoom = zoom
    }

    /// An image that fills the slide behind everything else.
    public var isBackground: Bool { kind == .image && placement == .background }
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
        if let typeface = deck.theme.headingTypeface,
           typeface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue(
                .error,
                "theme.headingTypeface",
                "A heading typeface must name a font family or system style; omit it to use the body's."
            )
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

        // Held to the accent's 3:1, WCAG's level for large and bold text,
        // which emphasised words on a slide always are; 4.5:1 is for body
        // text at reading size.
        for (name, value) in (deck.theme.highlights ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = "theme.highlights.\(name)"
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issue(.error, "theme.highlights", "A highlight needs a name for emphasis to give.")
            } else if !isHexColor(value) {
                issue(.error, path, "Use a six-digit hexadecimal colour such as #111827.")
            } else if let ratio = contrastRatio(value, deck.theme.backgroundColor), ratio < 3.0 {
                issue(
                    .warning,
                    path,
                    "Highlighted words contrast with the background at only "
                        + "\(formattedRatio(ratio)):1; aim for 3.0:1 or more."
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

            // Several passages sharing one attribution read as one passage with
            // a list of sources under it.
            // Only quoted matter counts. A slide with a bulleted list, one
            // quotation and its citation has one thing quoted, not two.
            let quoted = plan.quoteGroups
                .map { group in
                    group.quotations.filter { $0.kind == .quotation || $0.kind == .scripture }
                }
                .filter { !$0.isEmpty }
            if quoted.count == 1,
               let only = quoted.first,
               only.count > 1,
               plan.quoteGroups.contains(where: { $0.citation != nil }),
               slide.layout == .scripture || slide.layout == .quotation
                   || slide.layout == .titleAndBody || slide.layout == .title
                   || slide.layout == .closing {
                issue(
                    .warning,
                    "\(slidePath).blocks",
                    "\(only.count) quotations share one citation. Give each "
                        + "its own, directly after it, or join passages from the same "
                        + "place into one quotation with an ellipsis."
                )
            }

            // Text scales down to 45% before it is clipped, so an over-full
            // slide passes every other check and simply becomes unreadable.
            if let crowding = crowdingMessage(for: plan, layout: slide.layout) {
                issue(.warning, "\(slidePath).blocks", crowding)
            }

            // A variant on a layout that has no such form draws the plain
            // layout, which the author should know.
            if let variant = slide.variant, variant != .none, !variant.layouts.contains(slide.layout) {
                let names = variant.layouts.map(\.rawValue).sorted().joined(separator: " or ")
                issue(
                    .warning,
                    "\(slidePath).variant",
                    "A \(variant.rawValue) is a form of a \(names) slide; this \(slide.layout.rawValue) slide is drawn plain."
                )
            }
            if slide.drawnVariant == .comparison, plan.columnGroups.count < 2 {
                issue(
                    .warning,
                    "\(slidePath).variant",
                    "A comparison marks the words in which columns differ, and this slide has fewer than two."
                )
            }

            // A slide's own ground is held to the theme's own floor for words,
            // since the words can only take one of the theme's two grounds.
            if let ground = slide.backgroundColor {
                if !isHexColor(ground) {
                    issue(.error, "\(slidePath).backgroundColor", "Use a six-digit hexadecimal colour such as #111827.")
                } else if let ink = deck.theme.ink(on: ground), ink.contrast < 4.5 {
                    issue(
                        .warning,
                        "\(slidePath).backgroundColor",
                        "Neither of the theme's colours reads well on this background: the words "
                            + "contrast at only \(formattedRatio(ink.contrast)):1; aim for 4.5:1 or more."
                    )
                }
            }

            // A reveal with nothing to bring in a part at a time leaves the
            // slide arriving whole; said, so no one rehearses clicks that
            // will not come.
            let reveal = slide.revealPlan
            if slide.reveal == .stepwise, reveal.units.isEmpty {
                issue(
                    .warning,
                    "\(slidePath).reveal",
                    slide.layout == .image
                        ? "An image slide arrives whole. Reveal brings in passages, list items and columns."
                        : "This slide has only one part to bring in, so it arrives whole. Reveal brings in "
                            + "each passage, list item or column in turn."
                )
            }
            if slide.revealsEmphasis == true, !reveal.emphasisStep {
                issue(
                    .warning,
                    "\(slidePath).revealsEmphasis",
                    "No words on this slide are emphasised, or only a zoomed timeline's, which are lit "
                        + "throughout, so there is nothing to light up."
                )
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
                if let focus = block.focus {
                    if !focus.isValid {
                        issue(.error, "\(blockPath).focus", "A focus's x and y each run from 0 to 1.")
                    } else if block.kind != .image {
                        issue(.warning, "\(blockPath).focus", "Only a picture has a focus.")
                    } else if !block.isBackground {
                        issue(
                            .warning,
                            "\(blockPath).focus",
                            "A focus moves a picture behind the slide, which is cropped to fill it. "
                                + "A picture beside the words is shown whole."
                        )
                    }
                }
                if let figure = block.figure, figure != .none {
                    figureIssues(figure, block: block, path: blockPath).forEach { issue($0.0, $0.1, $0.2) }
                    if block.kind == .body, !LampPresentationFigure.isDrawn(on: slide.layout) {
                        issue(
                            .warning,
                            "\(blockPath).figure",
                            "A \(slide.layout.rawValue) slide draws a figure's lines as a list; "
                                + "a figure is drawn on title-and-body, blank, scripture and quotation slides."
                        )
                    }
                }
                if let zoom = block.zoom {
                    zoomIssues(zoom, block: block, path: blockPath).forEach { issue($0.0, $0.1, $0.2) }
                }
                if let tint = block.tint, tint != .none, block.kind != .image {
                    issue(.warning, "\(blockPath).tint", "Only a picture can be tinted.")
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
                } else if block.kind == .chart {
                    // A chart's text is an optional heading over its bars.
                    for (severity, path, message) in chartIssues(block.chart) {
                        issue(severity, "\(blockPath).\(path)", message)
                    }
                } else if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issue(.error, "\(blockPath).text", "This content block cannot be empty.")
                }
                if block.chart != nil && block.kind != .chart {
                    issue(.error, "\(blockPath).chart", "A chart is supported on chart content.")
                }
                if LampPresentationQuoteTypography.applies(to: block, layout: slide.layout),
                   hasTypedOuterQuotationMarks(block.text) {
                    issue(
                        .warning,
                        "\(blockPath).text",
                        "Lamp adds the quotation marks; remove these. Set "
                            + "\"typography\": \"verbatim\" to draw the text exactly as stored."
                    )
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
                if block.placement != nil && block.kind != .image {
                    issue(.error, "\(blockPath).placement", "Placement is supported on image content.")
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
                for (path, message) in emphasisIssues(in: block, theme: deck.theme) {
                    issue(.warning, "\(blockPath).\(path)", message)
                }
                if block.kind == .title && block.text.count > 90 {
                    issue(.warning, "\(blockPath).text", "This title may be too long for a slide.")
                }
                if block.kind == .body && block.shownTextLength(on: slide.layout) > 700 {
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

    /// What is wrong with a chart block's chart, as severity, path within the
    /// block and message.
    private static func chartIssues(
        _ chart: LampPresentationChart?
    ) -> [(LampPresentationDeckIssue.Severity, String, String)] {
        guard let chart else {
            return [(.error, "chart", "A chart block needs a chart: its source, by and measure.")]
        }
        var issues: [(LampPresentationDeckIssue.Severity, String, String)] = []
        let key = LampStrongsKey.normalized(chart.source.strongs)
        if key.isEmpty {
            issues.append((.error, "chart.source.strongs", "Name a Strong's key, such as G26."))
        } else if key.first != "H" && key.first != "G" {
            issues.append((
                .warning,
                "chart.source.strongs",
                "A bare number counts Hebrew and Greek alike. Prefix it with H or G."
            ))
        }
        if chart.by != .translation,
           chart.source.translationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append((.error, "chart.source.translationID", "A translation ID is required."))
        }
        if chart.by == .translation, let named = chart.source.translations,
           named.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append((
                .error,
                "chart.source.translations",
                "Name the translations to compare, or leave the list out to compare every tagged one."
            ))
        }
        if chart.source.translations != nil && chart.by != .translation {
            issues.append((
                .warning,
                "chart.source.translations",
                "Only a chart by translation compares translations; this one counts translationID."
            ))
        }
        if chart.source.includesOriginalLanguages && chart.by != .translation {
            issues.append((
                .warning,
                "chart.source.includesOriginalLanguages",
                "Only a chart by translation can hold the Hebrew and Greek texts back, or let them in."
            ))
        }
        if let filter = chart.source.filter {
            if filter.isEmpty {
                issues.append((
                    .warning,
                    "chart.source.filter",
                    "This filter names nothing, so every occurrence is counted."
                ))
            }
            let narrowsGrouping = switch chart.by {
            case .rendering: filter.rendering != nil
            case .form: filter.form != nil
            case .grammar: filter.grammar != nil && filter.grammar?.feature == chart.feature
            default: false
            }
            if narrowsGrouping {
                issues.append((
                    .warning,
                    "chart.source.filter",
                    "The filter keeps only one of the values this chart is grouped by, "
                        + "so it draws a single value."
                ))
            }
        }
        if chart.by == .grammar && chart.feature == nil {
            issues.append((
                .error,
                "chart.feature",
                "A chart by grammar names its feature, such as grammaticalCase or tense."
            ))
        }
        if chart.feature != nil && chart.by != .grammar {
            issues.append((.warning, "chart.feature", "A feature is read only by a chart by grammar."))
        }
        if chart.drawnStyle == .card && chart.by != .book {
            issues.append((
                .error,
                "chart.by",
                "A card draws a column for each book under the word, so it charts by book."
            ))
        }
        if chart.drawnStyle == .share && !chart.by.isPartOfWhole {
            issues.append((
                .error,
                "chart.style",
                chart.by == .translation
                    ? "Each translation counts the whole again, so they are not slices of one ring."
                    : "Companions are measured against chance, not counted, so they make no ring."
            ))
        }
        // Verses are only countable where a division holds them. A
        // rendering or a grammatical value is a count of occurrences, and
        // the verses behind it are not divided that way, so the chart would
        // silently draw occurrences under a verses label.
        if chart.measure == .verses && !chart.by.countsVerses {
            issues.append((
                .error,
                "chart.measure",
                "Only a chart by book, section or translation can count verses; "
                    + "\(chart.by.title.lowercased()) groups occurrences, which are not "
                    + "divided into verses."
            ))
        }
        // A grid shades each chapter, and a chapter holds no verse count.
        if chart.measure == .verses && chart.drawnStyle == .grid {
            issues.append((
                .error,
                "chart.measure",
                "A grid shades chapters, which hold no verse count; count occurrences "
                    + "or draw it as bars."
            ))
        }
        if chart.by == .companion && chart.measure == .perThousandWords {
            issues.append((
                .warning,
                "chart.measure",
                "A companion is measured by how many times chance it shares the key's verses, "
                    + "so the measure is not read."
            ))
        }
        if chart.headword != nil && chart.drawnStyle != .card {
            issues.append((.warning, "chart.headword", "Only a card draws a headword."))
        }
        if let figures = chart.figures {
            if chart.drawnStyle != .card {
                issues.append((.warning, "chart.figures", "Only a card prints figures."))
            }
            // A name Lamp does not know is left out rather than refused, so
            // that a deck from a newer Lamp opens; said all the same, because
            // the likelier writer of an unknown name is a typo, and a card
            // that quietly prints its usual three looks like it was obeyed.
            let unknown = figures.filter { LampStrongsCardFigure(rawValue: $0) == nil }
            if !unknown.isEmpty {
                issues.append((
                    .warning,
                    "chart.figures",
                    "\(unknown.map { "“\($0)”" }.joined(separator: ", ")) "
                        + "\(unknown.count == 1 ? "is not a figure" : "are not figures") a card prints, "
                        + "so \(unknown.count == 1 ? "it is" : "they are") left out. The figures are "
                        + LampStrongsCardFigure.allCases.map(\.rawValue).joined(separator: ", ") + "."
                ))
            }
            if figures.count > LampStrongsCardChoice.slots {
                issues.append((
                    .warning,
                    "chart.figures",
                    "A card prints \(LampStrongsCardChoice.slots) figures, "
                        + "so the rest are not drawn."
                ))
            }
        }
        if let range = chart.source.range, (try? LampReferenceParser.books(range)) == nil {
            issues.append((
                .error,
                "chart.source.range",
                "Name whole books, such as NT, Romans or Matthew-John, or leave the range out."
            ))
        }
        if chart.drawnStyle == .grid && chart.by != .book {
            issues.append((.error, "chart.by", "A grid shades each book's chapters, so it charts by book."))
        }
        if chart.drawnStyle == .share && chart.measure == .perThousandWords {
            issues.append((
                .warning,
                "chart.measure",
                "A share is of occurrences: rates per thousand words do not add up to a whole, "
                    + "so the ring counts occurrences."
            ))
        }
        if let values = chart.values {
            switch chart.drawnStyle {
            case .bars where values.count > LampPresentationChart.readableBars:
                issues.append((
                    .warning,
                    "chart.values",
                    "\(values.count) bars are hard to read from the back of a room. "
                        + "Chart by section, or narrow the range."
                ))
            case .grid where values.count > LampPresentationChart.readableGridRows:
                issues.append((
                    .warning,
                    "chart.values",
                    "A grid of \(values.count) books is too dense to read. Narrow the range."
                ))
            case .grid where chart.by == .book && values.contains { $0.chapters == nil }:
                issues.append((
                    .warning,
                    "chart.values",
                    "This grid has no chapters yet. Lamp works them out when the deck is built."
                ))
            case .share where values.count > LampPresentationChart.shareSlices:
                issues.append((
                    .warning,
                    "chart.values",
                    "A share of \(values.count) slices cannot be told apart. "
                        + "Build the deck again to gather the smallest."
                ))
            default:
                break
            }
        } else {
            issues.append((
                .warning,
                "chart.values",
                "No values yet. Lamp works them out from the library when the deck is built."
            ))
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

    /// Whether the author wrapped the whole text in quotation marks, which Lamp
    /// would then draw a second pair around.
    private static func hasTypedOuterQuotationMarks(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marks: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        guard trimmed.count >= 2,
              let first = trimmed.first, marks.contains(first),
              let last = trimmed.last, marks.contains(last)
        else { return false }
        // Marks at both ends with another between them belong to the text: two
        // speakers quoted in turn, not one quotation wrapped by hand.
        return !trimmed.dropFirst().dropLast().contains { marks.contains($0) }
    }

    /// Emphasis that will not be drawn as written, by the path of its entry
    /// within the block.
    ///
    /// Each is a warning, never an error: a deck that fails validation cannot
    /// be saved or synced, and rewording a slide in Slide Studio must not
    /// make its deck unsavable because an entry named the old words.
    private static func emphasisIssues(
        in block: LampPresentationBlock,
        theme: LampPresentationTheme
    ) -> [(path: String, message: String)] {
        guard let emphasis = block.emphasis, !emphasis.isEmpty else { return [] }
        guard block.kind != .image else {
            return [("emphasis", "Emphasis is drawn on words, and an image block has none.")]
        }
        guard block.kind != .chart else {
            return [("emphasis", "Emphasis is not drawn on a chart's heading.")]
        }
        var issues: [(path: String, message: String)] = []
        let characters = Array(block.text)
        var taken = [Bool](repeating: false, count: characters.count)
        for (index, entry) in emphasis.enumerated() {
            let path = "emphasis[\(index)]"
            guard !entry.text.isEmpty else {
                issues.append((path, "Name the words to emphasise."))
                continue
            }
            if let name = entry.highlight, theme.highlights?[name] == nil {
                issues.append((
                    path,
                    "The theme has no highlight named '\(name)', so these words take the accent colour."
                ))
            }
            let matches = entry.matches(in: characters)
            if matches.isEmpty {
                issues.append((
                    path,
                    "'\(entry.text)' is not in this block's text as whole words, so nothing is "
                        + "emphasised. Copy the words exactly as the text has them."
                ))
                continue
            }
            if let occurrence = entry.occurrence, !matches.indices.contains(occurrence - 1) {
                issues.append((
                    path,
                    occurrence < 1
                        ? "Count occurrences from 1."
                        : "'\(entry.text)' appears \(matches.count) time\(matches.count == 1 ? "" : "s") "
                            + "in this block's text, so occurrence \(occurrence) emphasises nothing."
                ))
                continue
            }
            var overlaps = false
            for match in entry.drawnMatches(in: characters) {
                if taken[match].contains(true) {
                    overlaps = true
                } else {
                    for offset in match { taken[offset] = true }
                }
            }
            if overlaps {
                issues.append((
                    path,
                    "'\(entry.text)' overlaps words an earlier entry emphasises, so it is not drawn there."
                ))
            }
        }
        return issues
    }

    /// Why a block went undrawn, when the reason is worth naming.
    /// What a figure's lines would draw badly or not at all.
    static func figureIssues(
        _ figure: LampPresentationFigure,
        block: LampPresentationBlock,
        path: String
    ) -> [(LampPresentationDeckIssue.Severity, String, String)] {
        let figurePath = "\(path).figure"
        guard block.kind == .body else {
            return [(.warning, figurePath, "Only a body block is drawn as a figure; this one is drawn as it is.")]
        }
        let lines = block.listItemRuns.map { $0.map(\.text).joined() }
        switch figure {
        case .timeline:
            var issues: [(LampPresentationDeckIssue.Severity, String, String)] = []
            if block.zoom != nil {
                if lines.count > LampPresentationTimelineZoom.mostEvents {
                    issues.append((.warning, figurePath,
                        "A timeline of \(lines.count) events is too long to show whole, even as marks along a line; "
                            + "keep a zoomed timeline to \(LampPresentationTimelineZoom.mostEvents), "
                            + "or split it across slides."))
                }
            } else if lines.count > LampPresentationFigure.mostTimelineEntries {
                issues.append((.warning, figurePath,
                    "A timeline of \(lines.count) events is too crowded to read across a slide; "
                        + "keep it to \(LampPresentationFigure.mostTimelineEntries), zoom it, "
                        + "or split it across slides."))
            }
            let undated = lines.enumerated().filter { LampPresentationFigure.timelineSplit($0.element) == nil }
            if !undated.isEmpty {
                let numbers = undated.map { String($0.offset + 1) }.joined(separator: ", ")
                issues.append((.warning, figurePath,
                    "Timeline line \(numbers) has no date: write each as a date, a spaced dash, and the event, "
                        + "such as \u{201C}c. 1000 BC \u{2014} David king in Jerusalem\u{201D}."))
            }
            return issues
        case .chiasm where lines.count < 3:
            return [(.warning, figurePath, "A chiasm needs at least three lines: a pair and its centre, or two pairs.")]
        case .parallel where lines.count % 2 == 1:
            return [(.warning, figurePath,
                "Parallel lines go in pairs, and the last line here has no partner; it is drawn on its own.")]
        default:
            return []
        }
    }

    /// What a timeline's zoom would draw differently from what it asks.
    static func zoomIssues(
        _ zoom: LampPresentationTimelineZoom,
        block: LampPresentationBlock,
        path: String
    ) -> [(LampPresentationDeckIssue.Severity, String, String)] {
        let zoomPath = "\(path).zoom"
        guard block.kind == .body, block.figure == .timeline else {
            return [(.warning, zoomPath, "Only a timeline zooms; this block is drawn without it.")]
        }
        let spans = LampPresentationTimelineZoom.spans
        var issues: [(LampPresentationDeckIssue.Severity, String, String)] = []
        if !spans.contains(zoom.span) {
            issues.append((.warning, "\(zoomPath).span",
                "A zoomed view shows \(spans.lowerBound) to \(spans.upperBound) events; "
                    + "this one is drawn showing \(min(max(zoom.span, spans.lowerBound), spans.upperBound))."))
        }
        let span = min(max(zoom.span, spans.lowerBound), spans.upperBound)
        let count = block.listItemRuns.count
        if count <= span {
            issues.append((.warning, zoomPath,
                "A view of \(span) events shows all \(count) of this timeline, so it is drawn whole without zooming."))
            return issues
        }
        for (key, value) in [("from", zoom.from), ("through", zoom.through)] {
            if let value, !(1...count).contains(value) {
                issues.append((.warning, "\(zoomPath).\(key)",
                    "The timeline's events are numbered 1 to \(count); \(value) is held to the nearer end."))
            }
        }
        if let from = zoom.from, let through = zoom.through, from > through {
            issues.append((.warning, zoomPath,
                "A zoom's from comes after its through, so only event \(min(max(from, 1), count)) is explored."))
        }
        return issues
    }

    private static func ignoredHint(
        for block: LampPresentationBlock,
        layout: LampPresentationSlideLayout
    ) -> String {
        if block.isBackground {
            return " behind it more than once"
        }
        switch (layout, block.kind) {
        case (.scripture, .title), (.quotation, .title):
            return " — these layouts are set without a heading"
        case (.title, _), (.closing, _):
            return " beyond its heading and one line beneath it"
        case (.twoColumn, .body), (.twoColumn, .subtitle),
             (.twoColumn, .scripture), (.twoColumn, .quotation):
            return " beyond its first four columns"
        case (.twoColumn, .citation):
            return " unless it directly follows the column it attributes"
        case (.twoColumn, .image), (.twoColumn, .chart):
            return " — two-column slides draw no picture or chart"
        case (_, .caption):
            return " without an image or chart to caption"
        case (_, .image), (_, .chart):
            return " — a slide draws one picture or chart"
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
            .reduce(0) { $0 + $1.shownTextLength(on: layout) }
        guard prose > 0 else { return nil }
        // A picture takes about half the slide, so the prose beside it has
        // roughly half the room. Passages under a title share the slide with
        // a heading set at its largest, which leaves them about as much.
        let underTitle = layout == .title || layout == .closing
        let ceiling = plan.image == nil && !underTitle ? 900 : 450
        guard prose > ceiling else { return nil }
        let shape = underTitle
            ? "the passages under this slide's title"
            : plan.image == nil
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
        LampPresentationColor(hex: value)?.luminance
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
        let base = decksDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.resolvingSymlinksInPath().path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        else { return nil }
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
                  source.resolvingSymlinksInPath().path.hasPrefix(
                    base.resolvingSymlinksInPath().path + "/"
                  ),
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
