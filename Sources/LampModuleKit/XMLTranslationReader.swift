import Foundation

/// Reads OSIS, Zefania and plain book/chapter/verse XML Bibles.
enum XMLTranslationReader {
    /// The format named by the document's root element, if it is one Lamp reads.
    static func format(of data: Data) -> LampTranslationSourceFormat? {
        let start = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let root = rootElementName(in: start) else { return nil }
        switch localName(root).lowercased() {
        case "osis": return .osis
        case "xmlbible": return .zefania
        case "bible": return .xmlBible
        default: return nil
        }
    }

    /// `documents` are one Bible, whole or a book per file, all in `format`.
    static func read(_ documents: [Data], format: LampTranslationSourceFormat) throws -> LampImportedTranslation {
        let delegate: XMLBibleDelegate = format == .osis ? OSISDelegate() : VerseXMLDelegate()
        for data in documents {
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else {
                let reason = parser.parserError?.localizedDescription ?? "unknown error"
                throw LampTranslationImportError.invalidXML("\(reason) (line \(parser.lineNumber))")
            }
        }
        let books = delegate.collector.finish()
        guard !books.isEmpty else {
            throw LampTranslationImportError.noScripture(skippedBooks: delegate.collector.report.skippedBooks)
        }
        return LampImportedTranslation(
            format: format,
            suggestedName: LampTranslationImporter.suggestion(delegate.metadata["title"]),
            suggestedAbbreviation: LampTranslationImporter.abbreviationSuggestion(delegate.metadata["abbreviation"]),
            language: LampTranslationImporter.iso639_1(delegate.metadata["language"]),
            copyright: LampTranslationImporter.suggestion(delegate.metadata["rights"]),
            report: delegate.collector.report,
            books: books
        )
    }

    static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func rootElementName(in text: String) -> String? {
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            if rest.hasPrefix("!--") {
                guard let end = rest.range(of: "-->") else { return nil }
                rest = rest[end.upperBound...]
                continue
            }
            guard let first = rest.first, first.isLetter || first == "_" else { continue }
            return String(rest.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" })
        }
        return nil
    }
}

/// What both XML readers share: the collector, the file's description of
/// itself, and the stack of what each open element began.
private class XMLBibleDelegate: NSObject, XMLParserDelegate {
    enum Capture {
        case note(text: String, kind: String)
        case heading(text: String, level: Int, beforeVerse: Int?)
        case metadata(key: String, text: String)
        case skipped
    }

    /// What closing an element undoes.
    enum Effect {
        case none
        case finishVerse
        case closeSpan(Int)
        /// Closes added words, which some sources run straight into the
        /// next word: `<transChange>he made</transChange><w>the</w>`.
        case closeAddition(Int)
        case endCapture
        case breakLine
    }

    var collector = TranslationCollector()
    var metadata: [String: String] = [:]
    var effects: [Effect] = []
    var captures: [Capture] = []
    private var separatesNextWord = false

    func start(_ name: String, attributes: [String: String]) -> Effect { .none }

    final func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        effects.append(start(XMLTranslationReader.localName(elementName), attributes: attributes))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let effect = effects.popLast() else { return }
        switch effect {
        case .none:
            break
        case .finishVerse:
            collector.finishVerse()
        case .closeSpan(let id):
            collector.closeSpan(id)
        case .closeAddition(let id):
            collector.closeSpan(id)
            separatesNextWord = true
        case .breakLine:
            collector.breakLine()
        case .endCapture:
            switch captures.popLast() {
            case .note(let text, let kind):
                collector.addFootnote(text, kind: kind)
            case .heading(let text, let level, let beforeVerse):
                collector.addHeading(text, level: level, beforeVerse: beforeVerse)
            case .metadata(let key, let text):
                let value = TranslationCollector.collapsingWhitespace(text)
                if metadata[key] == nil, !value.isEmpty {
                    metadata[key] = value
                }
            case .skipped, nil:
                break
            }
        }
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        text(string)
    }

    final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text(String(decoding: CDATABlock, as: UTF8.self))
    }

    private func text(_ string: String) {
        guard let capture = captures.last else {
            if separatesNextWord {
                separatesNextWord = false
                if let first = string.first, first.isLetter || first.isNumber, collector.lastCharacter?.isLetter == true {
                    collector.breakLine()
                }
            }
            collector.appendText(string)
            return
        }
        switch capture {
        case .note(let text, let kind):
            captures[captures.count - 1] = .note(text: text + string, kind: kind)
        case .heading(let text, let level, let beforeVerse):
            captures[captures.count - 1] = .heading(text: text + string, level: level, beforeVerse: beforeVerse)
        case .metadata(let key, let text):
            captures[captures.count - 1] = .metadata(key: key, text: text + string)
        case .skipped:
            break
        }
    }

    /// Notes and headings inside a heading, a note or skipped content are
    /// dropped with it.
    func beginCapture(_ capture: Capture) -> Effect {
        if let last = captures.last {
            switch last {
            case .heading, .note, .skipped:
                captures.append(.skipped)
                return .endCapture
            case .metadata:
                break
            }
        }
        captures.append(capture)
        return .endCapture
    }

    /// After a parse that stopped partway: close what it opened, so nothing
    /// half-read spills into the next document.
    func abandonOpenElements() {
        while let effect = effects.popLast() {
            switch effect {
            case .closeSpan(let id), .closeAddition(let id):
                collector.closeSpan(id)
            case .endCapture:
                _ = captures.popLast()
            case .none, .finishVerse, .breakLine:
                break
            }
        }
        captures = []
    }

    func ensureLocation(book: Int, chapter: Int) {
        if collector.bookNumber != book {
            collector.startBook(book)
        }
        if collector.chapterNumber != chapter {
            collector.startChapter(chapter)
        }
    }
}

// MARK: - OSIS

/// OSIS with verses as containers or as `sID`/`eID` milestones, as SWORD,
/// eBible.org and Paratext write it.
private final class OSISDelegate: XMLBibleDelegate {
    private var headerDepth = 0
    private var readingWork = false
    private var finishedWork = false
    /// Words of Christ given as `<q sID … who="Jesus"/>` … `<q eID …/>`.
    private var quoteSpans: [String: Int] = [:]
    /// Some converters put every verse of a psalm in a line group of its
    /// own. Only a group after one of several lines starts a stanza.
    private var linesInGroup = 0
    private var linesInPreviousGroup = 0

    override func start(_ name: String, attributes: [String: String]) -> Effect {
        if name == "header" {
            headerDepth += 1
            return .none
        }
        if headerDepth > 0 {
            return startInHeader(name, attributes: attributes)
        }

        // Most of a Bible with Strong's numbers is words: check for one first.
        if name == "w" { return word(attributes) }

        let isStart = attributes["eID"] == nil
        let isContainer = attributes["sID"] == nil && attributes["eID"] == nil

        switch name {
        case "osis", "osisCorpus", "reference", "hi", "foreign", "name", "abbr", "rdg", "catchWord",
             "inscription", "mentioned", "date", "a", "salute", "signed", "closer":
            return .none
        case "transChange":
            return attributes["type"] == "added" ? .closeAddition(collector.openSpan(.added)) : .none
        case "seg":
            return attributes["type"] == "x-selah" ? .closeSpan(collector.openSpan(.selah)) : .none
        case "osisText":
            metadata["abbreviation"] = metadata["abbreviation"] ?? attributes["osisIDWork"]
            metadata["language"] = metadata["language"] ?? attributes["xml:lang"]
            return .none
        case "div":
            return startDivision(attributes, isStart: isStart, isContainer: isContainer)
        case "chapter":
            if isStart, let location = location(attributes["osisID"] ?? attributes["sID"]) {
                if let book = location.book { ensureLocation(book: book, chapter: location.chapter) }
            } else if !isStart {
                collector.finishVerse()
            }
            return isContainer ? .finishVerse : .none
        case "verse":
            guard isStart else {
                collector.finishVerse()
                return .none
            }
            startVerse(attributes["osisID"] ?? attributes["sID"])
            return isContainer ? .finishVerse : .none
        case "title":
            guard isContainer else { return .none }
            switch attributes["type"] {
            case "main", "chapter", "runningHead", "parallel", "scope", "x-chapterLabel":
                return beginCapture(.skipped)
            case "psalm", "acrostic", "sub":
                return beginCapture(.heading(text: "", level: 2, beforeVerse: nil))
            default:
                let level = attributes["level"].flatMap(Int.init) ?? 1
                return beginCapture(.heading(text: "", level: level, beforeVerse: nil))
            }
        case "speaker":
            return beginCapture(.heading(text: "", level: 2, beforeVerse: nil))
        case "note":
            if attributes["type"] == "crossReference" {
                return beginCapture(.skipped)
            }
            return beginCapture(.note(text: "", kind: Self.footnoteKind(attributes["type"])))
        case "figure", "index", "caption":
            return isContainer ? beginCapture(.skipped) : .none
        case "q":
            return quote(attributes, isStart: isStart, isContainer: isContainer)
        case "divineName":
            return .closeSpan(collector.openSpan(.divineName))
        case "p":
            if isStart { collector.markParagraph() }
            return isContainer ? .breakLine : .none
        case "lg":
            if isStart {
                if linesInGroup > 0 { linesInPreviousGroup = linesInGroup }
                if linesInPreviousGroup > 1 { collector.markStanzaBreak() }
                linesInGroup = 0
            } else {
                collector.breakLine()
            }
            return isContainer ? .breakLine : .none
        case "l":
            guard isStart else {
                collector.breakLine()
                return .none
            }
            if attributes["type"] == "selah" {
                return isContainer ? .closeSpan(collector.openSpan(.selah)) : .none
            }
            linesInGroup += 1
            collector.markPoetryLine(indent: attributes["level"].flatMap(Int.init) ?? 1)
            return isContainer ? .breakLine : .none
        case "lb", "list", "item", "table", "row", "cell", "head":
            collector.breakLine()
            return isContainer ? .breakLine : .none
        case "milestone":
            if attributes["type"] == "x-p" || attributes["type"] == "pilcrow" || attributes["marker"] == "¶" {
                collector.markParagraph()
            }
            return .none
        default:
            collector.noteUnrecognized("<\(name)>")
            return .none
        }
    }

    private func startInHeader(_ name: String, attributes: [String: String]) -> Effect {
        switch name {
        case "work":
            readingWork = !finishedWork
            return .none
        case "title", "language", "rights":
            return readingWork ? beginCapture(.metadata(key: name, text: "")) : .none
        default:
            return .none
        }
    }

    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = XMLTranslationReader.localName(elementName)
        if name == "header" {
            headerDepth -= 1
        } else if name == "work", readingWork {
            readingWork = false
            finishedWork = true
        }
        super.parser(parser, didEndElement: elementName, namespaceURI: namespaceURI, qualifiedName: qualifiedName)
    }

    private func startDivision(_ attributes: [String: String], isStart: Bool, isContainer: Bool) -> Effect {
        guard isStart else { return .none }
        switch attributes["type"] {
        case "book":
            guard let id = attributes["osisID"] ?? attributes["sID"] else { return .none }
            if let book = LampCanonicalBooks.book(osisID: id) {
                if collector.bookNumber != book.number { collector.startBook(book.number) }
            } else {
                collector.skipBook(id)
            }
            quoteSpans = [:]
            return .none
        case "paragraph", "x-p":
            collector.markParagraph()
            return isContainer ? .breakLine : .none
        case "introduction", "front", "back", "preface", "titlePage", "glossary", "coverPage", "index":
            return isContainer ? beginCapture(.skipped) : .none
        default:
            return .none
        }
    }

    private func startVerse(_ identifier: String?) {
        let references = (identifier ?? "").split(whereSeparator: \.isWhitespace)
        guard let first = references.first, let start = location(String(first)), let verse = start.verse else {
            return
        }
        guard let book = start.book else {
            collector.skipBook(String(first.split(separator: ".").first ?? first))
            return
        }
        ensureLocation(book: book, chapter: start.chapter)
        let last = references.count > 1 ? location(String(references[references.count - 1]))?.verse : nil
        collector.startVerse(verse, through: last)
    }

    private func quote(_ attributes: [String: String], isStart: Bool, isContainer: Bool) -> Effect {
        let marker = attributes["marker"] ?? ""
        if isContainer {
            return attributes["who"] == "Jesus" ? .closeSpan(collector.openSpan(.redLetter)) : .none
        }
        if isStart {
            collector.appendText(marker)
            if attributes["who"] == "Jesus", let id = attributes["sID"] {
                quoteSpans[id] = collector.openSpan(.redLetter)
            }
        } else {
            if let id = attributes["eID"], let span = quoteSpans.removeValue(forKey: id) {
                collector.closeSpan(span)
            }
            collector.appendText(marker)
        }
        return .none
    }

    private func word(_ attributes: [String: String]) -> Effect {
        guard let lemmaAttribute = attributes["lemma"], lemmaAttribute.contains("strong:") else { return .none }
        let lemmas = lemmaAttribute.split(whereSeparator: \.isWhitespace)
        let strongs = lemmas.compactMap { $0.hasPrefix("strong:") ? String($0.dropFirst("strong:".count)) : nil }
        let lemma = lemmas.first { $0.hasPrefix("lemma.") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last.map(String.init) }
        let morphology = (attributes["morph"] ?? "").split(whereSeparator: \.isWhitespace)
            .map { USFMTranslationReader.withoutMorphologyScheme(String($0)) }
        return .closeSpan(collector.openSpan(.word(
            strongs: strongs,
            morphology: morphology.isEmpty ? nil : morphology.joined(separator: ","),
            lemma: lemma
        )))
    }

    /// "Gen.1.1" → (1, 1, 1); a book outside the 66 gives a nil book.
    private func location(_ osisID: String?) -> (book: Int?, chapter: Int, verse: Int?)? {
        guard let osisID else { return nil }
        let parts = osisID.split(separator: "!").first.map { $0.split(separator: ".") } ?? []
        guard parts.count >= 2, let chapter = Int(parts[1]) else { return nil }
        let verse = parts.count >= 3 ? Int(parts[2]) : nil
        return (LampCanonicalBooks.book(osisID: String(parts[0]))?.number, chapter, verse)
    }

    private static func footnoteKind(_ type: String?) -> String {
        switch type {
        case "variant": "manuscript"
        case "alternative": "alternate"
        case "explanation", "study": "explanation"
        default: "translation"
        }
    }
}

/// OSIS a verse at a time, as SWORD stores it. One delegate reads every
/// verse, so what runs across verses — words of Christ given as milestones —
/// carries on from one to the next.
final class OSISFragmentReader {
    private let delegate = OSISDelegate()

    var collector: TranslationCollector {
        get { delegate.collector }
        set { delegate.collector = newValue }
    }

    func read(_ fragment: String, osisID: String) {
        let parser = XMLParser(data: Data("<verse osisID=\"\(osisID)\">\(fragment)</verse>".utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard !parser.parse() else { return }
        // A verse that isn't well-formed keeps its words, without its markup.
        delegate.abandonOpenElements()
        delegate.collector.discardVerseText()
        delegate.collector.appendText(TagText.plain(fragment))
        delegate.collector.finishVerse()
        delegate.collector.noteUnrecognized("malformed OSIS")
    }
}

/// Text with its tags taken out and its entities read.
enum TagText {
    static func plain(_ markup: String) -> String {
        decodingEntities(markup.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
    }

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let afterAmpersand = rest[rest.index(after: ampersand)...]
            guard let semicolon = afterAmpersand.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = afterAmpersand
                continue
            }
            let name = afterAmpersand[..<semicolon]
            if let character = character(forEntity: String(name)) {
                result.append(character)
            } else {
                result += "&\(name);"
            }
            rest = afterAmpersand[afterAmpersand.index(after: semicolon)...]
        }
        return result + rest
    }

    private static func character(forEntity name: String) -> Character? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            let number = name.hasPrefix("#x") || name.hasPrefix("#X")
                ? UInt32(name.dropFirst(2), radix: 16)
                : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
            return number.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}

// MARK: - Zefania and plain XML

/// Zefania (`XMLBIBLE` / `BIBLEBOOK` / `CHAPTER` / `VERS`) and the plainer
/// formats shaped like it: `<b n><c n><v n>` and Beblia's
/// `<book number><chapter number><verse number>`.
private final class VerseXMLDelegate: XMLBibleDelegate {
    private var readingInformation = false

    override func start(_ name: String, attributes: [String: String]) -> Effect {
        let name = name.lowercased()
        if readingInformation {
            switch name {
            case "title", "identifier", "language", "rights":
                return beginCapture(.metadata(key: name == "identifier" ? "abbreviation" : name, text: ""))
            default:
                return .none
            }
        }

        switch name {
        case "xmlbible", "bible":
            metadata["title"] = metadata["title"] ?? attributes["biblename"] ?? attributes["translation"] ?? attributes["name"]
            return .none
        case "information":
            readingInformation = true
            return .none
        case "testament", "div", "sup":
            return .none
        case "biblebook", "book", "b":
            startBook(attributes)
            return .none
        case "chapter", "c":
            if collector.bookNumber != nil, let chapter = Self.number(attributes, keys: ["cnumber", "number", "n"]) {
                collector.startChapter(chapter)
            }
            return .none
        case "vers", "verse", "v":
            let value = attributes["vnumber"] ?? attributes["number"] ?? attributes["n"] ?? ""
            guard collector.chapterNumber != nil, let verse = Int(value.prefix(while: \.isNumber)) else {
                return .none
            }
            let afterDash = value.drop(while: { $0 != "-" }).dropFirst()
            collector.startVerse(verse, through: Int(afterDash.prefix(while: \.isNumber)))
            return .finishVerse
        case "caption":
            let beforeVerse = attributes["vref"].flatMap { Int($0.prefix(while: \.isNumber)) }
            return beginCapture(.heading(text: "", level: 1, beforeVerse: beforeVerse))
        case "gr", "gram":
            return word(attributes)
        case "style":
            guard let style = Self.style(attributes) else { return .none }
            return .closeSpan(collector.openSpan(style))
        case "note":
            return beginCapture(.note(text: "", kind: "translation"))
        case "br":
            collector.breakLine()
            return .none
        case "xref", "media", "prolog", "remark":
            return beginCapture(.skipped)
        default:
            collector.noteUnrecognized("<\(name)>")
            return .none
        }
    }

    override func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if XMLTranslationReader.localName(elementName).lowercased() == "information" {
            readingInformation = false
        }
        super.parser(parser, didEndElement: elementName, namespaceURI: namespaceURI, qualifiedName: qualifiedName)
    }

    private func startBook(_ attributes: [String: String]) {
        let name = attributes["bname"] ?? attributes["name"] ?? attributes["bsname"]
        if let number = Self.number(attributes, keys: ["bnumber", "number", "id", "n"]) {
            if let book = LampCanonicalBooks.book(number) {
                collector.startBook(book.number)
            } else {
                collector.skipBook(name ?? "Book \(number)")
            }
            return
        }
        let label = name ?? attributes["n"] ?? ""
        if let book = LampCanonicalBooks.book(named: label) {
            collector.startBook(book.number)
        } else {
            collector.skipBook(label.isEmpty ? "Unnamed book" : label)
        }
    }

    /// `str` holds bare numbers in Zefania; the testament says which lexicon.
    private func word(_ attributes: [String: String]) -> Effect {
        let prefix = (collector.bookNumber ?? 1) <= 39 ? "H" : "G"
        let strongs = (attributes["str"] ?? "").split(whereSeparator: \.isWhitespace).map { key in
            key.first?.isLetter == true ? String(key) : prefix + key
        }
        guard !strongs.isEmpty else { return .none }
        return .closeSpan(collector.openSpan(.word(strongs: strongs, morphology: attributes["rmac"])))
    }

    private static func style(_ attributes: [String: String]) -> SpanStyle? {
        let css = (attributes["css"] ?? "").lowercased().filter { !$0.isWhitespace }
        if css.contains("color:red") || css.contains("#ff0000") || css.contains("#f00") {
            return .redLetter
        }
        switch attributes["fs"]?.lowercased() {
        case "italic": return .added
        case "divinename", "small-caps": return .divineName
        default: return nil
        }
    }

    private static func number(_ attributes: [String: String], keys: [String]) -> Int? {
        for key in keys {
            if let value = attributes[key], let number = Int(value.trimmingCharacters(in: .whitespaces)) {
                return number
            }
        }
        return nil
    }
}
