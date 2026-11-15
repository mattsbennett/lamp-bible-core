import Foundation

/// Keeps a number that follows Hebrew (or other right-to-left) words in
/// English text with the English after it.
///
/// A European digit takes the direction of the last strong letter before it,
/// so in BDB's "…גֵּבִים 1Kgs 6:9" the "1" joins the Hebrew and is drawn on
/// its far side: "1 גֵּבִים Kgs 6:9". A LEFT-TO-RIGHT MARK (U+200E) in front
/// of the digit is a strong left-to-right letter of no width: the digit
/// reads as left to right, and the space before it, now between Hebrew and
/// left-to-right, takes the paragraph's direction.
///
/// The mark goes in only where a number has a right-to-left letter before it
/// and a left-to-right letter after it, in the same paragraph. Nothing else
/// changes: a number between two Hebrew words stays in their phrase, and
/// brackets, punctuation and the Hebrew's own order are drawn as they were.
/// A number that ends a paragraph after Hebrew is left alone too, since it
/// may be the Hebrew's own.
///
/// Isolating the Hebrew instead (U+2068 … U+2069) was tried first and
/// dropped: an isolate has to choose where the Hebrew stops, and wherever it
/// stops it can split a pair of brackets, reorder two parenthesised words or
/// run past the end of a paragraph, all of which drew correctly before.
///
/// This is for drawing only. A mark moves every later offset, so it goes in
/// after anything placed by the source text's offsets.
public enum LampBidiNumbers {
    public static let leftToRightMark: Unicode.Scalar = "\u{200E}"

    /// The Unicode scalar offsets in `text` that a left-to-right mark goes in
    /// front of, first to last.
    ///
    /// `tags` are markup the text carries but does not draw, such as search's
    /// `<mark>`: they are passed over as if absent. None when the text holds
    /// a directional embedding or isolate of its own, which is left to mean
    /// what it was put there to mean.
    public static func markOffsets(in text: String, ignoring tags: [String] = []) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        let hidden = hiddenOffsets(of: tags, in: scalars)

        // The first strong direction at or after each offset, up to the end
        // of its paragraph.
        var following = [Direction?](repeating: nil, count: scalars.count + 1)
        for offset in scalars.indices.reversed() {
            if hidden[offset] {
                following[offset] = following[offset + 1]
                continue
            }
            switch direction(of: scalars[offset]) {
            case .control: return []
            case .paragraphEnd: following[offset] = nil
            case .leftToRight: following[offset] = .leftToRight
            case .rightToLeft: following[offset] = .rightToLeft
            case .digit, .neutral: following[offset] = following[offset + 1]
            }
        }

        var offsets: [Int] = []
        var preceding: Direction?
        for offset in scalars.indices where !hidden[offset] {
            switch direction(of: scalars[offset]) {
            case .paragraphEnd: preceding = nil
            case .leftToRight: preceding = .leftToRight
            case .rightToLeft: preceding = .rightToLeft
            case .digit:
                if preceding == .rightToLeft, following[offset] == .leftToRight {
                    // In front of a currency or percent sign written onto
                    // the number, "$12", which the algorithm reads with its
                    // digits; between them the mark would part them.
                    // A search tag between them does not part them either.
                    var start = offset
                    var before = offset - 1
                    while before >= 0, hidden[before] || isWrittenOntoNumber(scalars[before]) {
                        if !hidden[before] { start = before }
                        before -= 1
                    }
                    offsets.append(start)
                    preceding = .leftToRight
                }
            case .neutral, .control: break
            }
        }
        return offsets
    }

    /// `text` with a left-to-right mark in front of each such number.
    public static func holdingLeftToRight(_ text: String, ignoring tags: [String] = []) -> String {
        let offsets = markOffsets(in: text, ignoring: tags)
        guard !offsets.isEmpty else { return text }
        var result = String.UnicodeScalarView()
        var marks = offsets.makeIterator()
        var next = marks.next()
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            if offset == next {
                result.append(leftToRightMark)
                next = marks.next()
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// Puts the marks into `value` in place. Each takes the attributes of the
    /// digit it stands before, so it sits inside that digit's link or colour.
    public static func holdLeftToRight(in value: inout AttributedString) {
        let offsets = markOffsets(in: String(value.characters))
        // Last first, so the offsets of those before stay good.
        for offset in offsets.reversed() {
            let scalars = value.unicodeScalars
            let digit = scalars.index(scalars.startIndex, offsetBy: offset)
            let attributes = value[digit ..< scalars.index(after: digit)].runs.first?.attributes
                ?? AttributeContainer()
            value.insert(AttributedString(String(leftToRightMark), attributes: attributes), at: digit)
        }
    }

    /// Puts the marks into `value` in place, as the `AttributedString` form
    /// does.
    public static func holdLeftToRight(in value: NSMutableAttributedString) {
        let offsets = markOffsets(in: value.string)
        guard !offsets.isEmpty else { return }
        // Scalar offsets to UTF-16 ones, which NSString counts in.
        var utf16Offsets: [Int] = []
        var wanted = offsets.makeIterator()
        var next = wanted.next()
        var utf16 = 0
        for (offset, scalar) in value.string.unicodeScalars.enumerated() {
            guard let target = next else { break }
            if offset == target {
                utf16Offsets.append(utf16)
                next = wanted.next()
            }
            utf16 += scalar.utf16.count
        }
        for location in utf16Offsets.reversed() {
            let attributes = value.attributes(at: location, effectiveRange: nil)
            value.insert(NSAttributedString(string: String(leftToRightMark), attributes: attributes), at: location)
        }
    }

    private enum Direction { case leftToRight, rightToLeft, digit, neutral, paragraphEnd, control }

    private static func direction(of scalar: Unicode.Scalar) -> Direction {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return .control
        case 0x000A, 0x000D, 0x001C...0x001E, 0x0085, 0x2029: return .paragraphEnd
        // European digits, which take the direction before them. Arabic's
        // own digits are not, and are neither letter.
        case 0x0030...0x0039, 0x00B2, 0x00B3, 0x00B9, 0x06F0...0x06F9,
             0x2070, 0x2074...0x2079, 0x2080...0x2089, 0xFF10...0xFF19: return .digit
        // Arabic script's numbers, their separators and signs: not letters.
        case 0x0600...0x0605, 0x0609, 0x060A, 0x060C, 0x0660...0x066C, 0x06DD, 0x08E2: return .neutral
        case 0xFB29: return .neutral
        case 0x200E: return .leftToRight
        case 0x200F: return .rightToLeft
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
             0x10800...0x10FFF, 0x1E800...0x1EFFF: return .rightToLeft
        default: return scalar.properties.isAlphabetic ? .leftToRight : .neutral
        }
    }

    /// A sign the algorithm takes with the digits it is written against:
    /// Unicode's European number terminators (ET), rule W5, listed from the
    /// standard rather than by general category, which counts an Afghani
    /// sign, a right-to-left letter to the algorithm, as currency. Not the
    /// separators (ES), "+" and "-": rule W4 joins one only between two
    /// digits, so before a number it stays where it was drawn.
    private static func isWrittenOntoNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0023...0x0025, 0x00A2...0x00A5, 0x00B0, 0x00B1, 0x058F, 0x0609, 0x060A, 0x066A,
             0x09F2, 0x09F3, 0x09FB, 0x0AF1, 0x0BF9, 0x0E3F, 0x17DB, 0x2030...0x2034,
             0x20A0...0x20CF, 0x212E, 0x2213, 0xA838, 0xA839, 0xFE5F, 0xFE69, 0xFE6A,
             0xFF03...0xFF05, 0xFFE0, 0xFFE1, 0xFFE5, 0xFFE6, 0x11FDD...0x11FE0, 0x1E2FF:
            return true
        default:
            return false
        }
    }

    /// Which scalars belong to one of `tags`, matched whole.
    private static func hiddenOffsets(of tags: [String], in scalars: [Unicode.Scalar]) -> [Bool] {
        var hidden = [Bool](repeating: false, count: scalars.count)
        let patterns = tags.map { Array($0.unicodeScalars) }.filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return hidden }
        var offset = 0
        while offset < scalars.count {
            if let pattern = patterns.first(where: {
                offset + $0.count <= scalars.count && Array(scalars[offset ..< offset + $0.count]) == $0
            }) {
                for covered in offset ..< offset + pattern.count { hidden[covered] = true }
                offset += pattern.count
            } else {
                offset += 1
            }
        }
        return hidden
    }
}
