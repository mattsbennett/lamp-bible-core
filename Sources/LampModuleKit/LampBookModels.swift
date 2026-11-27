import Foundation

public struct LampBookAnnotationData: Codable, Equatable, Hashable, Sendable {
    public let startReference: Int?
    public let endReference: Int?
    public let references: [LampBookVerseRange]
    public let strongs: String?
    public let url: String?
    public let style: String?
    public let source: String?
    public let footnoteID: String?
    public let pageNumber: String?
    public let mediaID: String?
    public let mediaType: String?
    /// Where a `link` goes, or the note a `scripture` annotation also opens.
    public let target: LampLinkTarget?
    /// Whether a target was given at all — read, or written wrong and so
    /// none — for the inspector to tell a link left out from one broken.
    let hasTargetField: Bool

    enum CodingKeys: String, CodingKey {
        case startReference = "sv"
        case endReference = "ev"
        case references = "refs"
        case strongs, url, style, source
        case footnoteID = "footnoteId"
        case pageNumber = "pageNum"
        case mediaID = "mediaId"
        case mediaType, target
    }

    public init(
        startReference: Int? = nil,
        endReference: Int? = nil,
        references: [LampBookVerseRange] = [],
        strongs: String? = nil,
        url: String? = nil,
        style: String? = nil,
        source: String? = nil,
        footnoteID: String? = nil,
        pageNumber: String? = nil,
        mediaID: String? = nil,
        mediaType: String? = nil,
        target: LampLinkTarget? = nil
    ) {
        self.target = target
        hasTargetField = target != nil
        self.startReference = startReference
        self.endReference = endReference
        self.references = references
        self.strongs = strongs
        self.url = url
        self.style = style
        self.source = source
        self.footnoteID = footnoteID
        self.pageNumber = pageNumber
        self.mediaID = mediaID
        self.mediaType = mediaType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startReference = try container.decodeIfPresent(Int.self, forKey: .startReference)
        endReference = try container.decodeIfPresent(Int.self, forKey: .endReference)
        references = try container.decodeIfPresent([LampBookVerseRange].self, forKey: .references) ?? []
        strongs = try container.decodeIfPresent(String.self, forKey: .strongs)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        style = try container.decodeIfPresent(String.self, forKey: .style)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        footnoteID = try container.decodeIfPresent(String.self, forKey: .footnoteID)
        if let string = try? container.decodeIfPresent(String.self, forKey: .pageNumber) {
            pageNumber = string
        } else if let number = try? container.decode(Int.self, forKey: .pageNumber) {
            pageNumber = String(number)
        } else {
            pageNumber = nil
        }
        mediaID = try container.decodeIfPresent(String.self, forKey: .mediaID)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        // A target that cannot be read is no target: the annotation, and the
        // text it is on, still read.
        // So is one whose address was written wrong: kept, it would lose the
        // wrong field on being written again and come back as a link to this
        // module. Found by Codex.
        target = (try? container.decodeIfPresent(LampLinkTarget.self, forKey: .target)) ?? nil
        hasTargetField = container.contains(.target)
    }
}

public struct LampBookVerseRange: Codable, Equatable, Hashable, Sendable {
    public let startReference: Int
    public let endReference: Int?
    public let label: String?

    enum CodingKeys: String, CodingKey {
        case startReference = "sv"
        case endReference = "ev"
        case label
    }

    public init(startReference: Int, endReference: Int? = nil, label: String? = nil) {
        self.startReference = startReference
        self.endReference = endReference
        self.label = label
    }
}

public struct LampBookAnnotation: Codable, Equatable, Hashable, Sendable {
    public let type: String
    public let start: Int
    public let end: Int
    public let text: String?
    public let data: LampBookAnnotationData?

    public init(
        type: String,
        start: Int,
        end: Int,
        text: String? = nil,
        data: LampBookAnnotationData? = nil
    ) {
        self.type = type
        self.start = start
        self.end = end
        self.text = text
        self.data = data
    }
}

public struct LampBookFootnoteReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let offset: Int

    public init(id: String, offset: Int) {
        self.id = id
        self.offset = offset
    }
}

public struct LampBookAnnotatedText: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let annotations: [LampBookAnnotation]
    public let footnoteReferences: [LampBookFootnoteReference]

    enum CodingKeys: String, CodingKey {
        case text, annotations
        case footnoteReferences = "footnote_refs"
    }

    public init(
        text: String,
        annotations: [LampBookAnnotation] = [],
        footnoteReferences: [LampBookFootnoteReference] = []
    ) {
        self.text = text
        self.annotations = annotations
        self.footnoteReferences = footnoteReferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        annotations = try container.decodeIfPresent([LampBookAnnotation].self, forKey: .annotations) ?? []
        footnoteReferences = try container.decodeIfPresent(
            [LampBookFootnoteReference].self,
            forKey: .footnoteReferences
        ) ?? []
    }
}

public enum LampBookTextValue: Codable, Equatable, Sendable {
    case plain(String)
    case annotated(LampBookAnnotatedText)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
        } else {
            self = .annotated(try container.decode(LampBookAnnotatedText.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let value): try container.encode(value)
        case .annotated(let value): try container.encode(value)
        }
    }

    public var annotatedText: LampBookAnnotatedText {
        switch self {
        case .plain(let value): LampBookAnnotatedText(text: value)
        case .annotated(let value): value
        }
    }

    public var text: String { annotatedText.text }
}

public struct LampBookListItem: Codable, Equatable, Sendable {
    public let content: LampBookAnnotatedText
    public let children: [LampBookListItem]

    public init(content: LampBookAnnotatedText, children: [LampBookListItem] = []) {
        self.content = content
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(LampBookAnnotatedText.self, forKey: .content)
        children = try container.decodeIfPresent([LampBookListItem].self, forKey: .children) ?? []
    }

    private enum CodingKeys: String, CodingKey { case content, children }
}

public struct LampBookTableCell: Codable, Equatable, Sendable {
    public let content: LampBookAnnotatedText
    public let column: Int
    public let columnSpan: Int
    public let rowSpan: Int
    public let isHeader: Bool
    /// `left`, `center` or `right`; nil for the reader's own.
    public let alignment: String?
    /// An opaque label the cell shares with others drawn alike, named in a
    /// legend: what the author's chart marks it as, such as `good-king`.
    public let label: String?

    public init(
        content: LampBookAnnotatedText,
        column: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1,
        isHeader: Bool = false,
        alignment: String? = nil,
        label: String? = nil
    ) {
        self.alignment = alignment
        self.label = label
        self.content = content
        self.column = column
        self.columnSpan = max(columnSpan, 1)
        self.rowSpan = max(rowSpan, 1)
        self.isHeader = isHeader
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(
            LampBookAnnotatedText.self,
            forKey: .content
        ) ?? LampBookAnnotatedText(text: "")
        column = try container.decodeIfPresent(Int.self, forKey: .column) ?? 0
        columnSpan = max(
            try container.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1,
            1
        )
        rowSpan = max(
            try container.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1,
            1
        )
        isHeader = try container.decodeIfPresent(Bool.self, forKey: .isHeader) ?? false
        alignment = LampBookDecoding.string(container, .alignment)
            .flatMap { ["left", "center", "right"].contains($0) ? $0 : nil }
        label = LampBookDecoding.string(container, .label)
    }

    private enum CodingKeys: String, CodingKey {
        case content, column
        case columnSpan = "colSpan"
        case rowSpan
        case isHeader = "header"
        case alignment = "align"
        case label
    }
}

public struct LampBookTableRow: Codable, Equatable, Sendable {
    public let cells: [LampBookTableCell]
    /// An opaque label the row shares with others drawn alike, named in a
    /// legend.
    public let label: String?

    public init(cells: [LampBookTableCell], label: String? = nil) {
        self.cells = cells
        self.label = label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cells = try container.decodeIfPresent(
            [LampBookTableCell].self,
            forKey: .cells
        ) ?? []
        label = LampBookDecoding.string(container, .label)
    }

    private enum CodingKeys: String, CodingKey { case cells, label }
}

/// Reads for fields added after a reader already read the block: one of the
/// wrong type is absent, never a reason to lose the block it is on, as an
/// unknown key never was.
enum LampBookDecoding {
    static func string<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    static func value<Value: Decodable, Key: CodingKey>(
        _ type: Value.Type, _ container: KeyedDecodingContainer<Key>, _ key: Key
    ) -> Value? {
        (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// An array read entry by entry, keeping each that reads.
    static func array<Element: Decodable, Key: CodingKey>(
        _ type: Element.Type, _ container: KeyedDecodingContainer<Key>, _ key: Key
    ) -> [Element] {
        guard var entries = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [Element] = []
        while !entries.isAtEnd {
            if let element = try? entries.decode(type) {
                out.append(element)
            } else {
                _ = try? entries.decode(LampBookSkipped.self)
            }
        }
        return out
    }
}

/// Any JSON value, read and set aside, so a list can step past an entry it
/// cannot read.
private struct LampBookSkipped: Decodable {
    init(from decoder: Decoder) throws {}
}

public struct LampBookContentBlock: Codable, Equatable, Sendable {
    public let type: String
    public let content: LampBookAnnotatedText?
    public let level: Int?
    public let listType: String?
    public let items: [LampBookListItem]
    public let mediaID: String?
    public let caption: LampBookTextValue?
    public let alignment: String?
    public let showWaveform: Bool
    public let autoplay: Bool
    public let columnCount: Int?
    public let rows: [LampBookTableRow]
    /// The block's anchor, unique within its module (a commentary's volume).
    public let id: String?
    /// What the author calls the block, such as `map` or `chart`. Not
    /// interpreted.
    public let role: String?
    /// A figure's title, and its second line, such as an era.
    public let title: LampBookTextValue?
    public let subtitle: LampBookTextValue?
    /// A figure's contents, in printed order: pictures, paragraphs, lists,
    /// tables and headings. Never another figure.
    public let children: [LampBookContentBlock]
    /// Notes printed under a figure or table.
    public let notes: [LampBookAnnotatedText]
    /// What the labels on a table's rows and cells stand for.
    public let legend: [LampBookLegendEntry]

    /// What a figure may hold, as `book_schema.json`'s `figureChild` says.
    public static let figureChildTypes: Set<String> = ["image", "paragraph", "list", "table", "heading"]

    enum CodingKeys: String, CodingKey {
        case type, content, level, listType, items
        case mediaID = "mediaId"
        case caption, alignment, showWaveform, autoplay, columnCount, rows
        case id, role, title, subtitle, children, notes, legend
    }

    public init(
        type: String,
        content: LampBookAnnotatedText? = nil,
        level: Int? = nil,
        listType: String? = nil,
        items: [LampBookListItem] = [],
        mediaID: String? = nil,
        caption: LampBookTextValue? = nil,
        alignment: String? = nil,
        showWaveform: Bool = false,
        autoplay: Bool = false,
        columnCount: Int? = nil,
        rows: [LampBookTableRow] = [],
        id: String? = nil,
        role: String? = nil,
        title: LampBookTextValue? = nil,
        subtitle: LampBookTextValue? = nil,
        children: [LampBookContentBlock] = [],
        notes: [LampBookAnnotatedText] = [],
        legend: [LampBookLegendEntry] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.subtitle = subtitle
        // Held to the kinds a figure holds here as when read, so a figure
        // built in code projects and round-trips as one read does. Found by
        // Codex.
        self.children = type == "figure" ? children.filter { Self.figureChildTypes.contains($0.type) } : []
        self.notes = notes
        self.legend = legend
        self.type = type
        self.content = content
        self.level = level
        self.listType = listType
        self.items = items
        self.mediaID = mediaID
        self.caption = caption
        self.alignment = alignment
        self.showWaveform = showWaveform
        self.autoplay = autoplay
        self.columnCount = columnCount
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        content = try container.decodeIfPresent(LampBookAnnotatedText.self, forKey: .content)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        listType = try container.decodeIfPresent(String.self, forKey: .listType)
        items = try container.decodeIfPresent([LampBookListItem].self, forKey: .items) ?? []
        mediaID = try container.decodeIfPresent(String.self, forKey: .mediaID)
        caption = try container.decodeIfPresent(LampBookTextValue.self, forKey: .caption)
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        showWaveform = try container.decodeIfPresent(Bool.self, forKey: .showWaveform) ?? false
        autoplay = try container.decodeIfPresent(Bool.self, forKey: .autoplay) ?? false
        columnCount = try container.decodeIfPresent(Int.self, forKey: .columnCount)
        rows = try container.decodeIfPresent([LampBookTableRow].self, forKey: .rows) ?? []
        // The fields a figure brought, each read on its own: a malformed one
        // is absent, and costs no reader the block.
        id = LampBookDecoding.string(container, .id)
        role = LampBookDecoding.string(container, .role)
        title = LampBookDecoding.value(LampBookTextValue.self, container, .title)
        subtitle = LampBookDecoding.value(LampBookTextValue.self, container, .subtitle)
        // A child that cannot be read is left out, as a block of a section is,
        // and so is one of a kind a figure does not hold — another figure, a
        // recording, a quotation — whatever wrote it: the compilers do not
        // run the schema. Found by Codex.
        // And only a figure has any: another block's are never drawn, nor
        // projected. Found by Codex.
        children = type == "figure"
            ? LampBookDecoding.array(LampBookContentBlock.self, container, .children)
                .filter { Self.figureChildTypes.contains($0.type) }
            : []
        notes = LampBookDecoding.array(LampBookAnnotatedText.self, container, .notes)
        legend = LampBookDecoding.array(LampBookLegendEntry.self, container, .legend)
    }
}

public struct LampBookFootnote: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let content: LampBookTextValue

    public init(id: String, content: LampBookTextValue) {
        self.id = id
        self.content = content
    }
}

public struct LampBookMedia: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let filename: String
    public let mimeType: String
    public let size: Int?
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let waveform: [Double]
    public let transcription: String?
    public let alt: String?
    public let created: Int?

    public init(
        id: String,
        type: String,
        filename: String,
        mimeType: String,
        size: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        waveform: [Double] = [],
        transcription: String? = nil,
        alt: String? = nil,
        created: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.waveform = waveform
        self.transcription = transcription
        self.alt = alt
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        waveform = try container.decodeIfPresent([Double].self, forKey: .waveform) ?? []
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        alt = try container.decodeIfPresent(String.self, forKey: .alt)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, filename, mimeType, size, width, height, duration
        case waveform, transcription, alt, created
    }
}
