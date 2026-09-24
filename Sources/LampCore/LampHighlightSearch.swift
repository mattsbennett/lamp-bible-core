import Foundation

public enum LampHighlightSearch {
    public static func normalizedColor(_ color: String?) -> String {
        let value = color?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        return value?.isEmpty == false ? value! : "FFCC00"
    }

    public static func matchesColor(_ color: String?, in selectedColors: Set<String>?) -> Bool {
        guard let selectedColors, !selectedColors.isEmpty else { return true }
        let normalized = Set(selectedColors.map { normalizedColor($0) })
        return normalized.contains(normalizedColor(color))
    }

    public static func markedSnippet(
        text: String, startOffset: Int, endOffset: Int
    ) -> String {
        guard startOffset >= 0, endOffset > startOffset,
              endOffset <= text.count else { return "<mark>\(text)</mark>" }
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return "<mark>\(text[start..<end])</mark>"
    }
}
