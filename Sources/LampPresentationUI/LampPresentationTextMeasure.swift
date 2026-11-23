import CoreGraphics
import CoreText
import Foundation
import LampCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// How large a line or a passage of text draws, measured with CoreText in the
/// deck's typeface, for a figure that must reserve room before SwiftUI lays
/// it out: a zoomed timeline's dates and events, whose frames are fixed so
/// nothing moves as the view zooms, and a map's names.
///
/// A count of characters guessed at widths that held for Latin dates and fell
/// far short for Chinese ones, and at heights that cut a long event short.
enum LampPresentationTextMeasure {
    /// The font the canvas draws `family` in at `size`: the same family, the
    /// same system design for Lamp's own styles, and the same smallest size
    /// (`floor`), or what is measured is not what is drawn.
    static func font(family: String?, size: CGFloat, bold: Bool, floor: CGFloat = 10) -> CTFont {
        let size = max(size, floor)
        let named = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch named {
        case nil, "", "system-sans", "system-serif", "system-rounded":
            return systemFont(size: size, bold: bold, design: named ?? "system-rounded")
        case .some(let name):
            let base = CTFontCreateWithName(name as CFString, size, nil)
            guard bold else { return base }
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        }
    }

    private static func systemFont(size: CGFloat, bold: Bool, design: String) -> CTFont {
        #if canImport(AppKit)
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let wanted: NSFontDescriptor.SystemDesign = switch design {
        case "system-serif": .serif
        case "system-sans": .default
        default: .rounded
        }
        let descriptor = base.fontDescriptor.withDesign(wanted) ?? base.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #elseif canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let wanted: UIFontDescriptor.SystemDesign = switch design {
        case "system-serif": .serif
        case "system-sans": .default
        default: .rounded
        }
        let descriptor = base.fontDescriptor.withDesign(wanted) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #else
        return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
        #endif
    }

    /// The size `runs` draw at, each in bold where it is marked or where
    /// `bold`, wrapped to `width` where one is given, with `lineSpacing`
    /// between lines as the slide sets it.
    static func size(
        _ runs: [LampPresentationTextRun],
        family: String?,
        size: CGFloat,
        bold: Bool,
        width: CGFloat? = nil,
        lineSpacing: CGFloat = 0,
        floor: CGFloat = 10
    ) -> CGSize {
        guard runs.contains(where: { !$0.text.isEmpty }), size > 0 else { return .zero }
        var spacing = lineSpacing
        let paragraph = withUnsafeBytes(of: &spacing) { pointer in
            let settings = [CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment,
                valueSize: MemoryLayout<CGFloat>.size,
                value: pointer.baseAddress!
            )]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let string = CFAttributedStringCreateMutable(nil, 0)!
        for run in runs where !run.text.isEmpty {
            let start = CFAttributedStringGetLength(string)
            CFAttributedStringReplaceString(string, CFRange(location: start, length: 0), run.text as CFString)
            let range = CFRange(location: start, length: CFAttributedStringGetLength(string) - start)
            let font = font(family: family, size: size, bold: bold || run.mark != nil, floor: floor)
            CFAttributedStringSetAttribute(string, range, kCTFontAttributeName, font)
            CFAttributedStringSetAttribute(string, range, kCTParagraphStyleAttributeName, paragraph)
        }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            setter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    /// The size plain `text` draws at.
    static func size(
        _ text: String,
        family: String?,
        size: CGFloat,
        bold: Bool,
        width: CGFloat? = nil,
        lineSpacing: CGFloat = 0,
        floor: CGFloat = 10
    ) -> CGSize {
        Self.size(
            [LampPresentationTextRun(text: text, mark: nil)], family: family, size: size, bold: bold,
            width: width, lineSpacing: lineSpacing, floor: floor
        )
    }

    /// The most characters a line of `text` must keep together: the longest
    /// run between spaces, where each Chinese or Japanese character, which a
    /// line may break after, counts alone.
    static func longestUnbreakable(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character.isWhitespace {
                current = 0
            } else if character.unicodeScalars.contains(where: breaksAround) {
                current = 0
                longest = max(longest, 1)
            } else {
                current += 1
                longest = max(longest, current)
            }
        }
        return longest
    }

    private static func breaksAround(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic
            || (0x3040...0x30FF).contains(scalar.value)  // Hiragana and Katakana
            || (0x3000...0x303F).contains(scalar.value)  // CJK punctuation
            || (0xFF00...0xFFEF).contains(scalar.value)  // Full-width forms
    }
}
