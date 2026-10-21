import Foundation

/// A SWORD Bible module: the `mods.d/<name>.conf` that describes it and the
/// verse files it names, read from a zip or a folder.
///
/// Verses are found by their position in a verse-numbering scheme, a
/// testament at a time, so only the schemes whose 66 books are laid out as
/// the KJV's are read: KJV, KJVA, NRSV and NRSVA.
struct SwordModule {
    struct Configuration {
        let moduleName: String
        private let entries: [(key: String, value: String)]

        init(text: String) {
            var name = ""
            var entries: [(key: String, value: String)] = []
            var pending: (key: String, value: String)?
            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if var continued = pending {
                    // A value ending in a backslash carries on to the next line.
                    continued.value += "\n" + line
                    pending = continued
                } else if line.hasPrefix("["), line.hasSuffix("]"), name.isEmpty {
                    name = String(line.dropFirst().dropLast())
                    continue
                } else if line.isEmpty || line.hasPrefix("#") {
                    continue
                } else if let equals = line.firstIndex(of: "=") {
                    pending = (
                        String(line[..<equals]).trimmingCharacters(in: .whitespaces),
                        String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    )
                } else {
                    continue
                }
                if let current = pending {
                    if current.value.hasSuffix("\\") {
                        pending = (current.key, String(current.value.dropLast()))
                    } else {
                        entries.append(current)
                        pending = nil
                    }
                }
            }
            if let pending { entries.append(pending) }
            self.moduleName = name
            self.entries = entries
        }

        subscript(_ key: String) -> String? {
            entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        func has(_ key: String) -> Bool { self[key] != nil }

        /// Text meant for a person, without the RTF a conf sometimes carries.
        func readable(_ key: String) -> String? {
            guard let value = self[key] else { return nil }
            let text = value
                .replacingOccurrences(of: #"\\pard?"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\\qc"#, with: " ", options: .regularExpression)
            let collapsed = TranslationCollector.collapsingWhitespace(text)
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    enum Markup {
        case osis, thml, gbf, plain
    }

    enum Versification {
        case kjv, nrsv

        /// Verses in each chapter of book `number`. NRSV numbers two more
        /// verses than the KJV: 3 John 1:15 and Revelation 12:18.
        func verseCounts(book number: Int) -> [Int] {
            var counts = LampCanonicalBooks.book(number)?.verseCounts ?? []
            if self == .nrsv {
                if number == 64 { counts[0] = 15 }
                if number == 66 { counts[11] = 18 }
            }
            return counts
        }
    }

    let configuration: Configuration
    let markup: Markup
    let versification: Versification
    let includesApocrypha: Bool
    let isUTF8: Bool
    private let files: SwordFileSource
    private let dataPath: String
    private let driver: String
    private let cipher: SapphireCipher?

    /// - Throws: `.needsUnlockKey` for a locked module and no key.
    init(configuration: Configuration, files: SwordFileSource, unlockKey: String?) throws {
        let name = configuration.moduleName
        let driver = (configuration["ModDrv"] ?? "").lowercased()
        guard ["ztext", "ztext4", "rawtext", "rawtext4"].contains(driver) else {
            let reason = driver.hasSuffix("com") || driver.hasSuffix("com4") ? "is a commentary, not a Bible"
                : driver.hasSuffix("ld") || driver.hasSuffix("ld4") ? "is a dictionary, not a Bible"
                : driver.hasSuffix("genbook") ? "is a book, not a Bible"
                : "isn’t a Bible"
            throw LampTranslationImportError.unsupportedSwordModule(moduleName: name, reason: reason)
        }
        if driver.hasPrefix("z") {
            let compression = (configuration["CompressType"] ?? "ZIP").uppercased()
            guard compression == "ZIP" else {
                throw LampTranslationImportError.unsupportedSwordModule(
                    moduleName: name, reason: "is compressed with \(compression), which Lamp can’t read yet"
                )
            }
        }

        switch (configuration["Versification"] ?? "KJV").uppercased() {
        case "KJV": versification = .kjv; includesApocrypha = false
        case "KJVA": versification = .kjv; includesApocrypha = true
        case "NRSV": versification = .nrsv; includesApocrypha = false
        case "NRSVA": versification = .nrsv; includesApocrypha = true
        default:
            throw LampTranslationImportError.unsupportedSwordModule(
                moduleName: name,
                reason: "numbers its verses the \(configuration["Versification"] ?? "") way, which Lamp can’t map yet"
            )
        }

        switch (configuration["SourceType"] ?? "Plain").uppercased() {
        case "OSIS": markup = .osis
        case "THML": markup = .thml
        case "GBF": markup = .gbf
        case "PLAIN": markup = .plain
        case let other:
            throw LampTranslationImportError.unsupportedSwordModule(
                moduleName: name, reason: "is written in \(other) markup, which Lamp can’t read yet"
            )
        }

        if configuration.has("CipherKey") {
            let key = (configuration["CipherKey"] ?? "").isEmpty ? unlockKey?.trimmingCharacters(in: .whitespacesAndNewlines) : configuration["CipherKey"]
            guard let key, !key.isEmpty else {
                throw LampTranslationImportError.needsUnlockKey(
                    moduleName: configuration.readable("Description") ?? name,
                    unlockURL: configuration["UnlockURL"]
                )
            }
            cipher = SapphireCipher(key: SapphireCipher.personalizedKey(key))
        } else {
            cipher = nil
        }

        self.configuration = configuration
        self.files = files
        self.driver = driver
        self.isUTF8 = (configuration["Encoding"] ?? "").uppercased().replacingOccurrences(of: "-", with: "") == "UTF8"
        var path = configuration["DataPath"] ?? ""
        while path.hasPrefix("./") { path.removeFirst(2) }
        if !path.isEmpty, !path.hasSuffix("/") { path += "/" }
        self.dataPath = path
    }

    var isLocked: Bool { cipher != nil }

    /// The verse store of one testament (1 is the Old, 2 the New), or nil
    /// when the module has none.
    func testament(_ number: Int) throws -> SwordTestament? {
        let prefix = dataPath + (number == 1 ? "ot" : "nt")
        switch driver {
        case "ztext", "ztext4":
            for blockLetter in ["b", "c", "v"] {
                guard let verses = try files.data(at: "\(prefix).\(blockLetter)zv") else { continue }
                guard let blocks = try files.data(at: "\(prefix).\(blockLetter)zs"),
                      let text = try files.data(at: "\(prefix).\(blockLetter)zz") else {
                    throw LampTranslationImportError.unreadableArchive(configuration.moduleName)
                }
                return ZTextTestament(
                    verseIndex: [UInt8](verses), blockIndex: [UInt8](blocks), blocks: [UInt8](text),
                    verseEntrySize: driver == "ztext4" ? 12 : 10, cipher: cipher,
                    moduleName: configuration.readable("Description") ?? configuration.moduleName
                )
            }
            return nil
        default:
            guard let index = try files.data(at: "\(prefix).vss") else { return nil }
            guard let text = try files.data(at: prefix) else {
                throw LampTranslationImportError.unreadableArchive(configuration.moduleName)
            }
            return RawTextTestament(index: [UInt8](index), text: [UInt8](text), entrySize: driver == "rawtext4" ? 8 : 6, cipher: cipher)
        }
    }

    /// Where each chapter's verses sit in a testament's index: after a slot
    /// for the module, one for the testament, one per book and one per
    /// chapter, each heading what follows it.
    func chapterPositions(testament: Int) -> [(book: Int, chapter: Int, headingIndex: Int, verseCount: Int)] {
        Self.chapterPositions(testament: testament, versification: versification)
    }

    /// Where a verse sits: its testament and its slot in that testament's index.
    static func position(book: Int, chapter: Int, verse: Int, versification: Versification = .kjv) -> (testament: Int, index: Int)? {
        let testament = book <= 39 ? 1 : 2
        guard let chapterPosition = chapterPositions(testament: testament, versification: versification)
            .first(where: { $0.book == book && $0.chapter == chapter }) else { return nil }
        return (testament, chapterPosition.headingIndex + verse)
    }

    static func chapterPositions(testament: Int, versification: Versification) -> [(book: Int, chapter: Int, headingIndex: Int, verseCount: Int)] {
        let books = testament == 1 ? Array(1...39) : Array(40...66)
        var positions: [(book: Int, chapter: Int, headingIndex: Int, verseCount: Int)] = []
        var index = 1
        for book in books {
            index += 1
            for (chapterIndex, count) in versification.verseCounts(book: book).enumerated() {
                index += 1
                positions.append((book, chapterIndex + 1, index, count))
                index += count
            }
        }
        return positions
    }

    func decode(_ bytes: Data) -> String {
        isUTF8 ? String(decoding: bytes, as: UTF8.self) : (String(data: bytes, encoding: .isoLatin1) ?? "")
    }
}

protocol SwordTestament {
    func text(at index: Int) throws -> Data?
}

/// zText: verses gathered into compressed blocks, a book, chapter or verse
/// each, with an index from verse to block.
final class ZTextTestament: SwordTestament {
    private let verseIndex: [UInt8]
    private let blockIndex: [UInt8]
    private let blocks: [UInt8]
    private let verseEntrySize: Int
    private let cipher: SapphireCipher?
    private let moduleName: String
    private var cached: (number: Int, bytes: [UInt8])?

    init(verseIndex: [UInt8], blockIndex: [UInt8], blocks: [UInt8], verseEntrySize: Int, cipher: SapphireCipher?, moduleName: String) {
        self.verseIndex = verseIndex
        self.blockIndex = blockIndex
        self.blocks = blocks
        self.verseEntrySize = verseEntrySize
        self.cipher = cipher
        self.moduleName = moduleName
    }

    func text(at index: Int) throws -> Data? {
        let entry = index * verseEntrySize
        guard index >= 0, entry + verseEntrySize <= verseIndex.count else { return nil }
        let blockNumber = Int(SwordBytes.uint32(verseIndex, entry))
        let start = Int(SwordBytes.uint32(verseIndex, entry + 4))
        let size = verseEntrySize == 10
            ? Int(SwordBytes.uint16(verseIndex, entry + 8))
            : Int(SwordBytes.uint32(verseIndex, entry + 8))
        guard size > 0 else { return nil }
        let block = try self.block(blockNumber)
        guard start < block.count else { return nil }
        return SwordBytes.untilNUL(block[start..<min(block.count, start + size)])
    }

    private func block(_ number: Int) throws -> [UInt8] {
        if let cached, cached.number == number { return cached.bytes }
        let entry = number * 12
        guard entry + 12 <= blockIndex.count else { throw LampTranslationImportError.unreadableArchive(moduleName) }
        let offset = Int(SwordBytes.uint32(blockIndex, entry))
        let compressedSize = Int(SwordBytes.uint32(blockIndex, entry + 4))
        let size = Int(SwordBytes.uint32(blockIndex, entry + 8))
        guard offset + compressedSize <= blocks.count else { throw LampTranslationImportError.unreadableArchive(moduleName) }

        var compressed = Data(blocks[offset..<(offset + compressedSize)])
        if let cipher {
            compressed = cipher.decrypt(compressed)
        }
        // zlib's own format: a two-byte header before the DEFLATE stream.
        guard compressed.count > 2,
              compressed[compressed.startIndex] & 0x0F == 8,
              (Int(compressed[compressed.startIndex]) << 8 | Int(compressed[compressed.startIndex + 1])) % 31 == 0,
              let inflated = try? LampZlib.decompressedPrefix(
                  of: compressed.dropFirst(2),
                  count: size > 0 ? size : compressedSize * 20
              ) else {
            throw cipher == nil
                ? LampTranslationImportError.unreadableArchive(moduleName)
                : LampTranslationImportError.wrongUnlockKey(moduleName: moduleName)
        }
        let bytes = [UInt8](inflated)
        cached = (number, bytes)
        return bytes
    }
}

/// RawText: each verse stored as it is, with an index of where.
struct RawTextTestament: SwordTestament {
    let index: [UInt8]
    let text: [UInt8]
    let entrySize: Int
    let cipher: SapphireCipher?

    func text(at position: Int) throws -> Data? {
        let entry = position * entrySize
        guard position >= 0, entry + entrySize <= index.count else { return nil }
        let start = Int(SwordBytes.uint32(index, entry))
        let size = entrySize == 6 ? Int(SwordBytes.uint16(index, entry + 4)) : Int(SwordBytes.uint32(index, entry + 4))
        guard size > 0, start < text.count else { return nil }
        var bytes = Data(text[start..<min(text.count, start + size)])
        if let cipher {
            bytes = cipher.decrypt(bytes)
        }
        return SwordBytes.untilNUL(bytes[...])
    }
}

enum SwordBytes {
    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func untilNUL<C: Collection>(_ bytes: C) -> Data where C.Element == UInt8 {
        Data(bytes.prefix { $0 != 0 })
    }
}

// MARK: - Where the files are

/// Reads a module's files by their path from the module's root, the folder
/// that holds `mods.d`.
protocol SwordFileSource {
    func data(at path: String) throws -> Data?
}

struct ZipSwordFiles: SwordFileSource {
    let archive: LampZipArchive
    let root: String
    private let entries: [String: LampZipArchive.Entry]

    init(archive: LampZipArchive, root: String) {
        self.archive = archive
        self.root = root
        // SWORD's paths are lowercase by convention, not always in fact.
        self.entries = Dictionary(
            archive.entries.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }
        )
    }

    func data(at path: String) throws -> Data? {
        guard let entry = entries[(root + path).lowercased()] else { return nil }
        return try archive.contents(of: entry)
    }
}

struct FolderSwordFiles: SwordFileSource {
    let root: URL

    func data(at path: String) throws -> Data? {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
