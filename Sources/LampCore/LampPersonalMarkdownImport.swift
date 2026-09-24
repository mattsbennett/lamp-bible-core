import Foundation

public enum LampPersonalMarkdownKind: Sendable {
    case notes
    case devotionals
}

public struct LampPersonalMarkdownImportResult: Equatable, Sendable {
    public let kind: LampPersonalMarkdownKind
    public let importedCount: Int

    public init(kind: LampPersonalMarkdownKind, importedCount: Int) {
        self.kind = kind
        self.importedCount = importedCount
    }
}

public extension LampLibrary {
    /// Imports editable personal content from Markdown. Notes use reference
    /// headings such as `## Chapter 1` and `### 1:1`; devotionals use YAML
    /// frontmatter or `## Title` headings, matching Lamp Bible's Markdown exports.
    func importPersonalMarkdown(
        from sourceURL: URL,
        as kind: LampPersonalMarkdownKind
    ) throws -> LampPersonalMarkdownImportResult {
        guard ["md", "markdown"].contains(sourceURL.pathExtension.lowercased()) else {
            throw LampLibraryError.invalidStudyDataExtension
        }

        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let markdown = try String(contentsOf: sourceURL, encoding: .utf8)
        let filename = sourceURL.deletingPathExtension().lastPathComponent

        switch kind {
        case .notes:
            let drafts = try LampPersonalMarkdownParser.notes(
                from: markdown,
                filename: filename
            )
            for draft in drafts {
                _ = try setPersonalVerseNote(
                    reference: draft.reference,
                    content: draft.content,
                    verseReferences: draft.verseReferences
                )
            }
            return LampPersonalMarkdownImportResult(kind: kind, importedCount: drafts.count)

        case .devotionals:
            let drafts = try LampPersonalMarkdownParser.devotionals(
                from: markdown,
                filename: filename
            )
            for draft in drafts {
                _ = try savePersonalDevotional(LampDevotional(
                    id: UUID().uuidString,
                    moduleID: "personal-devotionals",
                    moduleName: "My Writing",
                    title: draft.title,
                    author: draft.author,
                    date: draft.date,
                    tags: draft.tags,
                    category: draft.category,
                    summary: draft.summary,
                    content: draft.content,
                    created: Date(),
                    lastModified: Date(),
                    isEditable: true
                ))
            }
            return LampPersonalMarkdownImportResult(kind: kind, importedCount: drafts.count)
        }
    }
}

private enum LampPersonalMarkdownParser {
    struct NoteDraft {
        let reference: Int
        let verseReferences: [Int]
        let content: String
    }

    struct DevotionalDraft {
        let title: String
        let author: String?
        let date: String?
        let tags: [String]
        let category: String?
        let summary: String?
        let content: String
    }

    static func notes(from markdown: String, filename: String) throws -> [NoteDraft] {
        let (metadata, body) = frontmatter(in: markdown)
        var currentBook = metadata["book"] ?? bookName(from: filename)
        var currentChapter: Int?
        var currentRange: LampAgentReferenceRange?
        var contentLines: [String] = []
        var drafts: [NoteDraft] = []

        func flush() {
            guard let range = currentRange else {
                contentLines.removeAll()
                return
            }
            let content = contentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            contentLines.removeAll()
            guard !content.isEmpty else { return }

            let startVerse = range.start.verse ?? 0
            let reference = encodedReference(
                book: range.start.book,
                chapter: range.start.chapter,
                verse: startVerse
            )
            var references = [reference]
            if range.start.book == range.end.book,
               range.start.chapter == range.end.chapter,
               let endVerse = range.end.verse,
               endVerse >= startVerse {
                references = (startVerse...endVerse).map {
                    encodedReference(
                        book: range.start.book,
                        chapter: range.start.chapter,
                        verse: $0
                    )
                }
            }
            drafts.append(NoteDraft(
                reference: reference,
                verseReferences: references,
                content: content
            ))
        }

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let heading = markdownHeading(trimmed)
            let candidate = heading?.text ?? bracketedReference(trimmed)

            if let candidate,
               let range = completeReference(candidate, currentBook: currentBook) {
                flush()
                currentBook = LampBibleReferenceFormatter.bookName(range.start.book)
                currentChapter = range.start.chapter
                currentRange = range
                continue
            }

            if let heading {
                if let chapter = labeledNumber("chapter", in: heading.text) {
                    flush()
                    currentChapter = chapter
                    currentRange = nil
                    continue
                }

                if let book = recognizedBookName(heading.text) {
                    flush()
                    currentBook = book
                    currentChapter = nil
                    currentRange = nil
                    continue
                }

                if let currentBook, let currentChapter,
                   isIntroductionHeading(heading.text),
                   let range = try? LampReferenceParser.parse("\(currentBook) \(currentChapter)") {
                    flush()
                    currentRange = range
                    continue
                }

                if let currentBook, let currentChapter,
                   let verses = verseNumbers(in: heading.text),
                   let range = try? LampReferenceParser.parse(
                       "\(currentBook) \(currentChapter):\(verses.start)"
                           + (verses.end.map { "-\($0)" } ?? "")
                   ) {
                    flush()
                    currentRange = range
                    continue
                }
            }

            if currentRange != nil {
                contentLines.append(line)
            }
        }
        flush()

        guard !drafts.isEmpty else {
            throw LampLibraryError.invalidPersonalContent(
                "No verse-linked notes were found in the Markdown file."
            )
        }
        return drafts
    }

    static func devotionals(from markdown: String, filename: String) throws -> [DevotionalDraft] {
        let (metadata, body) = frontmatter(in: markdown)
        if let title = metadata["title"]?.nilIfBlank {
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw LampLibraryError.invalidPersonalContent(
                    "The Markdown devotional has no content."
                )
            }
            return [devotional(
                title: title,
                content: content,
                metadata: metadata
            )]
        }

        var drafts: [DevotionalDraft] = []
        var currentTitle: String?
        var currentMetadata: [String: String] = [:]
        var contentLines: [String] = []

        func flush() {
            guard let currentTitle else {
                contentLines.removeAll()
                return
            }
            let content = contentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            contentLines.removeAll()
            guard !content.isEmpty else { return }
            drafts.append(devotional(
                title: currentTitle,
                content: content,
                metadata: currentMetadata
            ))
            currentMetadata = [:]
        }

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## "), !trimmed.hasPrefix("### ") {
                flush()
                currentTitle = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if currentTitle != nil, parseInlineMetadata(trimmed, into: &currentMetadata) {
                continue
            }
            if currentTitle != nil, trimmed != "---" {
                contentLines.append(line)
            }
        }
        flush()

        if drafts.isEmpty {
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw LampLibraryError.invalidPersonalContent(
                    "The Markdown devotional has no content."
                )
            }
            drafts = [devotional(title: filename, content: content, metadata: metadata)]
        }
        return drafts
    }

    private static func devotional(
        title: String,
        content: String,
        metadata: [String: String]
    ) -> DevotionalDraft {
        DevotionalDraft(
            title: title,
            author: metadata["author"]?.nilIfBlank,
            date: metadata["date"]?.nilIfBlank,
            tags: commaSeparated(metadata["tags"]),
            category: metadata["category"]?.nilIfBlank,
            summary: metadata["summary"]?.nilIfBlank,
            content: content
        )
    }

    private static func frontmatter(in markdown: String) -> ([String: String], String) {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ([:], markdown) }

        var metadata: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
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

    private static func parseInlineMetadata(
        _ line: String,
        into metadata: inout [String: String]
    ) -> Bool {
        guard line.contains("**Date:**") || line.contains("**Tags:**") else { return false }
        for component in line.components(separatedBy: "|") {
            let value = component.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("**Date:**") {
                metadata["date"] = String(value.dropFirst("**Date:**".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("**Tags:**") {
                metadata["tags"] = String(value.dropFirst("**Tags:**".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return true
    }

    private static func markdownHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6,
              line.dropFirst(hashes.count).first == " " else { return nil }
        return (
            hashes.count,
            String(line.dropFirst(hashes.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func bracketedReference(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return nil }
        return String(line.dropFirst().dropLast())
    }

    private static func completeReference(
        _ candidate: String,
        currentBook: String?
    ) -> LampAgentReferenceRange? {
        let cleaned = candidate
            .replacingOccurrences(of: #"^(?:Verses?|Reference):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = try? LampReferenceParser.parse(cleaned), range.start.verse != nil {
            return range
        }
        guard let currentBook,
              cleaned.range(of: #"^\d+:\d+(?:-\d+(?::\d+)?)?$"#, options: .regularExpression) != nil,
              let range = try? LampReferenceParser.parse("\(currentBook) \(cleaned)") else {
            return nil
        }
        return range
    }

    private static func recognizedBookName(_ candidate: String) -> String? {
        let cleaned = candidate
            .replacingOccurrences(of: #"\s+Notes$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = try? LampReferenceParser.parse("\(cleaned) 1:1") else { return nil }
        return LampBibleReferenceFormatter.bookName(range.start.book)
    }

    private static func bookName(from filename: String) -> String? {
        recognizedBookName(filename.replacingOccurrences(of: "_", with: " "))
    }

    private static func labeledNumber(_ label: String, in value: String) -> Int? {
        let pattern = "^\(label)\\s+(\\d+)$"
        guard let match = value.firstMatch(for: pattern), match.count == 1 else { return nil }
        return Int(match[0])
    }

    private static func verseNumbers(in value: String) -> (start: Int, end: Int?)? {
        guard let match = value.firstMatch(for: #"^Verses?\s+(\d+)(?:-(\d+))?$"#, caseInsensitive: true),
              let start = Int(match[0]) else { return nil }
        return (start, match.count > 1 ? Int(match[1]) : nil)
    }

    private static func isIntroductionHeading(_ value: String) -> Bool {
        ["introduction", "general notes"].contains(value.lowercased())
    }

    private static func encodedReference(book: Int, chapter: Int, verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    private static func commaSeparated(_ value: String?) -> [String] {
        value?.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func firstMatch(for pattern: String, caseInsensitive: Bool = false) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let result = expression.firstMatch(
                  in: self,
                  range: NSRange(startIndex..., in: self)
              ), result.range == NSRange(startIndex..., in: self) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let range = Range(result.range(at: index), in: self) else { return nil }
            return String(self[range])
        }
    }
}
