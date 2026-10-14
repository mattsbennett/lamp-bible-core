import Foundation

public enum LampReferenceParser {
    public static func parse(_ source: String) throws -> LampAgentReferenceRange {
        let normalized = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        guard !normalized.isEmpty else { throw LampAgentError.invalidReference(source) }

        let pieces = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = try parseCompletePoint(pieces[0], source: source)
        let end = pieces.count == 1
            ? start
            : try parseEndPoint(pieces[1], inheriting: start, source: source)
        guard sortValue(end, missingVerse: 999) >= sortValue(start, missingVerse: 1) else {
            throw LampAgentError.invalidReference(source)
        }
        return LampAgentReferenceRange(start: start, end: end)
    }

    private static func parseCompletePoint(
        _ value: String,
        source: String
    ) throws -> LampAgentReferencePoint {
        let captures = try match(#"^(.+?)\s+(\d+)(?::(\d+))?$"#, in: value)
        guard captures.count == 3,
              let book = bookNumber(for: captures[0]),
              let chapter = Int(captures[1]), (1...999).contains(chapter) else {
            throw LampAgentError.invalidReference(source)
        }
        let verse: Int?
        if captures[2].isEmpty {
            verse = nil
        } else {
            guard let value = Int(captures[2]), (1...999).contains(value) else {
                throw LampAgentError.invalidReference(source)
            }
            verse = value
        }
        return LampAgentReferencePoint(book: book, chapter: chapter, verse: verse)
    }

    private static func parseEndPoint(
        _ value: String,
        inheriting start: LampAgentReferencePoint,
        source: String
    ) throws -> LampAgentReferencePoint {
        if value.rangeOfCharacter(from: .letters) != nil {
            return try parseCompletePoint(value, source: source)
        }
        if let colon = value.firstIndex(of: ":") {
            let chapterText = value[..<colon].trimmingCharacters(in: .whitespaces)
            let verseText = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let chapter = Int(chapterText), (1...999).contains(chapter),
                  let verse = Int(verseText), (1...999).contains(verse) else {
                throw LampAgentError.invalidReference(source)
            }
            return LampAgentReferencePoint(book: start.book, chapter: chapter, verse: verse)
        }
        guard let number = Int(value), (1...999).contains(number) else {
            throw LampAgentError.invalidReference(source)
        }
        return start.verse == nil
            ? LampAgentReferencePoint(book: start.book, chapter: number)
            : LampAgentReferencePoint(book: start.book, chapter: start.chapter, verse: number)
    }

    private static func match(_ pattern: String, in value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        guard let result = expression.firstMatch(in: value, range: range),
              result.range == range else { return [] }
        return (1..<result.numberOfRanges).map { index in
            let capture = result.range(at: index)
            guard capture.location != NSNotFound,
                  let range = Range(capture, in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func sortValue(_ point: LampAgentReferencePoint, missingVerse: Int) -> Int {
        point.book * 1_000_000 + point.chapter * 1_000 + (point.verse ?? missingVerse)
    }

    public static func bookNumber(for value: String) -> Int? {
        aliases[normalizeBook(value)]
    }

    private static func normalizeBook(_ value: String) -> String {
        value.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar)) }
            return nil
        }.reduce(into: "") { $0.append($1) }
    }

    private static let aliases: [String: Int] = {
        var result: [String: Int] = [:]
        for number in 1...66 {
            result[normalizeBook(LampBibleReferenceFormatter.bookName(number))] = number
            result[normalizeBook(LampBibleReferenceFormatter.bookAbbreviation(number))] = number
        }
        let extras: [Int: [String]] = [
            1: ["Ge"], 2: ["Ex", "Exo"], 3: ["Le"], 4: ["Nu"], 5: ["Dt", "Deu"],
            6: ["Jos"], 7: ["Jdg"], 8: ["Rut"], 9: ["1 Sa", "I Samuel", "Samuel"], 10: ["2 Sa", "II Samuel"],
            11: ["1 Ki", "I Kings", "Kings"], 12: ["2 Ki", "II Kings"],
            13: ["1 Ch", "I Chronicles", "Chronicles"], 14: ["2 Ch", "II Chronicles"],
            15: ["Ezr"], 17: ["Est"], 19: ["Psalm", "Psa"], 20: ["Pro"],
            21: ["Eccles", "Ecc"], 22: ["Song of Solomon", "Canticles", "Sos", "Sng"],
            26: ["Eze"], 29: ["Joe"], 30: ["Amo"], 31: ["Oba"], 32: ["Jon"],
            36: ["Zep"], 38: ["Zec"],
            40: ["Mt", "Mat"], 41: ["Mr", "Mk", "Mrk", "Mar"], 42: ["Lk", "Luk"],
            43: ["Jn", "Joh", "Jhn"], 44: ["Act"],
            45: ["Ro"], 46: ["1 Co", "I Corinthians", "Corinthians"], 47: ["2 Co", "II Corinthians"], 50: ["Php"],
            52: ["1 Th", "I Thessalonians", "Thessalonians"], 53: ["2 Th", "II Thessalonians"],
            54: ["1 Ti", "I Timothy", "Timothy"], 55: ["2 Ti", "II Timothy"],
            56: ["Tit"], 57: ["Phm"], 59: ["Jam"],
            60: ["1 Pe", "I Peter", "Peter"], 61: ["2 Pe", "II Peter"],
            62: ["1 Jn", "1 Jo", "I John"], 63: ["2 Jn", "2 Jo", "II John"],
            64: ["3 Jn", "3 Jo", "III John"], 65: ["Jud"], 66: ["Apocalypse", "Revelations"],
        ]
        for (number, names) in extras {
            for name in names { result[normalizeBook(name)] = number }
        }
        return result
    }()
}
