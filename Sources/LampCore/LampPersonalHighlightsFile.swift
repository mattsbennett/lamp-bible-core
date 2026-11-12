import Foundation
import LampModuleKit

/// The file one of the reader's highlight sets travels in, built from
/// records alone.
///
/// The last of the three personal kinds, and the odd one of them. Notes and
/// writings travel as the whole collection in one file, written directly as
/// SQLite. A highlight set travels as **one file per set**, authored as the
/// portable JSON a module is written in and then compiled — so what crosses
/// is the *compiled* shape, `LampModuleCompiledSchema.tables(for:
/// .highlights)`, with the set's identity in the module's own metadata.
/// `LampPersonalExportSchema.exportedTables(for: .highlights)` describes a
/// different file: the whole library's highlights in one, for a backup.
/// ios-56 found that split when its pin would not fit.
///
/// Because it is compiled rather than hand-written, the bytes were already
/// a shared concern — `LampModuleCompiler` is core's. What was not shared
/// is the document: which fields go in, under which names, in which order.
/// That is here now, so the phone builds the same document from its own
/// records and the compiler does the rest.
public enum LampPersonalHighlightsFile {
    /// Everything about a set that reaches the file.
    public struct Set: Sendable {
        public var id: String
        public var moduleID: String
        public var name: String
        public var translationID: String
        public var description: String?
        /// Seconds, as both apps store them.
        public var created: Int?
        public var lastModified: Int?
        /// In the order they are written: `ref, sc, ec, id`.
        public var highlights: [LampVerseHighlight]
        /// In the order they are written: `name, color, style`.
        public var themes: [LampHighlightTheme]

        public init(
            id: String,
            moduleID: String,
            name: String,
            translationID: String,
            description: String? = nil,
            created: Int? = nil,
            lastModified: Int? = nil,
            highlights: [LampVerseHighlight],
            themes: [LampHighlightTheme] = []
        ) {
            self.id = id
            self.moduleID = moduleID
            self.name = name
            self.translationID = translationID
            self.description = description
            self.created = created
            self.lastModified = lastModified
            self.highlights = highlights
            self.themes = themes
        }
    }

    /// The portable document a set is authored as.
    ///
    /// A field that has nothing to say is left out rather than written
    /// empty: an absent `description` and a `description` of `""` are not
    /// the same claim, and a reader that cannot tell them apart overwrites
    /// one device's description with the other's silence.
    public static func document(for set: Set) throws -> [String: Any] {
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": set.moduleID,
            "type": "highlights",
            "name": set.name,
            "translationId": set.translationID,
        ]
        if let created = set.created { meta["created"] = created }
        if let lastModified = set.lastModified { meta["lastModified"] = lastModified }
        if let description = set.description { meta["description"] = description }
        if !set.themes.isEmpty {
            meta["themes"] = set.themes.map { theme -> [String: Any] in
                var value: [String: Any] = [
                    "color": theme.color,
                    "style": theme.style.rawValue,
                    "name": theme.name,
                ]
                if let description = theme.description { value["description"] = description }
                return value
            }
        }
        let grouped = Dictionary(grouping: set.highlights, by: \.reference)
        let verses: [[String: Any]] = grouped.keys.sorted().map { reference in
            let spans: [[String: Any]] = (grouped[reference] ?? []).map { highlight in
                var span: [String: Any] = [
                    "sc": highlight.startOffset,
                    "ec": highlight.endOffset,
                    "style": highlight.style.rawValue,
                ]
                if let color = highlight.color { span["color"] = color }
                return span
            }
            return ["ref": reference, "highlights": spans]
        }
        return ["meta": meta, "verses": verses]
    }
}
