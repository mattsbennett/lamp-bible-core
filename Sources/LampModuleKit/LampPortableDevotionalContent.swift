import Foundation

/// A read projection of the structured devotional content used by iOS.
/// The JSON remains the source of truth; this Markdown is for clients whose
/// reader already renders Markdown. Unknown fields are left in the JSON.
public enum LampPortableDevotionalContent {
    public static func markdown(from contentJSON: String) -> String? {
        if let plain = LampPortableDevotionalMedia.plainMarkdown(from: contentJSON) {
            return plain
        }
        guard let data = contentJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let blocks: [String]
        if let values = value as? [[String: Any]] {
            blocks = values.compactMap(renderBlock)
        } else if let structured = value as? [String: Any] {
            guard structured["introduction"] != nil || structured["sections"] != nil
                    || structured["conclusion"] != nil else { return nil }
            blocks = renderStructured(structured)
        } else {
            return nil
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderStructured(_ value: [String: Any]) -> [String] {
        var blocks: [String] = []
        if let introduction = value["introduction"] as? [[String: Any]] {
            blocks += introduction.compactMap(renderBlock)
        }
        if let sections = value["sections"] as? [[String: Any]] {
            for section in sections { blocks += renderSection(section) }
        }
        if let conclusion = value["conclusion"] as? [[String: Any]] {
            blocks += conclusion.compactMap(renderBlock)
        }
        return blocks
    }

    private static func renderSection(_ section: [String: Any]) -> [String] {
        var blocks: [String] = []
        if let title = section["title"] as? String, !title.isEmpty {
            let level = min(6, max(1, section["level"] as? Int ?? 2))
            blocks.append("\(String(repeating: "#", count: level)) \(title)")
        }
        if let values = section["blocks"] as? [[String: Any]] {
            blocks += values.compactMap(renderBlock)
        }
        if let sections = section["subsections"] as? [[String: Any]] {
            for nested in sections { blocks += renderSection(nested) }
        }
        return blocks
    }

    private static func renderBlock(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        let content = annotatedText(block["content"])
        switch type {
        case "paragraph":
            return content
        case "heading":
            guard let content else { return nil }
            let level = min(6, max(1, block["level"] as? Int ?? 1))
            return "\(String(repeating: "#", count: level)) \(content)"
        case "blockquote":
            guard let content else { return nil }
            let lines = content.components(separatedBy: .newlines)
            return lines.enumerated().map { index, line in
                "> \(line)\(index < lines.count - 1 ? "  " : "")"
            }.joined(separator: "\n")
        case "list":
            guard let items = block["items"] as? [[String: Any]] else { return nil }
            return renderList(
                items, numbered: block["listType"] as? String == "numbered", depth: 0
            ).joined(separator: "\n")
        case "image":
            guard let id = block["mediaId"] as? String else { return nil }
            let caption = plainCaption(block["caption"]) ?? ""
            return "![\(caption)](media/\(id))"
        case "audio":
            guard let id = block["mediaId"] as? String else { return nil }
            let caption = plainCaption(block["caption"]) ?? "Audio"
            return "[\(caption)](media/\(id))"
        case "table":
            guard let table = block["tableData"] as? [String: Any],
                  let headers = table["headers"] as? [String] else { return nil }
            let rows = table["rows"] as? [[String]] ?? []
            return ([
                "| " + headers.joined(separator: " | ") + " |",
                "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |",
            ] + rows.map { "| " + $0.joined(separator: " | ") + " |" })
                .joined(separator: "\n")
        default:
            return content
        }
    }

    private static func renderList(
        _ items: [[String: Any]], numbered: Bool, depth: Int
    ) -> [String] {
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let marker = numbered ? "\(index + 1)." : "-"
            lines.append("\(String(repeating: "  ", count: depth))\(marker) \(annotatedText(item["content"]) ?? "")")
            if let children = item["children"] as? [[String: Any]] {
                lines += renderList(children, numbered: numbered, depth: depth + 1)
            }
        }
        return lines
    }

    private static func plainCaption(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? [String: Any])?["text"] as? String
    }

    private static func annotatedText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any],
              let text = object["text"] as? String else { return nil }
        let annotations = object["annotations"] as? [[String: Any]] ?? []
        let footnotes = object["footnote_refs"] as? [[String: Any]] ?? []
        guard !annotations.isEmpty || !footnotes.isEmpty else { return text }

        // iOS stores offsets in Swift Character units (`String.count`).
        let characters = Array(text)
        var openings: [Int: [String]] = [:]
        var closings: [Int: [String]] = [:]
        for annotation in annotations {
            guard let start = annotation["start"] as? Int,
                  let end = annotation["end"] as? Int,
                  start >= 0, start < end, end <= characters.count,
                  let wrapper = annotationWrapper(annotation) else { continue }
            openings[start, default: []].append(wrapper.open)
            closings[end, default: []].insert(wrapper.close, at: 0)
        }
        var markers: [Int: [String]] = [:]
        for footnote in footnotes {
            guard let offset = footnote["offset"] as? Int,
                  let id = footnote["id"] as? String,
                  offset >= 0, offset <= characters.count else { continue }
            markers[offset, default: []].append("[^\(id)]")
        }
        var result = ""
        for index in 0...characters.count {
            result += (closings[index] ?? []).joined()
            result += (markers[index] ?? []).joined()
            result += (openings[index] ?? []).joined()
            if index < characters.count { result.append(characters[index]) }
        }
        return result
    }

    private static func annotationWrapper(
        _ annotation: [String: Any]
    ) -> (open: String, close: String)? {
        guard let type = annotation["type"] as? String else { return nil }
        let data = annotation["data"] as? [String: Any] ?? [:]
        switch type {
        case "emphasis":
            switch data["style"] as? String {
            case "bold": return ("**", "**")
            case "italic": return ("*", "*")
            default: return nil
            }
        case "scripture":
            guard let start = data["sv"] as? Int else { return nil }
            let end = data["ev"] as? Int
            let url = end.map { "lampbible://verse/\(start)/\($0)" }
                ?? "lampbible://verse/\(start)"
            return ("[", "](\(url))")
        case "strongs":
            guard let key = data["strongs"] as? String else { return nil }
            return ("[", "](lampbible://strongs/\(key))")
        case "link":
            guard let url = data["url"] as? String else { return nil }
            return ("[", "](\(url))")
        default:
            return nil
        }
    }
}
