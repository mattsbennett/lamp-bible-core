import Foundation

/// A Bible file format Lamp can turn into a translation module.
public enum LampTranslationSourceFormat: String, CaseIterable, Sendable {
    case usfm
    case osis
    case zefania
    /// The plain book/chapter/verse XML many Bible sites export, such as
    /// `<bible><b n="Genesis"><c n="1"><v n="1">` or Beblia's
    /// `<bible><testament><book number="1"><chapter number="1"><verse number="1">`.
    case xmlBible
    /// A CrossWire SWORD module, locked or not, zipped or as a folder.
    case sword

    public var displayName: String {
        switch self {
        case .usfm: "USFM"
        case .osis: "OSIS XML"
        case .zefania: "Zefania XML"
        case .xmlBible: "XML Bible"
        case .sword: "SWORD module"
        }
    }
}

/// What an import kept, left out, or couldn't read, so a user sees it rather
/// than finding a gap later.
public struct LampTranslationImportReport: Equatable, Sendable {
    public var bookCount = 0
    public var chapterCount = 0
    public var verseCount = 0
    /// Books outside the 66 — deuterocanonical books, for instance — named as
    /// the source names them. Their text is left out.
    public var skippedBooks: [String] = []
    /// Markup the reader doesn't know, with how often it appeared. The text
    /// inside it is kept.
    public var unrecognizedMarkup: [String: Int] = [:]
    /// The first reference (BBCCCVVV) of each bridged range such as 16–17,
    /// whose text is kept under its first verse.
    public var verseBridges: [Int] = []
    /// References that appeared a second time; the second copy is left out.
    public var duplicateVerses: [Int] = []

    public init() {}
}

public enum LampTranslationImportError: Error, LocalizedError, Equatable, Sendable {
    case unrecognizedFormat(String)
    case unreadableText(String)
    case invalidXML(String)
    case unreadableArchive(String)
    case noScripture(skippedBooks: [String])
    /// A locked SWORD module, read without the key bought for it.
    case needsUnlockKey(moduleName: String, unlockURL: String?)
    case wrongUnlockKey(moduleName: String)
    case unsupportedSwordModule(moduleName: String, reason: String)
    case severalSwordModules([String])

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat(let name):
            return "‘\(name)’ isn’t a Bible format Lamp can import. Lamp reads USFM, OSIS XML, and Zefania and other XML Bibles, or a zip or folder of them."
        case .unreadableText(let name):
            return "‘\(name)’ isn’t readable text."
        case .invalidXML(let reason):
            return "The XML couldn’t be read: \(reason)"
        case .unreadableArchive(let name):
            return "‘\(name)’ couldn’t be unzipped. It may be damaged, encrypted, or use a kind of zip Lamp can’t open."
        case .noScripture(let skippedBooks):
            if skippedBooks.isEmpty {
                return "No verses were found in the file."
            }
            return "No verses from the 66 books were found. Left out: \(skippedBooks.joined(separator: ", "))."
        case .needsUnlockKey(let moduleName, _):
            return "“\(moduleName)” is locked. Enter the unlock key you received for it."
        case .wrongUnlockKey(let moduleName):
            return "That key doesn’t unlock “\(moduleName)”."
        case .unsupportedSwordModule(let moduleName, let reason):
            return "“\(moduleName)” \(reason)."
        case .severalSwordModules(let names):
            return "This holds several SWORD Bibles (\(names.joined(separator: ", "))). Choose the zip or .conf file of the one to import."
        }
    }
}

extension LampTranslationImportError {
    /// For a locked SWORD module: what to say when asking for its key, and
    /// where keys are sold when the module says. Nil for any other error.
    public var unlockPrompt: String? {
        switch self {
        case .needsUnlockKey(_, let unlockURL):
            return [errorDescription, unlockURL.map { "Keys for it are available from \($0)." }]
                .compactMap { $0 }
                .joined(separator: " ")
        case .wrongUnlockKey:
            return errorDescription
        default:
            return nil
        }
    }
}

/// A Bible read from a file in another format, ready to become a `.lamp`
/// translation module.
public struct LampImportedTranslation: Sendable {
    public let format: LampTranslationSourceFormat
    /// What the file calls itself, when it says.
    public let suggestedName: String?
    public let suggestedAbbreviation: String?
    /// An ISO 639-1 code where the file gives a language Lamp recognises.
    public let language: String?
    public let copyright: String?
    public let report: LampTranslationImportReport
    let books: [ImportedBook]

    /// What an import says of its own licence: the user's copy, for their use.
    public static let importedLicense = "Imported by the user from their own copy, for personal use."

    /// Translation JSON, as `LampModuleCompiler` takes it and as Lamp's own
    /// module sources keep it, for a pipeline that finishes the JSON itself.
    public func moduleJSON(
        id: String,
        name: String,
        abbreviation: String,
        language: String? = nil,
        license: String = importedLicense
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: moduleRoot(id: id, name: name, abbreviation: abbreviation, language: language, license: license),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Translation JSON, as `LampModuleCompiler` takes it.
    func moduleRoot(
        id: String,
        name: String,
        abbreviation: String,
        language: String? = nil,
        license: String = importedLicense
    ) -> [String: Any] {
        let language = language ?? self.language ?? "en"
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": id,
            "type": "translation",
            "name": name,
            "abbreviation": abbreviation,
            "language": language,
            "textDirection": Locale.Language(identifier: language).characterDirection == .rightToLeft ? "rtl" : "ltr",
            "license": license,
            "features": features,
            // Worked out from the chapters' lengths: an imported file rarely
            // says, and a psalm numbered from its title read as English would
            // stand a verse out from every other translation.
            "versification": LampVersification.likeliestScheme(forVerseCounts: verseCounts).rawValue,
        ]
        if let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language) {
            meta["languageName"] = languageName
        }
        if let copyright {
            meta["copyright"] = copyright
        }

        return [
            "meta": meta,
            "books": books.map(Self.json),
        ]
    }

    /// Writes `<id>.lamp` into `directory`.
    public func compile(
        into directory: URL,
        id: String,
        name: String,
        abbreviation: String,
        language: String? = nil
    ) throws -> ModuleCompilationResult {
        try LampModuleCompiler().compile(
            root: moduleRoot(id: id, name: name, abbreviation: abbreviation, language: language),
            sourceFilename: "\(id).json",
            destinationURL: directory.appendingPathComponent(id).appendingPathExtension("lamp")
        )
    }

    /// The last verse of each chapter, by book: what tells one numbering
    /// scheme from another.
    private var verseCounts: [Int: [Int: Int]] {
        var counts: [Int: [Int: Int]] = [:]
        for book in books {
            for chapter in book.chapters {
                counts[book.number, default: [:]][chapter.number] = chapter.verses.map(\.number).max() ?? 0
            }
        }
        return counts
    }

    private var features: [String: Bool] {
        var features = [
            "strongs": false, "morphology": false, "redLetter": false, "footnotes": false,
            "sectionHeadings": false, "poetry": false, "paragraphs": false,
        ]
        for chapter in books.lazy.flatMap(\.chapters) {
            if !chapter.headings.isEmpty { features["sectionHeadings"] = true }
            for verse in chapter.verses {
                if !verse.footnotes.isEmpty { features["footnotes"] = true }
                if verse.paragraph { features["paragraphs"] = true }
                if verse.poetryIndent > 0 || verse.stanzaBreak { features["poetry"] = true }
                for annotation in verse.annotations {
                    if annotation.kind == "strongs" { features["strongs"] = true }
                    if annotation.kind == "red-letter" { features["redLetter"] = true }
                    if annotation.morphology != nil { features["morphology"] = true }
                }
            }
        }
        return features
    }

    private static func json(_ book: ImportedBook) -> [String: Any] {
        let canonical = LampCanonicalBooks.book(book.number)
        return [
            "id": canonical?.osisID ?? String(book.number),
            "name": canonical?.name ?? "Book \(book.number)",
            "number": book.number,
            "testament": canonical?.testament ?? "OT",
            "chapters": book.chapters.map { chapter in
                var object: [String: Any] = [
                    "chapter": chapter.number,
                    "verses": chapter.verses.map { json($0, book: book.number, chapter: chapter.number) },
                ]
                if !chapter.headings.isEmpty {
                    object["headings"] = chapter.headings.map {
                        ["beforeVerse": $0.beforeVerse, "level": $0.level, "text": $0.text] as [String: Any]
                    }
                }
                return object
            },
        ]
    }

    private static func json(_ verse: ImportedVerse, book: Int, chapter: Int) -> [String: Any] {
        var content: [String: Any] = ["text": verse.text]
        if !verse.annotations.isEmpty {
            let characters = Array(verse.text)
            content["annotations"] = verse.annotations.map { annotation in
                var object: [String: Any] = [
                    "type": annotation.kind,
                    "start": annotation.start,
                    "end": annotation.end,
                    "text": String(characters[annotation.start..<annotation.end]),
                ]
                var data: [String: Any] = [:]
                data["strongs"] = annotation.strongs
                data["morphology"] = annotation.morphology
                data["lemma"] = annotation.lemma
                if !data.isEmpty {
                    object["data"] = data
                }
                return object
            }
        }
        if !verse.footnotes.isEmpty {
            content["footnote_refs"] = verse.footnotes.map { ["id": $0.id, "offset": $0.offset] as [String: Any] }
        }

        var object: [String: Any] = [
            "v": verse.number,
            "ref": book * 1_000_000 + chapter * 1_000 + verse.number,
            "content": content,
        ]
        if !verse.footnotes.isEmpty {
            object["footnotes"] = verse.footnotes.map { ["id": $0.id, "type": $0.kind, "content": $0.content] }
        }
        if verse.paragraph {
            object["paragraph"] = true
        }
        if verse.poetryIndent > 0 || verse.stanzaBreak {
            var poetry: [String: Any] = [:]
            if verse.poetryIndent > 0 { poetry["indent"] = verse.poetryIndent }
            if verse.stanzaBreak { poetry["stanzaBreak"] = true }
            object["poetry"] = poetry
        }
        return object
    }
}

/// Turns a Bible the user already has — USFM, OSIS, Zefania or another XML
/// Bible, alone or in a zip or folder — into a translation module.
///
/// Only the 66 books are kept, in the standard verse grid every Lamp
/// translation shares; what is left out is listed in the report.
public struct LampTranslationImporter: Sendable {
    public init() {}

    /// `unlockKey` opens a locked SWORD module; reading one without it throws
    /// `.needsUnlockKey`, and an app asks for the key and reads again.
    public func read(_ url: URL, unlockKey: String? = nil) throws -> LampImportedTranslation {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let modsD = url.appendingPathComponent("mods.d", isDirectory: true)
            if FileManager.default.fileExists(atPath: modsD.path) {
                let confs = try FileManager.default.contentsOfDirectory(at: modsD, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "conf" }
                    .compactMap { conf in Self.decodeText(try Data(contentsOf: conf)).map { (conf.path, $0) } }
                return try readSword(confs, files: FolderSwordFiles(root: url), name: url.lastPathComponent, unlockKey: unlockKey)
            }
            return try read(files: folderFiles(url), name: url.lastPathComponent)
        }
        if url.pathExtension.lowercased() == "conf" {
            guard let text = Self.decodeText(try Data(contentsOf: url)) else {
                throw LampTranslationImportError.unreadableText(url.lastPathComponent)
            }
            // A module's root holds `mods.d`, where its conf lives.
            let folder = url.deletingLastPathComponent()
            let root = folder.lastPathComponent.lowercased() == "mods.d" ? folder.deletingLastPathComponent() : folder
            return try readSword([(url.path, text)], files: FolderSwordFiles(root: root), name: url.lastPathComponent, unlockKey: unlockKey)
        }
        return try read(data: Data(contentsOf: url, options: [.mappedIfSafe]), filename: url.lastPathComponent, unlockKey: unlockKey)
    }

    public func read(data: Data, filename: String, unlockKey: String? = nil) throws -> LampImportedTranslation {
        guard LampZipArchive.isZip(data) else {
            return try read(files: [(filename, data)], name: filename)
        }
        do {
            let archive = try LampZipArchive(data: data)
            let confs = try archive.entries
                .filter { Self.isSwordConf($0.path) }
                .compactMap { entry in Self.decodeText(try archive.contents(of: entry)).map { (entry.path, $0) } }
            if !confs.isEmpty {
                let root = confs[0].0.lowercased().range(of: "mods.d/").map { String(confs[0].0[..<$0.lowerBound]) } ?? ""
                return try readSword(confs, files: ZipSwordFiles(archive: archive, root: root), name: filename, unlockKey: unlockKey)
            }
            let files = try archive.entries
                .filter { !$0.isDirectory && Self.isCandidate($0.path) }
                .map { ($0.path, try archive.contents(of: $0)) }
            return try read(files: files, name: filename)
        } catch let error as LampTranslationImportError {
            throw error
        } catch {
            throw LampTranslationImportError.unreadableArchive(filename)
        }
    }

    /// A root may hold commentaries and dictionaries beside a Bible; only
    /// one Bible can be read at a time.
    private func readSword(
        _ confs: [(path: String, text: String)],
        files: SwordFileSource,
        name: String,
        unlockKey: String?
    ) throws -> LampImportedTranslation {
        let bibles = SwordTranslationReader.bibleConfigurations(confs)
        guard bibles.count <= 1 else {
            throw LampTranslationImportError.severalSwordModules(bibles.map(\.configuration.moduleName).sorted())
        }
        guard let bible = bibles.first?.configuration ?? confs.first.map({ SwordModule.Configuration(text: $0.text) }) else {
            throw LampTranslationImportError.unrecognizedFormat(name)
        }
        return try SwordTranslationReader.read(bible, files: files, unlockKey: unlockKey)
    }

    private static func isSwordConf(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/")
        return components.count >= 2 && components[components.count - 2] == "mods.d" && components.last?.hasSuffix(".conf") == true
    }

    /// A module ID for an imported translation that can't be mistaken for a
    /// bundled module or a personal collection, and isn't one of
    /// `existingIDs` (compared ignoring case, as the file system does).
    public static func moduleID(forAbbreviation abbreviation: String, avoiding existingIDs: Set<String> = []) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(abbreviation.map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let base = "imported-" + (cleaned.isEmpty ? "translation" : cleaned)
        let taken = Set(existingIDs.map { $0.lowercased() })
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func read(files: [(path: String, data: Data)], name: String) throws -> LampImportedTranslation {
        let usfm = files.filter { Self.looksLikeUSFM($0.data) }
        if !usfm.isEmpty {
            var reader = USFMTranslationReader()
            for file in usfm.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                guard let text = Self.decodeText(file.data) else {
                    throw LampTranslationImportError.unreadableText(file.path)
                }
                reader.read(text)
            }
            return try reader.finish()
        }

        let xml = files
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .compactMap { file in XMLTranslationReader.format(of: file.data).map { (format: $0, data: file.data) } }
        guard let format = xml.first?.format else {
            throw LampTranslationImportError.unrecognizedFormat(name)
        }
        return try XMLTranslationReader.read(xml.filter { $0.format == format }.map(\.data), format: format)
    }

    private func folderFiles(_ folder: URL) throws -> [(path: String, data: Data)] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(path: String, data: Data)] = []
        for case let url as URL in enumerator where Self.isCandidate(url.lastPathComponent) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append((url.path, try Data(contentsOf: url, options: [.mappedIfSafe])))
        }
        return files
    }

    private static let candidateExtensions: Set<String> = ["usfm", "sfm", "ptx", "txt", "xml", "osis", "zef"]

    private static func isCandidate(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !path.hasPrefix("__MACOSX/") else { return false }
        return candidateExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func looksLikeUSFM(_ data: Data) -> Bool {
        String(decoding: data.prefix(256), as: UTF8.self)
            .drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
            .hasPrefix("\\id ")
    }

    /// UTF-8, as the formats require; older files are sometimes Windows-1252.
    static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// What a file says about itself is sometimes a path or a file name
    /// rather than a title; that is no suggestion at all.
    static func suggestion(_ value: String?) -> String? {
        guard let value = value.map(TranslationCollector.collapsingWhitespace), !value.isEmpty,
              !value.contains("/"), !value.contains("\\") else { return nil }
        let lowercased = value.lowercased()
        guard !candidateExtensions.contains(where: { lowercased.hasSuffix(".\($0)") }) else { return nil }
        return value
    }

    /// "Bible.en.kjv" → "KJV"; "luth1912" → "LUTH1912".
    static func abbreviationSuggestion(_ value: String?) -> String? {
        guard let value = suggestion(value)?.split(separator: ".").last.map(String.init),
              value.count <= 12, !value.contains(" ") else { return nil }
        return value == value.lowercased() ? value.uppercased() : value
    }

    static func iso639_1(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else { return nil }
        let primary = String(code.prefix { $0.isLetter })
        let terminology = bibliographicCodes[primary] ?? primary
        guard let alpha2 = Locale.LanguageCode(terminology).identifier(.alpha2) ?? (primary.count == 2 ? primary : nil),
              alpha2.count == 2 else { return nil }
        return alpha2
    }

    /// The ISO 639-2 bibliographic codes that differ from the terminology
    /// codes Foundation knows. Zefania files use them ("GER", "FRE").
    private static let bibliographicCodes: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
        "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
        "tib": "bod", "wel": "cym",
    ]
}
