import Foundation

/// Strong's matching and range marking for translation annotations on both platforms.
public enum LampStrongsSearch {
    /// A verse whose tags carry `key` written exactly so. It misses a key
    /// written padded ("G0026") and one listed with others under a word
    /// ("G3588,G2316"); `sqlPrefilterPattern` with `holdsKey` finds both.
    public static func sqlLikePattern(for key: String) -> String {
        "%\"strongs\":%\"\(key.trimmingCharacters(in: .whitespacesAndNewlines))\"%"
    }

    /// A LIKE pattern for the annotations of every verse that might tag
    /// `key`, however it is written, to be confirmed with `holdsKey`: the
    /// key's number, which any of its forms contains. It also matches every
    /// verse whose offsets hold that number, which `sqlPrefilter` does not.
    public static func sqlPrefilterPattern(for key: String) -> String {
        let digits = LampStrongsKey.normalized(key).filter { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? "%\"strongs\"%" : "%\(digits)%"
    }

    /// A LIKE condition on `column` for the annotations of every verse that
    /// might tag `key`, to be confirmed with `holdsKey`: its letter and
    /// number, plain or padded to five digits ("G26", "G026" … "G00026").
    ///
    /// The number alone also matched every verse whose offsets held it, as
    /// `"start":26` does, so G26 read 12,494 of the KJV's verses in full to
    /// find the 106 that hold it; with its letter it reads 727. A bare number
    /// names no letter and falls back to the number alone.
    public static func sqlPrefilter(for key: String, column: String) -> (condition: String, arguments: [String]) {
        let normalized = LampStrongsKey.normalized(key)
        let letters = String(normalized.prefix { $0.isLetter })
        let digits = String(normalized.dropFirst(letters.count).prefix { $0.isASCII && $0.isNumber })
        guard !letters.isEmpty, !digits.isEmpty else {
            return ("\(column) LIKE ?", [sqlPrefilterPattern(for: key)])
        }
        let forms = (digits.count...max(digits.count, 5)).map {
            "%" + letters + String(repeating: "0", count: $0 - digits.count) + digits + "%"
        }
        return ("(" + forms.map { _ in "\(column) LIKE ?" }.joined(separator: " OR ") + ")", forms)
    }

    /// Whether a verse's annotations tag `key`, read as the reader reads
    /// them: each key a tag lists on its own, padding and case aside.
    public static func holdsKey(_ annotationsJSON: String?, key: String) -> Bool {
        guard let annotationsJSON else { return false }
        var holds = false
        LampStrongsAnalyzer.forEachTag(in: annotationsJSON) { tag in
            if !holds, LampStrongsKey.matches(tag, key) { holds = true }
        }
        return holds
    }

    public static func markedText(
        _ text: String,
        annotationsJSON: String?,
        key: String
    ) -> String {
        guard let annotationsJSON,
              let data = annotationsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return text }
        let annotations: [[String: Any]]
        if let direct = json as? [[String: Any]] {
            annotations = direct
        } else if let wrapped = json as? [String: Any],
                  let values = wrapped["annotations"] as? [[String: Any]] {
            annotations = values
        } else {
            return text
        }
        let length = text.count
        let ranges = annotations.compactMap { annotation -> (start: Int, end: Int)? in
            let value = (annotation["data"] as? [String: Any])?["strongs"]
                ?? annotation["strongs"]
            guard let strongs = value as? String,
                  strongs.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" || $0.isWhitespace })
                    .contains(where: { LampStrongsKey.matches(String($0), key) }),
                  let start = annotation["start"] as? Int,
                  let end = annotation["end"] as? Int,
                  start >= 0, end > start, end <= length else { return nil }
            return (start, end)
        }.sorted { $0.start < $1.start }
        guard !ranges.isEmpty else { return text }
        var merged: [(start: Int, end: Int)] = []
        for range in ranges {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = (last.start, max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        var result = text
        for range in merged.reversed() {
            let start = result.index(result.startIndex, offsetBy: range.start)
            let end = result.index(result.startIndex, offsetBy: range.end)
            result.insert(contentsOf: "</mark>", at: end)
            result.insert(contentsOf: "<mark>", at: start)
        }
        return result
    }
}
