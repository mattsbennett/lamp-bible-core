import Foundation
import LampModuleKit

/// The book information needed to format a passage for another Bible app.
public struct LampExternalBibleBook: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let osisID: String
    /// The USFM code, such as `JHN`, where it is known.
    ///
    /// Most of these apps take an OSIS identifier; YouVersion takes USFM, and
    /// the two differ for most books — `John` against `JHN`, `Ps` against
    /// `PSA`. Empty means unknown, and a link that needs it falls back to the
    /// OSIS identifier rather than building a reference out of nothing.
    public let usfmCode: String

    public init(number: Int, name: String, osisID: String, usfmCode: String = "") {
        self.number = number
        self.name = name
        self.osisID = osisID
        self.usfmCode = usfmCode
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
        // A reading of whole chapters ends at verse 999, which is how a
        // reference says "to the end of the chapter" rather than a verse
        // anybody has. Passed on as a verse number it asks another app for
        // verse 999, and a plan's daily reading is usually whole chapters.
        let wholeChapters = start.verse == 1 && end.verse == 999
        let sameChapter = start.book == end.book && start.chapter == end.chapter
        let path: String
        switch self {
        case .accordance:
            if wholeChapters {
                path = sameChapter
                    ? "\(startBook.osisID)_\(start.chapter)"
                    : "\(startBook.osisID)_\(start.chapter)-\(endBook.osisID)_\(end.chapter)"
            } else {
                path = "\(startBook.osisID)_\(start.chapter):\(start.verse)-\(endBook.osisID)_\(end.chapter):\(end.verse)"
            }
        case .eSword:
            path = "\(startName).\(start.chapter):\(start.verse)"
        case .logos:
            path = "\(startName)\(start.chapter):\(start.verse)"
        case .oliveTree:
            path = "\(start.book).\(start.chapter).\(start.verse)"
        case .youVersion:
            // USFM, not OSIS: YouVersion's references are JHN.3.16, and an
            // OSIS "John.3.16" takes it somewhere else or nowhere.
            let youVersionBook = startBook.usfmCode.isEmpty
                ? startBook.osisID
                : startBook.usfmCode
            path = sameChapter && !wholeChapters
                ? "\(youVersionBook).\(start.chapter).\(start.verse)-\(end.verse)"
                : "\(youVersionBook).\(start.chapter)"
        }
        return URL(string: urlRoot + path)
    }

    public static func canonicalBook(_ number: Int) -> LampExternalBibleBook? {
        guard (1...66).contains(number) else { return nil }
        return LampExternalBibleBook(
            number: number,
            name: LampBibleReferenceFormatter.bookName(number),
            osisID: LampBibleReferenceFormatter.bookAbbreviation(number),
            usfmCode: LampCanonicalBooks.book(number)?.usfmCode ?? ""
        )
    }
}
