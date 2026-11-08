import Foundation

/// A stretch of a dictionary sense's text set apart: bold, italic, or a run
/// of Greek or Hebrew.
///
/// Offsets count Unicode scalars in the field's text as `LampDictionarySense`
/// gives it — trimmed, and with a field's paragraphs joined — not in the
/// module's raw text, so an app applies them as they are.
public struct LampDictionaryStyle: Hashable, Sendable {
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case gloss, shortDefinition, definition, derivation, usage
    }

    public enum Kind: String, Hashable, Sendable {
        case bold, italic, greek, hebrew
    }

    public let field: Field
    public let kind: Kind
    public let start: Int
    public let end: Int

    public init(field: Field, kind: Kind, start: Int, end: Int) {
        self.field = field
        self.kind = kind
        self.start = start
        self.end = end
    }
}

enum LampDictionaryStyles {
    /// The field names a sense's JSON may use for each field, in the order
    /// `LampLibrary` reads them, so a style lands on the text that was shown.
    static let fieldKeys: [(LampDictionaryStyle.Field, [String])] = [
        (.gloss, ["gloss"]),
        (.shortDefinition, ["shortDefinition", "short_definition"]),
        (.definition, ["definition", "def"]),
        (.derivation, ["derivation"]),
        (.usage, ["usage"]),
    ]

    /// Every style a sense's fields carry, placed on the text the sense shows.
    static func styles(in sense: [String: Any]) -> [LampDictionaryStyle] {
        fieldKeys.flatMap { field, keys -> [LampDictionaryStyle] in
            guard let value = keys.lazy.compactMap({ sense[$0] }).first(where: { !($0 is NSNull) }),
                  let shown = LampModuleText.plainText(from: value) else { return [] }
            return styles(of: field, in: value, shown: shown)
        }
    }

    /// A field is a string, one annotated text, or a list of either, shown
    /// joined by a blank line. Each annotated text is placed at its own
    /// distance into what is shown.
    private static func styles(
        of field: LampDictionaryStyle.Field,
        in value: Any,
        shown: String
    ) -> [LampDictionaryStyle] {
        let shownScalars = Array(shown.unicodeScalars)
        var segments: [(object: [String: Any], offset: Int)] = []
        if let object = value as? [String: Any] {
            segments = [(object, 0)]
        } else if let values = value as? [Any] {
            var offset = 0
            for element in values {
                guard let text = LampModuleText.plainText(from: element) else { continue }
                if let object = element as? [String: Any] { segments.append((object, offset)) }
                offset += text.unicodeScalars.count + 2
            }
        }
        return segments.flatMap { segment in
            placed(in: segment.object, at: segment.offset, field: field, shown: shownScalars)
        }
    }

    private static func placed(
        in object: [String: Any],
        at offset: Int,
        field: LampDictionaryStyle.Field,
        shown: [Unicode.Scalar]
    ) -> [LampDictionaryStyle] {
        guard let raw = object["text"] as? String,
              let annotations = object["annotations"] as? [Any] else { return [] }
        // What the shown text dropped from the front of this one.
        let trimmed = raw.unicodeScalars.prefix {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }.count
        let rawScalars = Array(raw.unicodeScalars)
        return annotations.compactMap { value -> LampDictionaryStyle? in
            guard let annotation = value as? [String: Any],
                  let kind = kind(of: annotation),
                  let start = (annotation["start"] as? NSNumber)?.intValue,
                  let end = (annotation["end"] as? NSNumber)?.intValue,
                  start >= 0, end > start else { return nil }
            // The module's own words for the stretch, which a count in
            // another unit — graphemes, UTF-16 — would miss on pointed
            // Hebrew. Without them, the offsets are all there is to go on.
            let expected: [Unicode.Scalar] = (annotation["text"] as? String).map { Array($0.unicodeScalars) }
                ?? (end <= rawScalars.count ? Array(rawScalars[start..<end]) : [])
            guard !expected.isEmpty else { return nil }
            let at = offset + start - trimmed
            if let range = match(expected, in: shown, near: at) {
                return LampDictionaryStyle(field: field, kind: kind, start: range.lowerBound, end: range.upperBound)
            }
            return nil
        }
    }

    private static func kind(of annotation: [String: Any]) -> LampDictionaryStyle.Kind? {
        switch annotation["type"] as? String {
        case "emphasis":
            let style = (annotation["data"] as? [String: Any])?["style"] as? String
            switch style {
            case "bold": return .bold
            case "italic", nil: return .italic
            default: return nil
            }
        case "hebrew": return .hebrew
        case "greek": return .greek
        default: return nil
        }
    }

    /// Where `expected` is in `shown`: at `position` if it is there, else the
    /// occurrence nearest it. Nearest, not first, because a gloss word such as
    /// "cover" can recur, and the offset still says roughly where it was meant.
    private static func match(
        _ expected: [Unicode.Scalar],
        in shown: [Unicode.Scalar],
        near position: Int
    ) -> Range<Int>? {
        let length = expected.count
        guard length <= shown.count else { return nil }
        func holds(_ start: Int) -> Bool {
            start >= 0 && start + length <= shown.count && Array(shown[start..<start + length]) == expected
        }
        if holds(position) { return position..<position + length }
        var best: Int?
        for start in 0...(shown.count - length) where holds(start) {
            if best.map({ abs(start - position) < abs($0 - position) }) ?? true { best = start }
        }
        return best.map { $0..<$0 + length }
    }
}
