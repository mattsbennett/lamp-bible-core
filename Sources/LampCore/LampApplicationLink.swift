import Foundation
import LampModuleKit

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
    /// A book, or a section in it, or a block in that section by its `id`.
    case book(moduleID: String?, sectionID: String?, anchor: String?)
    /// A commentary's note on a passage: by the passage, and where two units
    /// share it, the one whose declared ID is `unit`; at a block by `anchor`.
    case commentaryPassage(
        moduleID: String, reference: Int, endReference: Int?,
        suffix: String?, unit: String?, anchor: String?
    )
    /// A section of a commentary volume's front matter, the volume found by
    /// its Bible book.
    case commentaryFrontMatter(moduleID: String, book: Int, sectionID: String, anchor: String?)
    /// One of the person's writings, by id: what a link between imported
    /// writings becomes.
    case writing(id: String)
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
        case "writing":
            guard let id = path.first?.removingPercentEncoding, !id.isEmpty else { return nil }
            self = .writing(id: id)
        case "book", "books":
            guard let link = Self.book(components.percentEncodedQueryItems ?? []) else { return nil }
            self = link
        case "commentary":
            guard let link = Self.place(components.percentEncodedQueryItems ?? [], kind: "commentary") else { return nil }
            self = link
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

    /// Where a link annotation's target goes, read in a module of
    /// `containingKind` whose ID is `containingModuleID`: the module the
    /// target names, or that one when it names none. Nil for a target that
    /// names no single place (`LampLinkTarget.destination(in:)`).
    public init?(target: LampLinkTarget, containingKind: String, containingModuleID: String) {
        guard let destination = target.destination(in: containingKind),
              // As given: a declared ID may hold spaces, and trimmed it would
              // name another module. Found by Codex.
              let moduleID = target.module ?? (containingModuleID.isEmpty ? nil : containingModuleID)
        else { return nil }
        switch destination {
        case .commentaryPassage(let start, let end, let suffix, let unit, let anchor):
            self = .commentaryPassage(
                moduleID: moduleID, reference: start, endReference: end,
                suffix: suffix, unit: unit, anchor: anchor
            )
        case .commentaryFrontMatter(let book, let section, let anchor):
            self = .commentaryFrontMatter(moduleID: moduleID, book: book, sectionID: section, anchor: anchor)
        case .bookSection(let section, let anchor):
            self = .book(moduleID: moduleID, sectionID: section, anchor: anchor)
        }
    }

    /// `lampbible://commentary?…` and `lampbible://book?…`, which open a
    /// place in a module: what `init?(url:)` reads back as this link. Nil for
    /// any other link, and for a place no URL reads back as.
    public var placeURL: URL? {
        let items: [(String, String?)]
        let route: String
        switch self {
        case .book(let moduleID, let sectionID, let anchor):
            route = "book"
            items = [("module", moduleID), ("section", sectionID), ("anchor", sectionID == nil ? nil : anchor)]
        case .commentaryPassage(let moduleID, let reference, let endReference, let suffix, let unit, let anchor):
            route = "commentary"
            items = [
                ("module", moduleID), ("sv", String(reference)), ("ev", endReference.map(String.init)),
                ("suffix", suffix), ("unit", unit), ("anchor", anchor),
            ]
        case .commentaryFrontMatter(let moduleID, let book, let sectionID, let anchor):
            route = "commentary"
            items = [("module", moduleID), ("book", String(book)), ("section", sectionID), ("anchor", anchor)]
        default:
            return nil
        }
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = route
        // Encoded here rather than by `queryItems`, which leaves `&`, `=`
        // and `+` in a value as they are, so an ID holding one would read
        // back as another parameter or a space.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let query = items.compactMap { name, value in
            value.flatMap { $0.isEmpty ? nil : $0 }.map {
                "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)"
            }
        }
        components.percentEncodedQuery = query.isEmpty ? nil : query.joined(separator: "&")
        // Only a URL that reads back as this link: a case can be built that
        // none does — a book naming neither book nor section reads as the
        // shelf, a passage ending before it begins as nothing. Found by
        // Codex.
        guard let url = components.url, LampApplicationLink(url: url) == self else { return nil }
        return url
    }

    /// A commentary place from its parameters, under the rules a link
    /// target's are read by (`LampLinkTarget.destination(in:)`): one route,
    /// a real passage or Bible book, and a number given as one. Nil for any
    /// other: a link written wrong opens nothing rather than somewhere near.
    /// A book link. With an anchor it is a place (`place(_:kind:)`), so
    /// with one route and a module named, as a target is; without, it is
    /// read as it always was — a module, a section, both, or neither for the
    /// shelf — but never beside a commentary's selector, which a target in a
    /// book refuses. Found by Codex.
    private static func book(_ encoded: [URLQueryItem]) -> LampApplicationLink? {
        // Given empty or with no value, a module or a section is none here,
        // as it always was: `section=` and `section` opened the book. Found
        // by Codex.
        guard let parameters = placeParameters(
            encoded, emptyIsNone: ["suffix", "module", "section"], valuelessIsNone: ["module", "section"]
        ) else { return nil }
        if parameters["anchor"] != nil { return place(encoded, kind: "book") }
        guard parameters.keys.allSatisfy(["module", "section"].contains) else { return nil }
        let moduleID = parameters["module"], sectionID = parameters["section"]
        return moduleID == nil && sectionID == nil
            ? .section(.books)
            : .book(moduleID: moduleID, sectionID: sectionID, anchor: nil)
    }

    /// A place in a module of `kind`, read as the link target it writes: its
    /// parameters are a target's fields, and the target says where it goes,
    /// so a URL and a target cannot disagree — three reviews in turn found
    /// a route reading its own way. A module must be named: a link outside
    /// every module has none to stand in. Nil for any written wrong.
    private static func place(_ encoded: [URLQueryItem], kind: String) -> LampApplicationLink? {
        guard let parameters = placeParameters(encoded), let moduleID = parameters["module"] else { return nil }
        func number(_ name: String) -> Int?? {
            guard let text = parameters[name] else { return .some(nil) }
            return Int(text).map { .some($0) }
        }
        guard let start = number("sv"), let end = number("ev"), let book = number("book") else { return nil }
        let target = LampLinkTarget(
            kind: kind, module: moduleID,
            startReference: start, endReference: end,
            suffix: parameters["suffix"], unit: parameters["unit"],
            book: book, section: parameters["section"], anchor: parameters["anchor"]
        )
        return LampApplicationLink(target: target, containingKind: kind, containingModuleID: moduleID)
    }

    /// Every field a link target has, by its name in JSON and in a URL.
    private static let targetFields = ["module", "sv", "ev", "suffix", "unit", "book", "section", "anchor"]

    /// A place link's parameters, read as a link target's fields are read
    /// from JSON (`LampLinkTarget.init(from:)`): each exactly as written,
    /// spaces and all, and nil for a link with any written wrong — given
    /// empty (but where `emptyIsNone`: a suffix, whose empty is none as the
    /// compiler stores it), without a value (but where `valuelessIsNone`),
    /// twice differently, byte for byte, or with a name or a value that does
    /// not decode. Read loosely — trimmed, an empty one as none, a second
    /// ignored — a link opened another note at the same passage or another
    /// section, over several reviews; `LampApplicationLinkTests` holds the
    /// URL and the JSON to the same answers. Found by Codex.
    ///
    /// From the query as written, still encoded, and decoded here: decoded
    /// by Foundation, a name that does not decode (`an%FFchor`) is empty and
    /// one of its values nil, as if given without one, so the field was
    /// passed over as not given. Found by Codex.
    private static func placeParameters(
        _ encoded: [URLQueryItem], emptyIsNone: Set<String> = ["suffix"], valuelessIsNone: Set<String> = []
    ) -> [String: String]? {
        var decoded: [(name: String, value: String?)] = []
        for item in encoded {
            guard let name = item.name.removingPercentEncoding else { return nil }
            if let value = item.value {
                guard let value = value.removingPercentEncoding else { return nil }
                decoded.append((name, value))
            } else {
                decoded.append((name, nil))
            }
        }
        var parameters: [String: String] = [:]
        for name in targetFields {
            let given = decoded.filter { $0.name == name }.map(\.value)
            guard let first = given.first else { continue }
            if valuelessIsNone.contains(name), given.allSatisfy({ $0 == nil }) { continue }
            // By bytes: `String` equality takes "Café" in two spellings as
            // one, which a module ID looked up in SQLite is not. Found by
            // Codex.
            guard let value = first, given.allSatisfy({ $0.map { Array($0.utf8) } == Array(value.utf8) })
            else { return nil }
            if value.isEmpty {
                guard emptyIsNone.contains(name) else { return nil }
                continue
            }
            parameters[name] = value
        }
        return parameters
    }

    /// `lampbible://writing/<id>`, which opens one of the person's writings.
    public static func writingURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "writing"
        components.path = "/" + id
        return components.url ?? URL(string: "lampbible://writing")!
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
}
