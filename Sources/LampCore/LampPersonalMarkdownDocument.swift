import Foundation

/// Markdown document framing shared by the personal-content importers. The
/// body parser remains free to interpret notes or devotionals differently.
public enum LampPersonalMarkdownDocument {
    /// Legacy inline definitions and Obsidian callouts. Preserve their IDs so
    /// repeated markers keep pointing to the same definition after import.
    public static func extractInlineFootnotes(
        in content: String
    ) -> (body: String, footnotes: [LampVerseFootnote]) {
        let lines = content.components(separatedBy: "\n")
        let definition = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:\s*(.*)$"#)
        let callout = try! NSRegularExpression(pattern: #"^>\s*\[!footnote\]\s*(\S+)\s*$"#)
        var body: [String] = []
        var footnotes: [LampVerseFootnote] = []
        var seen = Set<String>()
        var fence = LampMarkdownCodeFence()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if fence.contains(line) {
                body.append(line)
                index += 1
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            let quote = callout.firstMatch(in: line, range: range)
            let standard = definition.firstMatch(in: line, range: range)
            guard let match = quote ?? standard,
                  let identifierRange = Range(match.range(at: 1), in: line) else {
                body.append(line)
                index += 1
                continue
            }
            let identifier = String(line[identifierRange])
            var definitionLines: [String] = []
            if standard != nil, let textRange = Range(match.range(at: 2), in: line) {
                definitionLines.append(String(line[textRange]))
            }
            index += 1
            while index < lines.count {
                let next = lines[index]
                if quote != nil, next.hasPrefix(">") {
                    if callout.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil {
                        break
                    }
                    definitionLines.append(String(next.dropFirst(next.hasPrefix("> ") ? 2 : 1)))
                } else if quote == nil, next.hasPrefix("    ") || next.hasPrefix("\t") {
                    definitionLines.append(String(next.dropFirst(next.hasPrefix("\t") ? 1 : 4)))
                } else {
                    break
                }
                index += 1
            }
            if seen.insert(identifier).inserted {
                footnotes.append(LampVerseFootnote(
                    id: identifier,
                    content: definitionLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        return (body.joined(separator: "\n"), footnotes)
    }

    public static func frontmatterLines(in markdown: String) -> [String]? {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return nil }
        return Array(lines[1..<closing])
    }

    public static func frontmatter(in markdown: String) -> (metadata: [String: String], body: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ([:], markdown) }

        var metadata: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            metadata[key] = value
        }
        return (metadata, lines[(closing + 1)...].joined(separator: "\n"))
    }

    /// Removes a trailing footnote section while retaining multiline definitions.
    /// A thematic break without footnote definitions stays in the body.
    public static func extractFootnoteDefinitions(
        in body: String
    ) -> (body: String, definitions: [String: String]) {
        let lines = body.components(separatedBy: "\n")
        guard let separator = lines.indices.reversed().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else { return (body, [:]) }
        let footnoteLines = Array(lines[(separator + 1)...])
        guard footnoteLines.contains(where: { $0.hasPrefix("[^") && $0.contains("]:") }) else {
            return (body, [:])
        }
        var hasDefinition = false
        for line in footnoteLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("[^") && line.contains("]:") {
                hasDefinition = true
            } else if !(hasDefinition && (line.hasPrefix("    ") || line.hasPrefix("\t"))) {
                return (body, [:])
            }
        }

        var definitions: [String: String] = [:]
        var index = 0
        while index < footnoteLines.count {
            let line = footnoteLines[index]
            guard line.hasPrefix("[^"),
                  let closing = line.range(of: "]:") else {
                index += 1
                continue
            }
            let identifier = String(line[line.index(line.startIndex, offsetBy: 2)..<closing.lowerBound])
            guard !identifier.isEmpty else {
                index += 1
                continue
            }
            var content = [String(line[closing.upperBound...]).trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < footnoteLines.count {
                let continuation = footnoteLines[index]
                if continuation.hasPrefix("    ") {
                    content.append(String(continuation.dropFirst(4)))
                } else if continuation.hasPrefix("\t") {
                    content.append(String(continuation.dropFirst()))
                } else if continuation.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                } else {
                    break
                }
                index += 1
            }
            definitions[identifier] = content.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (Array(lines[..<separator]).joined(separator: "\n"), definitions)
    }

    /// Keep only definitions referenced by this note, so an imported multi-note
    /// file does not attach every footnote to its last verse.
    public static func restoringFootnotes(
        in content: String,
        definitions: [String: String]
    ) -> String {
        guard !definitions.isEmpty else { return content }
        let pattern = #"\[\^([^\]]+)\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return content }
        let matches = expression.matches(in: content, range: NSRange(content.startIndex..., in: content))
        var seen = Set<String>()
        let lines = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            let identifier = String(content[range])
            guard seen.insert(identifier).inserted, let definition = definitions[identifier] else { return nil }
            let definitionLines = definition.components(separatedBy: "\n")
            let continuation = definitionLines.dropFirst().map { "    \($0)" }
            return (["[^\(identifier)]: \(definitionLines.first ?? "")"] + continuation).joined(separator: "\n")
        }
        return lines.isEmpty ? content : content + "\n\n---\n\n" + lines.joined(separator: "\n")
    }
}

/// Tracks Markdown fences while importers interpret structural lines. Examples
/// inside a code block must never become note headings or footnote definitions.
struct LampMarkdownCodeFence {
    private var marker: Character?
    private var length = 0

    mutating func contains(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return marker != nil
        }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return marker != nil }
        if marker == nil {
            marker = first
            length = run.count
        } else if marker == first, run.count >= length,
                  trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
            marker = nil
        }
        return true
    }
}

public struct LampMarkdownScripture: Equatable, Sendable {
    public let label: String?
    public let startReference: Int
    public let endReference: Int?
}

/// The subset of devotional YAML written by both apps. Nested series and
/// scripture entries are parsed before indentation is discarded.
public struct LampDevotionalFrontmatter: Equatable, Sendable {
    public var values: [String: String] = [:]
    public var tags: [String] = []
    public var series: [String: String] = [:]
    public var scriptures: [LampMarkdownScripture] = []

    public init(lines: [String]) {
        enum Section { case none, series, scriptures }
        var section: Section = .none
        var scripture: [String: String] = [:]

        func appendScripture() {
            guard let start = scripture["sv"].flatMap(Int.init) else {
                scripture = [:]
                return
            }
            scriptures.append(LampMarkdownScripture(
                label: scripture["ref"],
                startReference: start,
                endReference: scripture["ev"].flatMap(Int.init)
            ))
            scripture = [:]
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if section == .scriptures, trimmed.hasPrefix("- ") {
                appendScripture()
                let entry = Self.keyValue(String(trimmed.dropFirst(2)))
                if let entry { scripture[entry.key] = entry.value }
                continue
            }
            if line.first?.isWhitespace == true {
                guard let entry = Self.keyValue(trimmed) else { continue }
                switch section {
                case .series: series[entry.key] = entry.value
                case .scriptures: scripture[entry.key] = entry.value
                case .none: break
                }
                continue
            }
            if section == .scriptures { appendScripture() }
            guard let entry = Self.keyValue(trimmed) else {
                section = .none
                continue
            }
            switch entry.key {
            case "series": section = .series
            case "keyScriptures": section = .scriptures
            default:
                section = .none
                values[entry.key.lowercased()] = entry.value
                if entry.key == "tags" {
                    let source = entry.value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    tags = source.split(separator: ",").map {
                        Self.unquote(String($0).trimmingCharacters(in: .whitespaces))
                    }.filter { !$0.isEmpty }
                }
            }
        }
        if section == .scriptures { appendScripture() }
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return (key, unquote(value))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) else { return value }
        return String(value.dropFirst().dropLast())
    }
}
