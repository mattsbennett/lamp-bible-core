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

    enum CodingKeys: String, CodingKey {
        case startReference = "sv"
        case endReference = "ev"
        case references = "refs"
        case strongs, url, style, source
        case footnoteID = "footnoteId"
        case pageNumber = "pageNum"
        case mediaID = "mediaId"
        case mediaType
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
        mediaType: String? = nil
    ) {
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

    public init(
        content: LampBookAnnotatedText,
        column: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1,
        isHeader: Bool = false
    ) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case content, column
        case columnSpan = "colSpan"
        case rowSpan
        case isHeader = "header"
    }
}

public struct LampBookTableRow: Codable, Equatable, Sendable {
    public let cells: [LampBookTableCell]

    public init(cells: [LampBookTableCell]) {
        self.cells = cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cells = try container.decodeIfPresent(
            [LampBookTableCell].self,
            forKey: .cells
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey { case cells }
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

    enum CodingKeys: String, CodingKey {
        case type, content, level, listType, items
        case mediaID = "mediaId"
        case caption, alignment, showWaveform, autoplay, columnCount, rows
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
        rows: [LampBookTableRow] = []
    ) {
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
