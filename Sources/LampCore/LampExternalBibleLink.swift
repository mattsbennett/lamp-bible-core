import Foundation

/// The book information needed to format a passage for another Bible app.
public struct LampExternalBibleBook: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let osisID: String

    public init(number: Int, name: String, osisID: String) {
        self.number = number
        self.name = name
        self.osisID = osisID
    }
}

public enum LampExternalBibleApplication: String, CaseIterable, Codable, Identifiable, Sendable {
    case accordance = "Accordance"
    case eSword = "e-Sword LT"
    case logos = "Logos"
    case oliveTree = "Olive Tree"
    case youVersion = "YouVersion"

    public var id: String { rawValue }

    public var scheme: String {
        switch self {
        case .accordance: "accord://"
        case .eSword: "e-sword://"
        case .logos: "logosres://"
        case .oliveTree: "olivetree://"
        case .youVersion: "youversion://"
        }
    }

    public var urlRoot: String {
        switch self {
        case .accordance: "accord://read/"
        case .eSword: "e-sword://"
        case .logos: "https://ref.ly/"
        case .oliveTree: "olivetree://bible/"
        case .youVersion: "youversion://bible?reference="
        }
    }

    /// Uses core's canonical 66-book catalog. Apps with installed book metadata
    /// can pass `book` so a module's own OSIS identifier remains authoritative.
    public func url(
        startReference: Int,
        endReference: Int? = nil,
        book: (Int) -> LampExternalBibleBook? = Self.canonicalBook
    ) -> URL? {
        let start = LampBibleReferenceFormatter.components(of: startReference)
        let end = LampBibleReferenceFormatter.components(of: endReference ?? startReference)
        guard let startBook = book(start.book), let endBook = book(end.book),
              !startBook.osisID.isEmpty, !endBook.osisID.isEmpty else { return nil }

        let startName = startBook.name.lowercased()
            .replacingOccurrences(of: " ", with: "")
        let path: String
        switch self {
        case .accordance:
            path = "\(startBook.osisID)_\(start.chapter):\(start.verse)-\(endBook.osisID)_\(end.chapter):\(end.verse)"
        case .eSword:
            path = "\(startName).\(start.chapter):\(start.verse)"
        case .logos:
            path = "\(startName)\(start.chapter):\(start.verse)"
        case .oliveTree:
            path = "\(start.book).\(start.chapter).\(start.verse)"
        case .youVersion:
            path = start.book == end.book && start.chapter == end.chapter
                ? "\(startBook.osisID).\(start.chapter).\(start.verse)-\(end.verse)"
                : "\(startBook.osisID).\(start.chapter)"
        }
        return URL(string: urlRoot + path)
    }

    public static func canonicalBook(_ number: Int) -> LampExternalBibleBook? {
        guard (1...66).contains(number) else { return nil }
        return LampExternalBibleBook(
            number: number,
            name: LampBibleReferenceFormatter.bookName(number),
            osisID: LampBibleReferenceFormatter.bookAbbreviation(number)
        )
    }
}
