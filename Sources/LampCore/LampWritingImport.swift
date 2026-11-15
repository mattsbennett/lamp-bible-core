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
    /// The folders above the one chosen, nearest first. A writing imported
    /// before from a folder further up took its id from a longer path; these
    /// let the same file, imported alone or from a folder inside that one,
    /// find it again rather than become a copy.
    public let ancestry: [String]
    /// The pictures and recordings its text links to, by the link as
    /// written, found in the folder that was chosen.
    public let attachments: [String: URL]
    /// A deck delivered beside it, which becomes its deck.
    public let deck: LampWritingImportDeckFile?
    /// Why the file could not be read, when it could not: it comes back as
    /// a rejected row, so one bad file does not hide the rest of a folder.
    public let readError: String?

    public init(
        path: String, markdown: String, modified: Date? = nil, created: Date? = nil,
        ancestry: [String] = [], attachments: [String: URL] = [:],
        deck: LampWritingImportDeckFile? = nil, readError: String? = nil
    ) {
        self.readError = readError
        self.path = path
        self.markdown = markdown
        self.modified = modified
        self.created = created
        self.ancestry = ancestry
        self.attachments = attachments
        self.deck = deck
    }
}

/// A `.lampdeck` beside a writing's file: `talk.lampdeck` beside `talk.md`,
/// or one a manifest names for it.
public struct LampWritingImportDeckFile: Equatable, Sendable {
    public let path: String
    public let data: Data
    /// The folder whose `Assets` holds the pictures the deck names.
    public let assetsDirectory: URL?

    public init(path: String, data: Data, assetsDirectory: URL?) {
        self.path = path
        self.data = data
        self.assetsDirectory = assetsDirectory
    }
}

/// What an import would do, or did, with one writing.
public struct LampWritingImportItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case writing
        /// A deck delivered beside a writing, imported with it.
        case deck
    }

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
    public var kind: Kind = .writing
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

    public var canImport: Bool { [.create, .update, .conflict].contains(action) }
}

/// The dry run: what importing a set of files would do. Nothing is written
/// until `LampLibrary.applyWritingImport(_:selecting:)`.
public struct LampWritingImportPlan: Sendable {
    public let items: [LampWritingImportItem]
    let writings: [String: LampDevotional]
    /// The library's copy of each writing as the plan saw it, so applying
    /// can tell whether it has changed since, even within the same second.
    let locals: [String: LampDevotional]
    /// Items bringing back a writing deleted here.
    let restored: Set<String>
    /// The pictures and recordings each writing brings.
    let media: [String: [LampWritingImportMedia]]
    /// Each deck row's deck, ready to save.
    let decks: [String: PlannedDeck]

    /// For each writing, the links the plan made to other writings, by the
    /// writing linked to, with each link as the file wrote it, in order: put
    /// back if that writing is not there when the import is applied.
    let links: [String: [String: [String]]]

    struct PlannedDeck: Sendable {
        let deck: LampPresentationDeck
        /// Each picture the deck names, by the path it is stored under.
        let assets: [String: URL]
        /// What each picture's bytes were when planned.
        let fingerprints: [String: String]
        /// The store's copy as the plan saw it, if it had one.
        let local: LampPresentationDeck?
    }

    public func count(_ action: LampWritingImportItem.Action) -> Int {
        items.filter { $0.action == action }.count
    }

    /// The plan as an agent reads it.
    public var report: LampWritingImportReport {
        LampWritingImportReport(
            create: count(.create), update: count(.update), unchanged: count(.unchanged),
            conflict: count(.conflict), rejected: count(.rejected), items: items
        )
    }
}

/// A plan's counts and items, for an agent or a script to read.
public struct LampWritingImportReport: Codable, Equatable, Sendable {
    public let create: Int
    public let update: Int
    public let unchanged: Int
    public let conflict: Int
    public let rejected: Int
    public let items: [LampWritingImportItem]
}

/// What applying a plan did.
public struct LampWritingImportResult: Equatable, Sendable {
    public let imported: [LampWritingImportItem]
    /// Chosen, but not written: the library's copy changed after the plan was
    /// made, so the plan no longer says what importing would do.
    public let refused: [LampWritingImportItem]
    /// Chosen, but not written, because something went wrong, said item by
    /// item; the rest of the import stands.
    public let failed: [LampWritingImportFailure]
    /// Anything that went wrong after the writings were written, which the
    /// person should hear of.
    public let problems: [String]
    /// What to keep to undo this import.
    public let undo: LampWritingImportUndo
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
            let folder = url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
            return [try file(
                at: url, path: folder.lastPathComponent + "/" + url.lastPathComponent,
                ancestry: ancestry(of: folder.deletingLastPathComponent()), root: folder
            )]
        }

        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let rootName = root.lastPathComponent
        let above = ancestry(of: root.deletingLastPathComponent())
        let manifestURL = root.appendingPathComponent("lamp-import.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            return try manifestFiles(manifestURL, root: root, rootName: rootName, ancestry: above)
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
            found.append(try file(at: fileURL, path: rootName + "/" + relative, ancestry: above, root: root))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            /// A deck for this writing, if not named after it.
            let deck: String?
        }
        let writings: [Entry]
    }

    private static func manifestFiles(
        _ manifestURL: URL, root: URL, rootName: String, ancestry: [String]
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
            var deckURL: URL?
            if let deck = entry.deck {
                let candidate = root.appendingPathComponent(deck).resolvingSymlinksInPath().standardizedFileURL
                guard candidate.path.hasPrefix(root.path + "/"),
                      candidate.pathExtension.lowercased() == "lampdeck" else {
                    throw LampLibraryError.invalidPersonalContent(
                        "lamp-import.json names \(deck), which is not a .lampdeck in the folder."
                    )
                }
                deckURL = candidate
            }
            return try file(
                at: fileURL, path: rootName + "/" + relativePath(of: fileURL, in: root),
                ancestry: ancestry, root: root, deckURL: deckURL
            )
        }
    }

    private static func relativePath(of fileURL: URL, in root: URL) -> String {
        let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : fileURL.lastPathComponent
    }

    /// The folders above `folder`, nearest first, as far as eight.
    static func ancestry(of folder: URL) -> [String] {
        Array(folder.pathComponents.dropFirst().reversed().prefix(8))
    }

    private static func file(
        at url: URL, path: String, ancestry: [String], root: URL, deckURL: URL? = nil
    ) throws -> LampWritingImportFile {
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return LampWritingImportFile(path: path, markdown: "", ancestry: ancestry, readError: "\(path) is not UTF-8 text.")
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let folder = url.deletingLastPathComponent()

        // Each picture or recording the text links to, if it is a file in
        // the folder chosen. One outside it is not looked for: an import
        // brings in what was chosen.
        var attachments: [String: URL] = [:]
        _ = rewritingLinks(in: text) { _, _, target in
            guard isRelativeLink(target), mediaType(of: target) != nil || target.hasPrefix("media/"),
                  attachments[target] == nil else { return nil }
            let decoded = target.removingPercentEncoding ?? target
            let candidate = folder.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard candidate.path.hasPrefix(rootPath + "/"),
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            attachments[target] = candidate
            return nil
        }

        // Its deck: the one a manifest named, or one named after it.
        let deckFile = deckURL ?? url.deletingPathExtension().appendingPathExtension("lampdeck")
        var deck: LampWritingImportDeckFile?
        if FileManager.default.fileExists(atPath: deckFile.path) {
            deck = LampWritingImportDeckFile(
                path: (path as NSString).deletingLastPathComponent + "/" + deckFile.lastPathComponent,
                data: try Data(contentsOf: deckFile),
                assetsDirectory: deckFile.deletingLastPathComponent()
            )
        }
        return LampWritingImportFile(
            path: path,
            markdown: text,
            modified: values?.contentModificationDate,
            created: values?.creationDate,
            ancestry: ancestry,
            attachments: attachments,
            deck: deck
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

    /// The other paths a file's id may have been made from at an earlier
    /// import: shorter, as when it was imported from a folder inside this
    /// one, or alone; and longer, from a folder above. Shorter first, then
    /// longer, each nearest first. Never fewer than a folder and a name.
    static func earlierPaths(of path: String, ancestry: [String]) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        var paths: [String] = []
        if components.count > 2 {
            for drop in 1...(components.count - 2) {
                paths.append(components.dropFirst(drop).joined(separator: "/"))
            }
        }
        for count in ancestry.indices.map({ $0 + 1 }) {
            paths.append((ancestry.prefix(count).reversed() + components).joined(separator: "/"))
        }
        return paths
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
        /// Added to the path a derived id is made from: a writing's place in
        /// a Lamp export holding several.
        var identitySuffix = ""
        var ancestry: [String] = []
        /// Pictures and recordings the text links to, found beside the file.
        var found: [FoundMedia] = []
        /// The same, named once the writing's id is settled.
        var media: [LampWritingImportMedia] = []
        var deck: LampWritingImportDeckFile?
        /// Links made to other writings: the writing linked to, and each link
        /// to it as written, in order.
        var links: [String: [String]] = [:]
    }

    struct FoundMedia: Equatable, Sendable {
        let target: String
        let url: URL
        let type: LampMediaType
        let alt: String?
    }

    static let knownKeys: Set<String> = [
        "id", "title", "subtitle", "author", "date", "category", "tags", "summary",
        "created", "lastmodified", "source", "series", "keyscriptures",
    ]

    static func candidates(from file: LampWritingImportFile) -> [Candidate] {
        let filename = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let readError = file.readError {
            return [Candidate(
                key: file.path, path: file.path, writing: nil,
                writingID: derivedID(path: file.path), idDerived: true, title: filename,
                errors: [readError]
            )]
        }
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
            candidate.ancestry = file.ancestry
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
        attachMedia(&candidate, from: file)
        candidate.deck = file.deck
        check(&candidate)
        return [candidate]
    }

    /// Lamp's own Markdown export of writing: a title heading, then each
    /// writing under `##`, ruled off from the next. One writing exported
    /// alone has no rule, so it is known by the details Lamp writes under its
    /// heading (`**Author:** …`, `> **Summary:** …`). A file of the writer's
    /// own that opens `# Title` then `## Section` has neither, and is one
    /// writing.
    static func isLampMarkdownExport(_ body: String) -> Bool {
        var fence = LampMarkdownCodeFence()
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") where !fence.contains(line) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        guard lines.count >= 3, lines[0].hasPrefix("# ") else { return false }
        if lines[1] == "---" { return lines[2].hasPrefix("## ") }
        guard lines[1].hasPrefix("## ") else { return false }
        // Where Lamp writes them: the line straight under the heading, or
        // under its italic subtitle. Prose there first means it is not.
        var next = lines.dropFirst(2).makeIterator()
        guard var line = next.next() else { return false }
        if line.hasPrefix("*"), !line.hasPrefix("**"), line.hasSuffix("*"), let after = next.next() {
            line = after
        }
        return line.range(
            of: #"^(\*\*(Author|Date|Tags|Category|Series|Series Order|Scripture):\*\*|> \*\*Summary:\*\*)"#,
            options: .regularExpression
        ) != nil
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
            let suffix = "#" + draft.title + (occurrence > 1 ? "#\(occurrence)" : "")
            var candidate = Candidate(
                key: index == 0 ? file.path : file.path + "#\(index + 1)",
                path: file.path, writing: nil,
                writingID: derivedID(path: file.path + suffix), idDerived: true, title: draft.title
            )
            candidate.identitySuffix = suffix
            candidate.ancestry = file.ancestry
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
            attachMedia(&candidate, from: file)
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
    private static let libraryMediaLink = try! NSRegularExpression(
        pattern: #"\]\((lamp-media://[^)\s]*)\)"#
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
        let libraryMedia = Set(captures(libraryMediaLink)).sorted()
        if !libraryMedia.isEmpty {
            candidate.errors.append("These name media inside another Lamp library, not files here: \(libraryMedia.joined(separator: ", ")).")
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

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
    ]
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "aif", "aiff", "caf", "flac",
    ]

    static func mediaType(of target: String) -> LampMediaType? {
        let ext = ((target.split(separator: "#").first.map(String.init) ?? target) as NSString)
            .pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// A link to a file beside this one, not a web address, an anchor, a
    /// Lamp link or a path from the top of the disk.
    static func isRelativeLink(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix("#") && !target.hasPrefix("/")
            && !target.contains("://") && !target.hasPrefix("mailto:")
    }

    /// A relative link from a file at `path`, as a path in the same terms.
    static func resolve(_ target: String, from path: String) -> String {
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for component in (target.removingPercentEncoding ?? target).split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() } else { return "../" + target }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    /// A code span: a run of backticks, then anything up to the same run,
    /// across a line break but not a blank line.
    private static let inlineCode = try! NSRegularExpression(
        pattern: #"(`+)(?:(?!\n[ \t]*\n)[\s\S])+?\1"#
    )
    private static let markdownLink = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\(([^)\s]+)\)"#
    )

    /// Calls `transform` with each link outside code — whether it is a
    /// picture, its text, and its target — and puts any target it returns in
    /// the link's place. Fenced blocks are left whole, and so is inline code,
    /// which may run across a line break within its paragraph.
    static func rewritingLinks(
        in content: String,
        _ transform: (_ isImage: Bool, _ label: String, _ target: String) -> String?
    ) -> String {
        guard content.contains("](") else { return content }
        // The text in runs: fenced code kept apart from the prose around it.
        var runs: [(text: String, isCode: Bool)] = []
        var fence = LampMarkdownCodeFence()
        for line in content.components(separatedBy: "\n") {
            let isCode = fence.contains(line)
            if let last = runs.last, last.isCode == isCode {
                runs[runs.count - 1].text += "\n" + line
            } else {
                runs.append((line, isCode))
            }
        }
        return runs.map { run -> String in
            guard !run.isCode, run.text.contains("](") else { return run.text }
            let text = run.text as NSString
            let whole = NSRange(location: 0, length: text.length)
            let code = inlineCode.matches(in: run.text, range: whole).map(\.range)
            // Asked in reading order, so the first of two links to one file
            // is the one heard first; replaced from the end, so the earlier
            // ranges still hold.
            var replacements: [(NSRange, String)] = []
            for match in markdownLink.matches(in: run.text, range: whole)
            where !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                let target = text.substring(with: match.range(at: 3))
                if let replacement = transform(
                    match.range(at: 1).length > 0, text.substring(with: match.range(at: 2)), target
                ) {
                    replacements.append((match.range(at: 3), replacement))
                }
            }
            var result = run.text
            for (range, replacement) in replacements.reversed() {
                guard let range = Range(range, in: result) else { continue }
                result.replaceSubrange(range, with: replacement)
            }
            return result
        }.joined(separator: "\n")
    }

    /// The pictures and recordings a writing's text links to, found in the
    /// folder. One that is not there rejects the file.
    static func attachMedia(_ candidate: inout Candidate, from file: LampWritingImportFile) {
        guard let writing = candidate.writing else { return }
        var found: [FoundMedia] = []
        var missing: [String] = []
        _ = rewritingLinks(in: writing.content) { _, label, target in
            guard isRelativeLink(target) else { return nil }
            let type = mediaType(of: target)
            guard type != nil || target.hasPrefix("media/") else { return nil }
            guard let url = file.attachments[target], let kind = type ?? mediaType(of: url.lastPathComponent) else {
                if !missing.contains(target) { missing.append(target) }
                return nil
            }
            if !found.contains(where: { $0.target == target }) {
                let alt = label.trimmingCharacters(in: .whitespaces)
                found.append(FoundMedia(target: target, url: url, type: kind, alt: alt.isEmpty ? nil : alt))
            }
            return nil
        }
        if !missing.isEmpty {
            candidate.errors.append("Pictures or recordings not found in the folder: \(missing.joined(separator: ", ")). A document passed in, rather than a folder, cannot bring them.")
        }
        candidate.found = found
    }

    /// Names each picture and recording in the text as Lamp names media,
    /// `media/<id>`. The id is made from the writing's id, the link and the
    /// file's bytes: the same picture in the same writing has the same id
    /// however the folder was chosen, so a second import reads as unchanged,
    /// and a picture replaced under the same name has a new one, so it comes
    /// in.
    static func nameMedia(_ candidate: inout Candidate) {
        guard let writing = candidate.writing, !candidate.found.isEmpty else { return }
        var names: [String: LampWritingImportMedia] = [:]
        for item in candidate.found {
            guard let bytes = try? Data(contentsOf: item.url) else {
                candidate.errors.append("\(item.target) cannot be read.")
                return
            }
            let fingerprint = fingerprint(bytes)
            names[item.target] = LampWritingImportMedia(
                id: derivedID(path: "media\u{0}\(candidate.writingID)\u{0}\(item.target)\u{0}\(fingerprint.prefix(16))"),
                url: item.url, type: item.type, alt: item.alt, fingerprint: fingerprint
            )
        }
        candidate.media = candidate.found.compactMap { names[$0.target] }
        let content = rewritingLinks(in: writing.content) { _, _, target in
            names[target].map { "media/\($0.id)" }
        }
        if content != writing.content {
            candidate.writing = writing.withContent(content)
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

extension LampDevotional {
    /// The same writing with other text.
    func withContent(_ newContent: String) -> LampDevotional {
        LampDevotional(
            id: id, moduleID: moduleID, moduleName: moduleName, title: title,
            subtitle: subtitle, author: author, date: date, tags: tags, category: category,
            seriesName: seriesName, seriesOrder: seriesOrder, keyScriptures: keyScriptures,
            summary: summary, content: newContent, contentJSON: nil, footnotes: footnotes,
            mediaJSON: mediaJSON, created: created, lastModified: lastModified, isEditable: isEditable
        )
    }

    /// The same writing under another id.
    func withID(_ newID: String) -> LampDevotional {
        LampDevotional(
            id: newID, moduleID: moduleID, moduleName: moduleName, title: title,
            subtitle: subtitle, author: author, date: date, tags: tags, category: category,
            seriesName: seriesName, seriesOrder: seriesOrder, keyScriptures: keyScriptures,
            summary: summary, content: content, contentJSON: contentJSON, footnotes: footnotes,
            mediaJSON: mediaJSON, created: created, lastModified: lastModified, isEditable: isEditable
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
