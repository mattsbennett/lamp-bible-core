import Foundation

/// Identifies Mac devotional attachments referenced by portable Markdown.
/// The URL remains the media ID so clients can preserve the authored link.
public enum LampPortableDevotionalMedia {
    public struct Reference: Equatable, Sendable {
        public enum Kind: String, Sendable { case image, audio }

        public let id: String
        public let devotionalID: String
        public let filename: String
        public let kind: Kind

        public var archivePath: String {
            "Media/Devotionals/\(devotionalID)/\(filename)"
        }

        public var mimeType: String {
            switch filename.lowercased().split(separator: ".").last.map(String.init) {
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "gif": "image/gif"
            case "webp": "image/webp"
            case "heic": "image/heic"
            case "m4a": "audio/mp4"
            case "mp3": "audio/mpeg"
            case "wav": "audio/wav"
            case "aac": "audio/aac"
            case "ogg": "audio/ogg"
            default: "application/octet-stream"
            }
        }
    }

    public enum ReferenceError: Error, LocalizedError {
        case malformedReference
        case wrongDevotional(String)
        case unsafeFilename(String)

        public var errorDescription: String? {
            switch self {
            case .malformedReference: "A devotional has an invalid lamp-media link."
            case .wrongDevotional(let id): "A devotional references media owned by \(id)."
            case .unsafeFilename(let filename): "Unsafe devotional media filename: \(filename)."
            }
        }
    }

    public enum MetadataError: Error, LocalizedError {
        case invalidJSON
        case duplicateID(String)
        case unsafeFilename(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: "Invalid devotional media metadata."
            case .duplicateID(let id): "Duplicate devotional media ID: \(id)."
            case .unsafeFilename(let filename): "Unsafe devotional media filename: \(filename)."
            }
        }
    }

    /// Append a rich reference without decoding and re-encoding older entries.
    /// Dictionaries for media authored by a newer client keep their unknown fields.
    public static func appending(
        _ reference: LampDevotionalMediaReference,
        to mediaJSON: String?
    ) throws -> String {
        guard isSafePathComponent(reference.filename) else {
            throw MetadataError.unsafeFilename(reference.filename)
        }
        let existing: [[String: Any]]
        if let mediaJSON {
            guard let decoded = try? JSONSerialization.jsonObject(
                with: Data(mediaJSON.utf8)
            ) as? [[String: Any]] else { throw MetadataError.invalidJSON }
            existing = decoded
        } else {
            existing = []
        }
        guard !existing.contains(where: { $0["id"] as? String == reference.id }) else {
            throw MetadataError.duplicateID(reference.id)
        }
        guard let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(reference)
        ) as? [String: Any] else { throw MetadataError.invalidJSON }
        let data = try JSONSerialization.data(
            withJSONObject: existing + [encoded], options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Read filenames without requiring an older client to understand every
    /// media type or future metadata field. All referenced files still transfer.
    public static func filenames(in mediaJSON: String?) throws -> [String] {
        guard let mediaJSON else { return [] }
        guard let entries = try? JSONSerialization.jsonObject(
            with: Data(mediaJSON.utf8)
        ) as? [[String: Any]] else { throw MetadataError.invalidJSON }
        return try entries.map { entry in
            guard let filename = entry["filename"] as? String else {
                throw MetadataError.invalidJSON
            }
            guard isSafePathComponent(filename) else {
                throw MetadataError.unsafeFilename(filename)
            }
            return filename
        }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(!?)\[[^\]]*\]\((lamp-media://([^)]*))\)"#
    )

    public static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.contains("\0")
            && (value as NSString).lastPathComponent == value
    }

    public static func iOSRemotePath(
        moduleID: String, devotionalID: String, filename: String
    ) throws -> String {
        guard isSafePathComponent(moduleID),
              isSafePathComponent(devotionalID),
              isSafePathComponent(filename) else {
            throw ReferenceError.unsafeFilename(filename)
        }
        return "DevotionalMedia/\(moduleID)/\(devotionalID)/\(filename)"
    }

    /// Resolve both the legacy Mac URL and iOS's metadata-backed media ID in
    /// a portable library. Unknown or unsafe links stay unchanged.
    public static func libraryURL(
        for link: URL,
        rootURL: URL,
        devotionalID: String?,
        references: [LampDevotionalMediaReference]
    ) -> URL {
        let owner: String
        let filename: String
        if link.scheme == "lamp-media" {
            owner = link.host ?? ""
            filename = link.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if link.scheme == nil, link.path.hasPrefix("media/"),
                  let devotionalID,
                  let reference = references.first(where: {
                      $0.id == String(link.path.dropFirst("media/".count))
                  }) {
            owner = devotionalID
            filename = reference.filename
        } else {
            return link
        }
        guard isSafePathComponent(owner), isSafePathComponent(filename) else { return link }
        return rootURL
            .appendingPathComponent("Media/Devotionals", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// TipTap uses `media/id` internally. Keep rich iOS IDs unchanged when
    /// saving, and restore legacy Mac URLs only for filename-based links.
    public static func editorMarkdown(from portableMarkdown: String) -> String {
        portableMarkdown.replacingOccurrences(
            of: #"lamp-media://[^/)\s]+/"#,
            with: "media/",
            options: .regularExpression
        )
    }

    public static func portableMarkdown(
        from editorMarkdown: String,
        devotionalID: String,
        richMediaIDs: Set<String>
    ) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\]\(media/([^)]+)\)"#)
        var portable = editorMarkdown
        let matches = pattern.matches(
            in: editorMarkdown,
            range: NSRange(editorMarkdown.startIndex..<editorMarkdown.endIndex, in: editorMarkdown)
        )
        for match in matches.reversed() {
            guard let idRange = Range(match.range(at: 1), in: portable),
                  let fullRange = Range(match.range, in: portable) else { continue }
            let id = String(portable[idRange])
            guard !richMediaIDs.contains(id) else { continue }
            portable.replaceSubrange(
                fullRange, with: "](lamp-media://\(devotionalID)/\(id))"
            )
        }
        return portable
    }

    /// Mac's personal export wraps authored Markdown in one unannotated
    /// paragraph. Rich blocks keep their structured representation.
    public static func plainMarkdown(from contentJSON: String) -> String? {
        guard let data = contentJSON.data(using: .utf8),
              let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              blocks.count == 1,
              blocks[0].count == 2,
              blocks[0]["type"] as? String == "paragraph",
              let content = blocks[0]["content"] as? [String: Any],
              content.count == 1 else { return nil }
        return content["text"] as? String
    }

    public static func references(in markdown: String, devotionalID: String) throws -> [Reference] {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let matches = pattern.matches(in: markdown, range: range)
        var references: [Reference] = []
        for match in matches {
            guard let pathRange = Range(match.range(at: 3), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown) else {
                throw ReferenceError.malformedReference
            }
            let path = markdown[pathRange]
            guard let separator = path.firstIndex(of: "/") else {
                throw ReferenceError.malformedReference
            }
            let id = String(path[..<separator])
            let filename = String(path[path.index(after: separator)...])
            guard id == devotionalID else { throw ReferenceError.wrongDevotional(id) }
            guard isSafePathComponent(filename) else {
                throw ReferenceError.unsafeFilename(filename)
            }
            let reference = Reference(
                id: String(markdown[urlRange]),
                devotionalID: id,
                filename: filename,
                kind: match.range(at: 1).length == 1 ? .image : .audio
            )
            if let prior = references.first(where: { $0.id == reference.id }) {
                guard prior.kind == reference.kind else { throw ReferenceError.malformedReference }
            } else {
                references.append(reference)
            }
        }
        return references
    }
}
