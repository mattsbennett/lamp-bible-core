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
                    title: draft.title,
                    content: draft.content,
                    verseReferences: draft.verseReferences,
                    footnotes: draft.footnotes
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
                    subtitle: draft.subtitle,
                    author: draft.author,
                    date: draft.date,
                    tags: draft.tags,
                    category: draft.category,
                    seriesName: draft.seriesName,
                    seriesOrder: draft.seriesOrder,
                    keyScriptures: draft.keyScriptures,
                    summary: draft.summary,
                    content: draft.content,
                    footnotes: draft.footnotes,
                    created: Date(),
                    lastModified: Date(),
                    isEditable: true
                ))
            }
            return LampPersonalMarkdownImportResult(kind: kind, importedCount: drafts.count)
        }
    }
}

public enum LampPersonalMarkdownParser {
    struct NoteDraft {
        let reference: Int
        let verseReferences: [Int]
        let title: String?
        let content: String
        let footnotes: [LampVerseFootnote]
    }

    public struct DevotionalDraft {
        public let title: String
        public let subtitle: String?
        public let author: String?
        public let date: String?
        public let tags: [String]
        public let category: String?
        public let seriesName: String?
        public let seriesOrder: Int?
        public let keyScriptures: [LampScriptureLink]
        public let summary: String?
        public let content: String
        public let footnotes: String?
    }

    static func notes(from markdown: String, filename: String) throws -> [NoteDraft] {
        let (metadata, body) = frontmatter(in: markdown)
        let extracted = LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: body)
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
            let parsed = noteContent(content, definitions: extracted.definitions)

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
            } else if range.start.book == range.end.book,
                      let endVerse = range.end.verse {
                references.append(encodedReference(
                    book: range.end.book,
                    chapter: range.end.chapter,
                    verse: endVerse
                ))
            }
            drafts.append(NoteDraft(
                reference: reference,
                verseReferences: references,
                title: parsed.title,
                content: parsed.body,
                footnotes: parsed.footnotes
            ))
        }

        for line in extracted.body.components(separatedBy: .newlines) {
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

    private static func noteContent(
        _ raw: String, definitions: [String: String]
    ) -> (title: String?, body: String, footnotes: [LampVerseFootnote]) {
        var lines = raw.components(separatedBy: "\n")
        var title: String?
        if let first = lines.first, first.hasPrefix("**Title:**") {
            title = String(first.dropFirst("**Title:**".count))
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            lines.removeFirst()
        }
        var footnotes: [LampVerseFootnote] = []
        if let heading = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "### Footnotes"
        }) {
            var parsed: [LampVerseFootnote] = []
            for line in lines[(heading + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- **"),
                      let separator = trimmed.range(of: ":**") else { continue }
                let id = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<separator.lowerBound])
                let content = String(trimmed[separator.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { parsed.append(LampVerseFootnote(id: id, content: content)) }
            }
            if !parsed.isEmpty {
                footnotes += parsed
                lines = Array(lines[..<heading])
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definitions.isEmpty else { return (title, body, footnotes) }
        let pattern = #"\[\^([^\]]+)\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return (title, body, footnotes)
        }
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var seen = Set(footnotes.map(\.id))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            let id = String(body[range])
            if seen.insert(id).inserted, let content = definitions[id] {
                footnotes.append(LampVerseFootnote(id: id, content: content))
            }
        }
        return (title, body, footnotes)
    }

    public static func devotionals(from markdown: String, filename: String) throws -> [DevotionalDraft] {
        let (metadata, body) = frontmatter(in: markdown)
        if let title = metadata["title"]?.nilIfBlank {
            let structured = LampPersonalMarkdownDocument.frontmatterLines(in: markdown)
                .map(LampDevotionalFrontmatter.init(lines:))
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw LampLibraryError.invalidPersonalContent(
                    "The Markdown devotional has no content."
                )
            }
            return [devotional(
                title: title,
                content: content,
                metadata: metadata,
                frontmatter: structured
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

        let lines = body.components(separatedBy: .newlines)
        let usesEntrySeparators = lines.prefix(while: {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("## ")
        }).contains { $0.trimmingCharacters(in: .whitespaces) == "---" }
        var pendingSeparator = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if usesEntrySeparators, trimmed == "---" {
                pendingSeparator = true
                continue
            }
            if pendingSeparator, trimmed.isEmpty { continue }
            if trimmed.hasPrefix("## "), !trimmed.hasPrefix("### "),
               currentTitle == nil || !usesEntrySeparators || pendingSeparator {
                flush()
                currentTitle = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSeparator = false
                continue
            }
            if pendingSeparator, currentTitle != nil {
                contentLines.append("---")
                pendingSeparator = false
            }
            if currentTitle != nil, parseInlineMetadata(trimmed, into: &currentMetadata) {
                continue
            }
            if currentTitle != nil, contentLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
               trimmed.hasPrefix("*"), trimmed.hasSuffix("*"), !trimmed.hasPrefix("**"),
               trimmed.count > 2 {
                currentMetadata["subtitle"] = String(trimmed.dropFirst().dropLast())
                continue
            }
            if currentTitle != nil, trimmed.hasPrefix("> **Summary:**") {
                currentMetadata["summary"] = String(trimmed.dropFirst("> **Summary:**".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if currentTitle != nil, currentMetadata["summary"] != nil,
               contentLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
               trimmed.hasPrefix("> ") {
                currentMetadata["summary"]! += "\n" + String(trimmed.dropFirst(2))
                continue
            }
            if currentTitle != nil, trimmed != "---" || usesEntrySeparators {
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
        metadata: [String: String],
        frontmatter: LampDevotionalFrontmatter? = nil
    ) -> DevotionalDraft {
        let (body, footnotes) = devotionalFootnotes(in: content)
        let (summary, mainBody) = devotionalSummary(in: body)
        return DevotionalDraft(
            title: title,
            subtitle: metadata["subtitle"]?.nilIfBlank,
            author: metadata["author"]?.nilIfBlank,
            date: metadata["date"]?.nilIfBlank,
            tags: frontmatter?.tags ?? commaSeparated(metadata["tags"]),
            category: metadata["category"]?.nilIfBlank,
            seriesName: frontmatter?.series["name"] ?? metadata["series"]?.nilIfBlank,
            seriesOrder: frontmatter?.series["order"].flatMap(Int.init)
                ?? metadata["series order"].flatMap(Int.init),
            keyScriptures: frontmatter?.scriptures.map {
                LampScriptureLink(
                    text: $0.label, startReference: $0.startReference,
                    endReference: $0.endReference
                )
            } ?? commaSeparated(metadata["scripture"]).compactMap { value in
                guard let range = try? LampReferenceParser.parse(value),
                      let start = range.start.reference else { return nil }
                return LampScriptureLink(
                    text: value, startReference: start, endReference: range.end.reference
                )
            },
            summary: metadata["summary"]?.nilIfBlank ?? summary,
            content: mainBody,
            footnotes: footnotes
        )
    }

    private static func devotionalSummary(in content: String) -> (summary: String?, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("## summary\n") else { return (nil, trimmed) }
        let lines = trimmed.components(separatedBy: "\n")
        let summaryStart = lines.indices.dropFirst().first(where: {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? lines.count
        let summaryEnd = lines.indices.dropFirst(summaryStart).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).isEmpty || lines[$0].hasPrefix("## ")
        }) ?? lines.count
        let summary = lines[summaryStart..<summaryEnd].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = lines[summaryEnd...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary.nilIfBlank, remaining.isEmpty ? trimmed : remaining)
    }

    private static func devotionalFootnotes(in content: String) -> (content: String, footnotes: String?) {
        let extracted = LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: content)
        if !extracted.definitions.isEmpty {
            let definitions = extracted.definitions.sorted { $0.key < $1.key }.map {
                (id: $0.key, content: $0.value)
            }
            return (
                extracted.body.trimmingCharacters(in: .whitespacesAndNewlines),
                LampPersonalMarkdownWriter.footnoteDefinitions(definitions)
            )
        }
        guard let range = content.range(of: "\n### Footnotes\n", options: .backwards) else {
            return (content, nil)
        }
        let footnotes = String(content[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard footnotes.components(separatedBy: .newlines).contains(where: {
            $0.hasPrefix("[^") && $0.contains("]:")
                || $0.trimmingCharacters(in: .whitespaces).hasPrefix("- **")
        }) else { return (content, nil) }
        return (String(content[..<range.lowerBound]), footnotes)
    }

    private static func frontmatter(in markdown: String) -> ([String: String], String) {
        let document = LampPersonalMarkdownDocument.frontmatter(in: markdown)
        return (Dictionary(uniqueKeysWithValues: document.metadata.map {
            ($0.key.lowercased(), $0.value)
        }), document.body)
    }

    private static func parseInlineMetadata(
        _ line: String,
        into metadata: inout [String: String]
    ) -> Bool {
        let names = ["Author", "Date", "Tags", "Category", "Series", "Series Order", "Scripture"]
        guard names.contains(where: { line.contains("**\($0):**") }) else { return false }
        for component in line.components(separatedBy: "|") {
            let value = component.trimmingCharacters(in: .whitespaces)
            for name in names {
                let prefix = "**\(name):**"
                if value.hasPrefix(prefix) {
                    metadata[name.lowercased()] = String(value.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
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
