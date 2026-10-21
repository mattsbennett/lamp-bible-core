import Foundation

/// One of the 66 books every Lamp translation is keyed to, with the
/// identifiers the formats Lamp reads use for it.
public struct LampCanonicalBook: Equatable, Sendable {
    /// 1 (Genesis) through 66 (Revelation); the book part of a BBCCCVVV reference.
    public let number: Int
    /// The OSIS book name, which is also the book `id` in translation JSON.
    public let osisID: String
    /// The three-character book code a USFM `\id` line starts with.
    public let usfmCode: String
    public let name: String

    public var testament: String { number <= 39 ? "OT" : "NT" }
}

public enum LampCanonicalBooks {
    public static let all: [LampCanonicalBook] = identifiers.enumerated().map { index, book in
        LampCanonicalBook(number: index + 1, osisID: book.osis, usfmCode: book.usfm, name: book.name)
    }

    private static let identifiers: [(osis: String, usfm: String, name: String)] = [
        ("Gen", "GEN", "Genesis"), ("Exod", "EXO", "Exodus"), ("Lev", "LEV", "Leviticus"),
        ("Num", "NUM", "Numbers"), ("Deut", "DEU", "Deuteronomy"), ("Josh", "JOS", "Joshua"),
        ("Judg", "JDG", "Judges"), ("Ruth", "RUT", "Ruth"), ("1Sam", "1SA", "1 Samuel"),
        ("2Sam", "2SA", "2 Samuel"), ("1Kgs", "1KI", "1 Kings"), ("2Kgs", "2KI", "2 Kings"),
        ("1Chr", "1CH", "1 Chronicles"), ("2Chr", "2CH", "2 Chronicles"), ("Ezra", "EZR", "Ezra"),
        ("Neh", "NEH", "Nehemiah"), ("Esth", "EST", "Esther"), ("Job", "JOB", "Job"),
        ("Ps", "PSA", "Psalms"), ("Prov", "PRO", "Proverbs"), ("Eccl", "ECC", "Ecclesiastes"),
        ("Song", "SNG", "Song of Songs"), ("Isa", "ISA", "Isaiah"), ("Jer", "JER", "Jeremiah"),
        ("Lam", "LAM", "Lamentations"), ("Ezek", "EZK", "Ezekiel"), ("Dan", "DAN", "Daniel"),
        ("Hos", "HOS", "Hosea"), ("Joel", "JOL", "Joel"), ("Amos", "AMO", "Amos"),
        ("Obad", "OBA", "Obadiah"), ("Jonah", "JON", "Jonah"), ("Mic", "MIC", "Micah"),
        ("Nah", "NAM", "Nahum"), ("Hab", "HAB", "Habakkuk"), ("Zeph", "ZEP", "Zephaniah"),
        ("Hag", "HAG", "Haggai"), ("Zech", "ZEC", "Zechariah"), ("Mal", "MAL", "Malachi"),
        ("Matt", "MAT", "Matthew"), ("Mark", "MRK", "Mark"), ("Luke", "LUK", "Luke"),
        ("John", "JHN", "John"), ("Acts", "ACT", "Acts"), ("Rom", "ROM", "Romans"),
        ("1Cor", "1CO", "1 Corinthians"), ("2Cor", "2CO", "2 Corinthians"), ("Gal", "GAL", "Galatians"),
        ("Eph", "EPH", "Ephesians"), ("Phil", "PHP", "Philippians"), ("Col", "COL", "Colossians"),
        ("1Thess", "1TH", "1 Thessalonians"), ("2Thess", "2TH", "2 Thessalonians"),
        ("1Tim", "1TI", "1 Timothy"), ("2Tim", "2TI", "2 Timothy"), ("Titus", "TIT", "Titus"),
        ("Phlm", "PHM", "Philemon"), ("Heb", "HEB", "Hebrews"), ("Jas", "JAS", "James"),
        ("1Pet", "1PE", "1 Peter"), ("2Pet", "2PE", "2 Peter"), ("1John", "1JN", "1 John"),
        ("2John", "2JN", "2 John"), ("3John", "3JN", "3 John"), ("Jude", "JUD", "Jude"),
        ("Rev", "REV", "Revelation"),
    ]

    public static func book(_ number: Int) -> LampCanonicalBook? {
        all.indices.contains(number - 1) ? all[number - 1] : nil
    }

    public static func book(usfmCode code: String) -> LampCanonicalBook? {
        byUSFMCode[code.uppercased()]
    }

    public static func book(osisID: String) -> LampCanonicalBook? {
        byOSISID[osisID] ?? book(named: osisID)
    }

    /// Matches English names and common abbreviations, ignoring case, spaces
    /// and periods: "1 Samuel", "1Sam", "1 Sam.", "Psalm", "Song of Solomon".
    public static func book(named name: String) -> LampCanonicalBook? {
        byNameKey[nameKey(name)]
    }

    private static let byUSFMCode = Dictionary(uniqueKeysWithValues: all.map { ($0.usfmCode, $0) })
    private static let byOSISID = Dictionary(uniqueKeysWithValues: all.map { ($0.osisID, $0) })

    private static let byNameKey: [String: LampCanonicalBook] = {
        var keys: [String: LampCanonicalBook] = [:]
        for book in all {
            for alias in [book.name, book.osisID, book.usfmCode] {
                keys[nameKey(alias)] = book
            }
        }
        let aliases: [String: Int] = [
            "Psalm": 19, "Psa": 19, "Song of Solomon": 22, "Songs": 22, "Canticles": 22,
            "Qoheleth": 21, "Revelations": 66, "Apocalypse": 66,
        ]
        for (alias, number) in aliases {
            keys[nameKey(alias)] = all[number - 1]
        }
        return keys
    }()

    private static func nameKey(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "." }
    }
}
