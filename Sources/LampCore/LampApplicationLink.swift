import Foundation

public enum LampApplicationSection: String, Codable, Equatable, Sendable {
    case today, reader, books, plans, devotionals, quizzes, search, modules
}

/// The shared meaning of Lamp Bible links. Apps decide how to present a link;
/// parsing and reference encoding remain the same on iOS and macOS.
public enum LampApplicationLink: Equatable, Sendable {
    case verse(reference: Int, endReference: Int?, translationID: String?)
    case reading(reference: Int, endReference: Int?, openExternal: Bool)
    case strongs(String)
    case reader(reference: Int?, translationID: String?)
    case book(moduleID: String?, sectionID: String?)
    case section(LampApplicationSection)
    case moduleFile(URL)
    case dataFile(URL)

    public init?(
        url: URL,
        bookNumberForOSIS: (String) -> Int? = Self.canonicalBookNumber
    ) {
        if url.isFileURL {
            switch url.pathExtension.lowercased() {
            case "lamp": self = .moduleFile(url)
            case "json": self = .dataFile(url)
            default: return nil
            }
            return
        }
        guard url.scheme?.lowercased() == "lampbible",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let route = (url.host?.isEmpty == false
                  ? url.host : url.pathComponents.dropFirst().first)?.lowercased() else {
            return nil
        }
        let query = components.queryItems ?? []
        let translation = query.first(where: { $0.name == "translation" })?.value
        let path = url.pathComponents.filter { $0 != "/" }

        switch route {
        case "verse":
            guard let first = path.first, let reference = Int(first) else { return nil }
            let end = path.count > 1 ? Int(path[1]) : nil
            self = .verse(reference: reference, endReference: end, translationID: translation)
        case "reading":
            guard let first = path.first, let reference = Int(first) else { return nil }
            let end = path.count > 1 ? Int(path[1]) : nil
            self = .reading(
                reference: reference, endReference: end,
                openExternal: query.first(where: { $0.name == "external" })?.value == "1"
            )
        case "strongs":
            guard let key = path.first?.removingPercentEncoding, !key.isEmpty else { return nil }
            self = .strongs(key)
        case "read", "reader":
            let reference = query.first(where: { $0.name == "reference" })?.value
                .flatMap(Int.init)
            self = .reader(reference: reference.flatMap { $0 > 0 ? $0 : nil },
                           translationID: translation)
        case "book", "books":
            let moduleID = query.first(where: { $0.name == "module" })?.value
                .flatMap(Self.nonempty)
            let sectionID = query.first(where: { $0.name == "section" })?.value
                .flatMap(Self.nonempty)
            self = moduleID == nil && sectionID == nil
                ? .section(.books)
                : .book(moduleID: moduleID, sectionID: sectionID)
        default:
            if let section = LampApplicationSection(rawValue: route) {
                self = .section(section)
                return
            }
            // Legacy compact links put the chapter in the URL port. Ranges in
            // that form are not valid URLs, so new links use /reference/.
            let compact: String
            if route == "reference" {
                guard let first = path.first else { return nil }
                compact = first.lowercased()
            } else {
                compact = url.absoluteString
                    .dropFirst("lampbible://".count)
                    .split(separator: "?", maxSplits: 1)
                    .first.map(String.init)?.lowercased() ?? route
            }
            let pattern = #"^(.+?)(\d+):(\d+)(?:-(\d+))?$"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: compact, range: NSRange(compact.startIndex..., in: compact)
                  ), match.range == NSRange(compact.startIndex..., in: compact),
                  let osisRange = Range(match.range(at: 1), in: compact),
                  let chapterRange = Range(match.range(at: 2), in: compact),
                  let verseRange = Range(match.range(at: 3), in: compact),
                  let book = bookNumberForOSIS(String(compact[osisRange])),
                  let chapter = Int(compact[chapterRange]),
                  let verse = Int(compact[verseRange]) else { return nil }
            let reference = book * 1_000_000 + chapter * 1_000 + verse
            var endReference: Int?
            if match.range(at: 4).location != NSNotFound,
               let endRange = Range(match.range(at: 4), in: compact),
               let endVerse = Int(compact[endRange]), endVerse > verse {
                endReference = book * 1_000_000 + chapter * 1_000 + endVerse
            }
            self = .verse(
                reference: reference, endReference: endReference,
                translationID: translation
            )
        }
    }

    public static func verseURL(
        reference: Int,
        endReference: Int? = nil,
        translationID: String? = nil,
        osisIDForBook: (Int) -> String? = canonicalOSISID
    ) -> URL? {
        let start = LampBibleReferenceFormatter.components(of: reference)
        guard let osisID = osisIDForBook(start.book), !osisID.isEmpty else { return nil }
        var route = "\(osisID.lowercased())\(start.chapter):\(start.verse)"
        if let endReference {
            let end = LampBibleReferenceFormatter.components(of: endReference)
            if end.book == start.book, end.chapter == start.chapter, end.verse > start.verse {
                route += "-\(end.verse)"
            }
        }
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "reference"
        components.path = "/\(route)"
        if let translationID {
            components.queryItems = [URLQueryItem(name: "translation", value: translationID)]
        }
        return components.url
    }

    public static func canonicalBookNumber(_ osisID: String) -> Int? {
        let key = osisID.lowercased()
        return (1...66).first {
            LampBibleReferenceFormatter.bookAbbreviation($0).lowercased() == key
        }
    }

    public static func canonicalOSISID(_ number: Int) -> String? {
        guard (1...66).contains(number) else { return nil }
        return LampBibleReferenceFormatter.bookAbbreviation(number)
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
