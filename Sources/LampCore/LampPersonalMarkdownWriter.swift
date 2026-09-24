import Foundation

public struct LampMarkdownDevotionalEntry: Sendable {
    public let title: String
    public let subtitle: String?
    public let author: String?
    public let date: String?
    public let tags: [String]
    public let category: String?
    public let seriesName: String?
    public let seriesOrder: Int?
    public let scriptureDescriptions: [String]
    public let summary: String?
    public let content: String
    public let footnotes: String?

    public init(
        title: String,
        subtitle: String? = nil,
        author: String? = nil,
        date: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        seriesName: String? = nil,
        seriesOrder: Int? = nil,
        scriptureDescriptions: [String] = [],
        summary: String? = nil,
        content: String,
        footnotes: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.date = date
        self.tags = tags
        self.category = category
        self.seriesName = seriesName
        self.seriesOrder = seriesOrder
        self.scriptureDescriptions = scriptureDescriptions
        self.summary = summary
        self.content = content
        self.footnotes = footnotes
    }
}

public enum LampPersonalMarkdownWriter {
    public static func noteHeading(reference: Int, endReference: Int? = nil) -> String {
        let chapter = (reference / 1_000) % 1_000
        let verse = reference % 1_000
        guard verse > 0 else { return "Introduction" }
        guard let endReference, endReference > reference else {
            return "\(chapter):\(verse)"
        }
        let endBook = endReference / 1_000_000
        guard endBook == reference / 1_000_000 else {
            return LampBibleReferenceFormatter.describeRange(
                from: reference, to: endReference
            )
        }
        let endChapter = (endReference / 1_000) % 1_000
        let endVerse = endReference % 1_000
        return endChapter == chapter
            ? "\(chapter):\(verse)-\(endVerse)"
            : "\(chapter):\(verse)-\(endChapter):\(endVerse)"
    }

    /// Common entry layout for multi-devotional exports on iOS and Mac.
    public static func devotionalEntry(_ entry: LampMarkdownDevotionalEntry) -> String {
        var blocks = ["## \(entry.title.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if let subtitle = entry.subtitle?.markdownValue {
            blocks.append("*\(subtitle)*")
        }
        var metadata: [String] = []
        if let author = entry.author?.markdownValue { metadata.append("**Author:** \(author)") }
        if let date = entry.date?.markdownValue { metadata.append("**Date:** \(date)") }
        if !entry.tags.isEmpty { metadata.append("**Tags:** \(entry.tags.joined(separator: ", "))") }
        if let category = entry.category?.markdownValue { metadata.append("**Category:** \(category)") }
        if let series = entry.seriesName?.markdownValue { metadata.append("**Series:** \(series)") }
        if let order = entry.seriesOrder { metadata.append("**Series Order:** \(order)") }
        if !metadata.isEmpty { blocks.append(metadata.joined(separator: " | ")) }
        if !entry.scriptureDescriptions.isEmpty {
            blocks.append("**Scripture:** \(entry.scriptureDescriptions.joined(separator: ", "))")
        }
        if let summary = entry.summary?.markdownValue {
            blocks.append("> **Summary:** \(summary.replacingOccurrences(of: "\n", with: "\n> "))")
        }
        if let content = entry.content.markdownValue { blocks.append(content) }
        if let footnotes = entry.footnotes?.markdownValue {
            blocks.append("### Footnotes\n\n\(footnotes)")
        }
        return blocks.joined(separator: "\n\n")
    }

    public static func rewritingFootnoteMarkers(
        in content: String,
        prefix: String,
        footnotes: [(id: String, content: String)]
    ) -> (content: String, definitions: [(id: String, content: String)]) {
        var rewritten = content
        var definitions: [(id: String, content: String)] = []
        var unattachedMarkers: [String] = []
        for footnote in footnotes {
            let identifier = "\(prefix)-\(footnote.id)"
            let localMarker = "[^\(footnote.id)]"
            let uniqueMarker = "[^\(identifier)]"
            if !rewritten.contains(localMarker) {
                unattachedMarkers.append(uniqueMarker)
            }
            rewritten = rewritten.replacingOccurrences(
                of: localMarker, with: uniqueMarker
            )
            definitions.append((identifier, footnote.content))
        }
        if !unattachedMarkers.isEmpty {
            rewritten += "\n\n" + unattachedMarkers.joined(separator: " ")
        }
        return (rewritten, definitions)
    }

    public static func footnoteDefinitions(_ footnotes: [(id: String, content: String)]) -> String {
        footnotes.map { footnote in
            let lines = footnote.content.components(separatedBy: "\n")
            return (["[^\(footnote.id)]: \(lines.first ?? "")"]
                + lines.dropFirst().map { "    \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

private extension String {
    var markdownValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
