import Foundation

/// A record that two devices changed to different content at the same moment.
///
/// Sync chooses by modification time, so when both sides carry the same one it
/// has nothing left to choose with. Rather than guess, it keeps what is on this
/// device, sets the incoming copy aside here, and lets the run finish — one
/// disagreement over one record should not stop a library from syncing.
///
/// The copy set aside is the whole incoming record, because a person choosing
/// between two versions may do so days later, long after the file it arrived in
/// has gone.
public struct LampSyncConflict: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case devotional
        case note
    }

    /// A part of a record the two versions disagree about.
    ///
    /// Named for what someone wrote rather than for the column it lives in,
    /// and decided with the same comparisons the merge itself used — a reason
    /// that does not match the decision is worse than no reason at all.
    public enum Difference: String, Sendable, CaseIterable {
        case title, subtitle, author, date, tags, category, series
        case keyScriptures, summary, body, footnotes, verses
        /// Structured blocks behind the same words.
        case formatting
        /// Images and audio carried with the record.
        case attachments

        public var label: String {
            switch self {
            case .title: "title"
            case .subtitle: "subtitle"
            case .author: "author"
            case .date: "date"
            case .tags: "tags"
            case .category: "category"
            case .series: "series"
            case .keyScriptures: "key scriptures"
            case .summary: "summary"
            case .body: "the text"
            case .footnotes: "footnotes"
            case .verses: "the verses it covers"
            case .formatting: "formatting"
            case .attachments: "attachments"
            }
        }
    }

    /// Which version of the record to keep.
    public enum Side: String, Sendable {
        /// What this device already had.
        case thisDevice
        /// What arrived from sync.
        case otherDevice
    }

    public let id: String
    public let kind: Kind
    /// The conflicted record's own identifier, as its table knows it.
    public let itemKey: String
    public let title: String
    /// Where to find the record, when the title alone does not say — the verse
    /// a note is attached to. Nil when the title already locates it.
    public let subtitle: String?
    public let thisDeviceModified: Date?
    public let otherDeviceModified: Date?
    /// A few lines of each version, enough to tell them apart without opening
    /// either one.
    public let thisDevicePreview: String
    public let otherDevicePreview: String
    /// What the two versions actually disagree about, in the order a reader
    /// meets it. Empty only if the disagreement has since been edited away.
    public let differences: [Difference]
    public let detected: Date

    public init(
        id: String,
        kind: Kind,
        itemKey: String,
        title: String,
        subtitle: String? = nil,
        thisDeviceModified: Date?,
        otherDeviceModified: Date?,
        thisDevicePreview: String,
        otherDevicePreview: String,
        differences: [Difference] = [],
        detected: Date
    ) {
        self.id = id
        self.kind = kind
        self.itemKey = itemKey
        self.title = title
        self.subtitle = subtitle
        self.thisDeviceModified = thisDeviceModified
        self.otherDeviceModified = otherDeviceModified
        self.thisDevicePreview = thisDevicePreview
        self.otherDevicePreview = otherDevicePreview
        self.differences = differences
        self.detected = detected
    }

    /// True when the two versions read the same but disagree elsewhere, so a
    /// caller can say that choosing a side also drops the other's title or
    /// date rather than show two panes that look identical.
    ///
    /// Read from the differences rather than by comparing previews: a preview
    /// stops at a few hundred characters, and two long writings that part
    /// company after the cut are not the same writing.
    public var differsBeyondBody: Bool {
        !differences.isEmpty && !differences.contains(.body)
    }

    /// The differences as a sentence fragment: "the text", "a title and a
    /// date", "a title, a date and footnotes".
    public var differenceSummary: String {
        let labels = differences.map(\.label)
        guard let last = labels.last else { return "something this device can no longer see" }
        guard labels.count > 1 else { return last }
        return labels.dropLast().joined(separator: ", ") + " and " + last
    }

    public static func identifier(kind: Kind, itemKey: String) -> String {
        "\(kind.rawValue):\(itemKey)"
    }

    /// Split an identifier back into its parts. Only the first colon divides
    /// them: a note's own key carries one of its own.
    public static func parse(id: String) -> (kind: Kind, itemKey: String)? {
        guard let divider = id.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(id[id.startIndex..<divider])) else { return nil }
        let itemKey = String(id[id.index(after: divider)...])
        return itemKey.isEmpty ? nil : (kind, itemKey)
    }
}

/// What a resolved conflict left behind, for a caller that wants to show it.
public enum LampSyncConflictResolution: Equatable, Sendable {
    case devotional(LampDevotional)
    case note(LampVerseNote)

    public var content: String {
        switch self {
        case .devotional(let devotional): devotional.content
        case .note(let note): note.content
        }
    }

    public var lastModified: Date? {
        switch self {
        case .devotional(let devotional): devotional.lastModified
        case .note(let note): note.lastModified
        }
    }
}

/// How a conflicted record is summarised for someone choosing between versions.
enum LampSyncConflictPreview {
    /// Flattened to one block of plain text, shortened, because a preview that
    /// runs to the length of the writing is no longer a preview.
    static func text(_ body: String, limit: Int = 280) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

/// The set-aside copy, flattened to one self-contained JSON document.
///
/// A stash is not a mirror of the columns the record lives in today. It can sit
/// unanswered across an update that adds a column, and every kind of record
/// that can disagree has a different set of them, so a document keeps the table
/// narrow and costs a new kind no schema change at all.
enum LampSyncConflictPayload {
    static func encode(_ devotional: LampDevotional) throws -> String {
        var object: [String: Any] = [
            "id": devotional.id,
            "title": devotional.title,
            "tags": devotional.tags,
            "content": devotional.content,
            "keyScriptures": devotional.keyScriptures.map { link -> [String: Any] in
                var value: [String: Any] = ["sv": link.startReference]
                if let end = link.endReference { value["ev"] = end }
                if let text = link.text { value["label"] = text }
                return value
            },
        ]
        object["subtitle"] = devotional.subtitle
        object["author"] = devotional.author
        object["date"] = devotional.date
        object["category"] = devotional.category
        object["seriesName"] = devotional.seriesName
        object["seriesOrder"] = devotional.seriesOrder
        object["summary"] = devotional.summary
        object["contentJSON"] = devotional.contentJSON
        object["footnotes"] = devotional.footnotes
        object["mediaJSON"] = devotional.mediaJSON
        object["created"] = devotional.created.map { Int($0.timeIntervalSince1970) }
        object["lastModified"] = devotional.lastModified.map { Int($0.timeIntervalSince1970) }
        return try json(object)
    }

    static func devotional(from payload: String) -> LampDevotional? {
        guard let object = object(from: payload),
              let id = object["id"] as? String,
              let content = object["content"] as? String else { return nil }
        let keyScriptures = (object["keyScriptures"] as? [[String: Any]] ?? [])
            .compactMap { value -> LampScriptureLink? in
                guard let start = value["sv"] as? Int else { return nil }
                return LampScriptureLink(
                    text: value["label"] as? String,
                    startReference: start,
                    endReference: value["ev"] as? Int
                )
            }
        return LampDevotional(
            id: id,
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: object["title"] as? String ?? "Untitled",
            subtitle: object["subtitle"] as? String,
            author: object["author"] as? String,
            date: object["date"] as? String,
            tags: object["tags"] as? [String] ?? [],
            category: object["category"] as? String,
            seriesName: object["seriesName"] as? String,
            seriesOrder: object["seriesOrder"] as? Int,
            keyScriptures: keyScriptures,
            summary: object["summary"] as? String,
            content: content,
            contentJSON: object["contentJSON"] as? String,
            footnotes: object["footnotes"] as? String,
            mediaJSON: object["mediaJSON"] as? String,
            created: (object["created"] as? Int)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastModified: (object["lastModified"] as? Int)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) },
            isEditable: true
        )
    }

    static func encode(_ note: LampVerseNote) throws -> String {
        var object: [String: Any] = [
            "id": note.id,
            "moduleID": note.moduleID,
            "reference": note.reference,
            "content": note.content,
            "verseReferences": note.verseReferences,
            "footnotes": note.footnotes.map { footnote -> [String: String] in
                var value = ["id": footnote.id, "content": footnote.content]
                if let kind = footnote.kind { value["type"] = kind }
                return value
            },
            "lastModified": Int(note.lastModified.timeIntervalSince1970),
        ]
        object["title"] = note.title
        return try json(object)
    }

    static func note(from payload: String) -> LampVerseNote? {
        guard let object = object(from: payload),
              let id = object["id"] as? String,
              let reference = object["reference"] as? Int,
              let content = object["content"] as? String else { return nil }
        let footnotes = (object["footnotes"] as? [[String: Any]] ?? [])
            .compactMap { value -> LampVerseFootnote? in
                guard let footnoteID = value["id"] as? String,
                      let body = value["content"] as? String else { return nil }
                return LampVerseFootnote(
                    id: footnoteID,
                    kind: value["type"] as? String,
                    content: body
                )
            }
        return LampVerseNote(
            id: id,
            moduleID: object["moduleID"] as? String ?? "personal-notes",
            reference: reference,
            title: object["title"] as? String,
            content: content,
            verseReferences: object["verseReferences"] as? [Int] ?? [],
            footnotes: footnotes,
            lastModified: Date(
                timeIntervalSince1970: TimeInterval(object["lastModified"] as? Int ?? 0)
            )
        )
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private static func object(from payload: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }
}

/// Why the two versions could not be reconciled.
///
/// Every test here is the one the merge used to reach `.conflict`. An empty
/// field and a missing one count as the same, because export leaves empty
/// fields out and a record has to match its own copy coming back. An incoming
/// record with nothing to say about its blocks or attachments is not
/// disagreeing about them.
extension LampSyncConflict {
    static func differences(
        between local: LampDevotional,
        and incoming: LampDevotional
    ) -> [Difference] {
        var differences: [Difference] = []
        if local.title != incoming.title { differences.append(.title) }
        if !same(local.subtitle, incoming.subtitle) { differences.append(.subtitle) }
        if !same(local.author, incoming.author) { differences.append(.author) }
        if !same(local.date, incoming.date) { differences.append(.date) }
        if local.tags != incoming.tags { differences.append(.tags) }
        if !same(local.category, incoming.category) { differences.append(.category) }
        if !same(local.seriesName, incoming.seriesName)
            || local.seriesOrder != incoming.seriesOrder { differences.append(.series) }
        if local.keyScriptures != incoming.keyScriptures { differences.append(.keyScriptures) }
        if !same(local.summary, incoming.summary) { differences.append(.summary) }
        if local.content != incoming.content { differences.append(.body) }
        if !same(local.footnotes, incoming.footnotes) { differences.append(.footnotes) }
        if incoming.contentJSON != nil,
           local.contentJSON != incoming.contentJSON { differences.append(.formatting) }
        if incoming.mediaJSON != nil,
           local.mediaJSON != incoming.mediaJSON { differences.append(.attachments) }
        return differences
    }

    static func differences(
        between local: LampVerseNote,
        and incoming: LampVerseNote
    ) -> [Difference] {
        var differences: [Difference] = []
        if !same(local.title, incoming.title) { differences.append(.title) }
        if local.content != incoming.content { differences.append(.body) }
        if local.verseReferences != incoming.verseReferences { differences.append(.verses) }
        if local.footnotes != incoming.footnotes { differences.append(.footnotes) }
        return differences
    }
}

/// Trimmed, with an empty field and a missing one treated alike — the same
/// test the merge applies, because export leaves empty fields out.
private func same(_ a: String?, _ b: String?) -> Bool {
    func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
    return trimmed(a) == trimmed(b)
}
