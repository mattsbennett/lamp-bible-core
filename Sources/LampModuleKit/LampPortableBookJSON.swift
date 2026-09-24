import Foundation

public struct LampDecodedBookItems<Element> {
    public let items: [Element]
    public let discardedCount: Int

    public init(items: [Element], discardedCount: Int) {
        self.items = items
        self.discardedCount = discardedCount
    }
}

/// Decodes portable book arrays one entry at a time, so a newer or malformed
/// entry cannot erase the rest of a chapter on either platform.
public enum LampPortableBookJSON {
    public static func decodeArray<Element: Decodable>(
        _ json: String?, as type: Element.Type
    ) -> LampDecodedBookItems<Element> {
        guard let json else { return LampDecodedBookItems(items: [], discardedCount: 0) }
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return LampDecodedBookItems(items: [], discardedCount: 1)
        }
        let decoder = JSONDecoder()
        var items: [Element] = []
        var discarded = 0
        for value in values {
            guard JSONSerialization.isValidJSONObject(value),
                  let itemData = try? JSONSerialization.data(withJSONObject: value),
                  let item = try? decoder.decode(Element.self, from: itemData) else {
                discarded += 1
                continue
            }
            items.append(item)
        }
        return LampDecodedBookItems(items: items, discardedCount: discarded)
    }

    public static func isSafeFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.hasPrefix("/"), !filename.contains("/"),
              !filename.contains("\\") else { return false }
        return (filename as NSString).lastPathComponent == filename
    }

    /// Returns a safe relative media path, including legacy nested book media
    /// folders. Module identifiers still use the stricter flat-name rule.
    public static func safeRelativeMediaPath(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !decoded.hasPrefix("/"), !decoded.contains("\\"),
              !components.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        return components.map(String.init).joined(separator: "/")
    }
}
