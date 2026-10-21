import Foundation

struct ImportedAnnotation: Equatable, Sendable {
    let kind: String
    let start: Int
    let end: Int
    let strongs: String?
    let morphology: String?
    let lemma: String?
}

struct ImportedFootnote: Equatable, Sendable {
    let id: String
    let kind: String
    let content: String
    /// Where the note's marker sits in the verse text.
    let offset: Int
}

struct ImportedVerse: Equatable, Sendable {
    let number: Int
    let text: String
    let annotations: [ImportedAnnotation]
    let footnotes: [ImportedFootnote]
    let paragraph: Bool
    let poetryIndent: Int
    let stanzaBreak: Bool
}

struct ImportedHeading: Equatable, Sendable {
    let beforeVerse: Int
    let level: Int
    let text: String
}

struct ImportedChapter: Equatable, Sendable {
    let number: Int
    let headings: [ImportedHeading]
    let verses: [ImportedVerse]
}

struct ImportedBook: Equatable, Sendable {
    let number: Int
    let chapters: [ImportedChapter]
}

/// A run of verse text with a meaning the reader shows: words of Christ,
/// added words, the divine name, Selah, or a word with its Strong's number.
struct SpanStyle: Equatable {
    var kind: String
    var strongs: String?
    var morphology: String?
    var lemma: String?

    static let redLetter = SpanStyle(kind: "red-letter")
    static let added = SpanStyle(kind: "added")
    static let divineName = SpanStyle(kind: "divine-name")
    static let selah = SpanStyle(kind: "selah")

    static func word(strongs: [String], morphology: String? = nil, lemma: String? = nil) -> SpanStyle {
        let keys = representedStrongs(strongs)
        return SpanStyle(
            kind: "strongs",
            strongs: keys.isEmpty ? nil : keys.joined(separator: ","),
            morphology: morphology,
            lemma: lemma
        )
    }

    /// H853 marks the untranslated Hebrew direct object. English texts tie it
    /// to the neighbouring translated word, where it would make that word look
    /// as though it stood for H853, so it is left off.
    static func representedStrongs(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { key in
            guard let normalized = normalizedStrongs(key), normalized != "H853",
                  seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    /// "H07225" → "H7225"; anything after the number ("H1234a") is dropped.
    static func normalizedStrongs(_ key: String) -> String? {
        guard let prefix = key.first.map({ Character($0.uppercased()) }), prefix == "H" || prefix == "G" else {
            return nil
        }
        let digits = key.dropFirst().prefix(while: \.isNumber)
        guard let number = Int(digits) else { return nil }
        return "\(prefix)\(number)"
    }
}

/// Verse text as it arrives in pieces from a source file: runs of whitespace
/// become one space, and none is left at either end. Offsets count
/// `Character`s, as the reader's annotation offsets do.
struct VerseTextBuilder {
    private(set) var characters: [Character] = []
    private var spaceIsPending = false
    /// A space written before a note's marker ("Mahanaim \f…\f*?") belongs
    /// to the note, not to punctuation that follows it.
    private var spaceIsBeforeNote = false
    /// A note between a clause's punctuation and the next word, with no
    /// space either side (`Hebrew,\f…\f*\wj ‘Saul`): the word still needs one.
    private var noteFollowsPunctuation = false

    var isEmpty: Bool { characters.isEmpty }
    var length: Int { characters.count }
    /// Where the next visible character will land.
    var nextOffset: Int { characters.count + (spaceIsPending ? 1 : 0) }
    var text: String { String(characters) }

    mutating func append<S: StringProtocol>(_ piece: S) {
        var isFirst = true
        for character in piece {
            defer { isFirst = false }
            if Self.isSpace(character) {
                spaceIsPending = !characters.isEmpty
                noteFollowsPunctuation = false
                continue
            }
            if noteFollowsPunctuation {
                noteFollowsPunctuation = false
                if character.isLetter || Self.openingQuotes.contains(character) {
                    characters.append(" ")
                }
            }
            if spaceIsPending {
                spaceIsPending = false
                if !(spaceIsBeforeNote && Self.closingPunctuation.contains(character)) {
                    characters.append(" ")
                }
                spaceIsBeforeNote = false
                appendJoining(character)
            } else if isFirst {
                appendJoining(character)
            } else {
                characters.append(character)
            }
        }
    }

    /// Asked of every character of a Bible: ASCII is answered without a
    /// Unicode property lookup.
    static func isSpace(_ character: Character) -> Bool {
        if let ascii = character.asciiValue {
            return ascii == 32 || (9...13).contains(ascii)
        }
        return character.isWhitespace
    }

    /// A line or block boundary: words on either side stay apart.
    mutating func appendSpace() {
        if !characters.isEmpty { spaceIsPending = true }
    }

    /// Where a footnote's marker goes: after the last character, before any
    /// space still to come.
    mutating func anchorNote() -> Int {
        spaceIsBeforeNote = spaceIsPending
        noteFollowsPunctuation = !spaceIsPending && characters.last.map(Self.clausePunctuation.contains) == true
        return characters.count
    }

    private static let clausePunctuation: Set<Character> = [",", ";", ":", ".", "!", "?"]
    private static let openingQuotes: Set<Character> = ["‘", "“", "\"", "'", "(", "["]

    private static let closingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "\u{2019}", "\u{201D}", "\u{00BB}", "\u{203A}", "\u{2026}",
    ]

    /// The last word written, without punctuation after it: where GBF and
    /// ThML put a Strong's number, after the word it belongs to.
    var precedingWordRange: Range<Int>? {
        var end = characters.count
        while end > 0, !Self.isWordCharacter(characters[end - 1]) { end -= 1 }
        var start = end
        while start > 0, Self.isWordCharacter(characters[start - 1]) { start -= 1 }
        return start < end ? start..<end : nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "’" || character == "'" || character == "-"
    }

    func trimmedRange(from start: Int, to end: Int) -> Range<Int>? {
        var start = max(0, start)
        let end = min(end, characters.count)
        while start < end, characters[start] == " " { start += 1 }
        return start < end ? start..<end : nil
    }

    /// A piece can start with a mark that belongs to the previous piece's
    /// last character (a Hebrew vowel point, an accent), and the finished
    /// string would count the two as one character.
    private mutating func appendJoining(_ character: Character) {
        if let last = characters.last {
            let joined = String(last) + String(character)
            if joined.count == 1 {
                characters[characters.count - 1] = Character(joined)
                return
            }
        }
        characters.append(character)
    }
}

/// A translation as a reader walks its source: books, chapters and verses
/// in whatever order and markup the source uses, kept in the 66-book grid.
///
/// Readers call the `mark…` methods where the source starts a paragraph,
/// poetry line or stanza. Where that happens before a verse begins, the verse
/// takes it; inside a verse it only keeps the words on either side apart,
/// because the translation format records them for whole verses.
struct TranslationCollector {
    private struct Chapter {
        var headings: [ImportedHeading] = []
        var verses: [Int: ImportedVerse] = [:]
    }

    private struct OpenVerse {
        let number: Int
        let isDuplicate: Bool
        var text = VerseTextBuilder()
        var annotations: [ImportedAnnotation] = []
        var footnotes: [ImportedFootnote] = []
        var paragraph: Bool
        var poetryIndent: Int
        var stanzaBreak: Bool
    }

    private struct ActiveSpan {
        let id: Int
        var style: SpanStyle
        var start: Int
    }

    private(set) var report = LampTranslationImportReport()
    private(set) var bookNumber: Int?
    private(set) var chapterNumber: Int?
    private var chapters: [Int: [Int: Chapter]] = [:]
    private var verse: OpenVerse?
    /// A heading marked inside a verse is `midVerse`. The format has no place
    /// inside a verse for it, so it goes before the next verse — where the
    /// last one still applies (a speaker who carries on, a section that has
    /// begun) but any earlier one in the same verse no longer does.
    private var pendingHeadings: [(level: Int, text: String, midVerse: Bool)] = []
    private var pendingParagraph = false
    private var pendingPoetryIndent = 0
    private var pendingStanzaBreak = false
    private var spans: [ActiveSpan] = []
    private var nextSpanID = 0
    private var footnoteCount = 0

    mutating func startBook(_ number: Int) {
        finishVerse()
        bookNumber = number
        chapterNumber = nil
        resetBookState()
    }

    /// A book outside the 66, named as the source names it. Its text is
    /// dropped until the next book starts. Front and back matter (a preface,
    /// a glossary) isn't Scripture and isn't reported.
    mutating func skipBook(_ identifier: String, reported: Bool = true) {
        finishVerse()
        bookNumber = nil
        chapterNumber = nil
        resetBookState()
        if reported, !report.skippedBooks.contains(identifier) {
            report.skippedBooks.append(identifier)
        }
    }

    mutating func startChapter(_ number: Int) {
        finishVerse()
        guard bookNumber != nil else { return }
        chapterNumber = number
    }

    /// `last` is the end of a bridge such as 16–17; Lamp keeps the bridge's
    /// text under its first verse. The next part of a verse given in parts
    /// (1a, 1b) is `continuing` it.
    mutating func startVerse(_ number: Int, through last: Int? = nil, continuing: Bool = false) {
        guard bookNumber != nil, chapterNumber != nil else {
            finishVerse()
            return
        }
        if continuing, verse?.number == number {
            verse?.text.appendSpace()
            return
        }
        finishVerse()
        if let last, last > number {
            report.verseBridges.append(reference(number))
        }
        verse = OpenVerse(
            number: number,
            isDuplicate: currentChapter?.verses[number] != nil,
            paragraph: pendingParagraph,
            poetryIndent: pendingPoetryIndent,
            // A break marked at the end of the last chapter has no stanza to
            // break from here.
            stanzaBreak: pendingStanzaBreak && currentChapter?.verses.isEmpty == false
        )
        for index in spans.indices {
            spans[index].start = 0
        }
        // A verse 0 is a Psalm title; what comes before it belongs to verse 1.
        guard number != 0 else { return }
        for heading in pendingHeadings {
            appendHeading(heading.text, level: heading.level, beforeVerse: number)
        }
        pendingHeadings = []
        pendingParagraph = false
        pendingPoetryIndent = 0
        pendingStanzaBreak = false
    }

    mutating func finishVerse() {
        guard var finished = verse else { return }
        verse = nil
        for span in spans {
            Self.annotate(&finished, with: span)
        }
        guard let chapterNumber, let bookNumber else { return }
        let text = finished.text.text
        guard !text.isEmpty else {
            // A verse a translation leaves out (it may be only a footnote)
            // passes its paragraph and line to the verse that takes its place.
            pendingParagraph = pendingParagraph || finished.paragraph
            pendingPoetryIndent = pendingPoetryIndent == 0 ? finished.poetryIndent : pendingPoetryIndent
            pendingStanzaBreak = pendingStanzaBreak || finished.stanzaBreak
            return
        }
        if finished.isDuplicate {
            report.duplicateVerses.append(reference(finished.number))
            return
        }
        if finished.number == 0 {
            pendingHeadings.append((level: 2, text: text, midVerse: false))
            return
        }
        chapters[bookNumber, default: [:]][chapterNumber, default: Chapter()].verses[finished.number] = ImportedVerse(
            number: finished.number,
            text: text,
            annotations: Self.joiningAdjacentSpans(finished.annotations),
            footnotes: finished.footnotes,
            paragraph: finished.paragraph,
            poetryIndent: finished.poetryIndent,
            stanzaBreak: finished.stanzaBreak
        )
    }

    mutating func appendText<S: StringProtocol>(_ text: S) {
        guard verse != nil else { return }
        // Text from XMLParser is Foundation's; walking it a Character at a
        // time is several times faster once it is Swift's own.
        var text = String(text)
        text.makeContiguousUTF8()
        if text.contains(where: { !VerseTextBuilder.isSpace($0) }) {
            // Anything still pending was marked inside this verse.
            pendingParagraph = false
            pendingPoetryIndent = 0
            pendingStanzaBreak = false
            if let last = pendingHeadings.lastIndex(where: \.midVerse) {
                pendingHeadings = pendingHeadings.enumerated()
                    .filter { !$0.element.midVerse || $0.offset == last }
                    .map(\.element)
            }
        }
        verse?.text.append(text)
    }

    var lastCharacter: Character? { verse?.text.characters.last }

    mutating func breakLine() {
        verse?.text.appendSpace()
    }

    mutating func markParagraph() {
        if verse?.text.isEmpty == true {
            verse?.paragraph = true
        } else {
            breakLine()
            pendingParagraph = true
        }
    }

    mutating func markPoetryLine(indent: Int) {
        let indent = max(1, indent)
        if verse?.text.isEmpty == true {
            verse?.poetryIndent = indent
        } else {
            breakLine()
            pendingPoetryIndent = indent
        }
    }

    /// Ignored before a chapter's first words, where there is no stanza to
    /// break from.
    mutating func markStanzaBreak() {
        let chapterHasText = currentChapter?.verses.isEmpty == false || verse?.text.isEmpty == false
        guard chapterHasText else { return }
        if verse?.text.isEmpty == true {
            verse?.stanzaBreak = true
        } else {
            breakLine()
            pendingStanzaBreak = true
        }
    }

    /// A heading goes before `beforeVerse` when the source says which verse;
    /// otherwise before the verse being read if none of its words have come
    /// yet, or else the next verse.
    mutating func addHeading(_ text: String, level: Int, beforeVerse: Int? = nil) {
        let text = Self.collapsingWhitespace(text)
        guard !text.isEmpty else { return }
        if let beforeVerse {
            appendHeading(text, level: level, beforeVerse: beforeVerse)
        } else if let verse, verse.text.isEmpty, verse.number != 0, !verse.isDuplicate {
            appendHeading(text, level: level, beforeVerse: verse.number)
        } else {
            pendingHeadings.append((level: level, text: text, midVerse: verse?.text.isEmpty == false))
        }
    }

    /// Spans stay open across verses until closed — words of Christ often run
    /// on for several — and each verse gets its own annotation for its part.
    mutating func openSpan(_ style: SpanStyle) -> Int {
        nextSpanID += 1
        spans.append(ActiveSpan(id: nextSpanID, style: style, start: verse?.text.nextOffset ?? 0))
        return nextSpanID
    }

    /// `style` replaces the span's style, for formats that give a word's
    /// Strong's number after the word.
    mutating func closeSpan(_ id: Int, style: SpanStyle? = nil) {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return }
        var span = spans.remove(at: index)
        if let style {
            span.style = style
        }
        if verse != nil {
            Self.annotate(&verse!, with: span)
        }
    }

    mutating func addFootnote(_ content: String, kind: String = "translation") {
        let content = Self.collapsingWhitespace(content)
        guard let offset = verse?.text.anchorNote(), !content.isEmpty else { return }
        footnoteCount += 1
        verse?.footnotes.append(ImportedFootnote(
            id: String(footnoteCount),
            kind: kind,
            content: content,
            offset: offset
        ))
    }

    mutating func annotatePrecedingWord(with style: SpanStyle) {
        guard let range = verse?.text.precedingWordRange,
              style.kind != "strongs" || style.strongs != nil else { return }
        verse?.annotations.append(ImportedAnnotation(
            kind: style.kind, start: range.lowerBound, end: range.upperBound,
            strongs: style.strongs, morphology: style.morphology, lemma: style.lemma
        ))
    }

    /// Clears what has been written of the verse being read, for a reader
    /// that found its markup broken and will write it again plainly.
    mutating func discardVerseText() {
        verse?.text = VerseTextBuilder()
        verse?.annotations = []
        verse?.footnotes = []
        for index in spans.indices {
            spans[index].start = 0
        }
    }

    /// Books a source holds that the reader didn't open, such as a SWORD
    /// module's Apocrypha.
    mutating func noteSkippedBook(_ identifier: String) {
        if !report.skippedBooks.contains(identifier) {
            report.skippedBooks.append(identifier)
        }
    }

    mutating func noteUnrecognized(_ markup: String) {
        report.unrecognizedMarkup[markup, default: 0] += 1
    }

    mutating func finish() -> [ImportedBook] {
        finishVerse()
        let books = chapters.keys.sorted().compactMap { bookNumber -> ImportedBook? in
            let bookChapters = chapters[bookNumber, default: [:]]
                .sorted { $0.key < $1.key }
                .compactMap { number, chapter -> ImportedChapter? in
                    guard !chapter.verses.isEmpty else { return nil }
                    return ImportedChapter(
                        number: number,
                        headings: chapter.headings,
                        verses: chapter.verses.values.sorted { $0.number < $1.number }
                    )
                }
            return bookChapters.isEmpty ? nil : ImportedBook(number: bookNumber, chapters: bookChapters)
        }
        report.bookCount = books.count
        report.chapterCount = books.reduce(0) { $0 + $1.chapters.count }
        report.verseCount = books.reduce(0) { total, book in
            book.chapters.reduce(total) { $0 + $1.verses.count }
        }
        return books
    }

    /// Sources often close and reopen a span around a footnote or at a
    /// poetry line (`\wj only born\wj*\f…\f* \wj Son…`). Runs of the same
    /// kind with only a space between are one run to a reader.
    static func joiningAdjacentSpans(_ annotations: [ImportedAnnotation]) -> [ImportedAnnotation] {
        var joined: [ImportedAnnotation] = []
        for annotation in annotations.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if annotation.kind != "strongs",
               let index = joined.lastIndex(where: { $0.kind == annotation.kind }),
               joined[index].end <= annotation.start, annotation.start <= joined[index].end + 1 {
                let previous = joined[index]
                joined[index] = ImportedAnnotation(
                    kind: previous.kind, start: previous.start, end: annotation.end,
                    strongs: nil, morphology: nil, lemma: nil
                )
            } else {
                joined.append(annotation)
            }
        }
        return joined
    }

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var currentChapter: Chapter? {
        guard let bookNumber, let chapterNumber else { return nil }
        return chapters[bookNumber]?[chapterNumber]
    }

    private func reference(_ verse: Int) -> Int {
        (bookNumber ?? 0) * 1_000_000 + (chapterNumber ?? 0) * 1_000 + verse
    }

    private mutating func appendHeading(_ text: String, level: Int, beforeVerse: Int) {
        guard let bookNumber, let chapterNumber else { return }
        chapters[bookNumber, default: [:]][chapterNumber, default: Chapter()].headings.append(
            ImportedHeading(beforeVerse: beforeVerse, level: level, text: text)
        )
    }

    private static func annotate(_ open: inout OpenVerse, with span: ActiveSpan) {
        guard span.style.kind != "strongs" || span.style.strongs != nil,
              let range = open.text.trimmedRange(from: span.start, to: open.text.length) else { return }
        open.annotations.append(ImportedAnnotation(
            kind: span.style.kind,
            start: range.lowerBound,
            end: range.upperBound,
            strongs: span.style.strongs,
            morphology: span.style.morphology,
            lemma: span.style.lemma
        ))
    }

    private mutating func resetBookState() {
        pendingHeadings = []
        pendingParagraph = false
        pendingPoetryIndent = 0
        pendingStanzaBreak = false
        spans = []
        footnoteCount = 0
    }
}
