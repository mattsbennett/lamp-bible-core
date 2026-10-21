import Foundation

/// Reads USFM, one book per `\id`, into a translation.
///
/// Paragraph and poetry markers, headings, words of Christ, added words, the
/// divine name, Selah, footnotes and Strong's numbers on `\w` map onto the
/// translation format. Introductions, cross-references, figures, published
/// verse numbers and reference ranges have no place in it and are dropped.
struct USFMTranslationReader {
    private enum Token {
        case marker(name: String, closing: Bool)
        /// The rest of the line after a marker such as `\id` or `\toc1`.
        case line(name: String, content: Substring)
        case chapter(String)
        case verse(String)
        /// `\*`, which ends a milestone's attributes.
        case milestoneEnd
        /// A marker written straight on to its attributes and closed by `\*`,
        /// as `\vid|MRK 7:9\*` in the official BSB: it marks a place and
        /// holds no text.
        case milestone(name: String)
        case text(Substring)
    }

    private enum Block {
        case text
        case heading(level: Int, text: String)
        case skipped
    }

    private enum Note {
        case footnote(text: String, awaitingCaller: Bool, skippingReference: Bool)
        case skipped
    }

    private struct CharacterSpan {
        let marker: String
        let spanID: Int?
        let dropsContent: Bool
        var attributes = ""
        var collectingAttributes = false
    }

    private var collector = TranslationCollector()
    /// The text after each book's code on its `\id` line. A translation's
    /// name is often there, the same in every book; a description that
    /// differs from book to book is the book's own.
    private var bookDescriptions: [String: Int] = [:]
    private var bookCount = 0
    private var inChapter = false
    private var block = Block.skipped
    /// What began the heading being read: an acrostic letter can come in
    /// two lines (`\qa ב`, `\qa BETH`) that are one heading.
    private var headingMarker: String?
    private var note: Note?
    private var spans: [CharacterSpan] = []
    private var skippingMilestoneAttributes = false
    /// After a `|` in a heading or note, the rest up to the next marker is the
    /// attributes of the marker it is in (`\ref Mark 1:3|MRK 1:3\ref*`).
    private var skippingAttributes = false

    mutating func read(_ text: String) {
        var tokenizer = Tokenizer(text)
        while let token = tokenizer.next() {
            handle(token)
        }
    }

    mutating func finish() throws -> LampImportedTranslation {
        endBlock()
        let books = collector.finish()
        guard !books.isEmpty else {
            throw LampTranslationImportError.noScripture(skippedBooks: collector.report.skippedBooks)
        }
        let commonDescription = bookDescriptions.max { $0.value < $1.value }
            .flatMap { bookCount == 1 || $0.value > 1 ? $0.key : nil }
        return LampImportedTranslation(
            format: .usfm,
            suggestedName: LampTranslationImporter.suggestion(commonDescription),
            suggestedAbbreviation: nil,
            language: nil,
            copyright: nil,
            report: collector.report,
            books: books
        )
    }

    private mutating func handle(_ token: Token) {
        if case .milestoneEnd = token {
            skippingMilestoneAttributes = false
            return
        }
        if case .text(let text) = token {
            route(text)
            return
        }
        skippingMilestoneAttributes = false
        skippingAttributes = false

        switch token {
        case .line(let name, let content):
            if name == "id" {
                startBook(content)
            }
        case .chapter(let number):
            endBlock()
            note = nil
            closeContentSpans()
            guard collector.bookNumber != nil else { return }
            if let chapter = Int(number.prefix(while: \.isNumber)) {
                collector.startChapter(chapter)
                inChapter = true
                block = .text
            } else {
                collector.noteUnrecognized("\\c \(number)")
            }
        case .verse(let number):
            endBlock()
            note = nil
            closeContentSpans()
            guard inChapter, let first = Int(number.prefix(while: \.isNumber)) else { return }
            let afterDash = number.drop(while: { $0 != "-" && $0 != "\u{2013}" }).dropFirst()
            // "1a", "1b": a verse in parts.
            let isPart = number.drop(while: \.isNumber).first?.isLetter == true
            collector.startVerse(first, through: Int(afterDash.prefix(while: \.isNumber)), continuing: isPart)
            block = .text
        case .marker(let name, let closing):
            closing ? close(name) : open(name)
        case .milestoneEnd, .milestone, .text:
            break
        }
    }

    private mutating func startBook(_ content: Substring) {
        endBlock()
        note = nil
        spans = []
        inChapter = false
        block = .skipped
        let code = String(content.prefix(while: { !$0.isWhitespace }).prefix(3)).uppercased()
        guard let book = LampCanonicalBooks.book(usfmCode: code) else {
            collector.skipBook(code, reported: !Self.peripheralBooks.contains(code))
            return
        }
        collector.startBook(book.number)
        bookCount += 1
        let description = content.dropFirst(code.count)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:")))
        if !description.isEmpty {
            bookDescriptions[description, default: 0] += 1
        }
    }

    // MARK: - Markers

    private mutating func open(_ name: String) {
        if name.hasSuffix("-s") || name.hasSuffix("-e") || name == "ts" {
            skippingMilestoneAttributes = true
            return
        }
        if Self.noteMarkers.contains(name) {
            // Notes in headings and introductions have no verse to belong to.
            if case .text = block, inChapter, Self.footnoteMarkers.contains(name) {
                note = .footnote(text: "", awaitingCaller: true, skippingReference: false)
            } else {
                note = .skipped
            }
            return
        }
        if case .footnote(let text, _, _) = note {
            // Inside a note every marker is a part of the note; only the
            // origin reference (\fr 3:16) repeats what the reader shows.
            note = .footnote(text: text, awaitingCaller: false, skippingReference: name == "fr" || name == "xo")
            return
        }
        if note != nil { return }

        if let level = Self.headingLevels[name] {
            if name == "qa", headingMarker == "qa", case .heading(let level, let text) = block {
                block = .heading(level: level, text: text + " ")
                return
            }
            endBlock()
            block = inChapter ? .heading(level: level, text: "") : .skipped
            headingMarker = name
            return
        }
        if Self.paragraphMarkers.contains(name) {
            endBlock()
            if inChapter {
                block = .text
                collector.markParagraph()
            }
            return
        }
        if let indent = Self.poetryMarkers[name] {
            endBlock()
            if inChapter {
                block = .text
                collector.markPoetryLine(indent: indent)
            }
            return
        }
        if Self.lineBreakMarkers.contains(name) {
            endBlock()
            if inChapter {
                block = .text
                collector.breakLine()
            }
            return
        }
        switch name {
        case "b":
            endBlock()
            if inChapter {
                block = .text
                collector.markStanzaBreak()
            }
            return
        case "nb":
            endBlock()
            if inChapter { block = .text }
            return
        default:
            break
        }
        if Self.skippedBlocks.contains(name) || Self.isIntroduction(name) {
            endBlock()
            block = .skipped
            return
        }

        guard case .text = block else { return }
        if let style = Self.styles[name] {
            spans.append(CharacterSpan(marker: name, spanID: collector.openSpan(style), dropsContent: false))
        } else if name == "w" {
            spans.append(CharacterSpan(marker: name, spanID: collector.openSpan(.word(strongs: [])), dropsContent: false))
        } else if Self.droppedContent.contains(name) {
            spans.append(CharacterSpan(marker: name, spanID: nil, dropsContent: true))
        } else {
            if !Self.plainStyles.contains(name) {
                collector.noteUnrecognized("\\\(name)")
            }
            spans.append(CharacterSpan(marker: name, spanID: nil, dropsContent: false))
        }
    }

    private mutating func close(_ name: String) {
        if Self.noteMarkers.contains(name) {
            if case .footnote(let text, _, _) = note {
                collector.addFootnote(text)
            }
            note = nil
            return
        }
        if case .footnote(let text, _, _) = note {
            note = .footnote(text: text, awaitingCaller: false, skippingReference: false)
            return
        }
        if note != nil { return }
        guard let index = spans.lastIndex(where: { $0.marker == name }) else { return }
        // Anything opened inside it and left open ends with it.
        while spans.count > index {
            end(spans.removeLast())
        }
    }

    private mutating func end(_ span: CharacterSpan) {
        guard let id = span.spanID else { return }
        guard span.marker == "w" else {
            collector.closeSpan(id)
            return
        }
        let attributes = Self.attributes(span.attributes, defaultName: "lemma")
        let strongs = (attributes["strong"] ?? "")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        collector.closeSpan(id, style: .word(
            strongs: strongs,
            morphology: attributes["x-morph"].map(Self.withoutMorphologyScheme),
            lemma: attributes["lemma"]
        ))
    }

    /// A verse or chapter ends spans whose content is not verse text (a
    /// published verse number, a word's attributes) even if the file never
    /// closes them; spans of verse text carry on.
    private mutating func closeContentSpans() {
        while let index = spans.lastIndex(where: { $0.dropsContent || $0.collectingAttributes }) {
            while spans.count > index {
                end(spans.removeLast())
            }
        }
    }

    private mutating func endBlock() {
        if case .heading(let level, let text) = block {
            collector.addHeading(text, level: level)
        }
        headingMarker = nil
        block = inChapter ? .text : .skipped
    }

    // MARK: - Text

    private mutating func route(_ text: Substring) {
        guard !skippingMilestoneAttributes else { return }

        switch note {
        case .footnote(var noteText, let awaitingCaller, let skippingReference):
            guard !skippingAttributes else { return }
            var text = text
            if awaitingCaller {
                // The caller (+, -, or a letter) comes first and isn't content.
                text = text.drop(while: \.isWhitespace).drop(while: { !$0.isWhitespace })
            }
            if let bar = text.firstIndex(of: "|") {
                text = text[..<bar]
                skippingAttributes = true
            }
            if !skippingReference {
                noteText += text
            }
            note = .footnote(text: noteText, awaitingCaller: false, skippingReference: skippingReference)
            return
        case .skipped:
            return
        case nil:
            break
        }

        switch block {
        case .skipped:
            return
        case .heading(let level, var heading):
            guard !skippingAttributes else { return }
            if let bar = text.firstIndex(of: "|") {
                heading += text[..<bar]
                skippingAttributes = true
            } else {
                heading += text
            }
            block = .heading(level: level, text: heading)
            return
        case .text:
            break
        }

        if let index = spans.indices.last, spans[index].collectingAttributes {
            spans[index].attributes += text
            return
        }
        if spans.contains(where: \.dropsContent) { return }
        if let index = spans.indices.last, let bar = text.firstIndex(of: "|") {
            collector.appendText(text[..<bar])
            spans[index].attributes = String(text[text.index(after: bar)...])
            spans[index].collectingAttributes = true
            return
        }
        collector.appendText(text)
    }

    /// `strong="H1234" x-morph="…"`, or a bare value for the marker's
    /// default attribute (`\w gracious|grace\w*`).
    private static func attributes(_ text: String, defaultName: String) -> [String: String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("=") else {
            return text.isEmpty ? [:] : [defaultName: text]
        }
        var attributes: [String: String] = [:]
        var rest = Substring(text)
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...].drop(while: \.isWhitespace)
            guard rest.first == "\"" else { break }
            rest = rest.dropFirst()
            guard let quote = rest.firstIndex(of: "\"") else { break }
            attributes[name] = String(rest[..<quote])
            rest = rest[rest.index(after: quote)...]
        }
        return attributes
    }

    static func withoutMorphologyScheme(_ morphology: String) -> String {
        for scheme in ["strongMorph:", "robinson:"] where morphology.hasPrefix(scheme) {
            return String(morphology.dropFirst(scheme.count))
        }
        return morphology
    }

    // MARK: - Marker tables

    private static let headingLevels: [String: Int] = [
        "s": 1, "s1": 1, "s2": 2, "s3": 3, "s4": 4,
        "ms": 1, "ms1": 1, "ms2": 2, "ms3": 3,
        "mt": 1, "mt1": 1, "mt2": 2, "mt3": 3, "mt4": 4,
        // Psalm titles, speakers and acrostic letters sit above their verse.
        "d": 2, "sp": 2, "qa": 2,
    ]

    private static let paragraphMarkers: Set<String> = [
        "p", "m", "po", "pr", "pc", "cls", "pmo", "pm", "pmc", "pmr", "mi",
        "pi", "pi1", "pi2", "pi3", "pi4", "ph", "ph1", "ph2", "ph3",
        "li", "li1", "li2", "li3", "li4", "lh", "lf", "lim", "lim1", "lim2", "lim3",
    ]

    private static let poetryMarkers: [String: Int] = [
        "q": 1, "q1": 1, "q2": 2, "q3": 3, "q4": 4,
        "qc": 1, "qr": 1, "qd": 1, "qm": 1, "qm1": 1, "qm2": 2, "qm3": 3,
    ]

    /// Table rows and cells: the words stay apart, the table doesn't survive.
    private static let lineBreakMarkers: Set<String> = [
        "tr", "th1", "th2", "th3", "th4", "thr1", "thr2", "thr3", "thr4",
        "tc1", "tc2", "tc3", "tc4", "tcr1", "tcr2", "tcr3", "tcr4",
    ]

    /// Reference ranges, chapter descriptions and other blocks with no place
    /// in a verse.
    private static let skippedBlocks: Set<String> = [
        "r", "mr", "sr", "sd", "sd1", "sd2", "sd3", "sd4", "cd", "lit", "pb", "periph", "mte", "mte1", "mte2",
    ]

    private static func isIntroduction(_ name: String) -> Bool {
        guard name.hasPrefix("i"), name != "it" else { return false }
        let base = name.dropFirst().prefix(while: \.isLetter)
        return ["mt", "mte", "s", "p", "pi", "m", "mi", "pq", "mq", "pr", "q", "b", "li", "ot", "o", "ex", "e"]
            .contains(String(base))
    }

    /// Footnotes, endnotes, and the cross-references and figures that are
    /// written like them but dropped.
    private static let noteMarkers: Set<String> = ["f", "fe", "ef", "x", "ex", "fig"]
    private static let footnoteMarkers: Set<String> = ["f", "fe", "ef"]

    private static let styles: [String: SpanStyle] = [
        "wj": .redLetter, "add": .added, "nd": .divineName, "qs": .selah,
    ]

    /// Character styles whose text is verse text, shown without the style.
    private static let plainStyles: Set<String> = [
        "bd", "it", "bdit", "em", "sc", "no", "sup", "ord", "pn", "png", "bk", "k", "tl",
        "sig", "sls", "qt", "qac", "lik", "liv", "liv1", "liv2", "litl", "dc", "wg", "wh", "wa",
        "rb", "pro", "ndx", "addpn", "jmp", "xt", "ref", "fv",
    ]

    /// Character styles whose content isn't verse text: published and
    /// alternate verse and chapter numbers, inline quotation references.
    private static let droppedContent: Set<String> = ["va", "vp", "ca", "rq", "cat", "fm"]

    private static let peripheralBooks: Set<String> = [
        "FRT", "BAK", "OTH", "INT", "CNC", "GLO", "TDX", "NDX",
        "XXA", "XXB", "XXC", "XXD", "XXE", "XXF", "XXG",
    ]

    // MARK: - Tokenizer

    private struct Tokenizer {
        private let bytes: [UInt8]
        private var position = 0

        init(_ text: String) {
            bytes = Array(text.utf8)
            // A byte-order mark is not text.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
        }

        private static let backslash = UInt8(ascii: "\\")
        private static let lineMarkers: Set<String> = [
            "id", "ide", "sts", "rem", "usfm", "h", "h1", "h2", "h3",
            "toc1", "toc2", "toc3", "toca1", "toca2", "toca3", "cl", "cp",
        ]

        mutating func next() -> Token? {
            guard position < bytes.count else { return nil }
            guard bytes[position] == Self.backslash, let marker = readMarker() else {
                return readText()
            }
            return marker
        }

        private mutating func readText() -> Token {
            let start = position
            position += 1
            while position < bytes.count, bytes[position] != Self.backslash {
                position += 1
            }
            return .text(substring(start, position))
        }

        private mutating func readMarker() -> Token? {
            var cursor = position + 1
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == UInt8(ascii: "*") {
                position = cursor + 1
                return .milestoneEnd
            }
            if bytes[cursor] == UInt8(ascii: "+") { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, Self.isNameByte(bytes[cursor]) {
                cursor += 1
            }
            guard cursor > nameStart else { return nil }
            let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "*") {
                position = cursor + 1
                return .marker(name: name, closing: true)
            }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "|") {
                position = cursor + 1
                while position + 1 < bytes.count, !(bytes[position] == Self.backslash && bytes[position + 1] == UInt8(ascii: "*")) {
                    position += 1
                }
                position = min(bytes.count, position + 2)
                return .milestone(name: name)
            }
            position = cursor
            skipOneSpace()

            if name == "c" || name == "v" {
                while position < bytes.count, bytes[position] == UInt8(ascii: " ") || bytes[position] == UInt8(ascii: "\t") {
                    position += 1
                }
                let start = position
                while position < bytes.count, !Self.isSpace(bytes[position]), bytes[position] != Self.backslash {
                    position += 1
                }
                let number = String(substring(start, position))
                skipOneSpace()
                return name == "c" ? .chapter(number) : .verse(number)
            }
            if Self.lineMarkers.contains(name) {
                let start = position
                while position < bytes.count, bytes[position] != UInt8(ascii: "\n"), bytes[position] != Self.backslash {
                    position += 1
                }
                return .line(name: name, content: substring(start, position))
            }
            return .marker(name: name, closing: false)
        }

        private mutating func skipOneSpace() {
            guard position < bytes.count, Self.isSpace(bytes[position]) else { return }
            if bytes[position] == UInt8(ascii: "\r"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "\n") {
                position += 1
            }
            position += 1
        }

        private func substring(_ start: Int, _ end: Int) -> Substring {
            Substring(String(decoding: bytes[start..<end], as: UTF8.self))
        }

        private static func isNameByte(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "-")
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        }
    }
}
