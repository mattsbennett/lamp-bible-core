import Foundation

/// A passage a book cites: a verse reference (book × 1,000,000 + chapter ×
/// 1,000 + verse), and the verse it runs to, when it runs past that one.
public struct LampBookPassage: Codable, Hashable, Sendable {
    public let start: Int
    public let end: Int?

    public init(start: Int, end: Int? = nil) {
        self.start = start
        self.end = end
    }

    /// The passages an annotation cites: its own range first, then each of its
    /// `refs` not already listed.
    public static func passages(of annotation: LampBookAnnotation) -> [LampBookPassage] {
        guard let data = annotation.data else { return [] }
        var passages: [LampBookPassage] = []
        if let start = data.startReference {
            passages.append(LampBookPassage(start: start, end: data.endReference))
        }
        for range in data.references {
            let passage = LampBookPassage(start: range.startReference, end: range.endReference)
            if !passages.contains(passage) { passages.append(passage) }
        }
        return passages
    }

    /// `lampbible://verse/<start>[/<end>]`, the form `LampApplicationLink`
    /// parses as a verse.
    public var verseURL: URL? {
        URL(string: "lampbible://verse/\(start)" + (end.map { "/\($0)" } ?? ""))
    }
}

/// A footnote as it appears in a book's text: a marker the resolver inserted,
/// or a stretch of the book's own words that the book links to the note.
public struct LampBookFootnoteMark: Codable, Hashable, Sendable {
    public let id: String
    /// Its number in the book, or nil for a note the book doesn't list.
    public let number: Int?
    /// Whether the resolver inserted this text, rather than finding it in the
    /// book.
    public let isMarker: Bool

    public init(id: String, number: Int?, isMarker: Bool) {
        self.id = id
        self.number = number
        self.isMarker = isMarker
    }
}

/// A word in the original language: what kind the book marks it as, and its
/// Strong's key where the converter found one. Many have none, the Greek and
/// Hebrew of a commentary most of all, and are still original-language words.
public struct LampBookOriginalLanguage: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case strongs, greek, hebrew
    }

    public let kind: Kind
    public let strongs: String?

    public init(kind: Kind, strongs: String? = nil) {
        self.kind = kind
        self.strongs = strongs
    }
}

public enum LampBookFootnoteNumbering {
    /// Each footnote's number: its position among the book's footnotes,
    /// counting from 1, the first entry winning for an ID listed twice.
    ///
    /// Not the order a section cites them in. Numbered that way, every
    /// section's first footnote would be 1, and a marker's number would stop
    /// matching the book's.
    public static func numbers(for footnotes: [LampBookFootnote]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for (index, footnote) in footnotes.enumerated() where numbers[footnote.id] == nil {
            numbers[footnote.id] = index + 1
        }
        return numbers
    }
}

/// What a stretch of a book's text is, beyond what Foundation's attributes can
/// say: Foundation has no underline intent, and no notion of a citation.
public enum LampBookTextAttributes {
    /// A cited passage: the first the annotation names.
    public enum Scripture: CodableAttributedStringKey {
        public typealias Value = LampBookPassage
        public static let name = "LampBookScripture"
    }

    public enum Footnote: CodableAttributedStringKey {
        public typealias Value = LampBookFootnoteMark
        public static let name = "LampBookFootnote"
    }

    public enum OriginalLanguage: CodableAttributedStringKey {
        public typealias Value = LampBookOriginalLanguage
        public static let name = "LampBookOriginalLanguage"
    }

    /// Emphasis the book sets as underlining.
    public enum Underline: CodableAttributedStringKey {
        public typealias Value = Bool
        public static let name = "LampBookUnderline"
    }

    /// A page marker the resolver inserted, with the spaces it put either
    /// side, by the printed page that starts there: everything the resolver
    /// inserts can be told from the book's own text.
    public enum Page: CodableAttributedStringKey {
        public typealias Value = String
        public static let name = "LampBookPage"
    }
}

extension AttributeScopes {
    public struct LampBookAttributes: AttributeScope {
        public let bookScripture: LampBookTextAttributes.Scripture
        public let bookFootnote: LampBookTextAttributes.Footnote
        public let bookOriginalLanguage: LampBookTextAttributes.OriginalLanguage
        public let bookUnderline: LampBookTextAttributes.Underline
        public let bookPage: LampBookTextAttributes.Page
        public let foundation: AttributeScopes.FoundationAttributes
    }

    /// For converting to and from `NSAttributedString`, which drops these
    /// attributes unless it is given the scope.
    public var lampBook: LampBookAttributes.Type { LampBookAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.LampBookAttributes, T>
    ) -> T {
        self[T.self]
    }
}

/// Resolves a book's annotated text into an attributed string that says what
/// each stretch of it is, and leaves how it looks, and what tapping it does,
/// to each app. Emphasis is `inlinePresentationIntent`, a link to the web is
/// `link`, and citations, footnotes, original-language words, underlining and
/// page markers are in `LampBookAttributes`.
///
/// Offsets are Unicode scalar offsets into `text`, which is how the book
/// converters count them. Devotional content counts Characters instead
/// (`LampPortableDevotionalContent`). The two agree until a character made of
/// several scalars, a pointed Hebrew letter or a decomposed accent, comes
/// before the offset.
///
/// A span that starts before the text or past its end, or ends before it
/// starts, is left out, since styling from a bad offset to the end of a
/// paragraph is worse than not styling it; one that only ends past the text is
/// cut at its end. A footnote marker past the end goes at the end, where a
/// trailing note belongs anyway.
///
/// A page annotation becomes a marker, "[p. 12]", where the page starts,
/// spaced from the words on either side, after any footnote markers at the
/// same place: those belong to the word the last page ended on. Its number is
/// the printed page; a page printed without one carries no annotation.
public enum LampBookTextResolver {
    public static func resolve(
        _ content: LampBookAnnotatedText,
        footnoteNumbers: [String: Int]
    ) -> AttributedString {
        var value = AttributedString(content.text)
        let length = value.unicodeScalars.count

        for annotation in content.annotations {
            guard let range = span(annotation.start, annotation.end, in: value, length: length) else {
                continue
            }
            switch annotation.type {
            case "scripture":
                if let passage = LampBookPassage.passages(of: annotation).first {
                    value[range].bookScripture = passage
                }
            case "strongs", "greek", "hebrew":
                if let kind = LampBookOriginalLanguage.Kind(rawValue: annotation.type) {
                    let key = annotation.data?.strongs.flatMap { $0.isEmpty ? nil : $0 }
                    value[range].bookOriginalLanguage = LampBookOriginalLanguage(kind: kind, strongs: key)
                }
            case "link":
                if let url = annotation.data?.url.flatMap(URL.init(string:)) {
                    value[range].link = url
                }
            case "footnote":
                if let id = annotation.data?.footnoteID {
                    value[range].bookFootnote = LampBookFootnoteMark(
                        id: id, number: footnoteNumbers[id], isMarker: false
                    )
                }
            case "emphasis":
                switch annotation.data?.style {
                case "bold": addIntent(.stronglyEmphasized, to: range, in: &value)
                case "underline": value[range].bookUnderline = true
                default: addIntent(.emphasized, to: range, in: &value)
                }
            case "quote":
                addIntent(.emphasized, to: range, in: &value)
            default:
                break
            }
        }

        var markers: [(offset: Int, order: Int, text: AttributedString)] = []
        for (order, reference) in content.footnoteReferences.enumerated() {
            let number = footnoteNumbers[reference.id]
            var marker = AttributedString("[\(number.map(String.init) ?? "•")]")
            marker.bookFootnote = LampBookFootnoteMark(id: reference.id, number: number, isMarker: true)
            markers.append((min(max(reference.offset, 0), length), order, marker))
        }
        let scalars = Array(content.text.unicodeScalars)
        for (order, annotation) in content.annotations.enumerated()
        where annotation.type == "page" && annotation.start >= 0 {
            guard let page = annotation.data?.pageNumber, !page.isEmpty else { continue }
            let offset = min(annotation.start, length)
            let before = offset > 0 && !scalars[offset - 1].properties.isWhitespace ? " " : ""
            let after = offset < length && !scalars[offset].properties.isWhitespace ? " " : ""
            var marker = AttributedString("\(before)[p. \(page)]\(after)")
            marker.bookPage = page
            markers.append((offset, content.footnoteReferences.count + order, marker))
        }
        // From the end, so each offset still counts the book's own text; markers
        // at one offset keep the order the book lists them in.
        for marker in markers.sorted(by: { ($0.offset, $0.order) > ($1.offset, $1.order) }) {
            let scalars = value.unicodeScalars
            value.insert(marker.text, at: scalars.index(scalars.startIndex, offsetBy: marker.offset))
        }
        return value
    }

    private static func span(
        _ start: Int,
        _ end: Int,
        in value: AttributedString,
        length: Int
    ) -> Range<AttributedString.Index>? {
        guard start >= 0, start < length, end > start else { return nil }
        let scalars = value.unicodeScalars
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(scalars.startIndex, offsetBy: min(end, length))
        return lower..<upper
    }

    /// Adds to the emphasis already there, so bold inside italics is both.
    private static func addIntent(
        _ intent: InlinePresentationIntent,
        to range: Range<AttributedString.Index>,
        in value: inout AttributedString
    ) {
        let runs = value[range].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
        for (runRange, existing) in runs {
            value[runRange].inlinePresentationIntent = existing.union(intent)
        }
    }
}
