import Foundation

/// Reads a SWORD Bible module verse by verse, in the order its verse-numbering
/// scheme lays the 66 books out.
enum SwordTranslationReader {
    /// The modules a root holds that are Bibles, by the path of their conf.
    static func bibleConfigurations(_ configurations: [(path: String, text: String)]) -> [(path: String, configuration: SwordModule.Configuration)] {
        configurations.compactMap { conf in
            let configuration = SwordModule.Configuration(text: conf.text)
            let driver = (configuration["ModDrv"] ?? "").lowercased()
            return ["ztext", "ztext4", "rawtext", "rawtext4"].contains(driver) ? (conf.path, configuration) : nil
        }
    }

    static func read(
        _ configuration: SwordModule.Configuration,
        files: SwordFileSource,
        unlockKey: String?
    ) throws -> LampImportedTranslation {
        let module = try SwordModule(configuration: configuration, files: files, unlockKey: unlockKey)
        var reader: SwordVerseReader = module.markup == .osis
            ? OSISVerses()
            : TaggedVerses(markup: module.markup)
        var checkedKey = !module.isLocked

        let testaments = try (1...2).map { try module.testament($0) }
        guard testaments.contains(where: { $0 != nil }) else {
            // Typically a conf chosen without the folder around it, which a
            // phone gives no access to.
            throw LampTranslationImportError.unsupportedSwordModule(
                moduleName: configuration.moduleName,
                reason: "has no verse files beside its conf. Choose the module’s zip or its whole folder"
            )
        }
        for (testament, store) in zip(1...2, testaments) {
            guard let store else { continue }
            for position in module.chapterPositions(testament: testament) {
                // Verse 0 is the chapter's heading slot.
                for verse in 0...position.verseCount {
                    guard let bytes = try store.text(at: position.headingIndex + verse), !bytes.isEmpty else { continue }
                    if !checkedKey {
                        // A wrong key on uncompressed text deciphers to noise
                        // rather than failing; noise isn't valid UTF-8.
                        if module.isUTF8, String(data: bytes, encoding: .utf8) == nil {
                            throw LampTranslationImportError.wrongUnlockKey(
                                moduleName: configuration.readable("Description") ?? configuration.moduleName
                            )
                        }
                        checkedKey = true
                    }
                    reader.read(module.decode(bytes), book: position.book, chapter: position.chapter, verse: verse)
                }
            }
        }

        if module.includesApocrypha {
            reader.collector.noteSkippedBook("the Apocrypha")
        }
        let books = reader.collector.finish()
        guard !books.isEmpty else {
            throw LampTranslationImportError.noScripture(skippedBooks: reader.collector.report.skippedBooks)
        }
        return LampImportedTranslation(
            format: .sword,
            suggestedName: LampTranslationImporter.suggestion(configuration.readable("Description")),
            suggestedAbbreviation: LampTranslationImporter.abbreviationSuggestion(
                configuration.readable("Abbreviation") ?? configuration.moduleName
            ),
            language: LampTranslationImporter.iso639_1(configuration["Lang"]),
            copyright: configuration.readable("ShortCopyright")
                ?? configuration.readable("Copyright")
                ?? configuration.readable("DistributionLicense"),
            report: reader.collector.report,
            books: books
        )
    }
}

private protocol SwordVerseReader {
    var collector: TranslationCollector { get set }
    mutating func read(_ text: String, book: Int, chapter: Int, verse: Int)
}

private struct OSISVerses: SwordVerseReader {
    private let fragments = OSISFragmentReader()

    var collector: TranslationCollector {
        get { fragments.collector }
        set { fragments.collector = newValue }
    }

    mutating func read(_ text: String, book: Int, chapter: Int, verse: Int) {
        let osisID = LampCanonicalBooks.book(book)?.osisID ?? "Gen"
        fragments.read(text, osisID: "\(osisID).\(chapter).\(verse)")
    }
}

/// GBF, ThML and plain text: a tag here and there in running text, rather
/// than XML a parser could take.
private struct TaggedVerses: SwordVerseReader {
    var collector = TranslationCollector()
    private let markup: SwordModule.Markup
    private var spans: [(tag: String, id: Int)] = []
    private var capture: (kind: Capture, text: String)?

    private enum Capture {
        case footnote, heading, skipped
    }

    init(markup: SwordModule.Markup) {
        self.markup = markup
    }

    mutating func read(_ text: String, book: Int, chapter: Int, verse: Int) {
        if collector.bookNumber != book { collector.startBook(book) }
        if collector.chapterNumber != chapter { collector.startChapter(chapter) }
        collector.startVerse(verse)
        guard markup != .plain else {
            collector.appendText(text)
            return
        }

        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            write(rest[..<open])
            guard let close = rest[open...].firstIndex(of: ">") else {
                rest = rest[open...]
                break
            }
            let tag = rest[rest.index(after: open)..<close]
            markup == .gbf ? gbf(String(tag)) : thml(String(tag))
            rest = rest[rest.index(after: close)...]
        }
        write(rest)
        // A note or heading never closed ends with its verse.
        if capture != nil { endCapture() }
    }

    private mutating func write(_ text: Substring) {
        guard !text.isEmpty else { return }
        let text = markup == .thml ? TagText.decodingEntities(String(text)) : String(text)
        if capture != nil {
            capture?.text += text
        } else {
            collector.appendText(text)
        }
    }

    private mutating func endCapture() {
        guard let capture else { return }
        self.capture = nil
        switch capture.kind {
        case .footnote: collector.addFootnote(capture.text)
        case .heading: collector.addHeading(capture.text, level: 1)
        case .skipped: break
        }
    }

    private mutating func open(_ style: SpanStyle?, tag: String) {
        spans.append((tag, style.map { collector.openSpan($0) } ?? 0))
    }

    private mutating func close(_ tag: String) {
        guard let index = spans.lastIndex(where: { $0.tag == tag }) else { return }
        let span = spans.remove(at: index)
        if span.id != 0 { collector.closeSpan(span.id) }
    }

    // MARK: GBF

    /// General Bible Format: `<FR>` … `<Fr>` words of Christ, `<FI>` … `<Fi>`
    /// added words, `<RF>` … `<Rf>` notes, `<TS>` … `<Ts>` titles, and
    /// `<WH1234>` after a word for its Strong's number.
    private mutating func gbf(_ tag: String) {
        let code = String(tag.prefix(2))
        if capture != nil {
            if code == "Rf" || code == "Ts" || code == "Tt" || code == "Rx" { endCapture() }
            return
        }
        switch code {
        case "FR": open(.redLetter, tag: "FR")
        case "Fr": close("FR")
        case "FI": open(.added, tag: "FI")
        case "Fi": close("FI")
        case "RF": capture = (.footnote, "")
        case "TS": capture = (.heading, "")
        case "TT", "RX": capture = (.skipped, "")
        case "CM": collector.markParagraph()
        case "CL": collector.breakLine()
        case "PP": collector.markPoetryLine(indent: 1)
        case "WH", "WG":
            let number = tag.dropFirst(2).prefix(while: \.isNumber)
            collector.annotatePrecedingWord(with: .word(strongs: ["\(code.last == "H" ? "H" : "G")\(number)"]))
        default:
            // Typefaces, quotation marks and word details the format has no
            // place for here.
            if !["F", "W", "Q", "C", "P", "D", "H", "J", "R", "T"].contains(code.first.map(String.init) ?? "") {
                collector.noteUnrecognized("<\(tag)>")
            }
        }
    }

    // MARK: ThML

    /// Theological Markup Language: HTML with `<note>`, `<sync>` for
    /// Strong's numbers and `<font color="red">` for words of Christ.
    private mutating func thml(_ tag: String) {
        let isClosing = tag.hasPrefix("/")
        let body = tag.drop { $0 == "/" }
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        let attributes = String(body.dropFirst(name.count)).lowercased()

        if capture != nil {
            if isClosing, ["note", "h1", "h2", "h3", "h4", "h5", "h6", "div"].contains(name) { endCapture() }
            return
        }
        switch (name, isClosing) {
        case ("note", false): capture = (.footnote, "")
        case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
            capture = (.heading, "")
        case ("div", false) where attributes.contains("sechead") || attributes.contains("title"):
            capture = (.heading, "")
        case ("font", false): open(attributes.contains("red") ? .redLetter : nil, tag: "font")
        case ("font", true): close("font")
        case ("sync", _) where attributes.contains("strongs"):
            if let value = Self.attribute("value", in: attributes) {
                let key = value.first?.isLetter == true ? value.uppercased() : "\(collector.bookNumber ?? 1 <= 39 ? "H" : "G")\(value)"
                collector.annotatePrecedingWord(with: .word(strongs: [key]))
            }
        case ("br", _): collector.breakLine()
        case ("p", false): collector.markParagraph()
        case ("p", true), ("sync", _), ("scripref", _), ("i", _), ("b", _), ("em", _), ("strong", _),
             ("span", _), ("a", _), ("u", _), ("sup", _), ("sub", _), ("small", _), ("div", _), ("font", _):
            break
        default:
            collector.noteUnrecognized("<\(name)>")
        }
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let range = attributes.range(of: "\(name)=") else { return nil }
        let rest = attributes[range.upperBound...]
        let quote = rest.first == "\"" || rest.first == "'" ? rest.first : nil
        let value = quote.map { quote in rest.dropFirst().prefix { $0 != quote } } ?? rest.prefix { !$0.isWhitespace && $0 != "/" }
        return value.isEmpty ? nil : String(value)
    }
}
