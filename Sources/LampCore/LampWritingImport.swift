import CryptoKit
import Foundation
import LampModuleKit

/// One Markdown file offered for import as writing.
public struct LampWritingImportFile: Equatable, Sendable {
    /// Where the file sits, as `<folder>/<path inside it>`: the folder that was
    /// chosen, or the file's own folder when one file was. A writing with no
    /// `id` of its own takes its id from this, so importing the same folder
    /// again, or one file from it, finds the same writings rather than adding
    /// copies.
    public let path: String
    public let markdown: String
    /// When the file was last saved. It stands in for `lastModified` when the
    /// front matter has none: a file saved since the last import reads as
    /// newer than Lamp's copy, and a copy edited in Lamp since reads as newer
    /// than the file.
    public let modified: Date?
    public let created: Date?

    public init(path: String, markdown: String, modified: Date? = nil, created: Date? = nil) {
        self.path = path
        self.markdown = markdown
        self.modified = modified
        self.created = created
    }
}

/// What an import would do, or did, with one writing.
public struct LampWritingImportItem: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Not in the library yet.
        case create
        /// In the library, and the file is newer.
        case update
        /// In the library exactly as the file has it. Nothing is written.
        case unchanged
        /// In the library, changed there since the file was saved. Lamp's copy
        /// is kept unless the person chooses the file's.
        case conflict
        /// The file cannot be imported as it is; `errors` says why.
        case rejected
    }

    /// The file's path; a Lamp Markdown export holding several writings adds
    /// `#2`, `#3` for the second and later.
    public let id: String
    public let path: String
    public let writingID: String
    /// The id was made from `path`, because the file did not give one.
    public let idDerived: Bool
    public let title: String
    public let action: Action
    /// The fields that differ from the library's copy.
    public let changes: [String]
    public let errors: [String]
    public let warnings: [String]
    /// What Lamp tidied on the way in, said so nothing changes unseen.
    public let normalized: [String]
    /// When the library's copy last changed, for an update or a conflict.
    public let libraryModified: Date?

    /// Creates and updates are offered ticked; a conflict waits to be chosen.
    public var importsByDefault: Bool { action == .create || action == .update }
}

/// The dry run: what importing a set of files would do. Nothing is written
/// until `LampLibrary.applyWritingImport(_:selecting:)`.
public struct LampWritingImportPlan: Sendable {
    public let items: [LampWritingImportItem]
    let writings: [String: LampDevotional]

    public func count(_ action: LampWritingImportItem.Action) -> Int {
        items.filter { $0.action == action }.count
    }
}

/// What applying a plan did.
public struct LampWritingImportResult: Equatable, Sendable {
    public let imported: [LampWritingImportItem]
    /// Chosen, but not written: the library's copy changed after the plan was
    /// made, so the plan no longer says what importing would do.
    public let refused: [LampWritingImportItem]
}

public enum LampWritingImport {
    /// Folders an import never looks in: tools' own files, not writing.
    static let skippedFolders: Set<String> = ["node_modules", "venv", ".venv", "__pycache__"]
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    /// More than this many files is a folder chosen by mistake.
    public static let fileLimit = 5_000

    /// The Markdown files in a folder, or the one file chosen.
    ///
    /// A folder's `lamp-import.json`, if it has one, names the files that are
    /// writing (`{"writings": [{"file": "a.md"}]}`), so an agent can keep its
    /// working files beside the ones it means. Without one, every Markdown
    /// file in the folder and the folders inside it is offered, except hidden
    /// ones and tools' folders.
    public static func files(at url: URL) throws -> [LampWritingImportFile] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LampLibraryError.invalidPersonalContent("There is no file at \(url.path).")
        }
        guard isDirectory.boolValue else {
            guard markdownExtensions.contains(url.pathExtension.lowercased()) else {
                throw LampLibraryError.invalidStudyDataExtension
            }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return [try file(at: url, path: folder + "/" + url.lastPathComponent)]
        }

        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let rootName = root.lastPathComponent
        let manifestURL = root.appendingPathComponent("lamp-import.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            return try manifestFiles(manifestURL, root: root, rootName: rootName)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [LampWritingImportFile] = []
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedFolders.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard markdownExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard found.count < fileLimit else {
                throw LampLibraryError.invalidPersonalContent(
                    "The folder holds more than \(fileLimit) Markdown files. Choose the folder of writing inside it."
                )
            }
            let relative = relativePath(of: fileURL, in: root)
            found.append(try file(at: fileURL, path: rootName + "/" + relative))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable { let file: String }
        let writings: [Entry]
    }

    private static func manifestFiles(
        _ manifestURL: URL, root: URL, rootName: String
    ) throws -> [LampWritingImportFile] {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LampLibraryError.invalidPersonalContent(
                "lamp-import.json must be {\"writings\": [{\"file\": \"name.md\"}, …]}."
            )
        }
        return try manifest.writings.map { entry in
            let fileURL = root.appendingPathComponent(entry.file).resolvingSymlinksInPath().standardizedFileURL
            guard fileURL.path.hasPrefix(root.path + "/"),
                  markdownExtensions.contains(fileURL.pathExtension.lowercased()) else {
                throw LampLibraryError.invalidPersonalContent(
                    "lamp-import.json names \(entry.file), which is not a Markdown file in the folder."
                )
            }
            return try file(at: fileURL, path: rootName + "/" + relativePath(of: fileURL, in: root))
        }
    }

    private static func relativePath(of fileURL: URL, in root: URL) -> String {
        let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : fileURL.lastPathComponent
    }

    private static func file(at url: URL, path: String) throws -> LampWritingImportFile {
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LampLibraryError.invalidPersonalContent("\(path) is not UTF-8 text.")
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return LampWritingImportFile(
            path: path,
            markdown: markdown.replacingOccurrences(of: "\r\n", with: "\n"),
            modified: values?.contentModificationDate,
            created: values?.creationDate
        )
    }

    /// The id a writing takes from its path when it gives none: the same path
    /// gives the same id, on any Mac, in any case.
    public static func derivedID(path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        var bytes = Array(SHA256.hash(data: Data(("lamp-writing-import\u{0}" + normalized).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }

    // MARK: - Reading one file

    /// One writing read from a file, before it is compared with the library.
    struct Candidate {
        var key: String
        var path: String
        var writing: LampDevotional?
        var writingID: String
        var idDerived: Bool
        var title: String
        var errors: [String] = []
        var warnings: [String] = []
        var normalized: [String] = []
    }

    static let knownKeys: Set<String> = [
        "id", "title", "subtitle", "author", "date", "category", "tags", "summary",
        "created", "lastmodified", "source", "series", "keyscriptures",
    ]

    static func candidates(from file: LampWritingImportFile) -> [Candidate] {
        let filename = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let lines = LampPersonalMarkdownDocument.frontmatterLines(in: file.markdown)
        var metadata: [String: String] = [:]
        var body = file.markdown
        var frontmatter: LampDevotionalFrontmatter?
        var warnings: [String] = []

        if let lines {
            let document = LampPersonalMarkdownDocument.frontmatter(in: file.markdown)
            body = document.body
            let structured = LampDevotionalFrontmatter(lines: lines)
            frontmatter = structured
            for (key, value) in structured.values { metadata[key] = value }
            let unknown = lines.compactMap { line -> String? in
                guard line.first?.isWhitespace == false, !line.hasPrefix("#"),
                      let separator = line.firstIndex(of: ":") else { return nil }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                return knownKeys.contains(key.lowercased()) ? nil : key
            }
            if !unknown.isEmpty {
                warnings.append("Front matter key\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "is" : "are") not part of a writing and \(unknown.count == 1 ? "was" : "were") left out.")
            }
            for entry in structured.unresolvedScriptures {
                warnings.append("Key scripture “\(entry)” is not a reference Lamp can read, so it was left out.")
            }
        } else if file.markdown.hasPrefix("---\n") {
            warnings.append("The file starts with --- but its front matter is never closed, so it was read as prose.")
        } else if isLampMarkdownExport(body) {
            return exportCandidates(from: file, body: body, filename: filename)
        }

        var candidate = Candidate(
            key: file.path, path: file.path, writing: nil,
            writingID: "", idDerived: false, title: ""
        )
        candidate.warnings = warnings

        // The title: the front matter's, else a heading the file opens with,
        // else the file's name, which is said.
        var title = metadata["title"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if let heading = leadingTitleHeading(in: body) {
            if title.isEmpty {
                title = heading.title
                body = heading.rest
                candidate.normalized.append("Title taken from the heading the file opens with.")
            } else if heading.title == title {
                body = heading.rest
                candidate.normalized.append("Removed the opening heading, which repeated the title.")
            }
        }
        if title.isEmpty {
            title = filename
            candidate.warnings.append("No title in the file, so its name, “\(filename)”, is the title.")
        }
        candidate.title = title

        if let id = metadata["id"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            candidate.writingID = id
            if !LampModuleIdentifier.isValid(id) {
                candidate.errors.append("The id “\(id)” may use \(LampModuleIdentifier.advice).")
            }
        } else {
            candidate.writingID = derivedID(path: file.path)
            candidate.idDerived = true
        }

        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            candidate.errors.append("The writing has no text.")
            return [candidate]
        }

        var lowercased: [String: String] = [:]
        for (key, value) in metadata { lowercased[key.lowercased()] = value }
        let draft = LampPersonalMarkdownParser.devotional(
            title: title, content: content, metadata: lowercased, frontmatter: frontmatter
        )
        if let written = lowercased["category"]?.trimmingCharacters(in: .whitespaces),
           !written.isEmpty, let category = draft.category, category != written {
            candidate.normalized.append("Category “\(written)” filed as “\(category)”.")
        }
        if let date = draft.date, !isISODate(date) {
            candidate.warnings.append("The date “\(date)” is not YYYY-MM-DD; it is kept as written.")
        }
        var created = file.created
        var modified = file.modified
        for (key, name) in [("created", "created"), ("lastmodified", "lastModified")] {
            guard let value = lowercased[key]?.nilIfEmpty else { continue }
            guard let date = timestamp(value) else {
                candidate.warnings.append("\(name) “\(value)” is not a date Lamp can read; the file's own date is used.")
                continue
            }
            if key == "created" { created = date } else { modified = date }
        }
        candidate.writing = LampDevotional(
            id: candidate.writingID,
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
            created: created,
            lastModified: modified,
            isEditable: true
        )
        check(&candidate)
        return [candidate]
    }

    /// Lamp's own Markdown export of several writings: a title heading, a
    /// rule, then each writing under `##`, ruled off from the next.
    static func isLampMarkdownExport(_ body: String) -> Bool {
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.count >= 3 && lines[0].hasPrefix("# ") && lines[1] == "---" && lines[2].hasPrefix("## ")
    }

    private static func exportCandidates(
        from file: LampWritingImportFile, body: String, filename: String
    ) -> [Candidate] {
        let drafts: [LampPersonalMarkdownParser.DevotionalDraft]
        do {
            drafts = try LampPersonalMarkdownParser.devotionals(from: body, filename: filename)
        } catch {
            return [Candidate(
                key: file.path, path: file.path, writing: nil,
                writingID: derivedID(path: file.path), idDerived: true, title: filename,
                errors: ["\(error.localizedDescription)"]
            )]
        }
        var seen: [String: Int] = [:]
        return drafts.enumerated().map { index, draft in
            seen[draft.title, default: 0] += 1
            let occurrence = seen[draft.title]!
            let identity = file.path + "#" + draft.title + (occurrence > 1 ? "#\(occurrence)" : "")
            var candidate = Candidate(
                key: index == 0 ? file.path : file.path + "#\(index + 1)",
                path: file.path, writing: nil,
                writingID: derivedID(path: identity), idDerived: true, title: draft.title
            )
            candidate.normalized.append("Read as one of \(drafts.count) writings in a Lamp Markdown export.")
            candidate.writing = LampDevotional(
                id: candidate.writingID,
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
                created: file.created,
                lastModified: file.modified,
                isEditable: true
            )
            check(&candidate)
            return candidate
        }
    }

    /// `# Title` as the first thing in the file.
    static func leadingTitleHeading(in body: String) -> (title: String, rest: String)? {
        var lines = body.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first, first.hasPrefix("# ") else { return nil }
        let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (title, lines.dropFirst().joined(separator: "\n"))
    }

    // MARK: - Checks on the text

    private static let lampLink = try! NSRegularExpression(pattern: #"\]\((lampbible://[^)\s]+)\)"#)
    private static let mediaLink = try! NSRegularExpression(
        pattern: #"\]\(((?:media/|lamp-media://)[^)\s]*)\)"#
    )
    private static let fileLink = try! NSRegularExpression(
        pattern: #"\]\(([^)\s:#]+\.(?:md|markdown))(?:#[^)\s]*)?\)"#, options: [.caseInsensitive]
    )
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"</?([a-zA-Z][a-zA-Z0-9]*)(?:\s[^<>]*)?/?>"#
    )
    private static let footnoteMarker = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#)

    static func check(_ candidate: inout Candidate) {
        guard let writing = candidate.writing else { return }
        let prose = proseOutsideCode(writing.content)
        let range = NSRange(prose.startIndex..., in: prose)
        func captures(_ expression: NSRegularExpression) -> [String] {
            expression.matches(in: prose, range: range).compactMap {
                Range($0.range(at: 1), in: prose).map { String(prose[$0]) }
            }
        }

        for link in Set(captures(lampLink)).sorted() {
            guard let url = URL(string: link), let parsed = LampApplicationLink(url: url) else {
                candidate.errors.append("\(link) is not a link Lamp can open.")
                continue
            }
            let references: [Int]
            switch parsed {
            case .verse(let reference, let end, _), .reading(let reference, let end, _):
                references = [reference] + (end.map { [$0] } ?? [])
            case .reader(let reference, _):
                references = reference.map { [$0] } ?? []
            default:
                references = []
            }
            if let bad = references.first(where: { !isCanonicalVerse($0) }) {
                candidate.errors.append("\(link) names \(bad), which is not a verse in the Bible.")
            }
        }
        let media = Set(captures(mediaLink)).sorted()
        if !media.isEmpty {
            candidate.errors.append("Pictures and audio cannot be imported yet: \(media.joined(separator: ", ")).")
        }
        let files = Set(captures(fileLink)).sorted()
        if !files.isEmpty {
            candidate.warnings.append("Links to other files will not open in Lamp: \(files.prefix(5).joined(separator: ", "))\(files.count > 5 ? ", and \(files.count - 5) more" : "").")
        }
        var tags: [String] = []
        for tag in captures(htmlTag).map({ $0.lowercased() }) where !tags.contains(tag) {
            tags.append(tag)
        }
        if !tags.isEmpty {
            candidate.warnings.append("Contains HTML (\(tags.prefix(6).map { "<\($0)>" }.joined(separator: ", "))). Writing in Lamp is Markdown: make it a heading, list or quotation to be sure it shows as meant.")
        }

        let defined = Set(LampDevotionalFootnotes.numbered(
            content: writing.content, footnotes: writing.footnotes
        ).footnotes.map(\.label))
        let missing = Set(captures(footnoteMarker)).subtracting(defined).sorted()
        if !missing.isEmpty {
            candidate.warnings.append("Footnote \(missing.map { "[^\($0)]" }.joined(separator: ", ")) \(missing.count == 1 ? "has" : "have") no definition.")
        }
    }

    /// The prose with fenced code taken out, so examples in a code block are
    /// not checked as the writing's own links.
    private static func proseOutsideCode(_ content: String) -> String {
        var fence = LampMarkdownCodeFence()
        return content.components(separatedBy: "\n")
            .filter { !fence.contains($0) }
            .joined(separator: "\n")
    }

    static func isCanonicalVerse(_ reference: Int) -> Bool {
        let book = reference / 1_000_000
        let chapter = (reference / 1_000) % 1_000
        let verse = reference % 1_000
        guard let counts = LampCanonicalBooks.book(book)?.verseCounts,
              counts.indices.contains(chapter - 1) else { return false }
        return verse >= 0 && verse <= counts[chapter - 1]
    }

    static func isISODate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// ISO 8601 with or without a time, or seconds since 1970.
    static func timestamp(_ value: String) -> Date? {
        if let seconds = Int(value) { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: value) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: value) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: value)
    }
}

public extension LampLibrary {
    /// What importing these files would do, without writing anything.
    func planWritingImport(_ files: [LampWritingImportFile]) throws -> LampWritingImportPlan {
        var candidates = files.flatMap(LampWritingImport.candidates(from:))
        var counts: [String: Int] = [:]
        for candidate in candidates where candidate.errors.isEmpty {
            counts[candidate.writingID, default: 0] += 1
        }
        for index in candidates.indices where (counts[candidates[index].writingID] ?? 0) > 1 {
            let others = candidates.filter {
                $0.writingID == candidates[index].writingID && $0.key != candidates[index].key
            }.map(\.path)
            candidates[index].errors.append("Another file has the same id (\(others.joined(separator: ", "))).")
        }

        let existing = Dictionary(
            try personalDevotionals().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let now = Date()
        var items: [LampWritingImportItem] = []
        var writings: [String: LampDevotional] = [:]
        for candidate in candidates {
            var warnings = candidate.warnings
            var action = LampWritingImportItem.Action.rejected
            var changes: [String] = []
            var libraryModified: Date?
            if candidate.errors.isEmpty, var writing = candidate.writing {
                if writing.lastModified == nil {
                    writing = writing.withLastModified(now)
                }
                let incoming = writing.lastModified.map { Int($0.timeIntervalSince1970) }
                if let local = existing[writing.id] {
                    libraryModified = local.lastModified
                    changes = local.differingAuthoredFields(from: writing)
                    if changes.isEmpty {
                        action = .unchanged
                    } else {
                        let decision = LampSyncMerge.decide(
                            localModified: local.lastModified.map { Int($0.timeIntervalSince1970) },
                            incomingModified: incoming,
                            sameContent: false
                        )
                        action = decision == .incoming ? .update : .conflict
                    }
                } else {
                    action = .create
                    if try isPersonalDevotionalDeleted(id: writing.id, itemModified: incoming) {
                        warnings.append("This writing was deleted from Lamp; importing it brings it back.")
                    }
                }
                writings[candidate.key] = writing
            }
            items.append(LampWritingImportItem(
                id: candidate.key,
                path: candidate.path,
                writingID: candidate.writingID,
                idDerived: candidate.idDerived,
                title: candidate.title,
                action: action,
                changes: changes,
                errors: candidate.errors,
                warnings: warnings,
                normalized: candidate.normalized,
                libraryModified: libraryModified
            ))
        }
        return LampWritingImportPlan(items: items, writings: writings)
    }

    /// Writes the chosen items of a plan. Each is checked again first: one
    /// whose library copy changed after the plan was made is refused rather
    /// than overwritten, since the plan no longer describes what would happen.
    ///
    /// Importing is the person's choice, so it counts as a fresh save for
    /// sync, and brings back a writing that was deleted. A chosen conflict is
    /// stamped newer than both copies, so the other devices take it too
    /// (`LampSyncMerge.resolutionTimestamp`).
    @discardableResult
    func applyWritingImport(
        _ plan: LampWritingImportPlan,
        selecting itemIDs: Set<String>
    ) throws -> LampWritingImportResult {
        let existing = Dictionary(
            try personalDevotionals().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var imported: [LampWritingImportItem] = []
        var refused: [LampWritingImportItem] = []
        var saved: [String] = []
        for item in plan.items where itemIDs.contains(item.id) {
            guard [.create, .update, .conflict].contains(item.action),
                  let writing = plan.writings[item.id] else { continue }
            let local = existing[writing.id]
            guard local?.lastModified == item.libraryModified,
                  (local == nil) == (item.action == .create) else {
                refused.append(item)
                continue
            }
            var stamped = writing
            if item.action == .conflict, let local {
                let resolved = LampSyncMerge.resolutionTimestamp(
                    localModified: local.lastModified.map { Int($0.timeIntervalSince1970) },
                    incomingModified: writing.lastModified.map { Int($0.timeIntervalSince1970) },
                    now: Int(Date().timeIntervalSince1970)
                ) ?? Int(Date().timeIntervalSince1970)
                stamped = writing.withLastModified(Date(timeIntervalSince1970: TimeInterval(resolved)))
            }
            try savePersonalDevotional(stamped, preserveLastModified: true)
            saved.append(writing.id)
            imported.append(item)
        }
        try recordPersonalDevotionalsPresent(saved)
        return LampWritingImportResult(imported: imported, refused: refused)
    }
}

extension LampDevotional {
    /// The fields a person writes that differ from `other`'s, by name. An
    /// empty field and a missing one are the same: export leaves out empty
    /// fields, so writing that stored "" must still match its own copy coming
    /// back. Import and sync compare with this one list, so they cannot drift.
    func differingAuthoredFields(from other: LampDevotional) -> [String] {
        func same(_ a: String?, _ b: String?) -> Bool {
            a?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                == b?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        var fields: [String] = []
        if title != other.title { fields.append("title") }
        if !same(subtitle, other.subtitle) { fields.append("subtitle") }
        if !same(author, other.author) { fields.append("author") }
        if !same(date, other.date) { fields.append("date") }
        if tags != other.tags { fields.append("tags") }
        if !same(category, other.category) { fields.append("category") }
        if !same(seriesName, other.seriesName) { fields.append("series") }
        if seriesOrder != other.seriesOrder { fields.append("series order") }
        if keyScriptures != other.keyScriptures { fields.append("key scriptures") }
        if !same(summary, other.summary) { fields.append("summary") }
        if content != other.content { fields.append("text") }
        if !LampSyncJSONComparison.sameValue(footnotes, other.footnotes) { fields.append("footnotes") }
        return fields
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
