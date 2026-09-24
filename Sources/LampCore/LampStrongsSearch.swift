import Foundation

/// Strong's matching and range marking for translation annotations on both platforms.
public enum LampStrongsSearch {
    public static func sqlLikePattern(for key: String) -> String {
        "%\"strongs\":%\"\(key.trimmingCharacters(in: .whitespacesAndNewlines))\"%"
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
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let length = text.count
        let ranges = annotations.compactMap { annotation -> (start: Int, end: Int)? in
            let value = (annotation["data"] as? [String: Any])?["strongs"]
                ?? annotation["strongs"]
            guard let strongs = value as? String, strongs.uppercased() == normalized,
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
