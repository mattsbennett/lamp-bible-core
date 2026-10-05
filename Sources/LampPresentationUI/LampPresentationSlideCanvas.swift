import LampCore
import SwiftUI

/// Renders one semantic slide at any size, on every platform.
///
/// The deck format carries content roles, never geometry, so this canvas owns
/// every typographic and spatial decision. Sizes are expressed against a fixed
/// 1,600 × 900 (or 1,200 × 900) design grid and scaled by `unit`, which keeps a
/// full-screen presenter, an editor preview, and a remote thumbnail visually
/// identical rather than merely similar.
/// Everything the canvas needs about a deck to draw one of its slides.
///
/// The presentation remote receives a theme and an aspect ratio without the
/// deck they belong to, so the renderer asks for these rather than for a whole
/// document.
public struct LampPresentationSlideStyle: Equatable, Sendable {
    public var theme: LampPresentationTheme
    public var aspectRatio: LampPresentationAspectRatio

    public init(
        theme: LampPresentationTheme,
        aspectRatio: LampPresentationAspectRatio
    ) {
        self.theme = theme
        self.aspectRatio = aspectRatio
    }

    public init(deck: LampPresentationDeck) {
        self.init(theme: deck.theme, aspectRatio: deck.aspectRatio)
    }
}

public struct LampPresentationSlideCanvas: View {
    public let slide: LampPresentationSlide
    public let style: LampPresentationSlideStyle

    /// Thumbnail rendering: clamps type to a legible floor and truncates long
    /// bodies instead of shrinking them past readability.
    public var compact: Bool

    public init(
        slide: LampPresentationSlide,
        style: LampPresentationSlideStyle,
        compact: Bool = false
    ) {
        self.slide = slide
        self.style = style
        self.compact = compact
    }

    public init(
        slide: LampPresentationSlide,
        deck: LampPresentationDeck,
        compact: Bool = false
    ) {
        self.init(slide: slide, style: .init(deck: deck), compact: compact)
    }

    private var foreground: Color { Color(lampDeckHex: style.theme.foregroundColor) ?? .white }
    private var accent: Color { Color(lampDeckHex: style.theme.accentColor) ?? .orange }
    private var background: Color { Color(lampDeckHex: style.theme.backgroundColor) ?? .black }

    public var body: some View {
        GeometryReader { geometry in
            let unit = min(
                geometry.size.width / (style.aspectRatio == .widescreen ? 1_600 : 1_200),
                geometry.size.height / 900
            )
            ZStack {
                background
                slideContent(unit: unit)
                    .padding(.horizontal, 96 * unit)
                    .padding(.vertical, 72 * unit)
            }
            .clipped()
        }
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Spoken as the slide reads: its title, then the content beneath it, so a
    /// VoiceOver listener follows the same thread as the room.
    private var accessibilityDescription: String {
        let spoken = slide.blocks.compactMap { block -> String? in
            if block.kind == .image {
                let described = block.altText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return described?.isEmpty == false ? described : "Image"
            }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return spoken.isEmpty ? slide.displayTitle : spoken.joined(separator: ". ")
    }

    @ViewBuilder
    private func slideContent(unit: CGFloat) -> some View {
        switch slide.layout {
        case .title, .closing:
            VStack(spacing: 24 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 76 * unit, weight: .bold, alignment: .center)
                }
                if let subtitle = block(for: .subtitle) ?? block(for: .body) {
                    slideBlockText(
                        subtitle,
                        size: 32 * unit,
                        weight: .regular,
                        alignment: .center,
                        color: accent
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .titleAndBody:
            VStack(alignment: .leading, spacing: 34 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 58 * unit, weight: .bold)
                    Rectangle().fill(accent).frame(width: 120 * unit, height: 6 * unit)
                }
                if let body = block(for: .body) ?? firstContentBlock {
                    slideBlockText(body, size: 32 * unit, weight: .regular)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .scripture, .quotation:
            VStack(alignment: .leading, spacing: 30 * unit) {
                if let quotation = block(for: slide.layout == .scripture ? .scripture : .quotation)
                    ?? block(for: .body) ?? firstContentBlock {
                    slideBlockText(quotation, size: 42 * unit, weight: .regular)
                }
                if let citation = block(for: .citation) {
                    slideBlockText(citation, size: 25 * unit, weight: .medium, color: accent)
                }
            }
            .padding(.leading, 34 * unit)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * unit)
                    .fill(accent)
                    .frame(width: 6 * unit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .twoColumn:
            VStack(alignment: .leading, spacing: 28 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 52 * unit, weight: .bold)
                }
                let columns = slide.blocks.filter { $0.kind == .body && !$0.text.isEmpty }
                HStack(alignment: .top, spacing: 50 * unit) {
                    slideBlockText(
                        columns.first ?? LampPresentationBlock(kind: .body, text: "First idea"),
                        size: 29 * unit,
                        weight: .regular
                    )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 2 * unit)
                    slideBlockText(
                        columns.dropFirst().first
                            ?? LampPresentationBlock(kind: .body, text: "Second idea"),
                        size: 29 * unit,
                        weight: .regular
                    )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .image:
            VStack(spacing: 22 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 48 * unit, weight: .bold)
                }
                RoundedRectangle(cornerRadius: 18 * unit)
                    .fill(foreground.opacity(0.09))
                    .overlay {
                        VStack(spacing: 10 * unit) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 70 * unit, weight: .light))
                            Text(slide.blocks.first { $0.kind == .image }?.assetPath ?? "Image")
                                .font(.system(size: 20 * unit))
                                .lineLimit(1)
                        }
                        .foregroundStyle(foreground.opacity(0.7))
                    }
                if let caption = block(for: .caption) {
                    slideBlockText(caption, size: 22 * unit, weight: .regular, alignment: .center)
                }
            }

        case .blank:
            VStack(alignment: .leading, spacing: 18 * unit) {
                ForEach(slide.blocks) { block in
                    if block.kind != .image {
                        slideBlockText(block, size: 31 * unit, weight: .regular)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func block(for kind: LampPresentationBlockKind) -> LampPresentationBlock? {
        slide.blocks.first { $0.kind == kind && !$0.text.isEmpty }
    }

    private var firstContentBlock: LampPresentationBlock? {
        slide.blocks.first { ![.title, .subtitle, .image].contains($0.kind) && !$0.text.isEmpty }
    }

    @ViewBuilder
    private func slideBlockText(
        _ block: LampPresentationBlock,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment = .leading,
        color: Color? = nil
    ) -> some View {
        if let listStyle = block.listStyle,
           block.kind == .body,
           !listItems(in: block.text).isEmpty {
            let items = listItems(in: block.text)
            VStack(alignment: .leading, spacing: size * 0.22) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: size * 0.28) {
                        Text(listMarker(for: listStyle, index: index))
                            .font(presentationFont(size: size, weight: weight))
                            .frame(
                                minWidth: size * (listStyle == .ordered ? 1.05 : 0.55),
                                alignment: .trailing
                            )
                        styledText(
                            item,
                            size: size,
                            weight: weight,
                            alignment: alignment,
                            color: color ?? foreground
                        )
                    }
                }
            }
            .foregroundStyle(color ?? foreground)
        } else {
            styledText(
                block.text,
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground
            )
        }
    }

    private func styledText(
        _ value: String,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color
    ) -> some View {
        Text(value)
            .font(presentationFont(size: size, weight: weight))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.12)
            .minimumScaleFactor(0.45)
            .lineLimit(compact ? 4 : nil)
    }

    private func presentationFont(size: CGFloat, weight: Font.Weight) -> Font {
        let resolvedSize = max(size, compact ? 4 : 10)
        switch style.theme.typeface?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "system-sans":
            return .system(size: resolvedSize, weight: weight)
        case "system-serif":
            return .system(size: resolvedSize, weight: weight, design: .serif)
        case .some(let family) where !family.isEmpty:
            return .custom(family, size: resolvedSize).weight(weight)
        default:
            return .system(size: resolvedSize, weight: weight, design: .rounded)
        }
    }

    private func listItems(in value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func listMarker(for style: LampPresentationListStyle, index: Int) -> String {
        switch style {
        case .unordered: "•"
        case .ordered: "\(index + 1)."
        }
    }
}

extension Color {
    /// Deck themes store six-digit hex, validated by `LampPresentationDeckValidator`.
    /// A leading `#` is optional so hand-written decks still render.
    init?(lampDeckHex: String) {
        var value = lampDeckHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}
